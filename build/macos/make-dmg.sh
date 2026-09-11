#!/usr/bin/env bash
# Packages a built Euro-Office.app into a distributable .dmg, using appdmg
# and the config/assets in desktop-apps/macos/fastlane/resources/. Not part
# of the three build steps in build/macos/README.md - this is an optional
# extra step, run after the Xcode build produces a real .app.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RESOURCES_DIR="${REPO_ROOT}/desktop-apps/macos/fastlane/resources"

usage() {
    cat <<EOF
Usage: $(basename "$0") --app <path-to-.app> --output <path-to-.dmg>

Required:
  --app <path>      The built .app bundle to package (e.g. build/macos/out/Euro-Office.app).
  --output <path>   Where to write the resulting .dmg.
EOF
}

APP_PATH=""
OUTPUT_PATH=""

while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP_PATH="$2"; shift 2 ;;
        --output) OUTPUT_PATH="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown argument: $1" 1>&2; usage 1>&2; exit 1 ;;
    esac
done

if [ -z "${APP_PATH}" ] || [ -z "${OUTPUT_PATH}" ]; then
    echo "error: --app and --output are required." 1>&2
    usage 1>&2
    exit 1
fi

if [ ! -d "${APP_PATH}" ]; then
    echo "error: ${APP_PATH} not found - build the Xcode project first (see" 1>&2
    echo "\"The three steps\" in build/macos/README.md)." 1>&2
    exit 1
fi

if ! command -v npx >/dev/null 2>&1; then
    echo "error: npx (Node.js) not found on PATH - needed to run appdmg." 1>&2
    echo "Install Node (e.g. \`brew install node\`) and try again." 1>&2
    exit 1
fi

APP_PATH_ABS="$(cd "${APP_PATH}" && pwd)"

echo "==> Generating appdmg config"
# Written inside RESOURCES_DIR (not system tmp) because appdmg resolves
# "background" relative to the config file's own directory, not cwd.
CONFIG_JSON="$(mktemp "${RESOURCES_DIR}/appdmg-XXXXXX.json")"
trap 'rm -f "${CONFIG_JSON}"' EXIT
jq --arg app_path "${APP_PATH_ABS}" '.contents[0].path = $app_path' \
    "${RESOURCES_DIR}/appdmg.json" > "${CONFIG_JSON}"

echo "==> Building DMG"
mkdir -p "$(dirname "${OUTPUT_PATH}")"
OUTPUT_PATH_ABS="$(cd "$(dirname "${OUTPUT_PATH}")" && pwd)/$(basename "${OUTPUT_PATH}")"
rm -f "${OUTPUT_PATH_ABS}"
( cd "${RESOURCES_DIR}" && npx --yes appdmg "${CONFIG_JSON}" "${OUTPUT_PATH_ABS}" )

echo ""
echo "DMG created: ${OUTPUT_PATH_ABS}"
