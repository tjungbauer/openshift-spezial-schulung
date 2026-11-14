# shellcheck shell=bash
# ---------------------------------------------------------------------------
#  Lab 01 – shared setup, tasks and checks.
#  Sourced by lab-01-walkthrough.sh (interactive) and lab-01-solve.sh
#  (automatic), all three in lab-01/trainer/. Works on the lab files in
#  lab-01/shop-catalog/ and uses the shared demo library from ../../demos/lib.
#
#  Needs:
#     DEV, RELEASE       full image names without tag, e.g.
#                          registry.acme.example/workshop/shop-group1-dev   (students, Nexus)
#                          quay.io/tjungbau/shop-catalog-dev                (trainer)
#                        or REGISTRY=HOST/ORG -> $REGISTRY/shop-catalog-dev and $REGISTRY/shop-catalog
#     PULL_USER, PULL_TOKEN  optional: pull secret for a private release repository
#     LAB_NS / -n NAME   namespace for task 6 (default: lab – created if missing,
#                        cleanup only removes the lab objects, never the project)
#     podman, skopeo, jq, curl; podman login to the registry
# ---------------------------------------------------------------------------

# this file lives in lab-01/trainer/ – the lab files are one level up
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_PROJECT="${LAB_NS:-${DEMO_PROJECT:-lab}}"
# shellcheck source=../../../demos/lib/demo-lib.sh
source "${LAB_DIR}/../../demos/lib/demo-lib.sh"

VERSION="${VERSION:-1.0.0}"
PLATFORM="${PLATFORM:-linux/amd64}"
PIP_INDEX_URL="${PIP_INDEX_URL:-}"   # Nexus PyPI mirror, passed as build arg if set
APP="shop-catalog"
BUILD_NAME="shop-catalog-cluster"
FAILS=0

# lab_init – call after parse_demo_args: tools, registry, git revision, login
lab_init() {
  LAB_NS="${DEMO_PROJECT}"
  require_cmd podman skopeo jq curl
  if [[ -z "${DEV:-}" || -z "${RELEASE:-}" ]]; then
    [[ -n "${REGISTRY:-}" ]] || die "Set DEV and RELEASE (or REGISTRY), e.g. REGISTRY=quay.io/tjungbau"
    DEV="${DEV:-${REGISTRY}/${APP}-dev}"
    RELEASE="${RELEASE:-${REGISTRY}/${APP}}"
  fi
  cd "${LAB_DIR}" || die "Cannot cd to ${LAB_DIR}"
  if git rev-parse HEAD >/dev/null 2>&1; then
    REVISION="$(git rev-parse HEAD)"
    SHA="$(git rev-parse --short HEAD)"
  else
    REVISION="${REVISION:-0000000000000000000000000000000000000000}"
    SHA="${REVISION:0:7}"
    warn "Not a git repository – using revision ${SHA}"
  fi
  TAG="${VERSION}-${SHA}"
  require_oc_login
  printf "%sImage:  %s %s:%s\n" "${C_BOLD}" "${C_RESET}" "${DEV}" "${TAG}"
  printf "%sRelease:%s %s:%s\n" "${C_BOLD}" "${C_RESET}" "${RELEASE}" "${TAG}"
}

# dev_digest – digest of the pushed dev image (empty if not pushed yet)
dev_digest() {
  skopeo inspect --format '{{.Digest}}' "docker://${DEV}:${TAG}" 2>/dev/null || true
}

release_digest() {
  skopeo inspect --format '{{.Digest}}' "docker://${RELEASE}:${TAG}" 2>/dev/null || true
}

route_host() {
  oc -n "${LAB_NS}" get route "${APP}" -o jsonpath='{.spec.host}' 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════════
#  Tasks
# ═══════════════════════════════════════════════════════════════════════════

task1() {
  section "Task 1 · Read the Containerfile"

  show_file shop-catalog/Containerfile
  show_file shop-catalog/.containerignore

  discuss \
    "Two FROM lines – two stages" \
    "" \
    "  build    python-312: pip installs the pinned packages" \
    "  runtime  python-312-minimal + packages + code – this ships" \
    "" \
    "requirements.txt before app/: the pip layer is cached." \
    "USER 1001 = the UBI Python user. OpenShift ignores it and" \
    "runs a random UID with group 0 – numeric + non-root counts." \
    "Port 8080 > 1024; .containerignore keeps .git and caches out."
}

task2() {
  section "Task 2 · Build with version, revision and labels"

  comment "Tag = version + short git SHA; the same strings go into the labels"
  run "podman build --platform ${PLATFORM} -t ${DEV}:${TAG} --build-arg VERSION=${VERSION} --build-arg REVISION=${REVISION}${PIP_INDEX_URL:+ --build-arg PIP_INDEX_URL=${PIP_INDEX_URL}} shop-catalog"

  comment "The OCI labels in the image"
  run "podman inspect ${DEV}:${TAG} --format '{{json .Labels}}' | jq 'with_entries(select(.key|startswith(\"org.opencontainers\")))'"

  discuss \
    "One version string everywhere" \
    "" \
    "Tag ${TAG} – label version ${VERSION}," \
    "label revision = full git commit, APP_VERSION in /info." \
    "" \
    "--platform ${PLATFORM}: Apple Silicon builds arm64 by" \
    "default, the cluster nodes run amd64."
}

task3() {
  section "Task 3 · Compare the build stage and the final image"

  comment "Build only stage 1 – the one that never ships"
  run "podman build --platform ${PLATFORM} --target build -t ${APP}-build${PIP_INDEX_URL:+ --build-arg PIP_INDEX_URL=${PIP_INDEX_URL}} shop-catalog"
  run "podman images | grep -E '${APP}|${DEV##*/}'"

  discuss \
    "Build stage vs. runtime image" \
    "" \
    "The build stage is the full Python image: pip, compilers," \
    "headers. The runtime image has Python, the packages and the" \
    "code – smaller to pull, fewer packages to scan and patch."
}

task4() {
  section "Task 4 · Push and inspect – straight from the registry"

  run "podman push ${DEV}:${TAG}"
  run "skopeo inspect docker://${DEV}:${TAG} | jq '{Digest, Labels}'"

  comment "The digest – the content address of the image"
  run "skopeo inspect --format '{{.Digest}}' docker://${DEV}:${TAG}"

  discuss \
    "Tag vs. digest" \
    "" \
    "A tag is a name that can be moved (unless the repo is immutable)." \
    "The digest is the hash of the content – it can never change." \
    "skopeo reads labels and digest without pulling the image."
}

task5() {
  local digest
  section "Task 5 · Promote by digest – dev → release"

  digest="$(dev_digest)"
  [[ -n "${digest}" ]] || { warn "No dev image found – run task 4 first."; return 0; }

  run "skopeo copy docker://${DEV}@${digest} docker://${RELEASE}:${TAG}"
  comment "Same digest in release as in dev"
  run "skopeo inspect --format '{{.Digest}}' docker://${RELEASE}:${TAG}"

  discuss \
    "Promote, don't rebuild" \
    "" \
    "Registry to registry, by digest: release gets exactly the" \
    "bits that were tested in dev. A rebuild would be a new image."
}

task6() {
  local digest
  section "Task 6 · Run it on OpenShift – by digest"

  digest="$(release_digest)"
  [[ -n "${digest}" ]] || { warn "No release image found – run task 5 first."; return 0; }

  # private repository (quay.io creates new repositories as private): pull secret
  if [[ -n "${PULL_USER:-}" && -n "${PULL_TOKEN:-}" ]]; then
    comment "Private repository – give the namespace pull access"
    if ! oc get secret lab-01-pull >/dev/null 2>&1; then
      run "oc create secret docker-registry lab-01-pull --docker-server=${RELEASE%%/*} --docker-username='${PULL_USER}' --docker-password=\"\${PULL_TOKEN}\""
    fi
    run "oc secrets link default lab-01-pull --for=pull"
    # a Pod stuck in ImagePullBackOff only picks up the secret when it is re-created
    oc get deployment "${APP}" >/dev/null 2>&1 && run "oc rollout restart deployment/${APP}"
  fi

  if oc get deployment "${APP}" >/dev/null 2>&1; then
    run "oc set image deployment/${APP} '*'=${RELEASE}@${digest}"
  else
    run "oc create deployment ${APP} --image=${RELEASE}@${digest} --port=8080"
  fi
  run "oc rollout status deployment/${APP} --timeout=180s"
  oc get service "${APP}" >/dev/null 2>&1 || run "oc expose deployment ${APP} --port=8080"
  oc get route "${APP}" >/dev/null 2>&1 || run "oc create route edge ${APP} --service=${APP}"

  wait_until "the router serves the Route" 60 "curl -fsk https://\$(route_host)/health" || true
  run "curl -sk https://\$(oc get route ${APP} -o jsonpath='{.spec.host}')/info"
  run "oc get deployment ${APP} -o jsonpath='{.spec.template.spec.containers[0].image}{\"\\n\"}'"

  comment "USER 1001 in the image – and the UID OpenShift really uses"
  run "oc exec deploy/${APP} -- id"

  discuss \
    "Same version in tag, labels and /info" \
    "" \
    "The Deployment references the digest: re-pushing the tag" \
    "cannot change what runs. ImagePullBackOff? Private registry –" \
    "pull secret + oc secrets link default ... --for=pull." \
    "" \
    "id shows a random UID from the project range, group 0 –" \
    "not the 1001 from the Containerfile."
}

bonus() {
  section "Bonus · Build in the cluster – BuildConfig, binary, docker strategy"

  if ! oc get bc "${BUILD_NAME}" >/dev/null 2>&1; then
    run "oc new-build --name=${BUILD_NAME} --binary --strategy=docker"
    run "oc patch bc/${BUILD_NAME} --type=merge -p '{\"spec\":{\"strategy\":{\"dockerStrategy\":{\"dockerfilePath\":\"Containerfile\"}}}}'"
  fi
  run "oc start-build ${BUILD_NAME} --from-dir=shop-catalog --follow"
  run "oc get imagestream ${BUILD_NAME}"

  discuss \
    "Same Containerfile, built in your namespace" \
    "" \
    "No podman on the laptop needed – the build uses your quota." \
    "The result lands in an ImageStream in the internal registry." \
    "Release builds belong into the CI pipeline (Day 2, module 11)."
}

# ═══════════════════════════════════════════════════════════════════════════
#  Checks
# ═══════════════════════════════════════════════════════════════════════════

expect() {
  if [[ "$2" == "$3" ]]; then
    printf "  %sPASS%s  %-44s %s\n" "${C_OK}" "${C_RESET}" "$1" "$3"
  else
    printf "  %sFAIL%s  %-44s got %s, expected %s\n" "${C_ERR}" "${C_RESET}" "$1" "${3:-nothing}" "$2"
    FAILS=$((FAILS + 1))
  fi
}

check() {
  local labels dev rel image info
  FAILS=0
  section "Checks for ${DEV}:${TAG} and namespace ${LAB_NS}"
  labels="$(skopeo inspect "docker://${DEV}:${TAG}" 2>/dev/null | jq -c '.Labels' 2>/dev/null || true)"
  dev="$(dev_digest)"
  rel="$(release_digest)"
  image="$(oc -n "${LAB_NS}" get deployment "${APP}" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  info="$(curl -sk -m 5 "https://$(route_host)/info" 2>/dev/null || true)"
  jq -e . >/dev/null 2>&1 <<<"${labels}" || labels='{}'
  jq -e . >/dev/null 2>&1 <<<"${info}" || info='{}'

  expect "dev image pushed" "yes" "$([[ -n "${dev}" ]] && echo yes || echo no)"
  expect "label version" "${VERSION}" "$(jq -r '."org.opencontainers.image.version" // empty' <<<"${labels}")"
  expect "label revision" "${REVISION}" "$(jq -r '."org.opencontainers.image.revision" // empty' <<<"${labels}")"
  expect "release digest = dev digest" "${dev:-dev missing}" "${rel:-release missing}"
  expect "Deployment uses the release digest" "${RELEASE}@${rel:-?}" "${image}"
  expect "/info version" "${VERSION}" "$(jq -r '.version // empty' <<<"${info}" 2>/dev/null || true)"
  expect "/info revision" "${REVISION}" "$(jq -r '.revision // empty' <<<"${info}" 2>/dev/null || true)"
  expect "Pod runs with group 0 (restricted-v2)" "0" \
    "$(oc -n "${LAB_NS}" exec deploy/"${APP}" -- id -g 2>/dev/null || true)"

  printf "\n"
  if [[ ${FAILS} -eq 0 ]]; then success "All checks passed"; else warn "${FAILS} check(s) failed"; fi
  return "${FAILS}"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Cleanup
# ═══════════════════════════════════════════════════════════════════════════

cleanup() {
  oc -n "${LAB_NS}" delete route/"${APP}" service/"${APP}" deployment/"${APP}" \
    --ignore-not-found >/dev/null 2>&1 || true
  # the pull secret: lab-01-pull (these scripts) or acme-pull (student README, task 6)
  oc -n "${LAB_NS}" secrets unlink default lab-01-pull >/dev/null 2>&1 || true
  oc -n "${LAB_NS}" secrets unlink default acme-pull >/dev/null 2>&1 || true
  oc -n "${LAB_NS}" delete bc/"${BUILD_NAME}" is/"${BUILD_NAME}" secret/lab-01-pull secret/acme-pull \
    --ignore-not-found >/dev/null 2>&1 || true
  info "deleted the lab objects in ${LAB_NS} (project kept)"
  podman rmi -f "${DEV}:${TAG}" "${APP}-build" >/dev/null 2>&1 || true
  info "removed the local images"
  info "the pushed images stay in ${DEV} and ${RELEASE} – remove them in the registry if needed"
}
