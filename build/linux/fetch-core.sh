#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Euro-Office contributors
# SPDX-License-Identifier: AGPL-3.0-only

# Puts the prebuilt core for the core checkout into build/linux/core-package,
# the core-package context of the desktop-linux bake target. The Docker build
# can't decide this itself: it sees core without its git metadata. When the
# build cache has no package for core, or core has local changes, the
# directory stays empty and the Docker build builds core.
# EO_CORE_CACHE=off|require and EO_CORE_CHANNELS work as in
# core/scripts/core_package.py.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "$(uname -m)" in
    x86_64)  platform=linux-amd64 ;;
    aarch64) platform=linux-arm64 ;;
    *)       echo "unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

status=0
python3 "$here/../../core/scripts/core_package.py" fetch --core "$here/../../core" \
    --platform "$platform" --product desktop --dest "$here/core-package" || status=$?
[ "$status" -eq 0 ] || [ "$status" -eq 3 ] || exit "$status"
mkdir -p "$here/core-package"
