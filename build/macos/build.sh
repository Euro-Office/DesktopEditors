#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${BUILD_DIR}/.." && pwd)"

read_build_tools_rev() {
  local rev_file="$1"
  if [[ ! -f "${rev_file}" ]]; then
    printf '[macos] error: build tools revision file not found: %s\n' "${rev_file}" >&2
    exit 1
  fi
  tr -d '[:space:]' < "${rev_file}"
}

PRODUCT_FAMILY_NAME="${PRODUCT_FAMILY_NAME:-Euro-Office}"
PRODUCT_NAME="${PRODUCT_NAME:-${PRODUCT_FAMILY_NAME}}"
BUNDLE_ID="${PRODUCT_BUNDLE_IDENTIFIER:-org.euro-office.desktopeditors}"
MACOS_PRODUCTS="${EO_MACOS_PRODUCTS:-suite}"
SCHEME="${SCHEME:-ONLYOFFICE-arm}"
DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
  shift
fi
ARCH="${1:-}"
BUILD_TOOLS_REV_FILE="${BUILD_TOOLS_REV_FILE:-${SCRIPT_DIR}/build_tools.sha}"
BUILD_TOOLS_REV="${BUILD_TOOLS_REV:-$(read_build_tools_rev "${BUILD_TOOLS_REV_FILE}")}"
BUILD_TOOLS_PLATFORM="${BUILD_TOOLS_PLATFORM:-mac_arm64}"
MIN_FREE_GIB="${MIN_FREE_GIB:-150}"
QT_DIR="${QT_DIR:-${REPO_ROOT}/_qt}"

OUT_DIR="${BUILD_DIR}/deploy/macos/arm64"
LOG_DIR="${BUILD_DIR}/deploy/macos/logs"
DERIVED_DATA_DIR="${BUILD_DIR}/deploy/macos/DerivedData/arm64"
TOOLS_BIN_DIR="${BUILD_DIR}/deploy/macos/tools/bin"
CMAKE_VENV_DIR="${BUILD_DIR}/deploy/macos/tools/cmake-venv"
PATCH_CLEANUP_FILE="${BUILD_DIR}/deploy/macos/tools/applied-patches.$$"
BUILD_TOOLS_DIR="${REPO_ROOT}/build_tools"
DESKTOP_APPS_DIR="${DESKTOP_APPS_DIR:-${REPO_ROOT}/desktop-apps}"
XCODE_PROJECT="${DESKTOP_APPS_DIR}/macos/ONLYOFFICE.xcodeproj"
PATCH_DIR="${SCRIPT_DIR}/patches"

PREFLIGHT_FAILURES=0
EXTERNAL_DESKTOP_APPS_LINK=""
EXTERNAL_REPO_SIBLING_LINKS=()
BUILT_XCODE_APP=""
STAGED_APPS=()

cleanup_external_desktop_apps_link() {
  if [[ -n "${EXTERNAL_DESKTOP_APPS_LINK}" && -L "${EXTERNAL_DESKTOP_APPS_LINK}" ]]; then
    rm "${EXTERNAL_DESKTOP_APPS_LINK}"
    mkdir -p "${EXTERNAL_DESKTOP_APPS_LINK}"
  fi
  local link_path
  if [[ "${#EXTERNAL_REPO_SIBLING_LINKS[@]}" -gt 0 ]]; then
    for link_path in "${EXTERNAL_REPO_SIBLING_LINKS[@]}"; do
      if [[ -L "${link_path}" ]]; then
        rm "${link_path}"
      fi
    done
  fi
}

cleanup_applied_patches() {
  local record patch_root patch_file
  if [[ ! -f "${PATCH_CLEANUP_FILE}" ]]; then
    return
  fi

  while IFS= read -r record; do
    [[ -z "${record}" ]] && continue
    patch_root="${record%%|*}"
    patch_file="${record#*|}"
    if git -C "${patch_root}" apply --unidiff-zero --reverse --check "${patch_file}" >/dev/null 2>&1; then
      git -C "${patch_root}" apply --unidiff-zero --reverse "${patch_file}" || true
    fi
  done < "${PATCH_CLEANUP_FILE}"
  rm -f "${PATCH_CLEANUP_FILE}"
}

cleanup() {
  cleanup_applied_patches
  cleanup_external_desktop_apps_link
}

trap cleanup EXIT

usage() {
  cat <<EOF
Usage:
  ./macos/build.sh --check
  ./macos/build.sh --dry-run arm64
  ./macos/build.sh arm64

Environment:
  MIN_FREE_GIB=150
  EO_SKIP_SPACE_CHECK=1
  QT_DIR=/path/to/qt-root
  BUILD_TOOLS_REV_FILE=${BUILD_TOOLS_REV_FILE}
  BUILD_TOOLS_REV=${BUILD_TOOLS_REV}
  EO_MACOS_PRODUCTS=suite
  EO_ALLOW_GIT_HTTPS_FALLBACK=1
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

cmake_version() {
  "$1" --version 2>/dev/null | awk 'NR == 1 { print $3 }'
}

cmake_is_compatible_version() {
  local version="$1"
  local major minor

  IFS=. read -r major minor _ <<< "${version}"
  if [[ ! "${major}" =~ ^[0-9]+$ || ! "${minor}" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  if (( major != 3 )); then
    return 1
  fi

  (( minor >= 21 ))
}

python_venv_available() {
  python3 -m venv --help >/dev/null 2>&1
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

check_cmake() {
  local needs_local_cmake=0

  if command -v cmake >/dev/null 2>&1; then
    local cmake_path cmake_found_version
    cmake_path="$(command -v cmake)"
    cmake_found_version="$(cmake_version "${cmake_path}")"
    if cmake_is_compatible_version "${cmake_found_version}"; then
      info "CMake ${cmake_found_version} found: ${cmake_path}"
      return
    fi

    warn "CMake ${cmake_found_version:-unknown} found at ${cmake_path}; build_tools HEIF requires CMake >= 3.21 and < 4"
    needs_local_cmake=1
  else
    warn "CMake was not found; build.sh will create a local CMake >= 3.21 and < 4"
    needs_local_cmake=1
  fi

  if [[ "${needs_local_cmake}" == "1" ]]; then
    if python_venv_available; then
      info "build.sh will create a local CMake venv under ${CMAKE_VENV_DIR}"
    else
      warn "python3 venv support is required to create a local compatible CMake"
      PREFLIGHT_FAILURES=$((PREFLIGHT_FAILURES + 1))
    fi
  fi
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

qt_dir_name_has_version() {
  local dir_name
  dir_name="$(basename "$1")"
  [[ "${dir_name}" =~ [0-9]+\.[0-9]+ ]]
}

qt_prefix_version() {
  local prefix="$1"
  local version
  version="$("${prefix}/bin/qmake" -query QT_VERSION 2>/dev/null | sed 's/^QT_VERSION://')"
  if [[ -z "${version}" ]]; then
    fail "could not determine Qt version from ${prefix}/bin/qmake"
  fi
  printf '%s\n' "${version}"
}

has_versioned_qt_layout() {
  local layout_root="$1"

  if [[ ! -x "${layout_root}/macos/bin/qmake" && ! -x "${layout_root}/clang_64/bin/qmake" ]]; then
    return 1
  fi

  if qt_dir_name_has_version "${layout_root}"; then
    return 0
  fi

  warn "ignoring Qt layout without versioned parent: ${layout_root}"
  return 1
}

check_qt() {
  if has_versioned_qt_layout "${QT_DIR}"; then
    info "Qt layout found: ${QT_DIR}"
    return
  fi

  local homebrew_qt
  homebrew_qt="$(discover_homebrew_qt || true)"
  if [[ -n "${homebrew_qt}" ]]; then
    local qt_version
    qt_version="$(qt_prefix_version "${homebrew_qt}")"
    info "Qt found via Homebrew/qmake: ${homebrew_qt}"
    info "build.sh will create a local Qt layout under ${QT_DIR}/${qt_version}/macos during the build"
    return
  fi

  warn "Qt was not found. Set QT_DIR to a build_tools layout root containing <version>/macos/bin/qmake or <version>/clang_64/bin/qmake."
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
  check_cmake
  check_qt
  check_signing

  if [[ "${PREFLIGHT_FAILURES}" -ne 0 ]]; then
    fail "preflight failed with ${PREFLIGHT_FAILURES} blocking issue(s)"
  fi
}

dry_run_existing_target() {
  local path="$1"

  if [[ -e "${path}" || -L "${path}" ]]; then
    resolved_path "${path}"
  else
    printf 'absent'
  fi
}

dry_run_sibling_link() {
  local name="$1"
  local target_dir="$2"
  local parent_dir="$3"
  local link_path="${parent_dir}/${name}"
  local current_target

  current_target="$(dry_run_existing_target "${link_path}")"
  info "dry-run: Xcode sibling ${name}: ${link_path} -> ${target_dir} (current: ${current_target})"
}

dry_run() {
  OUT_DIR="${BUILD_DIR}/deploy/macos/${ARCH}"
  DERIVED_DATA_DIR="${BUILD_DIR}/deploy/macos/DerivedData/${ARCH}"

  if [[ "${ARCH}" != "arm64" ]]; then
    fail "--dry-run currently supports arm64 only"
  fi

  local products
  products="$(selected_products | paste -sd, -)"

  info "dry-run: no submodules, symlinks, patches, build outputs, or git config will be changed"
  info "dry-run: product output: ${OUT_DIR}/${PRODUCT_NAME}.app"
  info "dry-run: bundle identifier: ${BUNDLE_ID}"
  info "dry-run: products: ${products}"
  info "dry-run: build_tools revision file: ${BUILD_TOOLS_REV_FILE}"
  info "dry-run: build_tools revision: ${BUILD_TOOLS_REV}"
  info "dry-run: Xcode project: ${XCODE_PROJECT}"
  info "dry-run: DerivedData: ${DERIVED_DATA_DIR}"
  info "dry-run: compatibility patches: ${PATCH_DIR}"

  if [[ "$(uname -s)" != "Darwin" ]]; then
    warn "dry-run: macOS build must run on Darwin; current host is $(uname -s)"
  fi

  if [[ "$(uname -m)" != "arm64" ]]; then
    warn "dry-run: arm64 build requested on $(uname -m); the real build will fail on this host"
  fi

  if [[ "${EO_ALLOW_GIT_HTTPS_FALLBACK:-0}" == "1" ]]; then
    info "dry-run: would opt in to local git@github.com: -> https://github.com/ rewrite if none exists"
  else
    info "dry-run: would leave git@github.com: submodule URLs unchanged"
  fi

  local default_desktop_apps_dir="${REPO_ROOT}/desktop-apps"
  local absolute_desktop_apps_dir
  absolute_desktop_apps_dir="$(absolute_path "${DESKTOP_APPS_DIR}")"

  if [[ "${absolute_desktop_apps_dir}" == "${default_desktop_apps_dir}" ]]; then
    info "dry-run: would use desktop-apps submodule in place: ${default_desktop_apps_dir}"
  else
    local resolved_default resolved_external desktop_apps_parent
    resolved_default="$(dry_run_existing_target "${default_desktop_apps_dir}")"
    if [[ -e "${DESKTOP_APPS_DIR}" || -L "${DESKTOP_APPS_DIR}" ]]; then
      resolved_external="$(resolved_path "${DESKTOP_APPS_DIR}")"
    else
      resolved_external="missing"
    fi
    desktop_apps_parent="$(cd "$(dirname "${DESKTOP_APPS_DIR}")" && pwd)"

    info "dry-run: external desktop-apps checkout: ${DESKTOP_APPS_DIR} (resolved: ${resolved_external})"
    info "dry-run: build_tools desktop-apps link: ${default_desktop_apps_dir} -> ${DESKTOP_APPS_DIR} (current: ${resolved_default})"
    dry_run_sibling_link build_tools "${BUILD_TOOLS_DIR}" "${desktop_apps_parent}"
    dry_run_sibling_link core "${REPO_ROOT}/core" "${desktop_apps_parent}"
    dry_run_sibling_link desktop-sdk "${REPO_ROOT}/desktop-sdk" "${desktop_apps_parent}"
    dry_run_sibling_link dictionaries "${REPO_ROOT}/dictionaries" "${desktop_apps_parent}"
  fi

  if has_versioned_qt_layout "${QT_DIR}"; then
    info "dry-run: would use Qt layout at ${QT_DIR}"
  else
    local homebrew_qt
    homebrew_qt="$(discover_homebrew_qt || true)"
    if [[ -n "${homebrew_qt}" ]]; then
      info "dry-run: would create build_tools Qt layout under ${QT_DIR} from ${homebrew_qt}"
    else
      warn "dry-run: Qt was not found; the real build needs QT_DIR or a Homebrew Qt install"
    fi
  fi

  info "dry-run: would update submodules, checkout build_tools, apply reviewed patches, build native payload, run xcodebuild, stage ${PRODUCT_NAME}.app, verify codesign and launch"
}

ensure_arm64_host() {
  if [[ "$(uname -m)" != "arm64" ]]; then
    fail "arm64 build requested on non-arm64 host ($(uname -m)); universal/x86_64 support is not wired yet"
  fi
}

is_empty_dir() {
  local dir="$1"
  [[ -d "${dir}" ]] && [[ -z "$(find "${dir}" -mindepth 1 -maxdepth 1 -print -quit)" ]]
}

resolved_path() {
  local path="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath "${path}"
    return
  fi

  python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "${path}"
}

absolute_path() {
  local path="$1"
  printf '%s/%s\n' "$(cd "$(dirname "${path}")" && pwd)" "$(basename "${path}")"
}

ensure_external_repo_sibling_for_xcode() {
  local name="$1"
  local target_dir="$2"
  local desktop_apps_parent
  local link_path
  local resolved_target_dir

  desktop_apps_parent="$(cd "${DESKTOP_APPS_DIR}/.." && pwd)"
  link_path="${desktop_apps_parent}/${name}"
  resolved_target_dir="$(resolved_path "${target_dir}")"

  if [[ -e "${link_path}" || -L "${link_path}" ]]; then
    local resolved_link_path
    resolved_link_path="$(resolved_path "${link_path}")"
    if [[ "${resolved_link_path}" != "${resolved_target_dir}" ]]; then
      fail "${link_path} already resolves to ${resolved_link_path}, expected ${resolved_target_dir}"
    fi
    if [[ -L "${link_path}" ]]; then
      info "using existing ${name} symlink: ${link_path}"
    fi
    return
  fi

  if [[ ! -d "${target_dir}" ]]; then
    fail "${target_dir} does not exist; cannot link ${name} for Xcode relative paths"
  fi

  ln -s "${target_dir}" "${link_path}"
  EXTERNAL_REPO_SIBLING_LINKS+=("${link_path}")
  info "linked ${name} into ${link_path} for Xcode relative paths"
}

ensure_external_repo_siblings_for_xcode() {
  local default_desktop_apps_dir="${REPO_ROOT}/desktop-apps"
  local absolute_desktop_apps_dir
  absolute_desktop_apps_dir="$(absolute_path "${DESKTOP_APPS_DIR}")"

  if [[ "${absolute_desktop_apps_dir}" == "${default_desktop_apps_dir}" ]]; then
    return
  fi

  ensure_external_repo_sibling_for_xcode build_tools "${BUILD_TOOLS_DIR}"
  ensure_external_repo_sibling_for_xcode core "${REPO_ROOT}/core"
  ensure_external_repo_sibling_for_xcode desktop-sdk "${REPO_ROOT}/desktop-sdk"
  ensure_external_repo_sibling_for_xcode dictionaries "${REPO_ROOT}/dictionaries"
}

ensure_external_desktop_apps_for_build_tools() {
  local default_desktop_apps_dir="${REPO_ROOT}/desktop-apps"
  local absolute_desktop_apps_dir
  local resolved_desktop_apps_dir
  absolute_desktop_apps_dir="$(absolute_path "${DESKTOP_APPS_DIR}")"
  resolved_desktop_apps_dir="$(resolved_path "${DESKTOP_APPS_DIR}")"

  if [[ "${absolute_desktop_apps_dir}" == "${default_desktop_apps_dir}" ]]; then
    return
  fi

  if [[ ! -d "${DESKTOP_APPS_DIR}" ]]; then
    fail "external desktop-apps checkout not found: ${DESKTOP_APPS_DIR}"
  fi

  if [[ -L "${default_desktop_apps_dir}" ]]; then
    local linked_target
    linked_target="$(resolved_path "${default_desktop_apps_dir}")"
    if [[ "${linked_target}" != "${resolved_desktop_apps_dir}" ]]; then
      fail "${default_desktop_apps_dir} already points to ${linked_target}, expected ${resolved_desktop_apps_dir}"
    fi
    info "using existing desktop-apps symlink: ${default_desktop_apps_dir}"
    return
  fi

  if [[ -e "${default_desktop_apps_dir}" ]]; then
    if ! is_empty_dir "${default_desktop_apps_dir}"; then
      fail "${default_desktop_apps_dir} exists and is not empty; cannot link external desktop-apps checkout"
    fi
    rmdir "${default_desktop_apps_dir}"
  fi

  ln -s "${DESKTOP_APPS_DIR}" "${default_desktop_apps_dir}"
  EXTERNAL_DESKTOP_APPS_LINK="${default_desktop_apps_dir}"
  info "linked external desktop-apps checkout into ${default_desktop_apps_dir} for build_tools"
}

ensure_submodules() {
  info "syncing submodules"
  if git -C "${REPO_ROOT}" config --local --get-regexp '^url\..*\.insteadOf$' 2>/dev/null | grep -q 'git@github.com:'; then
    info "using existing local git URL rewrite for git@github.com:"
  elif [[ "${EO_ALLOW_GIT_HTTPS_FALLBACK:-0}" == "1" ]]; then
    git -C "${REPO_ROOT}" config --local url.https://github.com/.insteadOf git@github.com:
    info "enabled opt-in HTTPS fallback for git@github.com: submodule URLs"
  else
    info "leaving git@github.com: submodule URLs unchanged; set EO_ALLOW_GIT_HTTPS_FALLBACK=1 to rewrite them to HTTPS"
  fi
  git -C "${REPO_ROOT}" submodule sync --recursive

  local default_desktop_apps_dir="${REPO_ROOT}/desktop-apps"
  if [[ "$(resolved_path "${DESKTOP_APPS_DIR}")" != "${default_desktop_apps_dir}" ]]; then
    info "using external desktop-apps checkout: ${DESKTOP_APPS_DIR}"
    git -C "${REPO_ROOT}" submodule update --init --recursive \
      core \
      core-fonts \
      desktop-sdk \
      dictionaries \
      document-templates \
      sdkjs \
      sdkjs-forms \
      web-apps
    ensure_external_desktop_apps_for_build_tools
    return
  fi

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

ensure_python_shim() {
  if command -v python >/dev/null 2>&1; then
    return
  fi

  mkdir -p "${TOOLS_BIN_DIR}"
  ln -sf "$(command -v python3)" "${TOOLS_BIN_DIR}/python"
  export PATH="${TOOLS_BIN_DIR}:${PATH}"
  info "using local python shim: ${TOOLS_BIN_DIR}/python -> $(command -v python3)"
}

prepend_path_var() {
  local name="$1"
  local value="$2"
  local current="${!name:-}"

  case ":${current}:" in
    *":${value}:"*) ;;
    *)
      if [[ -n "${current}" ]]; then
        export "${name}=${value}:${current}"
      else
        export "${name}=${value}"
      fi
      ;;
  esac
}

prepare_build_environment() {
  local katana_include="${REPO_ROOT}/core/Common/3dParty/html/katana-parser/src"
  local gumbo_include="${REPO_ROOT}/core/Common/3dParty/html/gumbo-parser/src"
  local hyphen_include="${REPO_ROOT}/core/Common/3dParty/hyphen"
  local hunspell_include="${REPO_ROOT}/core/Common/3dParty/hunspell/hunspell/src"

  mkdir -p "${TOOLS_BIN_DIR}"
  cat > "${TOOLS_BIN_DIR}/grunt" <<'EOF'
#!/usr/bin/env bash
set -e

dir="${PWD}"
while [[ "${dir}" != "/" ]]; do
  if [[ -x "${dir}/node_modules/.bin/grunt" ]]; then
    exec "${dir}/node_modules/.bin/grunt" "$@"
  fi
  dir="$(dirname "${dir}")"
done

echo "grunt shim: node_modules/.bin/grunt not found from ${PWD}" >&2
exit 127
EOF
  chmod +x "${TOOLS_BIN_DIR}/grunt"
  prepend_path_var PATH "${TOOLS_BIN_DIR}"

  # build_tools sets NODE_ENV=production before npm install. npm 10 honors that
  # by omitting dev dependencies, but the Grunt build files need local dev
  # helpers such as time-grunt. Clear both env spellings and explicitly include
  # dev dependencies so the behavior is stable across npm releases. The
  # production flag keeps older npm releases on the same path.
  unset NPM_CONFIG_OMIT npm_config_omit
  export NPM_CONFIG_INCLUDE=dev
  export NPM_CONFIG_PRODUCTION=false

  prepend_path_var CPATH "${katana_include}"
  prepend_path_var CPATH "${gumbo_include}"
  prepend_path_var CPATH "${hyphen_include}"
  prepend_path_var CPATH "${hunspell_include}"
  info "using local Node tool shim: ${TOOLS_BIN_DIR}/grunt"
  info "configuring npm to include dev dependencies required by Grunt build files"
  info "using qmake compatibility include paths: ${katana_include}, ${gumbo_include}, ${hyphen_include}, ${hunspell_include}"
}

reset_incomplete_boost_build() {
  local boost_build_dir="${REPO_ROOT}/core/Common/3dParty/boost/build/${BUILD_TOOLS_PLATFORM}"
  local boost_lib_dir="${boost_build_dir}/lib"

  if [[ ! -d "${boost_build_dir}" ]]; then
    return
  fi

  local required_libs=(
    libboost_system.a
    libboost_filesystem.a
    libboost_date_time.a
    libboost_regex.a
  )
  local missing=()
  local lib

  for lib in "${required_libs[@]}"; do
    if [[ ! -f "${boost_lib_dir}/${lib}" ]]; then
      missing+=("${lib}")
    fi
  done

  if [[ "${#missing[@]}" -eq 0 ]]; then
    return
  fi

  warn "removing incomplete Boost ${BUILD_TOOLS_PLATFORM} build; missing ${missing[*]}"
  rm -rf "${boost_build_dir}"
}

apply_reviewed_patch() {
  local patch_root="$1"
  local patch_file="$2"
  local description="$3"

  if [[ ! -f "${patch_file}" ]]; then
    fail "compatibility patch missing: ${patch_file}"
  fi
  if [[ ! -d "${patch_root}" ]]; then
    fail "patch root missing for ${description}: ${patch_root}"
  fi

  if git -C "${patch_root}" apply --unidiff-zero --check "${patch_file}" >/dev/null 2>&1; then
    git -C "${patch_root}" apply --unidiff-zero "${patch_file}"
    mkdir -p "$(dirname "${PATCH_CLEANUP_FILE}")"
    printf '%s|%s\n' "${patch_root}" "${patch_file}" >> "${PATCH_CLEANUP_FILE}"
    info "applied reviewed compatibility patch: ${description}"
    return
  fi

  if git -C "${patch_root}" apply --unidiff-zero --reverse --check "${patch_file}" >/dev/null 2>&1; then
    info "reviewed compatibility patch already present: ${description}"
    return
  fi

  fail "could not apply reviewed compatibility patch: ${description}"
}

prepare_boost_sources() {
  local boost_dir="${REPO_ROOT}/core/Common/3dParty/boost"
  local boost_src="${boost_dir}/boost_1_72_0"
  local date_time_src="${boost_src}/libs/date_time"
  local installed_include="${boost_dir}/build/${BUILD_TOOLS_PLATFORM}/include"

  printf '%s' 'boost_version_5' > "${boost_dir}/boost.data"

  if [[ ! -d "${boost_src}" ]]; then
    info "fetching Boost 1.72 source checkout for macOS compatibility patches"
    git -C "${boost_dir}" clone --recursive --depth=1 \
      https://github.com/boostorg/boost.git boost_1_72_0 -b boost-1.72.0
  fi

  apply_reviewed_patch \
    "${date_time_src}" \
    "${PATCH_DIR}/boost-date-time-duration.patch" \
    "Boost.DateTime source numeric casts"

  if [[ -f "${installed_include}/boost/date_time/posix_time/posix_time_duration.hpp" ]]; then
    apply_reviewed_patch \
      "${installed_include}" \
      "${PATCH_DIR}/boost-date-time-duration-installed.patch" \
      "Boost.DateTime installed header numeric casts"
  fi
}

iwork_module_version() {
  awk -F\" '/check_module_version/ { print $2; exit }' \
    "${BUILD_TOOLS_DIR}/scripts/core_common/modules/iwork.py"
}

patch_libetonyek_clang_compat() {
  local libetonyek_dir="${REPO_ROOT}/core/Common/3dParty/apple/libetonyek"
  local table_source="${libetonyek_dir}/src/lib/IWORKTable.cpp"
  local path_source="${libetonyek_dir}/src/lib/contexts/IWORKPathElement.cpp"

  if [[ ! -f "${table_source}" ]]; then
    fail "expected libetonyek source was not fetched: ${table_source}"
  fi

  if [[ ! -f "${path_source}" ]]; then
    fail "expected libetonyek source was not fetched: ${path_source}"
  fi

  apply_reviewed_patch \
    "${libetonyek_dir}" \
    "${PATCH_DIR}/libetonyek-clang-compat.patch" \
    "libetonyek numeric casts"
}

patch_odf_clang_compat() {
  apply_reviewed_patch \
    "${REPO_ROOT}/core" \
    "${PATCH_DIR}/odf-border-width-clang-compat.patch" \
    "ODF table border width casts"
}

prepare_iwork_sources() {
  local apple_dir="${REPO_ROOT}/core/Common/3dParty/apple"
  local version

  info "preparing iwork sources for macOS"
  (
    cd "${apple_dir}"
    python fetch.py
  )

  version="$(iwork_module_version)"
  if [[ -z "${version}" ]]; then
    fail "could not determine build_tools iwork module version"
  fi
  printf '%s' "${version}" > "${apple_dir}/module.version"

  patch_libetonyek_clang_compat
}

ensure_compatible_cmake() {
  local cmake_path cmake_found_version

  if command -v cmake >/dev/null 2>&1; then
    cmake_path="$(command -v cmake)"
    cmake_found_version="$(cmake_version "${cmake_path}")"
    if cmake_is_compatible_version "${cmake_found_version}"; then
      info "using CMake ${cmake_found_version}: ${cmake_path}"
      return
    fi
  fi

  if [[ -x "${CMAKE_VENV_DIR}/bin/cmake" ]]; then
    cmake_found_version="$(cmake_version "${CMAKE_VENV_DIR}/bin/cmake")"
    if ! cmake_is_compatible_version "${cmake_found_version}"; then
      rm -rf "${CMAKE_VENV_DIR}"
    fi
  fi

  if [[ ! -x "${CMAKE_VENV_DIR}/bin/cmake" ]]; then
    info "creating local CMake >= 3.21 and < 4 under ${CMAKE_VENV_DIR}"
    python_venv_available || fail "python3 venv support is required to create a local compatible CMake"
    python3 -m venv "${CMAKE_VENV_DIR}"
    "${CMAKE_VENV_DIR}/bin/python" -m pip install --upgrade pip
    "${CMAKE_VENV_DIR}/bin/python" -m pip install 'cmake>=3.21,<4'
  fi

  export PATH="${CMAKE_VENV_DIR}/bin:${PATH}"
  cmake_path="$(command -v cmake)"
  cmake_found_version="$(cmake_version "${cmake_path}")"
  if ! cmake_is_compatible_version "${cmake_found_version}"; then
    fail "compatible CMake was not found after setup; got ${cmake_found_version:-unknown} at ${cmake_path}"
  fi

  info "using local CMake ${cmake_found_version}: ${cmake_path}"
}

copy_qt_layout_from_prefix() {
  local prefix="$1"
  local qt_version
  qt_version="$(qt_prefix_version "${prefix}")"
  local layout_root="${QT_DIR}"

  if ! qt_dir_name_has_version "${layout_root}"; then
    layout_root="${QT_DIR}/${qt_version}"
  fi

  local target="${layout_root}/macos"

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

  QT_DIR="${layout_root}"
}

ensure_qt_layout() {
  if has_versioned_qt_layout "${QT_DIR}"; then
    info "using Qt layout at ${QT_DIR}"
    return
  fi

  local homebrew_qt
  homebrew_qt="$(discover_homebrew_qt || true)"
  if [[ -z "${homebrew_qt}" ]]; then
    fail "Qt was not found. Install Qt or set QT_DIR to a build_tools layout root containing <version>/macos/bin/qmake or <version>/clang_64/bin/qmake."
  fi

  copy_qt_layout_from_prefix "${homebrew_qt}"
}

build_native_payload() {
  mkdir -p "${LOG_DIR}"
  info "building native desktop payload via build_tools (${BUILD_TOOLS_PLATFORM})"
  ensure_compatible_cmake
  ensure_python_shim
  prepare_build_environment
  reset_incomplete_boost_build
  prepare_boost_sources

  (
    cd "${BUILD_TOOLS_DIR}"
    python3 configure.py \
      --update=0 \
      --module=desktop \
      --platform="${BUILD_TOOLS_PLATFORM}" \
      --qt-dir="${QT_DIR}" \
      --clean=1 \
      --git-protocol=https
    prepare_iwork_sources
    patch_odf_clang_compat
    python3 make.py
  ) 2>&1 | tee "${LOG_DIR}/build-tools-${BUILD_TOOLS_PLATFORM}.log"

  local payload_dir="${BUILD_TOOLS_DIR}/out/${BUILD_TOOLS_PLATFORM}/onlyoffice/desktopeditors"
  if [[ ! -d "${payload_dir}" ]]; then
    fail "expected desktop payload was not produced: ${payload_dir}"
  fi

  ensure_draw_empty_template "${payload_dir}"

  info "native payload ready: ${payload_dir}"
}

ensure_draw_empty_template() {
  local payload_dir="$1"
  local converter_dir="${payload_dir}/converter"
  local template="${converter_dir}/empty/new.vsdx"
  local x2t="${converter_dir}/x2t"
  local tmp_dir

  if [[ -f "${template}" ]]; then
    return
  fi

  if [[ ! -x "${x2t}" ]]; then
    fail "x2t converter missing; cannot generate Draw empty template: ${x2t}"
  fi

  mkdir -p "${converter_dir}/empty"
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/euro-office-vsdx.XXXXXX")"
  printf 'VSDY;v10;0;' > "${tmp_dir}/empty.vsdt"

  if ! "${x2t}" "${tmp_dir}/empty.vsdt" "${template}"; then
    rm -rf "${tmp_dir}"
    fail "failed to generate Draw empty template: ${template}"
  fi

  rm -rf "${tmp_dir}"

  if [[ ! -f "${template}" ]]; then
    fail "Draw empty template was not produced: ${template}"
  fi

  info "generated Draw empty template: ${template}"
}

codesign_identity() {
  local sign_identity="${CODESIGNING_IDENTITY:-${CODE_SIGN_IDENTITY:--}}"
  if [[ -z "${sign_identity}" ]]; then
    sign_identity="-"
  fi

  printf '%s\n' "${sign_identity}"
}

entitlements_file() {
  local entitlements="${DESKTOP_APPS_DIR}/macos/ONLYOFFICE/Resources/${SCHEME}/ONLYOFFICE.entitlements"
  if [[ -f "${entitlements}" ]]; then
    printf '%s\n' "${entitlements}"
  fi
}

selected_products() {
  case "${MACOS_PRODUCTS}" in
    suite)
      printf '%s\n' suite
      ;;
    *)
      fail "this Euro-Office branch exports only the suite app; set EO_MACOS_PRODUCTS=suite or use the AUTARQ branding branch for split app builds"
      ;;
  esac
}

product_app_name() {
  case "$1" in
    text) printf '%s Write\n' "${PRODUCT_FAMILY_NAME}" ;;
    spreadsheet) printf '%s Sheets\n' "${PRODUCT_FAMILY_NAME}" ;;
    presentation) printf '%s Keynote\n' "${PRODUCT_FAMILY_NAME}" ;;
    pdf) printf '%s PDF\n' "${PRODUCT_FAMILY_NAME}" ;;
    visio) printf '%s Draw\n' "${PRODUCT_FAMILY_NAME}" ;;
    suite) printf '%s\n' "${PRODUCT_NAME}" ;;
    *) fail "unknown macOS product component: $1" ;;
  esac
}

product_executable_name() {
  case "$1" in
    text) printf '%sWrite\n' "${PRODUCT_FAMILY_NAME//[^[:alnum:]]/}" ;;
    spreadsheet) printf '%sSheets\n' "${PRODUCT_FAMILY_NAME//[^[:alnum:]]/}" ;;
    presentation) printf '%sPresentation\n' "${PRODUCT_FAMILY_NAME//[^[:alnum:]]/}" ;;
    pdf) printf '%sPDF\n' "${PRODUCT_FAMILY_NAME//[^[:alnum:]]/}" ;;
    visio) printf '%sDraw\n' "${PRODUCT_FAMILY_NAME//[^[:alnum:]]/}" ;;
    suite) printf '%s\n' "${PRODUCT_NAME}" ;;
    *) fail "unknown macOS product component: $1" ;;
  esac
}

product_bundle_id() {
  case "$1" in
    text) printf '%s.write\n' "${BUNDLE_ID}" ;;
    spreadsheet) printf '%s.sheets\n' "${BUNDLE_ID}" ;;
    presentation) printf '%s.keynote\n' "${BUNDLE_ID}" ;;
    pdf) printf '%s.pdf\n' "${BUNDLE_ID}" ;;
    visio) printf '%s.draw\n' "${BUNDLE_ID}" ;;
    suite) printf '%s\n' "${BUNDLE_ID}" ;;
    *) fail "unknown macOS product component: $1" ;;
  esac
}

product_url_scheme() {
  case "$1" in
    text) printf 'euro-office-write\n' ;;
    spreadsheet) printf 'euro-office-sheets\n' ;;
    presentation) printf 'euro-office-presentation\n' ;;
    pdf) printf 'euro-office-pdf\n' ;;
    visio) printf 'euro-office-draw\n' ;;
    suite) printf 'euro-office\n' ;;
    *) fail "unknown macOS product component: $1" ;;
  esac
}

product_icon_file() {
  case "$1" in
    text) printf 'euro-office-write\n' ;;
    spreadsheet) printf 'euro-office-sheets\n' ;;
    presentation) printf 'euro-office-presentation\n' ;;
    pdf) printf 'euro-office-pdf\n' ;;
    visio) printf 'euro-office-draw\n' ;;
    suite) printf '' ;;
    *) fail "unknown macOS product component: $1" ;;
  esac
}

patch_product_info_plist() {
  local plist="$1"
  local app_name="$2"
  local executable_name="$3"
  local bundle_id="$4"
  local url_scheme="$5"
  local component="$6"
  local icon_file="$7"

  python3 - "${plist}" "${app_name}" "${executable_name}" "${bundle_id}" "${url_scheme}" "${component}" "${icon_file}" <<'PY'
import plistlib
import sys

plist_path, app_name, executable_name, bundle_id, url_scheme, component, icon_file = sys.argv[1:8]

allowed_extensions = {
    "text": {
        "docx", "doc", "odt", "ott", "rtf", "txt", "htm", "html", "dotx",
        "fodt", "xml", "epub", "mht", "fb2", "pages", "hwp", "hwpx", "hml",
    },
    "spreadsheet": {
        "xlsx", "xls", "ods", "xltx", "ots", "fods", "csv", "xlsm", "xlsb",
        "numbers",
    },
    "presentation": {
        "ppt", "pptx", "odp", "ppsx", "pps", "potx", "otp", "key", "odg",
    },
    "pdf": {
        "pdf", "docxf", "oform",
    },
    "visio": {
        "vsdx", "vssx", "vstx", "vsdm", "vssm", "vstm",
    },
}

if component not in allowed_extensions:
    raise SystemExit(f"unsupported product component: {component}")

with open(plist_path, "rb") as plist_file:
    info = plistlib.load(plist_file)

filtered_document_types = []
for document_type in info.get("CFBundleDocumentTypes", []):
    extensions = [ext.lower() for ext in document_type.get("CFBundleTypeExtensions", [])]
    if any(ext in allowed_extensions[component] for ext in extensions):
        filtered_document_types.append(document_type)

if not filtered_document_types:
    raise SystemExit(f"no document types matched product component: {component}")

info["CFBundleName"] = app_name
info["CFBundleDisplayName"] = app_name
info["CFBundleExecutable"] = executable_name
info["CFBundleIdentifier"] = bundle_id
info["EOProductComponent"] = component
if icon_file:
    info["CFBundleIconFile"] = icon_file
    info.pop("CFBundleIconName", None)
info["CFBundleURLTypes"] = [{
    "CFBundleTypeRole": "Editor",
    "CFBundleURLSchemes": [url_scheme],
}]
info["CFBundleDocumentTypes"] = filtered_document_types

with open(plist_path, "wb") as plist_file:
    plistlib.dump(info, plist_file, fmt=plistlib.FMT_XML, sort_keys=False)
PY
}

resign_app() {
  local app="$1"
  local sign_identity entitlements

  sign_identity="$(codesign_identity)"
  entitlements="$(entitlements_file)"

  local codesign_args=(--force --options runtime --sign "${sign_identity}")
  if [[ -n "${entitlements}" ]]; then
    codesign_args+=(--entitlements "${entitlements}")
  fi

  codesign "${codesign_args[@]}" "${app}"
}

build_xcode_app() {
  mkdir -p "${OUT_DIR}" "${LOG_DIR}"

  if [[ ! -d "${XCODE_PROJECT}" ]]; then
    fail "Xcode project not found: ${XCODE_PROJECT}"
  fi

  local sign_identity
  sign_identity="$(codesign_identity)"

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

  local staging_dir="${BUILD_DIR}/deploy/macos/staging/${ARCH}"
  rm -rf "${staging_dir}"
  mkdir -p "${staging_dir}"
  ditto "${built_app}" "${staging_dir}/${PRODUCT_NAME}.app"
  BUILT_XCODE_APP="${staging_dir}/${PRODUCT_NAME}.app"
  info "base app staged at ${BUILT_XCODE_APP}"
}

stage_product_app() {
  local component="$1"
  local app_name executable_name bundle_id url_scheme icon_file icon_source app old_exe candidate

  app_name="$(product_app_name "${component}")"
  executable_name="$(product_executable_name "${component}")"
  bundle_id="$(product_bundle_id "${component}")"
  url_scheme="$(product_url_scheme "${component}")"
  icon_file="$(product_icon_file "${component}")"
  app="${OUT_DIR}/${app_name}.app"

  rm -rf "${app}"
  ditto "${BUILT_XCODE_APP}" "${app}"

  if [[ "${component}" != "suite" ]]; then
    old_exe="${app}/Contents/MacOS/${PRODUCT_NAME}"
    if [[ ! -x "${old_exe}" ]]; then
      old_exe=""
      for candidate in "${app}/Contents/MacOS"/*; do
        if [[ -f "${candidate}" && -x "${candidate}" ]]; then
          old_exe="${candidate}"
          break
        fi
      done
    fi

    if [[ -z "${old_exe}" || ! -x "${old_exe}" ]]; then
      fail "app executable missing under ${app}/Contents/MacOS"
    fi

    mv "${old_exe}" "${app}/Contents/MacOS/${executable_name}"
    if [[ -n "${icon_file}" ]]; then
      icon_source="${DESKTOP_APPS_DIR}/macos/ONLYOFFICE/Resources/ProductIcons/${icon_file}.icns"
      if [[ ! -f "${icon_source}" ]]; then
        fail "product icon missing: ${icon_source}"
      fi
      cp "${icon_source}" "${app}/Contents/Resources/${icon_file}.icns"
    fi

    patch_product_info_plist "${app}/Contents/Info.plist" "${app_name}" "${executable_name}" "${bundle_id}" "${url_scheme}" "${component}" "${icon_file}"
    resign_app "${app}"
  fi

  STAGED_APPS+=("${app}")
  info "app exported to ${app}"
}

clean_macos_product_outputs() {
  if [[ -z "${OUT_DIR}" || "${OUT_DIR}" != "${BUILD_DIR}/deploy/macos/"* ]]; then
    fail "refusing to clean unexpected macOS output directory: ${OUT_DIR}"
  fi

  rm -rf \
    "${OUT_DIR}/${PRODUCT_NAME}.app" \
    "${OUT_DIR}/${PRODUCT_FAMILY_NAME}.app" \
    "${OUT_DIR}/${PRODUCT_FAMILY_NAME} Text.app" \
    "${OUT_DIR}/${PRODUCT_FAMILY_NAME} Spreadsheet.app" \
    "${OUT_DIR}/${PRODUCT_FAMILY_NAME} Sheets.app" \
    "${OUT_DIR}/${PRODUCT_FAMILY_NAME} Presentation.app" \
    "${OUT_DIR}/${PRODUCT_FAMILY_NAME} Keynote.app" \
    "${OUT_DIR}/${PRODUCT_FAMILY_NAME} PDF.app" \
    "${OUT_DIR}/${PRODUCT_FAMILY_NAME} Visio.app" \
    "${OUT_DIR}/${PRODUCT_FAMILY_NAME} Draw.app" \
    "${OUT_DIR}/Euro-Office Text.app" \
    "${OUT_DIR}/Euro-Office Spreadsheet.app" \
    "${OUT_DIR}/Euro-Office Presentation.app" \
    "${OUT_DIR}/Euro-Office PDF.app" \
    "${OUT_DIR}/Euro-Office Visio.app"
}

stage_macos_apps() {
  if [[ -z "${BUILT_XCODE_APP}" || ! -d "${BUILT_XCODE_APP}" ]]; then
    fail "base Xcode app was not staged"
  fi

  clean_macos_product_outputs
  STAGED_APPS=()

  local component
  while IFS= read -r component; do
    [[ -z "${component}" ]] && continue
    stage_product_app "${component}"
  done < <(selected_products)
}

wait_for_app_process() {
  local executable_path="$1"
  local app_name="$2"
  local attempt

  for attempt in $(seq 1 30); do
    if pgrep -f "${executable_path}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  warn "launch smoke test timed out waiting for ${app_name} after 30 seconds"
  return 1
}

verify_app() {
  local app="$1"
  local plist="${app}/Contents/Info.plist"
  local app_name executable_name bundle_id icon_file exe log_name

  if [[ ! -d "${app}" ]]; then
    fail "app bundle missing: ${app}"
  fi

  app_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "${plist}")"
  executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${plist}")"
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${plist}")"
  icon_file="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "${plist}" 2>/dev/null || true)"
  exe="${app}/Contents/MacOS/${executable_name}"
  log_name="${app_name// /-}"

  if [[ -n "${icon_file}" && ! -f "${app}/Contents/Resources/${icon_file}.icns" ]]; then
    fail "app icon missing for ${app_name}: ${icon_file}.icns"
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

  info "checking executable architecture for ${app_name}"
  file "${exe}" | tee "${LOG_DIR}/file-${log_name}.log"
  file "${exe}" | grep -q 'arm64' || fail "expected arm64 executable: ${exe}"

  info "verifying code signature for ${app_name}"
  codesign --verify --deep --strict --verbose=4 "${app}"

  if [[ "${EO_SKIP_LAUNCH:-0}" == "1" ]]; then
    info "skipping launch smoke test because EO_SKIP_LAUNCH=1"
    return
  fi

  info "running launch smoke test for ${app_name}"
  open -n "${app}"
  if ! wait_for_app_process "${app}/Contents/MacOS/${executable_name}" "${app_name}"; then
    fail "launch smoke test did not find a running ${app_name} process"
  fi
  osascript -e "tell application id \"${bundle_id}\" to quit" >/dev/null 2>&1 || true
  sleep 1
  pkill -f "${app}/Contents/MacOS/${executable_name}" >/dev/null 2>&1 || true
}

verify_apps() {
  local app
  if [[ "${#STAGED_APPS[@]}" -eq 0 ]]; then
    fail "no macOS apps were staged"
  fi

  for app in "${STAGED_APPS[@]}"; do
    verify_app "${app}"
  done
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
      if [[ "${DRY_RUN}" == "1" ]]; then
        dry_run
        return
      fi
      preflight
      ensure_arm64_host
      ensure_submodules
      ensure_build_tools
      ensure_external_repo_siblings_for_xcode
      ensure_qt_layout
      build_native_payload
      build_xcode_app
      stage_macos_apps
      verify_apps
      info "macOS ${ARCH} build complete: ${OUT_DIR}"
      ;;
    *)
      usage
      fail "unsupported macOS architecture: ${ARCH}"
      ;;
  esac
}

main "$@"
