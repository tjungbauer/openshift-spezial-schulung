"""shopkit – what every ACME shop service needs, in one small module.

Edit this file in shop/common/ only, then run `make sync-common`: every
service gets its own copy, so each image stays self-contained.

It provides:
  * JSON logs (one line per request) with the request id from X-Request-ID
  * /health/started, /health/ready, /health/live
  * /info and /metrics (Prometheus)
  * fault injection (FAULT_* env vars and POST /admin/fault)
  * OpenTelemetry tracing, only when OTEL_EXPORTER_OTLP_ENDPOINT is set
  * run(): uvicorn on $PORT with a graceful shutdown of at most 20 s
"""

import asyncio
import contextvars
import hmac
import json
import logging
import os
import random
import sys
import time
import uuid
from contextlib import asynccontextmanager

from fastapi import FastAPI, Header, HTTPException, Request, Response
from fastapi.responses import JSONResponse
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest
from pydantic import BaseModel, Field
from starlette.routing import Match

VERSION = os.getenv("APP_VERSION", "0.0.0-dev")
REVISION = os.getenv("APP_REVISION", "unknown")
POD = os.getenv("HOSTNAME", "local")

# paths that are never slowed down or failed by fault injection
EXEMPT_PREFIXES = ("/health/", "/metrics", "/info", "/admin/")

request_id_var = contextvars.ContextVar("request_id", default="-")
log = logging.getLogger("shop")

REQUESTS = Counter(
    "shop_http_requests_total", "HTTP requests handled", ["method", "endpoint", "status"]
)
DURATION = Histogram(
    "shop_http_request_duration_seconds", "HTTP request duration", ["method", "endpoint"]
)


# ── logging ─────────────────────────────────────────────────────────────────


class JsonFormatter(logging.Formatter):
    """One JSON object per log line – easy to search in the cluster logging stack."""

    def __init__(self, service: str):
        super().__init__()
        self.service = service

    def format(self, record: logging.LogRecord) -> str:
        entry = {
            "time": self.formatTime(record, "%Y-%m-%dT%H:%M:%S%z"),
            "level": record.levelname.lower(),
            "service": self.service,
            "pod": POD,
            "message": record.getMessage(),
            "request_id": request_id_var.get(),
        }
        trace_id = _current_trace_id()
        if trace_id:
            entry["trace_id"] = trace_id
        entry.update(getattr(record, "fields", {}))
        if record.exc_info:
            entry["error"] = self.formatException(record.exc_info)
        return json.dumps(entry)


def setup_logging(service: str) -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter(service))
    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(os.getenv("LOG_LEVEL", "info").upper())
    logging.getLogger("httpx").setLevel(logging.WARNING)  # we log our own request line


def downstream_headers() -> dict:
    """Headers to pass on when calling another shop service."""
    return {"X-Request-ID": request_id_var.get()}


# ── fault injection ─────────────────────────────────────────────────────────


def _env_bool(name: str) -> bool:
    return os.getenv(name, "false").strip().lower() in ("1", "true", "yes", "on")


class Faults(BaseModel):
    """Demo faults. All off by default."""

    delay_ms: int = Field(0, ge=0, le=60000)  # FAULT_DELAY_MS
    error_rate: float = Field(0.0, ge=0.0, le=1.0)  # FAULT_ERROR_RATE -> 503
    startup_delay_s: float = Field(0.0, ge=0.0)  # FAULT_STARTUP_DELAY_S
    fail_ready: bool = False  # FAULT_FAIL_READY

    @classmethod
    def from_env(cls) -> "Faults":
        return cls(
            delay_ms=int(os.getenv("FAULT_DELAY_MS", "0")),
            error_rate=float(os.getenv("FAULT_ERROR_RATE", "0")),
            startup_delay_s=float(os.getenv("FAULT_STARTUP_DELAY_S", "0")),
            fail_ready=_env_bool("FAULT_FAIL_READY"),
        )


class FaultUpdate(BaseModel):
    """Body of POST /admin/fault – only the fields you send are changed."""

    delay_ms: int | None = Field(None, ge=0, le=60000)
    error_rate: float | None = Field(None, ge=0.0, le=1.0)
    fail_ready: bool | None = None


# ── the app ─────────────────────────────────────────────────────────────────


def create_app(service: str, ready_check=lambda: True, on_startup=None) -> FastAPI:
    """A FastAPI app with health, info, metrics, admin, logging and faults.

    ready_check()  -> True if the service can serve requests right now
    on_startup()   -> called once when the app starts (load data, ...)
    """
    setup_logging(service)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        app.state.started_at = time.monotonic()
        if on_startup:
            on_startup()
        log.info("started", extra={"fields": {"version": VERSION, "revision": REVISION}})
        yield
        log.info("shutting down")

    app = FastAPI(title=f"ACME shop – {service}", version=VERSION, lifespan=lifespan)
    app.state.service = service
    app.state.faults = Faults.from_env()
    app.state.started_at = time.monotonic()

    def is_started() -> bool:
        elapsed = time.monotonic() - app.state.started_at
        return elapsed >= app.state.faults.startup_delay_s

    @app.get("/health/started", tags=["health"])
    def health_started():
        if not is_started():
            return JSONResponse({"status": "starting"}, status_code=503)
        return {"status": "started"}

    @app.get("/health/ready", tags=["health"])
    def health_ready():
        if not is_started():
            return JSONResponse({"status": "starting"}, status_code=503)
        if app.state.faults.fail_ready:
            return JSONResponse({"status": "not ready", "reason": "FAULT_FAIL_READY"}, status_code=503)
        if not ready_check():
            return JSONResponse({"status": "not ready", "reason": "dependency"}, status_code=503)
        return {"status": "ready"}

    @app.get("/health/live", tags=["health"])
    def health_live():
        # never checks other services: a restart would not fix them
        return {"status": "alive"}

    @app.get("/info", tags=["info"])
    def info():
        return {"app": service, "version": VERSION, "revision": REVISION, "pod": POD}

    @app.get("/metrics", tags=["info"])
    def metrics():
        return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

    @app.post("/admin/fault", tags=["admin"])
    def admin_fault(update: FaultUpdate, authorization: str | None = Header(None)):
        token = os.getenv("ADMIN_TOKEN")
        if not token:
            raise HTTPException(404, "admin endpoint disabled (ADMIN_TOKEN not set)")
        if not hmac.compare_digest(authorization or "", f"Bearer {token}"):
            raise HTTPException(401, "invalid admin token")
        faults = app.state.faults
        for field, value in update.model_dump(exclude_none=True).items():
            setattr(faults, field, value)
        log.warning("faults changed", extra={"fields": {"faults": faults.model_dump()}})
        return faults.model_dump()

    @app.middleware("http")
    async def every_request(request: Request, call_next):
        request_id = request.headers.get("x-request-id") or uuid.uuid4().hex
        request_id_var.set(request_id)
        path = request.url.path
        endpoint = _endpoint(app, request.scope)
        faults = app.state.faults
        start = time.perf_counter()

        if path.startswith(EXEMPT_PREFIXES):
            response = await call_next(request)
        else:
            if faults.delay_ms:
                await asyncio.sleep(faults.delay_ms / 1000)
            if faults.error_rate and random.random() < faults.error_rate:
                response = JSONResponse({"detail": "injected fault (FAULT_ERROR_RATE)"}, status_code=503)
            else:
                response = await call_next(request)

        duration = time.perf_counter() - start
        REQUESTS.labels(request.method, endpoint, str(response.status_code)).inc()
        DURATION.labels(request.method, endpoint).observe(duration)

        quiet = path.startswith(("/health/", "/metrics")) and not _env_bool("LOG_HEALTH")
        log.log(
            logging.DEBUG if quiet else logging.INFO,
            "request",
            extra={
                "fields": {
                    "method": request.method,
                    "path": path,
                    "status": response.status_code,
                    "duration_ms": round(duration * 1000, 1),
                }
            },
        )
        response.headers["X-Request-ID"] = request_id
        response.headers["X-Shop-App"] = service
        response.headers["X-Shop-Version"] = VERSION
        response.headers["X-Shop-Revision"] = REVISION
        response.headers["X-Shop-Pod"] = POD
        return response

    _setup_tracing(app, service)
    return app


def _endpoint(app: FastAPI, scope) -> str:
    """The route template (/products/{product_id}) – keeps metric labels small."""
    for route in app.router.routes:
        match, _ = route.matches(scope)
        if match == Match.FULL:
            return route.path
    return "unmatched"


# ── tracing ─────────────────────────────────────────────────────────────────

_tracing_enabled = False


def _setup_tracing(app: FastAPI, service: str) -> None:
    """OpenTelemetry, off unless OTEL_EXPORTER_OTLP_ENDPOINT is set.

    W3C trace context (traceparent) is the default propagator: incoming
    headers are read by the FastAPI instrumentation, outgoing httpx calls
    get them added by the httpx instrumentation.
    """
    global _tracing_enabled
    if not os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT"):
        return
    from opentelemetry import trace
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
    from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
    from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor

    attributes = {"service.version": VERSION}
    if not os.getenv("OTEL_SERVICE_NAME"):
        attributes["service.name"] = service
    provider = TracerProvider(resource=Resource.create(attributes))
    provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
    trace.set_tracer_provider(provider)
    FastAPIInstrumentor.instrument_app(app, excluded_urls="health/,metrics")
    HTTPXClientInstrumentor().instrument()
    _tracing_enabled = True
    log.info("tracing enabled", extra={"fields": {"endpoint": os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT")}})


def _current_trace_id() -> str | None:
    if not _tracing_enabled:
        return None
    from opentelemetry import trace

    context = trace.get_current_span().get_span_context()
    return format(context.trace_id, "032x") if context.is_valid else None


# ── run ─────────────────────────────────────────────────────────────────────


def run(app: FastAPI) -> None:
    """Start uvicorn. On SIGTERM it stops accepting connections, finishes the
    running requests and exits after at most 20 seconds."""
    import uvicorn

    uvicorn.run(
        app,
        host="0.0.0.0",
        port=int(os.getenv("PORT", "8080")),
        log_config=None,  # keep our JSON logging
        access_log=False,  # the middleware logs every request
        server_header=False,
        timeout_graceful_shutdown=20,
    )
