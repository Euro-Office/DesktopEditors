#!/usr/bin/env bash
# Stages a built desktop-sdk output tree for the Euro-Office-arm Xcode build.
#
# Mirrors the "overlay the common payload + generate fonts/theme thumbnails"
# portion of the Linux Docker stage (desktop-apps/.docker/desktop-apps.bake.Dockerfile)
# and Windows' build.ps1 (step 9/9b) - see build/macos/README.md for the full
# picture and what this script deliberately does NOT do (build desktop-sdk
# itself, or run xcodebuild).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

STAGE_DIR="${STAGE_DIR:-}"
PAYLOAD_DIR="${PAYLOAD_DIR:-${REPO_ROOT}/build/deploy/common}"
CORE_FONTS_DIR="${CORE_FONTS_DIR:-${REPO_ROOT}/core-fonts}"
EO_CORE_3RD_PARTY_DIR="${EO_CORE_3RD_PARTY_DIR:-}"

usage() {
    cat <<EOF
Usage: $(basename "$0") --stage-dir <path> --3rdparty-dir <path> [options]

Required:
  --stage-dir <path>       The desktop-sdk CMake build directory (must already
                            contain a built package/ - build desktop-sdk first,
                            see "Build steps for a new developer" in the plan).
  --3rdparty-dir <path>    EO_CORE_3RD_PARTY_DIR - where boost/icu/v8/etc. were
                            fetched to (same value used to build desktop-sdk).

Optional:
  --payload-dir <path>     Extracted desktop-common web payload.
                            Default: ${REPO_ROOT}/build/deploy/common
  --core-fonts-dir <path>  The core-fonts submodule checkout.
                            Default: ${REPO_ROOT}/core-fonts

Env vars STAGE_DIR, PAYLOAD_DIR, CORE_FONTS_DIR, EO_CORE_3RD_PARTY_DIR work the
same as the matching flags.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --stage-dir) STAGE_DIR="$2"; shift 2 ;;
        --payload-dir) PAYLOAD_DIR="$2"; shift 2 ;;
        --core-fonts-dir) CORE_FONTS_DIR="$2"; shift 2 ;;
        --3rdparty-dir) EO_CORE_3RD_PARTY_DIR="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown argument: $1" 1>&2; usage 1>&2; exit 1 ;;
    esac
done

if [ -z "${STAGE_DIR}" ] || [ -z "${EO_CORE_3RD_PARTY_DIR}" ]; then
    echo "error: --stage-dir and --3rdparty-dir are required." 1>&2
    usage 1>&2
    exit 1
fi

if [ ! -d "${STAGE_DIR}/package" ]; then
    echo "error: ${STAGE_DIR}/package not found - build desktop-sdk first (see" 1>&2
    echo "\"Build steps for a new developer\" in the plan). This script only stages" 1>&2
    echo "an already-built tree, it doesn't build desktop-sdk itself." 1>&2
    exit 1
fi

if [ ! -d "${PAYLOAD_DIR}" ]; then
    echo "error: ${PAYLOAD_DIR} not found - build/extract the desktop-common web" 1>&2
    echo "payload first (docker buildx bake desktop-common)." 1>&2
    exit 1
fi

if ! command -v ninja >/dev/null 2>&1; then
    echo "error: ninja not found on PATH." 1>&2
    exit 1
fi

echo "==> Merging native build output (package/) into converter/"
mkdir -p "${STAGE_DIR}/converter"
cp -R "${STAGE_DIR}/package/." "${STAGE_DIR}/converter/"

echo "==> Merging web payload"
cp "${PAYLOAD_DIR}/index.html" "${STAGE_DIR}/index.html"
rm -rf "${STAGE_DIR}/editors" "${STAGE_DIR}/fonts" "${STAGE_DIR}/providers"
cp -R "${PAYLOAD_DIR}/editors" "${STAGE_DIR}/editors"
cp -R "${PAYLOAD_DIR}/fonts" "${STAGE_DIR}/fonts"
cp -R "${PAYLOAD_DIR}/providers" "${STAGE_DIR}/providers"
cp -R "${PAYLOAD_DIR}/converter/." "${STAGE_DIR}/converter/"

# allfontsgen/allthemesgen aren't part of the desktop-sdk build - build them
# standalone, straight into converter/, same as x2t's own dylib siblings.
# Rebuilt every run (not cached) so they're always current against whatever
# kernel/graphics fixes have landed - the MAC-macro bug earlier this session
# was invisible until these tools were actually exercised.
TOOLS_DIR="${STAGE_DIR}/.tools"
mkdir -p "${TOOLS_DIR}"

build_tool() {
    local name="$1"
    local src_dir="$2"
    local build_dir="${TOOLS_DIR}/${name}-build"

    echo "==> Building ${name}"
    if [ ! -f "${build_dir}/CMakeCache.txt" ]; then
        cmake -S "${src_dir}" -B "${build_dir}" \
            -G Ninja -DCMAKE_BUILD_TYPE=Release \
            -DEO_CORE_3RD_PARTY_DIR="${EO_CORE_3RD_PARTY_DIR}" \
            -DEO_CORE_TOOLS_DIR="${STAGE_DIR}/converter"
    fi
    cmake --build "${build_dir}"
}

build_tool allfontsgen "${REPO_ROOT}/core/DesktopEditor/AllFontsGen"
build_tool allthemesgen "${REPO_ROOT}/core/DesktopEditor/allthemesgen"

echo "==> Generating fonts"
# allfontsgen caches: if converter/fonts.log matches what it just scanned AND
# converter/font_selection.bin (always that literal filename, regardless of
# --selection's value) already exists, it silently skips regeneration - exit
# 0, nothing written. Harmless on a first run, but breaks "safe to re-run" on
# a staging dir that's been staged before. Force a fresh run every time.
rm -f "${STAGE_DIR}/converter/fonts.log" "${STAGE_DIR}/converter/font_selection.bin"
"${STAGE_DIR}/converter/allfontsgen" \
    --use-system=1 \
    --input="${STAGE_DIR}/fonts" \
    --input="${CORE_FONTS_DIR}" \
    --allfonts="${STAGE_DIR}/converter/AllFonts.js" \
    --allfonts-web="${STAGE_DIR}/editors/sdkjs/common/AllFonts.js" \
    --output-web="${STAGE_DIR}/editors/fonts" \
    --selection="${STAGE_DIR}/converter/font_selection.bin"

# allfontsgen can exit 0 while writing effectively nothing (this bit us
# directly this session - it silently wrote an 8-byte font_selection.bin due
# to an unrelated bug in a dependency). Check real content, not just exit
# code or bare existence.
MIN_SELECTION_BYTES=1024
for f in "${STAGE_DIR}/converter/AllFonts.js" "${STAGE_DIR}/editors/sdkjs/common/AllFonts.js"; do
    if [ ! -s "$f" ]; then
        echo "error: allfontsgen did not produce $f" 1>&2
        exit 1
    fi
done
selection_size=$(stat -f %z "${STAGE_DIR}/converter/font_selection.bin" 2>/dev/null || echo 0)
if [ "${selection_size}" -lt "${MIN_SELECTION_BYTES}" ]; then
    echo "error: font_selection.bin is only ${selection_size} bytes (expected at least ${MIN_SELECTION_BYTES})" 1>&2
    echo "- allfontsgen likely exited 0 while finding no real fonts. Check its --input paths." 1>&2
    exit 1
fi

echo "==> Generating theme thumbnails"
"${STAGE_DIR}/converter/allthemesgen" \
    --converter-dir="${STAGE_DIR}/converter" \
    --src="${STAGE_DIR}/editors/sdkjs/slide/themes" \
    --allfonts="${STAGE_DIR}/converter/AllFonts.js" \
    --output="${STAGE_DIR}/editors/sdkjs/common/Images"

if [ -z "$(ls -A "${STAGE_DIR}/editors/sdkjs/common/Images" 2>/dev/null)" ]; then
    echo "error: allthemesgen did not populate editors/sdkjs/common/Images" 1>&2
    exit 1
fi

echo "==> Removing generator binaries from converter/ (dev tools, not shipped)"
rm -f "${STAGE_DIR}/converter/allfontsgen" "${STAGE_DIR}/converter/allthemesgen"

echo ""
echo "Staging complete: ${STAGE_DIR}"
echo "Ready for: xcodebuild -project desktop-apps/macos/Euro-Office.xcodeproj -scheme Euro-Office-arm EO_MAC_STAGE_DIR=${STAGE_DIR} build"
