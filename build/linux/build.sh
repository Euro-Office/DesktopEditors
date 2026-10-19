#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") [--no-package]

    --no-package  Build only the app and unpack it to ./deploy/desktopeditors
                  (skips the .deb/.rpm/.tar.xz packaging step).
EOF
}

TARGET="packages"
for arg in "$@"; do
    case "$arg" in
        --no-package) TARGET="desktop-app" ;;
        -h|--help)    usage; exit 0 ;;
        *)            echo "Unknown option: $arg" >&2; usage >&2; exit 1 ;;
    esac
done

NEXTCLOUD_USER=""
NEXTCLOUD_PASS=""
REGISTRY="ghcr.io/euro-office"
TAG="latest"
PRODUCT_VERSION=$(cat ../../VERSION.txt)
BUILD_NUMBER="dev.0"
BRANDING_DIR="../"
COMPANY_NAME="Euro-Office"
PRODUCT_NAME="Desktop Editors"
BUILD_COMMITS="DesktopEditors=$(git rev-parse HEAD) $(git -C ../.. submodule foreach --quiet 'echo $name=$(git rev-parse HEAD)' | tr '\n' ' ')"
BUILD_DATE=$(date -u +%F)

export NEXTCLOUD_USER NEXTCLOUD_PASS REGISTRY TAG PRODUCT_VERSION \
       BUILD_NUMBER BRANDING_DIR COMPANY_NAME PRODUCT_NAME BUILD_COMMITS BUILD_DATE

docker buildx bake -f ../docker-bake.hcl -f docker-bake.hcl "$TARGET" \
       --set "desktop-linux.contexts.desktop-common=target:desktop-common" \
       --set "*.context=../.."

if [ "$TARGET" = "desktop-app" ]; then
    rm -rf ./deploy/desktopeditors
    mkdir -p ./deploy/desktopeditors
    tar -xf ./deploy/desktopeditors.tar -C ./deploy/desktopeditors
    rm ./deploy/desktopeditors.tar
    echo "App ready: run ./start_desktop.sh from $(pwd)/deploy/desktopeditors"
fi
