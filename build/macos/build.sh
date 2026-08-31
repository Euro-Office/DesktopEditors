#!/usr/bin/env bash
#
# Euro-Office DesktopEditors -- macOS build entry point.
#
# Similar to the Windows ps1 script, but uses docker for common files if necessary.
#   
#   1. preflight        chec host, Xcode, CLT, cmake/ninja/python, disk, submodules
#   2. patches          apply clang-strictness fixes, applied reversibly
#   3. third-party      core/Common/3dParty via build_3rdparty.py (CEF, ICU, ...)
#   4. cmake            build/macos/CMakeLists.txt -> core libs, x2t, the SDK
#   5. stage            assemble the tree the Xcode project reads
#   6. xcodebuild       the Cocoa app in desktop-apps/macos
#   7. sign + verify    ad-hoc by default, Developer ID when configured
#   8. package          optional .dmg

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${BUILD_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
PRODUCT_VERSION="${PRODUCT_VERSION:-9.3.1}"
BUILD_NUMBER="${BUILD_NUMBER:-dev.1}"
COMPANY_NAME="${COMPANY_NAME:-Euro-Office}"
PRODUCT_NAME="${PRODUCT_NAME:-DesktopEditors}"

# macOS bundle identity. Should be kept in sync with desktop-apps/macos.
APP_NAME="${APP_NAME:-Euro-Office}"
BUNDLE_ID="${PRODUCT_BUNDLE_IDENTIFIER:-org.euro-office.desktopeditors}"

# arm64 is the default.
ARCH="${ARCH:-arm64}"

# Oldest macOS the result runs on. 11.0 is the first Apple Silicon release.
MACOS_DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET:-11.0}"

# The platform-independent editors payload produced by the `build-common` CI
# job. Locally, unpack the `common-files` artifact here (or point at it).
COMMON_DIR="${COMMON_DIR:-${REPO_ROOT}/common}"

# Signing. Empty CODESIGNING_IDENTITY means ad-hoc ("-"), which is enough to
# run locally but not to distribute.
CODESIGNING_IDENTITY="${CODESIGNING_IDENTITY:-}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"

MIN_FREE_GIB="${MIN_FREE_GIB:-60}"

OUT_ROOT="${BUILD_DIR}/deploy/macos"
OUT_DIR="${OUT_ROOT}/${ARCH}"
STAGE_DIR="${OUT_DIR}/stage"
CMAKE_BUILD_DIR="${OUT_DIR}/cmake"
DERIVED_DATA_DIR="${OUT_DIR}/DerivedData"
THIRD_PARTY_DIR="${OUT_ROOT}/third_party"
LOG_DIR="${OUT_ROOT}/logs"

DESKTOP_APPS_DIR="${DESKTOP_APPS_DIR:-${REPO_ROOT}/desktop-apps}"
XCODE_PROJECT="${DESKTOP_APPS_DIR}/macos/ONLYOFFICE.xcodeproj"
PATCH_DIR="${SCRIPT_DIR}/patches"
VCPKG_ROOT="${VCPKG_ROOT:-${OUT_ROOT}/vcpkg}"

MODE="build"
PREFLIGHT_FAILURES=0
APPLIED_PATCHES=()

# applied also for 3rd parties - every dependency is tagged with the
# same minimum OS as the rest.
export MACOSX_DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET}"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
IN_ACTIONS="${GITHUB_ACTIONS:-false}"
GROUP_OPEN=0

close_group() {
  if [[ "${IN_ACTIONS}" == "true" && ${GROUP_OPEN} -eq 1 ]]; then
    printf '::endgroup::\n'
    GROUP_OPEN=0
  fi
}

step() {
  close_group
  if [[ "${IN_ACTIONS}" == "true" ]]; then
    printf '::group::%s\n' "$*"
    GROUP_OPEN=1
  else
    printf '\n\033[1m==> %s\033[0m\n' "$*"
  fi
}

info() { printf '[macos] %s\n' "$*"; }
warn() { printf '[macos] warning: %s\n' "$*" >&2; }
fail() { close_group; printf '[macos] error: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
# Revert patches on cleanup for clean tree
revert_patches() {
  local record root patch
  for record in "${APPLIED_PATCHES[@]:-}"; do
    [[ -z "${record}" ]] && continue
    root="${record%%|*}"
    patch="${record#*|}"
    if git -C "${root}" apply --unidiff-zero --reverse --check "${patch}" >/dev/null 2>&1; then
      git -C "${root}" apply --unidiff-zero --reverse "${patch}" || true
    fi
  done
  APPLIED_PATCHES=()
}

cleanup() {
  local rc=$?
  revert_patches
  close_group
  return ${rc}
}
trap cleanup EXIT

usage() {
  cat <<EOF
Usage:
  ./build/macos/build.sh [--check | --dry-run] [arm64 | x86_64]

Modes:
  --check      run preflight only, report what is missing, change nothing
  --dry-run    print every phase and the paths it would touch, change nothing
  (default)    run the full build

Environment:
  ARCH=arm64                       target architecture (arm64 | x86_64)
  COMMON_DIR=<path>                editors payload from the build-common job
  PRODUCT_VERSION=${PRODUCT_VERSION}
  BUILD_NUMBER=${BUILD_NUMBER}
  MACOS_DEPLOYMENT_TARGET=${MACOS_DEPLOYMENT_TARGET}
  CODESIGNING_IDENTITY="Developer ID Application: ..."   (default: ad-hoc)
  DEVELOPMENT_TEAM=<team-id>
  VCPKG_ROOT=<path>
  MIN_FREE_GIB=${MIN_FREE_GIB}
  EO_SKIP_SPACE_CHECK=1            skip the free-space preflight
  EO_SKIP_COMMON=1                 do not build the editors payload with docker
  EO_SKIP_THIRD_PARTY=1            reuse an existing third-party install tree
  EO_SKIP_XCODE=1                  build the native payload only, no .app
  EO_MAKE_DMG=1                    also produce a .dmg
  EO_INSTALL_DEPS=1                let Homebrew install missing build tools
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)   MODE="check"; shift ;;
    --dry-run) MODE="dry-run"; shift ;;
    -h|--help) usage; exit 0 ;;
    arm64|x86_64) ARCH="$1"; shift ;;
    *) usage >&2; fail "unknown argument: $1" ;;
  esac
done

# Re-derive the arch-dependent paths in case ARCH came from the command line.
OUT_DIR="${OUT_ROOT}/${ARCH}"
STAGE_DIR="${OUT_DIR}/stage"
CMAKE_BUILD_DIR="${OUT_DIR}/cmake"
DERIVED_DATA_DIR="${OUT_DIR}/DerivedData"

case "${ARCH}" in
  arm64)  CMAKE_OSX_ARCH="arm64";  XCODE_SCHEME="ONLYOFFICE-arm" ;;
  x86_64) CMAKE_OSX_ARCH="x86_64"; XCODE_SCHEME="ONLYOFFICE-x86_64" ;;
  *) fail "unsupported architecture: ${ARCH} (expected arm64 or x86_64)" ;;
esac

# ---------------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------------
need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    warn "missing required command: $1${2:+  (brew install $2)}"
    PREFLIGHT_FAILURES=$((PREFLIGHT_FAILURES + 1))
    return 1
  fi
  info "found $1"
}

# CMake 4 removed compatibility with the cmake_minimum_required, but still used
# by subprojects. Pass CMAKE_POLICY_VERSION_MINIMUM at configure time.
cmake_needs_policy_shim() {
  local major
  major="$(cmake --version 2>/dev/null | awk 'NR==1 { split($3, v, "."); print v[1] }')"
  [[ -n "${major}" && "${major}" -ge 4 ]]
}

preflight() {
  step "1. Preflight"

  [[ "$(uname -s)" == "Darwin" ]] || fail "this script only runs on macOS (found $(uname -s))"
  info "host: macOS $(sw_vers -productVersion) on $(uname -m)"

  if [[ "$(uname -m)" != "arm64" && "${ARCH}" == "arm64" ]]; then
    warn "building arm64 on a $(uname -m) host is not supported"
    PREFLIGHT_FAILURES=$((PREFLIGHT_FAILURES + 1))
  fi

  if ! xcode-select -p >/dev/null 2>&1; then
    warn "no Xcode selected -- run: sudo xcode-select -s /Applications/Xcode.app"
    PREFLIGHT_FAILURES=$((PREFLIGHT_FAILURES + 1))
  else
    info "Xcode: $(xcodebuild -version 2>/dev/null | head -1) at $(xcode-select -p)"
  fi

  need_cmd git
  need_cmd python3 python
  need_cmd cmake cmake
  need_cmd ninja ninja
  need_cmd pkg-config pkg-config

  # vcpkg builds hunspell through autotools on macOS
  need_cmd autoconf autoconf
  need_cmd aclocal automake
  need_cmd glibtoolize libtool

  if command -v ccache >/dev/null 2>&1; then
    info "found ccache -- compiler cache enabled"
  else
    warn "ccache not found -- building without a compiler cache (brew install ccache)"
  fi

  if cmake_needs_policy_shim; then
    info "cmake $(cmake --version | awk 'NR==1{print $3}') -- passing CMAKE_POLICY_VERSION_MINIMUM=3.10"
  fi

  if [[ "${EO_SKIP_SPACE_CHECK:-0}" != "1" ]]; then
    local free_gib
    free_gib="$(df -g "${REPO_ROOT}" | awk 'NR==2 { print $4 }')"
    if [[ -n "${free_gib}" && "${free_gib}" -lt "${MIN_FREE_GIB}" ]]; then
      warn "only ${free_gib}GiB free under ${REPO_ROOT}; want >= ${MIN_FREE_GIB}GiB (EO_SKIP_SPACE_CHECK=1 to override)"
      PREFLIGHT_FAILURES=$((PREFLIGHT_FAILURES + 1))
    else
      info "free space: ${free_gib}GiB"
    fi
  fi

  if [[ ! -d "${REPO_ROOT}/core/DesktopEditor" || ! -d "${DESKTOP_APPS_DIR}/macos" ]]; then
    warn "submodules look uninitialised -- run: git submodule update --init --recursive"
    PREFLIGHT_FAILURES=$((PREFLIGHT_FAILURES + 1))
  else
    info "submodules present"
  fi

  if [[ ! -d "${XCODE_PROJECT}" ]]; then
    warn "Xcode project not found at ${XCODE_PROJECT}"
    PREFLIGHT_FAILURES=$((PREFLIGHT_FAILURES + 1))
  fi

  if [[ -d "${COMMON_DIR}" ]]; then
    info "common payload: ${COMMON_DIR}"
  elif [[ "${EO_SKIP_COMMON:-0}" != "1" ]] && command -v docker >/dev/null 2>&1 \
       && docker info >/dev/null 2>&1; then
    info "common payload absent; will build it with docker (phase 3b)"
  else
    warn "common payload not found at ${COMMON_DIR}, and docker is not available to build it"
    warn "  start Docker, or download the 'common-files' artifact from the build-common"
    warn "  CI job and unpack it there, or set COMMON_DIR."
    warn "  The .app cannot run without the editors payload."
    PREFLIGHT_FAILURES=$((PREFLIGHT_FAILURES + 1))
  fi

  if [[ -n "${CODESIGNING_IDENTITY}" ]]; then
    if security find-identity -v -p codesigning 2>/dev/null | grep -qF "${CODESIGNING_IDENTITY}"; then
      info "signing identity available: ${CODESIGNING_IDENTITY}"
    else
      warn "signing identity not found in the keychain: ${CODESIGNING_IDENTITY}"
      PREFLIGHT_FAILURES=$((PREFLIGHT_FAILURES + 1))
    fi
  else
    info "no CODESIGNING_IDENTITY set -- the app will be signed ad-hoc (local use only)"
  fi

  if [[ ${PREFLIGHT_FAILURES} -gt 0 ]]; then
    if [[ "${EO_INSTALL_DEPS:-0}" == "1" ]] && command -v brew >/dev/null 2>&1; then
      step "1b. Installing missing tools with Homebrew"
      brew install cmake ninja ccache pkg-config autoconf automake libtool \
        || warn "brew install reported errors"
      info "re-run the script to re-check"
    fi
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 2. Compatibility patches
# ---------------------------------------------------------------------------
# Clang is stricter than the GCC/MSVC that Windows and Linux use.
apply_patch() {
  local root="$1" patch="$2"
  [[ -f "${patch}" ]] || return 0

  if git -C "${root}" apply --unidiff-zero --reverse --check "${patch}" >/dev/null 2>&1; then
    info "already applied: $(basename "${patch}")"
    return 0
  fi
  if ! git -C "${root}" apply --unidiff-zero --check "${patch}" >/dev/null 2>&1; then
    warn "patch no longer applies (upstream may have fixed it): $(basename "${patch}")"
    return 0
  fi
  git -C "${root}" apply --unidiff-zero "${patch}"
  APPLIED_PATCHES+=("${root}|${patch}")
  info "applied: $(basename "${patch}")"
}

apply_patches() {
  step "2. Compatibility patches"
  [[ -d "${PATCH_DIR}" ]] || { info "no patches directory"; return 0; }

  local patch
  shopt -s nullglob
  for patch in "${PATCH_DIR}"/core-*.patch; do
    apply_patch "${REPO_ROOT}/core" "${patch}"
  done
  for patch in "${PATCH_DIR}"/desktop-sdk-*.patch; do
    apply_patch "${REPO_ROOT}/desktop-sdk" "${patch}"
  done
  for patch in "${PATCH_DIR}"/desktop-apps-*.patch; do
    apply_patch "${DESKTOP_APPS_DIR}" "${patch}"
  done
  shopt -u nullglob
}

# ---------------------------------------------------------------------------
# 3. vcpkg (hunspell)
# ---------------------------------------------------------------------------
ensure_vcpkg() {
  step "3. vcpkg"
  if [[ ! -x "${VCPKG_ROOT}/vcpkg" ]]; then
    if [[ ! -d "${VCPKG_ROOT}/.git" ]]; then
      info "cloning vcpkg into ${VCPKG_ROOT}"
      git clone https://github.com/microsoft/vcpkg.git "${VCPKG_ROOT}"
    fi
    "${VCPKG_ROOT}/bootstrap-vcpkg.sh" -disableMetrics
  fi
  info "VCPKG_ROOT=${VCPKG_ROOT}"
  info "manifest mode pins versions via core/vcpkg.json's builtin-baseline"
}

# ---------------------------------------------------------------------------
# 3b. The editors payload
# ---------------------------------------------------------------------------
# Shared between all targets
build_common() {
  [[ -d "${COMMON_DIR}" ]] && return 0
  [[ "${EO_SKIP_COMMON:-0}" == "1" ]] && return 0

  step "3b. Building the editors payload (docker)"
  info "this is the long one: JS editors plus the core WASM"

  local tarball="${OUT_ROOT}/common.tar"
  rm -f "${tarball}"

  ( cd "${BUILD_DIR}" && PRODUCT_VERSION="${PRODUCT_VERSION}" BUILD_NUMBER="${BUILD_NUMBER}" \
      BUILD_ROOT="${BUILD_ROOT:-/package}" NUGET_CACHE=local \
      docker buildx bake --allow=fs.read=.. -f docker-bake.hcl desktop-common \
        --set "desktop-common.output=type=tar,dest=${tarball}" )

  [[ -f "${tarball}" ]] || fail "bake did not produce ${tarball}"

  mkdir -p "${COMMON_DIR}"
  tar -xf "${tarball}" -C "${COMMON_DIR}"
  info "common payload: ${COMMON_DIR}"
}

# ---------------------------------------------------------------------------
# 4. CMake: the native payload
# ---------------------------------------------------------------------------
cmake_build() {
  step "4. CMake configure + build"
  mkdir -p "${CMAKE_BUILD_DIR}"

  local args=(
    -S "${SCRIPT_DIR}"
    -B "${CMAKE_BUILD_DIR}"
    -G Ninja
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_OSX_ARCHITECTURES="${CMAKE_OSX_ARCH}"
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET}"
    -DCMAKE_TOOLCHAIN_FILE="${VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake"
    -DVCPKG_MANIFEST_MODE=ON
    -DVCPKG_MANIFEST_DIR="${REPO_ROOT}/core"
    -DEO_CORE_3RD_PARTY_DIR="${THIRD_PARTY_DIR}"
    -DEO_MACOS_BUNDLE_ID_PREFIX="${BUNDLE_ID}"
    -DEO_MACOS_VERSION="${PRODUCT_VERSION}"
    -DABOUT_PAGE_APP_NAME="Desktop Editors"
  )

  if cmake_needs_policy_shim; then
    args+=(-DCMAKE_POLICY_VERSION_MINIMUM=3.10)
  fi

  # Ninja (not Xcode) as the generator, as it honours 
  # CMAKE_<LANG>_COMPILER_LAUNCHER, which is how the compiler cache attaches.
  if command -v ccache >/dev/null 2>&1; then
    args+=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)
  fi

  ( set -x; cmake "${args[@]}" )
  ( set -x; cmake --build "${CMAKE_BUILD_DIR}" --parallel )
}

# ---------------------------------------------------------------------------
# 5. Stage
# ---------------------------------------------------------------------------
# Assemble the Xcode tree in $(EO_STAGE_DIR). Its layout is what build_tools 
# used to emit at build_tools/out/mac_<arch>/onlyoffice/desktopeditors.
# Fixes: Transofrm shallow CEF bundles into a proper bundle for Xcode. Keeps the
# binary, then resigns it.
make_cef_framework_versioned() {
  local fw="$1"
  [[ -d "${fw}/Versions" ]] && return 0

  mkdir -p "${fw}/Versions/A"
  local item
  for item in "Chromium Embedded Framework" Libraries Resources; do
    [[ -e "${fw}/${item}" ]] && mv "${fw}/${item}" "${fw}/Versions/A/"
  done

  ln -s A "${fw}/Versions/Current"
  ln -s "Versions/Current/Chromium Embedded Framework" "${fw}/Chromium Embedded Framework"
  ln -s Versions/Current/Libraries "${fw}/Libraries"
  ln -s Versions/Current/Resources "${fw}/Resources"
}

stage_payload() {
  step "5. Staging the native payload"

  rm -rf "${STAGE_DIR}"
  mkdir -p "${STAGE_DIR}/converter"

  local bin="${CMAKE_BUILD_DIR}/package"
  local sdk_bin="${CMAKE_BUILD_DIR}/ascdocumentscore/bin"

  [[ -d "${bin}" ]] || fail "no CMake output at ${bin} -- did the build succeed?"

  # Frameworks and helper bundles the app embeds.
  local item
  for item in "ascdocumentscore.framework" \
              "editors_helper.app" \
              "editors_helper (GPU).app" \
              "editors_helper (Renderer).app"; do
    if [[ -e "${sdk_bin}/${item}" ]]; then
      cp -R "${sdk_bin}/${item}" "${STAGE_DIR}/"
    else
      warn "missing from the SDK build output: ${item}"
    fi
  done

  # CEF, prebuilt
  local cef_framework="${THIRD_PARTY_DIR}/install/cef/Release/Chromium Embedded Framework.framework"
  if [[ -d "${cef_framework}" ]]; then
    cp -R "${cef_framework}" "${STAGE_DIR}/"
    make_cef_framework_versioned "${STAGE_DIR}/Chromium Embedded Framework.framework"
  else
    warn "CEF framework not found at ${cef_framework}"
  fi

  # Copy converter libraries and frameworks to staging
  find "${bin}" -maxdepth 1 \( -name '*.dylib' -o -type f -perm -111 \) \
    -exec cp -R {} "${STAGE_DIR}/converter/" \; 2>/dev/null || true
  find "${bin}" -maxdepth 1 -name '*.framework' -type d \
    -exec cp -R {} "${STAGE_DIR}/converter/" \; 2>/dev/null || true

  # The editors payload from build-common, overlaid as-is.
  if [[ -d "${COMMON_DIR}" ]]; then
    info "overlaying common payload from ${COMMON_DIR}"
    ditto "${COMMON_DIR}" "${STAGE_DIR}"
  else
    warn "no common payload -- the .app will build but will not run"
  fi

  # This generates explicit errors before running everything.
  local missing=()
  local entry
  for entry in index.html editors fonts providers; do
    [[ -e "${STAGE_DIR}/${entry}" ]] || missing+=("${entry}")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    warn "common payload is missing: ${missing[*]}"
    warn "  the Xcode resource copy phase will fail on the first of these."
    warn "  Check that COMMON_DIR points at the unpacked 'common-files' artifact."
  fi

  info "staged at ${STAGE_DIR}"
}

# ---------------------------------------------------------------------------
# 6. Xcode
# ---------------------------------------------------------------------------
xcode_build() {
  step "6. xcodebuild (${XCODE_SCHEME})"
  mkdir -p "${LOG_DIR}"

  local sign_args=()
  if [[ -n "${CODESIGNING_IDENTITY}" ]]; then
    sign_args+=("CODE_SIGN_IDENTITY=${CODESIGNING_IDENTITY}" "CODE_SIGN_STYLE=Manual")
    [[ -n "${DEVELOPMENT_TEAM}" ]] && sign_args+=("DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM}")
  else
    # Ad-hoc signing, not distributable
    sign_args+=("CODE_SIGN_IDENTITY=-" "CODE_SIGN_STYLE=Manual" "CODE_SIGNING_REQUIRED=NO" "CODE_SIGNING_ALLOWED=YES")
  fi

  ( set -x; xcodebuild \
      -project "${XCODE_PROJECT}" \
      -scheme "${XCODE_SCHEME}" \
      -configuration Release \
      -derivedDataPath "${DERIVED_DATA_DIR}" \
      ARCHS="${CMAKE_OSX_ARCH}" \
      ONLY_ACTIVE_ARCH=NO \
      MACOSX_DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET}" \
      EO_STAGE_DIR="${STAGE_DIR}" \
      MARKETING_VERSION="${PRODUCT_VERSION}" \
      CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
      "${sign_args[@]}" \
      build )

  local built="${DERIVED_DATA_DIR}/Build/Products/Release/${APP_NAME}.app"
  [[ -d "${built}" ]] || fail "expected ${built} but it was not produced"

  rm -rf "${OUT_DIR}/${APP_NAME}.app"
  ditto "${built}" "${OUT_DIR}/${APP_NAME}.app"
  info "app: ${OUT_DIR}/${APP_NAME}.app"
}

# ---------------------------------------------------------------------------
# 7. Verify
# ---------------------------------------------------------------------------
# Sign all bundles, even locally, so that it can also be tested locally.
adhoc_sign() {
  [[ -n "${CODESIGNING_IDENTITY}" ]] && return 0
  step "6b. Ad-hoc signing nested bundles"

  local app="${OUT_DIR}/${APP_NAME}.app"
  local bundle
  while IFS= read -r bundle; do
    codesign --force --sign - --timestamp=none "${bundle}" >/dev/null 2>&1 \
      || warn "could not ad-hoc sign ${bundle##*/}"
  done < <(find "${app}/Contents/Frameworks" -maxdepth 1 \( -name '*.framework' -o -name '*.app' \) 2>/dev/null)

  codesign --force --sign - --timestamp=none "${app}" >/dev/null 2>&1 \
    || warn "could not ad-hoc sign the app"
}

verify_app() {
  step "7. Verifying"
  local app="${OUT_DIR}/${APP_NAME}.app"

  codesign --verify --deep --strict --verbose=2 "${app}" \
    || warn "codesign verification reported problems"

  if [[ -n "${CODESIGNING_IDENTITY}" ]]; then
    spctl --assess --type execute --verbose=4 "${app}" \
      || warn "Gatekeeper assessment failed (expected until the app is notarised)"
  fi

  # Check for launch
  if [[ "${EO_SKIP_LAUNCH:-0}" == "1" ]]; then
    info "launch check skipped (EO_SKIP_LAUNCH=1)"
    return 0
  fi

  info "launch check"

  local exe="${app}/Contents/MacOS/${APP_NAME}"
  local before
  before="$(pgrep -f "${exe}" 2>/dev/null | sort -u || true)"

  open -n "${app}" >/dev/null 2>&1 || { warn "could not launch the app"; return 0; }

  local waited=0 now new
  while (( waited < 30 )); do
    sleep 1
    waited=$((waited + 1))
    now="$(pgrep -f "${exe}" 2>/dev/null | sort -u || true)"
    new="$(comm -13 <(printf '%s\n' "${before}") <(printf '%s\n' "${now}") | tr -d ' ')"
    if [[ -n "${new}" ]]; then
      # wait a sec, cef or bundle failure will show almost immediately
      sleep 4
      if kill -0 ${new} 2>/dev/null; then
        info "app still running ${waited}s after launch (pid ${new//$'\n'/ })"
        kill ${new} 2>/dev/null || true
        return 0
      fi
      warn "app started but exited immediately -- check the bundle's dependencies"
      return 0
    fi
  done
  warn "app did not appear as a running process within 30s"
}

# ---------------------------------------------------------------------------
# 8. Package
# ---------------------------------------------------------------------------
make_dmg() {
  [[ "${EO_MAKE_DMG:-0}" == "1" ]] || return 0
  step "8. Packaging .dmg"

  local app="${OUT_DIR}/${APP_NAME}.app"
  local dmg="${OUT_DIR}/${APP_NAME}-${PRODUCT_VERSION}-${ARCH}.dmg"
  local staging="${OUT_DIR}/dmg-staging"

  rm -rf "${staging}" "${dmg}"
  mkdir -p "${staging}"
  ditto "${app}" "${staging}/${APP_NAME}.app"
  ln -s /Applications "${staging}/Applications"

  hdiutil create -volname "${APP_NAME}" -srcfolder "${staging}" -ov -format UDZO "${dmg}"
  rm -rf "${staging}"
  info "dmg: ${dmg}"
}

# ---------------------------------------------------------------------------
# Dry run
# ---------------------------------------------------------------------------
dry_run() {
  cat <<EOF

Dry run -- nothing below is executed.

  target arch            ${ARCH}
  deployment target      ${MACOS_DEPLOYMENT_TARGET}
  repo root              ${REPO_ROOT}
  common payload         ${COMMON_DIR}
  third-party install    ${THIRD_PARTY_DIR}/install
  cmake build dir        ${CMAKE_BUILD_DIR}
  stage dir              ${STAGE_DIR}
  Xcode project          ${XCODE_PROJECT}
  Xcode scheme           ${XCODE_SCHEME}
  derived data           ${DERIVED_DATA_DIR}
  output app             ${OUT_DIR}/${APP_NAME}.app
  signing                ${CODESIGNING_IDENTITY:-ad-hoc (-)}

Phases:
  2. apply $(ls "${PATCH_DIR}"/*.patch 2>/dev/null | wc -l | tr -d ' ') compatibility patch(es), reverted on exit
  3. bootstrap vcpkg at ${VCPKG_ROOT}
  4. cmake -S ${SCRIPT_DIR} -B ${CMAKE_BUILD_DIR} -G Ninja
  5. stage frameworks, helper bundles, CEF, converter, common payload
  6. xcodebuild -scheme ${XCODE_SCHEME} EO_STAGE_DIR=${STAGE_DIR}
  7. codesign --verify + launch check
  8. dmg: ${EO_MAKE_DMG:-0}

EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  case "${MODE}" in
    check)
      if preflight; then
        close_group
        info "preflight passed -- ready to build"
        exit 0
      fi
      close_group
      fail "preflight found ${PREFLIGHT_FAILURES} problem(s)"
      ;;
    dry-run)
      preflight || warn "preflight found ${PREFLIGHT_FAILURES} problem(s)"
      close_group
      dry_run
      exit 0
      ;;
  esac

  preflight || fail "preflight found ${PREFLIGHT_FAILURES} problem(s); fix them or run with --check for detail"

  apply_patches
  ensure_vcpkg
  build_common

  if [[ "${EO_SKIP_THIRD_PARTY:-0}" != "1" ]]; then
    : 
  fi

  cmake_build
  stage_payload

  if [[ "${EO_SKIP_XCODE:-0}" == "1" ]]; then
    close_group
    info "EO_SKIP_XCODE=1 -- stopping after the native payload"
    exit 0
  fi

  xcode_build
  adhoc_sign
  verify_app
  make_dmg

  close_group
  info "done: ${OUT_DIR}/${APP_NAME}.app"
}

main
