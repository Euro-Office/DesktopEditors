#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${BUILD_DIR}/.." && pwd)"

PRODUCT_NAME="${PRODUCT_NAME:-Euro-Office}"
BUNDLE_ID="${PRODUCT_BUNDLE_IDENTIFIER:-org.euro-office.desktopeditors}"
SCHEME="${SCHEME:-ONLYOFFICE-arm}"
ARCH="${1:-}"
BUILD_TOOLS_REV="${BUILD_TOOLS_REV:-c5f6c2e02b50dfcc5c53a207f9a6cde84896de91}"
BUILD_TOOLS_PLATFORM="${BUILD_TOOLS_PLATFORM:-mac_arm64}"
MIN_FREE_GIB="${MIN_FREE_GIB:-150}"
QT_DIR="${QT_DIR:-${REPO_ROOT}/_qt}"

OUT_DIR="${BUILD_DIR}/deploy/macos/arm64"
LOG_DIR="${BUILD_DIR}/deploy/macos/logs"
DERIVED_DATA_DIR="${BUILD_DIR}/deploy/macos/DerivedData/arm64"
BUILD_TOOLS_DIR="${REPO_ROOT}/build_tools"
DESKTOP_APPS_DIR="${DESKTOP_APPS_DIR:-${REPO_ROOT}/desktop-apps}"
XCODE_PROJECT="${DESKTOP_APPS_DIR}/macos/ONLYOFFICE.xcodeproj"

PREFLIGHT_FAILURES=0

usage() {
  cat <<EOF
Usage:
  ./macos/build.sh --check
  ./macos/build.sh arm64

Environment:
  MIN_FREE_GIB=150
  EO_SKIP_SPACE_CHECK=1
  QT_DIR=/path/to/qt-layout
  BUILD_TOOLS_REV=${BUILD_TOOLS_REV}
  CODESIGNING_IDENTITY="Developer ID Application: ..."
  DEVELOPMENT_TEAM=<team-id>
  EO_SKIP_LAUNCH=1
EOF
}

info() {
  printf '[macos] %s\n' "$*"
}

warn() {
  printf '[macos] warning: %s\n' "$*" >&2
}

fail() {
  printf '[macos] error: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    warn "missing required command: ${cmd}"
    PREFLIGHT_FAILURES=$((PREFLIGHT_FAILURES + 1))
  fi
}

check_optional_cmd() {
  local cmd="$1"
  if command -v "${cmd}" >/dev/null 2>&1; then
    info "found optional command: ${cmd}"
  else
    warn "missing optional command: ${cmd}"
  fi
}

free_gib() {
  df -Pk "${REPO_ROOT}" | awk 'NR == 2 { print int($4 / 1024 / 1024) }'
}

check_disk_space() {
  if [[ "${EO_SKIP_SPACE_CHECK:-0}" == "1" ]]; then
    warn "skipping disk-space check because EO_SKIP_SPACE_CHECK=1"
    return
  fi

  local available
  available="$(free_gib)"
  if [[ "${available}" -lt "${MIN_FREE_GIB}" ]]; then
    warn "only ${available}GiB free under ${REPO_ROOT}; macOS builds usually need at least ${MIN_FREE_GIB}GiB"
    PREFLIGHT_FAILURES=$((PREFLIGHT_FAILURES + 1))
  else
    info "free disk space: ${available}GiB"
  fi
}

check_xcode() {
  local developer_dir
  developer_dir="$(xcode-select -p 2>/dev/null || true)"
  if [[ -z "${developer_dir}" ]]; then
    warn "xcode-select is not configured"
    PREFLIGHT_FAILURES=$((PREFLIGHT_FAILURES + 1))
    return
  fi

  info "Xcode developer dir: ${developer_dir}"
  xcodebuild -version 2>/dev/null | sed 's/^/[macos] /' || {
    warn "xcodebuild is installed but not usable"
    PREFLIGHT_FAILURES=$((PREFLIGHT_FAILURES + 1))
  }
}

discover_homebrew_qt() {
  local prefix=""

  if command -v brew >/dev/null 2>&1; then
    prefix="$(brew --prefix qt@5 2>/dev/null || true)"
    if [[ -z "${prefix}" ]]; then
      prefix="$(brew --prefix qt@6 2>/dev/null || true)"
    fi
    if [[ -z "${prefix}" ]]; then
      prefix="$(brew --prefix qt 2>/dev/null || true)"
    fi
  fi

  if [[ -z "${prefix}" ]] && command -v qmake >/dev/null 2>&1; then
    prefix="$(cd "$(dirname "$(command -v qmake)")/.." && pwd)"
  fi

  if [[ -n "${prefix}" && -x "${prefix}/bin/qmake" ]]; then
    printf '%s\n' "${prefix}"
  fi
}

check_qt() {
  if [[ -x "${QT_DIR}/macos/bin/qmake" ]]; then
    info "Qt layout found: ${QT_DIR}/macos"
    return
  fi

  if [[ -x "${QT_DIR}/clang_64/bin/qmake" ]]; then
    info "Qt layout found: ${QT_DIR}/clang_64"
    return
  fi

  local homebrew_qt
  homebrew_qt="$(discover_homebrew_qt || true)"
  if [[ -n "${homebrew_qt}" ]]; then
    info "Qt found via Homebrew/qmake: ${homebrew_qt}"
    info "build.sh will create a local Qt layout under ${QT_DIR}/macos during the build"
    return
  fi

  warn "Qt was not found. Set QT_DIR to a layout containing macos/bin/qmake or clang_64/bin/qmake."
  PREFLIGHT_FAILURES=$((PREFLIGHT_FAILURES + 1))
}

check_signing() {
  local identities
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  if printf '%s\n' "${identities}" | grep -q '0 valid identities found'; then
    warn "no valid code-signing identities found; build will use ad-hoc signing"
    return
  fi

  if [[ -n "${CODESIGNING_IDENTITY:-}" ]]; then
    info "CODESIGNING_IDENTITY is set"
  fi

  if [[ -n "${identities}" ]]; then
    printf '%s\n' "${identities}" | sed 's/^/[macos] signing: /'
  else
    warn "could not inspect code-signing identities; build will use ad-hoc signing unless configured"
  fi
}

preflight() {
  PREFLIGHT_FAILURES=0

  if [[ "$(uname -s)" != "Darwin" ]]; then
    warn "macOS build must run on Darwin"
    PREFLIGHT_FAILURES=$((PREFLIGHT_FAILURES + 1))
  fi

  need_cmd git
  need_cmd python3
  need_cmd xcode-select
  need_cmd xcodebuild
  need_cmd xcrun
  need_cmd plutil
  need_cmd codesign
  need_cmd security
  need_cmd ditto
  need_cmd file
  check_optional_cmd gh

  check_disk_space
  check_xcode
  check_qt
  check_signing

  if [[ "${PREFLIGHT_FAILURES}" -ne 0 ]]; then
    fail "preflight failed with ${PREFLIGHT_FAILURES} blocking issue(s)"
  fi
}

ensure_arm64_host() {
  if [[ "$(uname -m)" != "arm64" ]]; then
    fail "arm64 build requested on non-arm64 host ($(uname -m)); universal/x86_64 support is not wired yet"
  fi
}

ensure_submodules() {
  info "syncing submodules"
  git -C "${REPO_ROOT}" config --local url.https://github.com/.insteadOf git@github.com:
  git -C "${REPO_ROOT}" submodule sync --recursive
  git -C "${REPO_ROOT}" submodule update --init --recursive
}

ensure_build_tools() {
  if [[ ! -d "${BUILD_TOOLS_DIR}/.git" ]]; then
    info "cloning ONLYOFFICE/build_tools into ${BUILD_TOOLS_DIR}"
    git clone --filter=blob:none https://github.com/ONLYOFFICE/build_tools.git "${BUILD_TOOLS_DIR}"
  fi

  info "checking out build_tools ${BUILD_TOOLS_REV}"
  git -C "${BUILD_TOOLS_DIR}" fetch --tags origin
  git -C "${BUILD_TOOLS_DIR}" checkout "${BUILD_TOOLS_REV}"
}

copy_qt_layout_from_prefix() {
  local prefix="$1"
  local target="${QT_DIR}/macos"

  info "creating local Qt layout at ${target} from ${prefix}"
  rm -rf "${target}"
  mkdir -p "${target}"

  local item name
  for item in "${prefix}"/*; do
    name="$(basename "${item}")"
    if [[ "${name}" == "mkspecs" ]]; then
      cp -R "${item}" "${target}/${name}"
    else
      ln -s "${item}" "${target}/${name}"
    fi
  done
}

ensure_qt_layout() {
  if [[ -x "${QT_DIR}/macos/bin/qmake" || -x "${QT_DIR}/clang_64/bin/qmake" ]]; then
    info "using Qt layout at ${QT_DIR}"
    return
  fi

  local homebrew_qt
  homebrew_qt="$(discover_homebrew_qt || true)"
  if [[ -z "${homebrew_qt}" ]]; then
    fail "Qt was not found. Install Qt or set QT_DIR to a layout containing macos/bin/qmake or clang_64/bin/qmake."
  fi

  copy_qt_layout_from_prefix "${homebrew_qt}"
}

build_native_payload() {
  mkdir -p "${LOG_DIR}"
  info "building native desktop payload via build_tools (${BUILD_TOOLS_PLATFORM})"

  (
    cd "${BUILD_TOOLS_DIR}"
    python3 configure.py \
      --update=0 \
      --module=desktop \
      --platform="${BUILD_TOOLS_PLATFORM}" \
      --qt-dir="${QT_DIR}" \
      --clean=1 \
      --git-protocol=https
    python3 make.py
  ) 2>&1 | tee "${LOG_DIR}/build-tools-${BUILD_TOOLS_PLATFORM}.log"

  local payload_dir="${BUILD_TOOLS_DIR}/out/${BUILD_TOOLS_PLATFORM}/onlyoffice/desktopeditors"
  if [[ ! -d "${payload_dir}" ]]; then
    fail "expected desktop payload was not produced: ${payload_dir}"
  fi

  info "native payload ready: ${payload_dir}"
}

build_xcode_app() {
  mkdir -p "${OUT_DIR}" "${LOG_DIR}"

  if [[ ! -d "${XCODE_PROJECT}" ]]; then
    fail "Xcode project not found: ${XCODE_PROJECT}"
  fi

  local sign_identity="${CODESIGNING_IDENTITY:-${CODE_SIGN_IDENTITY:--}}"
  if [[ -z "${sign_identity}" ]]; then
    sign_identity="-"
  fi

  info "building ${PRODUCT_NAME}.app with scheme ${SCHEME}"
  xcodebuild \
    -project "${XCODE_PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -derivedDataPath "${DERIVED_DATA_DIR}" \
    PRODUCT_NAME="${PRODUCT_NAME}" \
    PRODUCT_BUNDLE_IDENTIFIER="${BUNDLE_ID}" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="${sign_identity}" \
    CODESIGNING_IDENTITY="${CODESIGNING_IDENTITY:-}" \
    DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}" \
    build 2>&1 | tee "${LOG_DIR}/xcode-${SCHEME}.log"

  local products_dir="${DERIVED_DATA_DIR}/Build/Products/Release"
  local built_app="${products_dir}/${PRODUCT_NAME}.app"
  if [[ ! -d "${built_app}" ]]; then
    local candidate
    built_app=""
    for candidate in "${products_dir}"/*.app; do
      if [[ -d "${candidate}" ]]; then
        built_app="${candidate}"
        break
      fi
    done
  fi

  if [[ -z "${built_app}" || ! -d "${built_app}" ]]; then
    fail "Xcode did not produce an app bundle under ${products_dir}"
  fi

  rm -rf "${OUT_DIR}/${PRODUCT_NAME}.app"
  ditto "${built_app}" "${OUT_DIR}/${PRODUCT_NAME}.app"
  info "app exported to ${OUT_DIR}/${PRODUCT_NAME}.app"
}

verify_app() {
  local app="${OUT_DIR}/${PRODUCT_NAME}.app"
  local exe="${app}/Contents/MacOS/${PRODUCT_NAME}"

  if [[ ! -d "${app}" ]]; then
    fail "app bundle missing: ${app}"
  fi

  if [[ ! -x "${exe}" ]]; then
    local candidate
    exe=""
    for candidate in "${app}/Contents/MacOS"/*; do
      if [[ -f "${candidate}" && -x "${candidate}" ]]; then
        exe="${candidate}"
        break
      fi
    done
  fi

  if [[ -z "${exe}" || ! -x "${exe}" ]]; then
    fail "app executable missing under ${app}/Contents/MacOS"
  fi

  info "checking executable architecture"
  file "${exe}" | tee "${LOG_DIR}/file-${PRODUCT_NAME}.log"
  file "${exe}" | grep -q 'arm64' || fail "expected arm64 executable: ${exe}"

  info "verifying code signature"
  codesign --verify --deep --strict --verbose=4 "${app}"

  if [[ "${EO_SKIP_LAUNCH:-0}" == "1" ]]; then
    info "skipping launch smoke test because EO_SKIP_LAUNCH=1"
    return
  fi

  info "running launch smoke test"
  open -n "${app}"
  sleep 4
  if ! pgrep -x "${PRODUCT_NAME}" >/dev/null 2>&1; then
    fail "launch smoke test did not find a running ${PRODUCT_NAME} process"
  fi
  osascript -e "tell application \"${PRODUCT_NAME}\" to quit" >/dev/null 2>&1 || true
}

main() {
  case "${ARCH}" in
    -h|--help|"")
      usage
      ;;
    --check)
      preflight
      info "preflight passed"
      ;;
    arm64)
      OUT_DIR="${BUILD_DIR}/deploy/macos/${ARCH}"
      DERIVED_DATA_DIR="${BUILD_DIR}/deploy/macos/DerivedData/${ARCH}"
      preflight
      ensure_arm64_host
      ensure_submodules
      ensure_build_tools
      ensure_qt_layout
      build_native_payload
      build_xcode_app
      verify_app
      info "macOS ${ARCH} build complete: ${OUT_DIR}/${PRODUCT_NAME}.app"
      ;;
    *)
      usage
      fail "unsupported macOS architecture: ${ARCH}"
      ;;
  esac
}

main "$@"
