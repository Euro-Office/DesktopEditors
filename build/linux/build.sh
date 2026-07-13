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

detect_build_parallel_level() {
       local cpu_count mem_kib mem_mib jobs

       cpu_count=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1)
       mem_kib=$(awk '/MemAvailable:/ { print $2; exit } /MemTotal:/ { print $2; exit }' /proc/meminfo 2>/dev/null || echo 0)

       if [[ -z "${mem_kib}" || "${mem_kib}" -le 0 ]]; then
              mem_mib=0
              jobs=1
       else
              mem_mib=$((mem_kib / 1024))
              jobs=$((mem_mib / 8192))
              if [[ "${jobs}" -lt 1 ]]; then
                     jobs=1
              fi
       fi

       if [[ "${jobs}" -gt "${cpu_count}" ]]; then
              jobs="${cpu_count}"
       fi

       if [[ "${jobs}" -gt 4 ]]; then
              jobs=4
       fi

       printf '%s\n' "${jobs}"
}

if [[ -z "${CMAKE_BUILD_PARALLEL_LEVEL:-}" ]]; then
       CMAKE_BUILD_PARALLEL_LEVEL=$(detect_build_parallel_level)
       echo "Auto-selected CMAKE_BUILD_PARALLEL_LEVEL=${CMAKE_BUILD_PARALLEL_LEVEL} based on host RAM/CPU"
else
       echo "Using CMAKE_BUILD_PARALLEL_LEVEL=${CMAKE_BUILD_PARALLEL_LEVEL} from environment"
fi

export NEXTCLOUD_USER NEXTCLOUD_PASS REGISTRY TAG PRODUCT_VERSION \
       BUILD_NUMBER BRANDING_DIR COMPANY_NAME PRODUCT_NAME GIT_COMMIT \
       CMAKE_BUILD_PARALLEL_LEVEL

# Build the common payload first, then package the Linux desktop build.
# Splitting phases reduces peak RAM pressure compared to a single combined bake.
docker buildx bake -f ../docker-bake.hcl desktop-common \
       --set "*.context=../.." \
       --set "core-wasm.args.CMAKE_BUILD_PARALLEL_LEVEL=${CMAKE_BUILD_PARALLEL_LEVEL}"

docker buildx bake -f ../docker-bake.hcl -f docker-bake.hcl packages \
       --set "*.context=../.." \
       --set "desktop-linux.args.CMAKE_BUILD_PARALLEL_LEVEL=${CMAKE_BUILD_PARALLEL_LEVEL}"