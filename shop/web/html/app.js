// ACME shop – the whole UI in one file, no framework, no build step.
//
// Every call goes to /api/<service>/... on this host; web (nginx) proxies it.
// review is optional: without it the products simply have no stars.
// Each backend answers with X-Shop-Version / -Revision / -Pod headers – the
// footer shows them, so you can watch load balancing and rolling updates.
"use strict";

const SERVICES = ["web", "catalog", "cart", "orders", "review"];
const POLL_MS = 2000;
const money = new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" });
const $ = (selector) => document.querySelector(selector);

const state = {
  products: new Map(),           // id -> product
  reviews: new Map(),            // id -> { stars, count } – empty while review is down
  cart: { items: [], count: 0 },
  status: {},                    // service -> { up: bool, reason: string }
  servedBy: {},                  // service -> { version, revision, pod }
};

function escapeHtml(text) {
  return String(text).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

// ── talking to the backends ──────────────────────────────────────────────────

async function call(service, path, options = {}) {
  const url = service === "web" ? path : `/api/${service}${path}`;
  let response;
  try {
    response = await fetch(url, { ...options, headers: { "Content-Type": "application/json" } });
  } catch (error) {
    setStatus(service, false, "no connection");
    throw new Error(`${service}: no connection`);
  }
  noteServedBy(service, response.headers);
  const body = await response.json().catch(() => ({}));
  if (response.status === 502 || response.status === 504) {
    setStatus(service, false, "unreachable");
    throw new Error(`${service} is unreachable`);
  }
  if (response.status === 503) {
    setStatus(service, false, "unavailable (503)");
    throw new Error(body.detail || `${service} is unavailable`);
  }
  setStatus(service, true);
  if (!response.ok) throw new Error(body.detail || `${service}: HTTP ${response.status}`);
  return body;
}

function noteServedBy(service, headers) {
  const pod = headers.get("X-Shop-Pod");
  if (!pod) return;
  updateServedBy(service, {
    version: headers.get("X-Shop-Version"),
    revision: headers.get("X-Shop-Revision"),
    pod,
  });
}

// ── status panel and footer ──────────────────────────────────────────────────

function setStatus(service, up, reason = "") {
  const before = state.status[service];
  state.status[service] = { up, reason };
  if (!before || before.up !== up || before.reason !== reason) renderStatus();
}

function renderStatus() {
  $("#status").innerHTML = SERVICES.map((service) => {
    const s = state.status[service];
    const css = !s ? "unknown" : s.up ? "" : "down";
    const text = !s ? "checking …" : s.up ? "ok" : s.reason;
    return `<span class="chip ${css}">${service}: ${escapeHtml(text)}</span>`;
  }).join("");
  renderServedBy();
}

function updateServedBy(service, info) {
  const before = state.servedBy[service] || {};
  state.servedBy[service] = { ...info, changed: before.pod && before.pod !== info.pod };
  renderServedBy();
}

function renderServedBy() {
  $("#served-by").innerHTML = SERVICES.map((service) => {
    const info = state.servedBy[service] || {};
    const down = state.status[service] && !state.status[service].up;
    return `<tr class="${down ? "down" : ""}">
      <td>${service}</td>
      <td>${escapeHtml(info.version || "–")}</td>
      <td><code>${escapeHtml(info.revision || "–")}</code></td>
      <td class="${info.changed ? "changed" : ""}"><code>${escapeHtml(info.pod || "–")}</code></td>
    </tr>`;
  }).join("");
}

async function poll() {
  await Promise.all(SERVICES.map((service) =>
    call(service, "/info")
      .then((info) => updateServedBy(service, info))
      .catch(() => {})));
}

// ── products ─────────────────────────────────────────────────────────────────

async function loadProducts() {
  try {
    const body = await call("catalog", "/products");
    document.body.dataset.theme = body.theme;          // v2 = the canary look
    state.products = new Map(body.products.map((p) => [p.id, p]));
    renderProducts();
    renderCart();
  } catch (error) {
    if (!state.products.size) $("#products").innerHTML = `<p class="muted">Products are not available right now – ${escapeHtml(error.message)}.</p>`;
  }
}

function renderProducts() {
  $("#products").innerHTML = [...state.products.values()].map((p) => `
    <article class="card">
      ${p.badge ? `<span class="badge">${escapeHtml(p.badge)}</span>` : ""}
      <div class="picture" aria-hidden="true">${escapeHtml(p.emoji)}</div>
      <h3>${escapeHtml(p.name)}</h3>
      ${starsHtml(p.id)}
      <p>${escapeHtml(p.description)}</p>
      <div class="row">
        <span class="price">${money.format(p.price_pence / 100)}</span>
        <span class="stock ${p.stock < 5 ? "low" : ""}">${p.stock > 0 ? `${p.stock} in stock` : "sold out"}</span>
      </div>
      <button class="primary" type="button" data-add="${escapeHtml(p.id)}" ${p.stock > 0 ? "" : "disabled"}>Add to cart</button>
    </article>`).join("");
}

// ── reviews (optional) ───────────────────────────────────────────────────────

async function loadReviews() {
  try {
    const body = await call("review", "/reviews");
    state.reviews = new Map(Object.entries(body.reviews));
  } catch (error) {
    state.reviews = new Map();   // review down: no stars, everything else keeps working
  }
  if (state.products.size) renderProducts();
}

function starsHtml(productId) {
  const review = state.reviews.get(productId);
  if (!review) return "";
  const full = Math.round(review.stars);
  return `<div class="stars" title="${review.stars} of 5 stars">
    <span aria-hidden="true">${"★".repeat(full)}<span class="off">${"★".repeat(5 - full)}</span></span>
    <small>${review.stars.toFixed(1)} (${review.count})</small></div>`;
}

// ── cart ─────────────────────────────────────────────────────────────────────

async function loadCart() {
  try {
    state.cart = await call("cart", "/cart");
    renderCart();
  } catch (error) { /* the status panel shows it */ }
}

function quantityOf(productId) {
  const line = state.cart.items.find((item) => item.product_id === productId);
  return line ? line.quantity : 0;
}

async function setQuantity(productId, quantity) {
  try {
    state.cart = await call("cart", `/cart/items/${encodeURIComponent(productId)}`, {
      method: "PUT", body: JSON.stringify({ quantity }),
    });
    renderCart();
  } catch (error) { toast(error.message, true); }
}

function renderCart() {
  $("#cart-count").textContent = state.cart.count;
  let total = 0;
  $("#cart-items").innerHTML = state.cart.items.map((item) => {
    const p = state.products.get(item.product_id) || { name: item.product_id, emoji: "📦", price_pence: 0 };
    total += p.price_pence * item.quantity;
    return `<li>
      <span class="emoji" aria-hidden="true">${escapeHtml(p.emoji)}</span>
      <span class="grow">${escapeHtml(p.name)}<small>${money.format(p.price_pence / 100)} each</small></span>
      <span class="qty">
        <button type="button" data-qty="${escapeHtml(item.product_id)}" data-delta="-1" aria-label="one less">−</button>
        ${item.quantity}
        <button type="button" data-qty="${escapeHtml(item.product_id)}" data-delta="1" aria-label="one more">+</button>
      </span>
    </li>`;
  }).join("") || `<li class="muted">Your cart is empty.</li>`;
  $("#cart-total").textContent = money.format(total / 100);
  $("#checkout").disabled = state.cart.count === 0;
}

async function checkout() {
  $("#checkout").disabled = true;
  try {
    const order = await call("orders", "/orders", {
      method: "POST", body: JSON.stringify({ items: state.cart.items }),
    });
    await call("cart", "/cart", { method: "DELETE" });
    toast(`Order ${order.id} placed – ${money.format(order.total_pence / 100)}, stored by pod ${order.pod}.`);
    closeDrawers();
    await Promise.all([loadCart(), loadProducts()]);
  } catch (error) {
    toast(`Order not placed: ${error.message}`, true);
    renderCart();
  }
}

// ── orders ───────────────────────────────────────────────────────────────────

async function loadOrders() {
  try {
    const body = await call("orders", "/orders");
    const note = $("#storage-note");
    note.hidden = body.persistent;
    note.textContent = `Orders are stored in ${body.storage} on temporary storage (emptyDir) – they are gone when the orders pod restarts.`;
    $("#order-list").innerHTML = body.orders.map((order) => `
      <li>
        <span class="emoji" aria-hidden="true">🧾</span>
        <span class="grow">Order ${escapeHtml(order.id)}
          <small>${new Date(order.created).toLocaleString("en-GB")} · ${order.items.map((i) => `${i.quantity} × ${escapeHtml(i.name)}`).join(", ")}</small>
          <small>stored by ${escapeHtml(order.pod)}</small></span>
        <strong>${money.format(order.total_pence / 100)}</strong>
      </li>`).join("") || `<li class="muted">No orders yet.</li>`;
  } catch (error) {
    $("#order-list").innerHTML = `<li class="muted">Orders are not available right now – ${escapeHtml(error.message)}.</li>`;
  }
}

// ── drawers, toast and events ────────────────────────────────────────────────

function openDrawer(id) {
  closeDrawers();
  $(id).setAttribute("aria-hidden", "false");
  $("#backdrop").hidden = false;
}

function closeDrawers() {
  document.querySelectorAll(".drawer").forEach((d) => d.setAttribute("aria-hidden", "true"));
  $("#backdrop").hidden = true;
}

let toastTimer;
function toast(message, isError = false) {
  const element = $("#toast");
  element.textContent = message;
  element.className = `toast ${isError ? "error" : ""}`;
  element.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { element.hidden = true; }, 5000);
}

document.addEventListener("click", (event) => {
  const target = event.target.closest("button, .backdrop");
  if (!target) return;
  if (target.dataset.add) setQuantity(target.dataset.add, quantityOf(target.dataset.add) + 1);
  else if (target.dataset.qty) setQuantity(target.dataset.qty, Math.max(0, quantityOf(target.dataset.qty) + Number(target.dataset.delta)));
  else if (target.id === "cart-button") { openDrawer("#cart"); loadCart(); }
  else if (target.id === "orders-button") { openDrawer("#orders"); loadOrders(); }
  else if (target.id === "checkout") checkout();
  else if (target.hasAttribute("data-close") || target.id === "backdrop") closeDrawers();
});
document.addEventListener("keydown", (event) => { if (event.key === "Escape") closeDrawers(); });

renderStatus();
loadProducts().then(loadReviews);         // products first – the stars follow if review answers
loadCart();
poll();
setInterval(poll, POLL_MS);
setInterval(loadProducts, 5 * POLL_MS);   // fresh stock – and the canary look, if catalog 2.x answers
setInterval(loadReviews, 2 * POLL_MS);    // stars disappear / come back within a few seconds
