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
Usage: $(basename "$0") --app <path-to-.app> --output <path-to-.dmg> [--title <name>]

Required:
  --app <path>      The built .app bundle to package (e.g. build/macos/out/Euro-Office.app).
  --output <path>   Where to write the resulting .dmg.

Optional:
  --title <name>    DMG window/volume title (default: appdmg.json's own "title").
EOF
}

APP_PATH=""
OUTPUT_PATH=""
TITLE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP_PATH="$2"; shift 2 ;;
        --output) OUTPUT_PATH="$2"; shift 2 ;;
        --title) TITLE="$2"; shift 2 ;;
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
# appdmg requires the config file to literally have a .json extension, but
# macOS's mktemp only randomizes trailing X's - a template ending in X's
# followed by ".json" never gets substituted at all (confirmed: it always
# creates the same fixed filename, colliding on a second call). Get a real
# unique name from mktemp first, then rename it to add the required suffix.
CONFIG_JSON_TMP="$(mktemp -t appdmg)"
CONFIG_JSON="${CONFIG_JSON_TMP}.json"
mv "${CONFIG_JSON_TMP}" "${CONFIG_JSON}"
trap 'rm -f "${CONFIG_JSON}"' EXIT
# Rewrite both the app path and the background path to absolute values, so
# the config file no longer needs to live next to background.png for
# appdmg's relative-path resolution to work (it can now live anywhere, e.g.
# system tmp, instead of RESOURCES_DIR).
jq --arg app_path "${APP_PATH_ABS}" --arg background "${RESOURCES_DIR}/background.png" \
   --arg title "${TITLE}" \
    '.contents[0].path = $app_path | .background = $background
     | if $title != "" then .title = $title else . end' \
    "${RESOURCES_DIR}/appdmg.json" > "${CONFIG_JSON}"

echo "==> Building DMG"
mkdir -p "$(dirname "${OUTPUT_PATH}")"
OUTPUT_PATH_ABS="$(cd "$(dirname "${OUTPUT_PATH}")" && pwd)/$(basename "${OUTPUT_PATH}")"
rm -f "${OUTPUT_PATH_ABS}"
npx --yes appdmg "${CONFIG_JSON}" "${OUTPUT_PATH_ABS}"

echo ""
echo "DMG created: ${OUTPUT_PATH_ABS}"
