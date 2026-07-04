#!/usr/bin/env bash
# ==============================================================================
# Linux build entry point — engine-agnostic.
#
# Preferred path: Docker Buildx `bake`, which reads the docker-bake.hcl graphs
# directly. If Docker Buildx is unavailable but Podman is, this script instead
# replays the same target graph as ordered `podman build` calls. The two paths
# are intended to be equivalent; the bake HCL files remain the single source of
# truth for the Docker path, and the Podman path mirrors them below.
#
#   Docker:  docker buildx bake ...            (the .hcl files)
#   Podman:  podman build ... --build-context  (this script's replay)
#
# Run from this directory (build/linux). Override any variable via the
# environment, e.g. `BUILD_NUMBER=ci.42 ./build.sh`.
# ==============================================================================
set -euo pipefail

# ── Configuration (matches the defaults in the docker-bake.hcl files) ────────
NEXTCLOUD_USER="${NEXTCLOUD_USER:-}"
NEXTCLOUD_PASS="${NEXTCLOUD_PASS:-}"
REGISTRY="${REGISTRY:-ghcr.io/euro-office}"
TAG="${TAG:-latest}"
PRODUCT_VERSION="${PRODUCT_VERSION:-$(cat ../../VERSION)}"
BUILD_NUMBER="${BUILD_NUMBER:-dev.0}"
BRANDING_DIR="${BRANDING_DIR:-../}"
COMPANY_NAME="${COMPANY_NAME:-Euro-Office}"
PRODUCT_NAME="${PRODUCT_NAME:-Desktop Editors}"
GIT_COMMIT="${GIT_COMMIT:-$(git rev-parse --short HEAD)}"

# Derived args shared by every target (mirrors the `_common` target's args and
# the COMPANY_NAME_LOW regex_replace in the HCL).
BUILD_ROOT="${BUILD_ROOT:-/package}"
NUGET_CACHE="${NUGET_CACHE:-local}"
CACHE_BUST="${CACHE_BUST:-1}"
COMPANY_NAME_LOW="${COMPANY_NAME_LOW:-$(printf '%s' "$COMPANY_NAME" | tr '[:upper:]' '[:lower:]' | sed -E 's/[[:space:]]+/-/g')}"

export NEXTCLOUD_USER NEXTCLOUD_PASS REGISTRY TAG PRODUCT_VERSION \
       BUILD_NUMBER BRANDING_DIR COMPANY_NAME PRODUCT_NAME GIT_COMMIT

# ── Engine detection ─────────────────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }

if have docker && docker buildx bake --help >/dev/null 2>&1; then
  ENGINE=docker
elif have podman; then
  ENGINE=podman
else
  echo "error: neither 'docker buildx bake' nor 'podman' is available." >&2
  echo "       install Docker with the Buildx plugin, or Podman." >&2
  exit 1
fi
echo ">> build engine: ${ENGINE}"

# ══════════════════════════════════════════════════════════════════════════════
# Docker path — delegate to bake, unchanged behavior.
# ══════════════════════════════════════════════════════════════════════════════
if [ "$ENGINE" = docker ]; then
  ( cd .. && docker buildx bake desktop-common )
  docker buildx bake packages
  exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════
# Podman path — replay the bake graph as ordered `podman build` calls.
#
# bake's  contexts = { name = "target:X" }  becomes a prebuilt local image that
# we pass with  --build-context name=docker-image://<tag>  so the Dockerfile's
# `COPY --from=name` resolves against it. Cache mounts, secrets, bind mounts and
# heredocs in the Dockerfiles are all supported by Podman's buildah backend, so
# the Dockerfiles are used verbatim.
#
# Note: the bake  cache-from/cache-to type=local  layer caches are a Buildx
# feature and don't apply here; Podman keeps its own layer cache plus the
# in-build ccache/npm/em caches (RUN --mount=type=cache), so incremental
# rebuilds still benefit.
# ══════════════════════════════════════════════════════════════════════════════

REPO_ROOT="$(cd ../.. && pwd)"

# COMMON_ARGS mirrors the `_common` target's args block in the HCL, plus
# NUGET_SOURCE_PATH=. — the HCL leaves that arg unset and BuildKit then treats
# the bind mount `source=${NUGET_SOURCE_PATH}` as the build-context root, but
# Buildah rejects an empty source. Passing "." (relative to the context)
# reproduces BuildKit's behavior explicitly.
COMMON_ARGS=(
  --build-arg "NUGET_SOURCE_PATH=."
  --build-arg "PRODUCT_VERSION=${PRODUCT_VERSION}"
  --build-arg "BUILD_NUMBER=${BUILD_NUMBER}"
  --build-arg "BUILD_ROOT=${BUILD_ROOT}"
  --build-arg "NUGET_CACHE=${NUGET_CACHE}"
  --build-arg "CACHE_BUST=${CACHE_BUST}"
  --build-arg "BRANDING_DIR=${BRANDING_DIR}"
  --build-arg "PRODUCT_NAME=${PRODUCT_NAME}"
  --build-arg "COMPANY_NAME=${COMPANY_NAME}"
  --build-arg "COMPANY_NAME_LOW=${COMPANY_NAME_LOW}"
)

# pbuild <image-tag> <dockerfile-relative-to-repo-root> [extra podman build args...]
# Context is always the repo root, matching `context = ".."` / `"../.."` in the HCL.
pbuild() {
  local tag="$1"; shift
  local dockerfile="$1"; shift
  echo ">> podman build ${tag}  (${dockerfile})"
  podman build \
    -t "$tag" \
    -f "${REPO_ROOT}/${dockerfile}" \
    "${COMMON_ARGS[@]}" \
    "$@" \
    "${REPO_ROOT}"
}

# ── Stage 1: desktop-common (build/docker-bake.hcl) ──────────────────────────
CORE_WASM_IMG="${REGISTRY}/core-wasm:${TAG}"
DESKTOP_JS_IMG="${REGISTRY}/desktop-js:${TAG}"
WEB_APPS_IMG="${REGISTRY}/web-apps:${TAG}"
SDKJS_DESKTOP_IMG="${REGISTRY}/sdkjs-desktop:${TAG}"
DESKTOP_COMMON_IMG="${REGISTRY}/desktop-common:${GIT_COMMIT}"

pbuild "$CORE_WASM_IMG" "core/.docker/core-wasm.bake.Dockerfile"

pbuild "$DESKTOP_JS_IMG" "desktop-apps/.docker/desktop-js.bake.Dockerfile"

pbuild "$WEB_APPS_IMG" "web-apps/.docker/web-apps.bake.Dockerfile"

pbuild "$SDKJS_DESKTOP_IMG" "sdkjs/.docker/sdkjs.bake.Dockerfile" \
  --target sdkjs-desktop \
  --build-context "core-wasm=docker-image://${CORE_WASM_IMG}"

pbuild "$DESKTOP_COMMON_IMG" "build/.docker/desktop-composer.bake.Dockerfile" \
  --target desktop-common \
  --build-context "desktop-js=docker-image://${DESKTOP_JS_IMG}" \
  --build-context "sdkjs-desktop=docker-image://${SDKJS_DESKTOP_IMG}" \
  --build-context "web-apps=docker-image://${WEB_APPS_IMG}"

# ── Stage 2: packages (build/linux/docker-bake.hcl) ──────────────────────────
CORE_BASE_IMG="${REGISTRY}/core-base:${TAG}"
DESKTOP_LINUX_IMG="${REGISTRY}/desktop-linux:${TAG}"

pbuild "$CORE_BASE_IMG" "core/.docker/core.bake.Dockerfile" \
  --target core-base

SECRET_ARGS=()
if [ -n "$NEXTCLOUD_USER" ] || [ -n "$NEXTCLOUD_PASS" ]; then
  SECRET_ARGS+=(
    --secret "id=nextcloud_user,env=NEXTCLOUD_USER"
    --secret "id=nextcloud_pass,env=NEXTCLOUD_PASS"
  )
fi

# ${SECRET_ARGS[@]+...} guards against the "unbound variable" error `set -u`
# raises for an empty array on older bash (e.g. macOS bash 3.2).
#
# TAR_OPTIONS=--no-same-owner: the v8 third-party step unpacks Chromium's
# Debian sysroot, whose entries are owned by UIDs far beyond a rootless
# user namespace's subuid range; without this, tar's chown fails with EINVAL
# and the configure step aborts. Rootful engines are unaffected either way.
#
# CMAKE_BUILD_PARALLEL_LEVEL: the desktop compile has very large translation
# units (~2 GiB per compiler job); ninja's default of nproc jobs OOMs typical
# developer machines. Cap jobs at available-RAM/2GiB (override with BUILD_JOBS).
if [ -z "${BUILD_JOBS:-}" ]; then
  mem_avail_kb=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
  BUILD_JOBS=$(( mem_avail_kb / (2 * 1024 * 1024) ))
  [ "$BUILD_JOBS" -lt 2 ] && BUILD_JOBS=2
  [ "$BUILD_JOBS" -gt "$(nproc)" ] && BUILD_JOBS=$(nproc)
fi
echo ">> compile parallelism: ${BUILD_JOBS} jobs"

pbuild "$DESKTOP_LINUX_IMG" "desktop-apps/.docker/desktop-apps.bake.Dockerfile" \
  --env "TAR_OPTIONS=--no-same-owner" \
  --env "CMAKE_BUILD_PARALLEL_LEVEL=${BUILD_JOBS}" \
  --target desktop-linux \
  --build-context "core-base=docker-image://${CORE_BASE_IMG}" \
  --build-context "desktop-common=docker-image://${DESKTOP_COMMON_IMG}" \
  ${SECRET_ARGS[@]+"${SECRET_ARGS[@]}"}

# `packages` exports to the local filesystem (bake: output type=local,dest=...).
OUT_DIR="./deploy/packages"
mkdir -p "$OUT_DIR"
echo ">> podman build packages -> ${OUT_DIR}"
# OMP_NUM_THREADS caps `nproc` (which honors it), and thus the thread count of
# the xz -9 compressors in the packaging Makefile — at full core count they
# need ~0.7 GiB per thread and get OOM-killed on smaller machines.
podman build \
  -f "${REPO_ROOT}/build/.docker/packages.bake.Dockerfile" \
  --env "OMP_NUM_THREADS=${BUILD_JOBS}" \
  --target packages \
  "${COMMON_ARGS[@]}" \
  --build-context "desktop-linux=docker-image://${DESKTOP_LINUX_IMG}" \
  -o "type=local,dest=${OUT_DIR}" \
  "${REPO_ROOT}"

echo ">> done. packages in $(cd "$OUT_DIR" && pwd)"
