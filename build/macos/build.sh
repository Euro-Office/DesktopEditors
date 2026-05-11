#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${BUILD_DIR}/.." && pwd)"

PRODUCT_FAMILY_NAME="${PRODUCT_FAMILY_NAME:-Euro-Office}"
PRODUCT_NAME="${PRODUCT_NAME:-${PRODUCT_FAMILY_NAME}}"
BUNDLE_ID="${PRODUCT_BUNDLE_IDENTIFIER:-org.euro-office.desktopeditors}"
MACOS_PRODUCTS="${EO_MACOS_PRODUCTS:-split}"
SCHEME="${SCHEME:-ONLYOFFICE-arm}"
ARCH="${1:-}"
BUILD_TOOLS_REV="${BUILD_TOOLS_REV:-c5f6c2e02b50dfcc5c53a207f9a6cde84896de91}"
BUILD_TOOLS_PLATFORM="${BUILD_TOOLS_PLATFORM:-mac_arm64}"
MIN_FREE_GIB="${MIN_FREE_GIB:-150}"
QT_DIR="${QT_DIR:-${REPO_ROOT}/_qt}"

OUT_DIR="${BUILD_DIR}/deploy/macos/arm64"
LOG_DIR="${BUILD_DIR}/deploy/macos/logs"
DERIVED_DATA_DIR="${BUILD_DIR}/deploy/macos/DerivedData/arm64"
TOOLS_BIN_DIR="${BUILD_DIR}/deploy/macos/tools/bin"
CMAKE_VENV_DIR="${BUILD_DIR}/deploy/macos/tools/cmake-venv"
BUILD_TOOLS_DIR="${REPO_ROOT}/build_tools"
DESKTOP_APPS_DIR="${DESKTOP_APPS_DIR:-${REPO_ROOT}/desktop-apps}"
XCODE_PROJECT="${DESKTOP_APPS_DIR}/macos/ONLYOFFICE.xcodeproj"

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

trap cleanup_external_desktop_apps_link EXIT

usage() {
  cat <<EOF
Usage:
  ./macos/build.sh --check
  ./macos/build.sh arm64

Environment:
  MIN_FREE_GIB=150
  EO_SKIP_SPACE_CHECK=1
  QT_DIR=/path/to/qt-root
  BUILD_TOOLS_REV=${BUILD_TOOLS_REV}
  EO_MACOS_PRODUCTS=split|suite|text,spreadsheet,presentation,pdf
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
  git -C "${REPO_ROOT}" config --local url.https://github.com/.insteadOf git@github.com:
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
  unset NPM_CONFIG_OMIT npm_config_omit
  export NPM_CONFIG_INCLUDE=dev

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

patch_boost_datetime_header() {
  local source="$1"

  if [[ ! -f "${source}" ]]; then
    return
  fi

  if ! grep -q 'numeric_cast<.*_type>' "${source}"; then
    return
  fi

  perl -0pi -e '
    s/numeric_cast<hour_type>\(h\)/static_cast<hour_type>(h)/g;
    s/numeric_cast<min_type>\(m\)/static_cast<min_type>(m)/g;
    s/numeric_cast<sec_type>\(s\)/static_cast<sec_type>(s)/g;
  ' "${source}"
  info "patched Boost.DateTime numeric casts for current Clang/Boost compatibility: ${source}"
}

prepare_boost_sources() {
  local boost_dir="${REPO_ROOT}/core/Common/3dParty/boost"
  local boost_src="${boost_dir}/boost_1_72_0"
  local source_header="${boost_src}/libs/date_time/include/boost/date_time/posix_time/posix_time_duration.hpp"
  local installed_header="${boost_dir}/build/${BUILD_TOOLS_PLATFORM}/include/boost/date_time/posix_time/posix_time_duration.hpp"

  printf '%s' 'boost_version_5' > "${boost_dir}/boost.data"

  if [[ ! -d "${boost_src}" ]]; then
    info "fetching Boost 1.72 source checkout for macOS compatibility patches"
    git -C "${boost_dir}" clone --recursive --depth=1 \
      https://github.com/boostorg/boost.git boost_1_72_0 -b boost-1.72.0
  fi

  patch_boost_datetime_header "${source_header}"
  patch_boost_datetime_header "${installed_header}"
}

iwork_module_version() {
  awk -F\" '/check_module_version/ { print $2; exit }' \
    "${BUILD_TOOLS_DIR}/scripts/core_common/modules/iwork.py"
}

patch_libetonyek_clang_compat() {
  local table_source="${REPO_ROOT}/core/Common/3dParty/apple/libetonyek/src/lib/IWORKTable.cpp"
  local path_source="${REPO_ROOT}/core/Common/3dParty/apple/libetonyek/src/lib/contexts/IWORKPathElement.cpp"
  local patched=0

  if [[ ! -f "${table_source}" ]]; then
    fail "expected libetonyek source was not fetched: ${table_source}"
  fi

  if [[ ! -f "${path_source}" ]]; then
    fail "expected libetonyek source was not fetched: ${path_source}"
  fi

  if grep -q 'numeric_cast<int>(' "${table_source}"; then
    perl -0pi -e 's/numeric_cast<int>\((col|r|numRepeat|cell\.m_columnSpan|cell\.m_rowSpan)\)/static_cast<int>($1)/g' "${table_source}"
    patched=1
  fi

  if grep -q 'numeric_cast<unsigned>(' "${path_source}"; then
    perl -0pi -e 's/numeric_cast<unsigned>\(get\(m_point\)\.m_x\)/static_cast<unsigned>(get(m_point).m_x)/g; s/numeric_cast<unsigned>\(m_value\)/static_cast<unsigned>(m_value)/g' "${path_source}"
    patched=1
  fi

  if [[ "${patched}" -eq 1 ]]; then
    info "patched libetonyek numeric casts for current Clang/Boost compatibility"
  fi
}

patch_odf_clang_compat() {
  local sources=(
    "${REPO_ROOT}/core/OdfFile/Reader/Converter/pptx_table_context.cpp"
    "${REPO_ROOT}/core/OdfFile/Reader/Converter/xlsx_borders.cpp"
  )
  local source
  local patched=0

  for source in "${sources[@]}"; do
    if [[ ! -f "${source}" ]]; then
      fail "expected ODF converter source was not found: ${source}"
    fi

    if grep -q 'boost::lexical_cast<int>(borderStyle->get_length().get_value_unit(odf_types::length::emu))' "${source}"; then
      perl -0pi -e 's/boost::lexical_cast<int>\(borderStyle->get_length\(\)\.get_value_unit\(odf_types::length::emu\)\)/static_cast<int>(borderStyle->get_length().get_value_unit(odf_types::length::emu))/g' "${source}"
      patched=1
    fi
  done

  if [[ "${patched}" -eq 1 ]]; then
    info "patched ODF table border width casts for current Clang/Boost compatibility"
  fi
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

  info "native payload ready: ${payload_dir}"
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
    split)
      printf '%s\n' text spreadsheet presentation pdf
      ;;
    suite)
      printf '%s\n' suite
      ;;
    all)
      printf '%s\n' suite text spreadsheet presentation pdf
      ;;
    *)
      printf '%s\n' "${MACOS_PRODUCTS//,/ }" | xargs -n1
      ;;
  esac
}

product_app_name() {
  case "$1" in
    text) printf '%s Text\n' "${PRODUCT_FAMILY_NAME}" ;;
    spreadsheet) printf '%s Spreadsheet\n' "${PRODUCT_FAMILY_NAME}" ;;
    presentation) printf '%s Presentation\n' "${PRODUCT_FAMILY_NAME}" ;;
    pdf) printf '%s PDF\n' "${PRODUCT_FAMILY_NAME}" ;;
    suite) printf '%s\n' "${PRODUCT_NAME}" ;;
    *) fail "unknown macOS product component: $1" ;;
  esac
}

product_executable_name() {
  case "$1" in
    text) printf 'EuroOfficeText\n' ;;
    spreadsheet) printf 'EuroOfficeSpreadsheet\n' ;;
    presentation) printf 'EuroOfficePresentation\n' ;;
    pdf) printf 'EuroOfficePDF\n' ;;
    suite) printf '%s\n' "${PRODUCT_NAME}" ;;
    *) fail "unknown macOS product component: $1" ;;
  esac
}

product_bundle_id() {
  case "$1" in
    text|spreadsheet|presentation|pdf) printf '%s.%s\n' "${BUNDLE_ID}" "$1" ;;
    suite) printf '%s\n' "${BUNDLE_ID}" ;;
    *) fail "unknown macOS product component: $1" ;;
  esac
}

product_url_scheme() {
  case "$1" in
    text) printf 'euro-office-text\n' ;;
    spreadsheet) printf 'euro-office-spreadsheet\n' ;;
    presentation) printf 'euro-office-presentation\n' ;;
    pdf) printf 'euro-office-pdf\n' ;;
    suite) printf 'euro-office\n' ;;
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

  python3 - "${plist}" "${app_name}" "${executable_name}" "${bundle_id}" "${url_scheme}" "${component}" <<'PY'
import plistlib
import sys

plist_path, app_name, executable_name, bundle_id, url_scheme, component = sys.argv[1:7]

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
  local app_name executable_name bundle_id url_scheme app old_exe candidate

  app_name="$(product_app_name "${component}")"
  executable_name="$(product_executable_name "${component}")"
  bundle_id="$(product_bundle_id "${component}")"
  url_scheme="$(product_url_scheme "${component}")"
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
    patch_product_info_plist "${app}/Contents/Info.plist" "${app_name}" "${executable_name}" "${bundle_id}" "${url_scheme}" "${component}"
    resign_app "${app}"
  fi

  STAGED_APPS+=("${app}")
  info "app exported to ${app}"
}

stage_macos_apps() {
  if [[ -z "${BUILT_XCODE_APP}" || ! -d "${BUILT_XCODE_APP}" ]]; then
    fail "base Xcode app was not staged"
  fi

  STAGED_APPS=()

  local component
  while IFS= read -r component; do
    [[ -z "${component}" ]] && continue
    stage_product_app "${component}"
  done < <(selected_products)
}

verify_app() {
  local app="$1"
  local plist="${app}/Contents/Info.plist"
  local app_name executable_name bundle_id exe log_name

  if [[ ! -d "${app}" ]]; then
    fail "app bundle missing: ${app}"
  fi

  app_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "${plist}")"
  executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${plist}")"
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${plist}")"
  exe="${app}/Contents/MacOS/${executable_name}"
  log_name="${app_name// /-}"

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
  sleep 4
  if ! pgrep -f "${app}/Contents/MacOS/${executable_name}" >/dev/null 2>&1; then
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
