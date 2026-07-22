#!/usr/bin/env bash
set -euo pipefail

NEXTCLOUD_USER=""
NEXTCLOUD_PASS=""
REGISTRY="ghcr.io/euro-office"
TAG="latest"
PRODUCT_VERSION=$(cat ../../VERSION.txt)
BUILD_NUMBER="dev.0"
BRANDING_DIR="../"
COMPANY_NAME="Euro-Office"
PRODUCT_NAME="Desktop Editors"
GIT_COMMIT=$(git rev-parse --short HEAD)

# Override to produce a baseline x86-64 build for legacy hardware, e.g.:
#   ARCH_TRIPLET=x64-linux-baseline ARCH_MARCH_FLAGS=-march=x86-64 ./build.sh
ARCH_TRIPLET="${ARCH_TRIPLET:-x64-linux-v2}"
ARCH_MARCH_FLAGS="${ARCH_MARCH_FLAGS:--march=x86-64-v2}"

export NEXTCLOUD_USER NEXTCLOUD_PASS REGISTRY TAG PRODUCT_VERSION \
       BUILD_NUMBER BRANDING_DIR COMPANY_NAME PRODUCT_NAME GIT_COMMIT \
       ARCH_TRIPLET ARCH_MARCH_FLAGS

docker buildx bake -f ../docker-bake.hcl -f docker-bake.hcl packages \
       --set "desktop-linux.contexts.desktop-common=target:desktop-common" \
       --set "*.context=../.."