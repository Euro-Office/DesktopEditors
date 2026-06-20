#!/usr/bin/env bash
set -euo pipefail

NEXTCLOUD_USER=""
NEXTCLOUD_PASS=""
REGISTRY="ghcr.io/euro-office"
TAG="latest"
PRODUCT_VERSION=$(cat ../../VERSION)
BUILD_NUMBER="dev.0"
BRANDING_DIR="../"
COMPANY_NAME="Euro-Office"
PRODUCT_NAME="Desktop Editors"
GIT_COMMIT=$(git rev-parse --short HEAD)

export NEXTCLOUD_USER NEXTCLOUD_PASS REGISTRY TAG PRODUCT_VERSION \
       BUILD_NUMBER BRANDING_DIR COMPANY_NAME PRODUCT_NAME GIT_COMMIT

docker buildx bake -f ../docker-bake.hcl -f docker-bake.hcl packages \
       --set "desktop-linux.contexts.desktop-common=target:desktop-common" \
       --set "*.context=../.."