#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Euro-Office contributors
# SPDX-License-Identifier: AGPL-3.0-only

# Puts core's prebuilt WebAssembly modules for the core checkout into
# build/core-wasm-package. When that directory exists, set CORE_WASM_PACKAGE
# to it and the bake takes the modules from there instead of building
# core-wasm. When the build cache has no package for core, or core has local
# changes, the directory is removed and the bake builds core-wasm.
# EO_CORE_CACHE=off|require and EO_CORE_CHANNELS work as in
# core/scripts/core_package.py.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dest="$here/core-wasm-package"

status=0
python3 "$here/../core/scripts/core_package.py" fetch --core "$here/../core" \
    --platform wasm --product engine --dest "$dest" || status=$?
[ "$status" -eq 0 ] && exit 0
rm -rf "$dest"
[ "$status" -eq 3 ] || exit "$status"
