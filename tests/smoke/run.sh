#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Euro-Office contributors
# SPDX-License-Identifier: AGPL-3.0-only
#
# Runs the smoke tests against a desktop editors .deb.
# Usage: run.sh PACKAGE.deb [RESULTS_DIR]
# Screenshots and app logs of each test end up in RESULTS_DIR (default ./results).
set -euo pipefail

deb=$(realpath "${1:?Usage: run.sh PACKAGE.deb [RESULTS_DIR]}")
results=$(realpath -m "${2:-results}")
here=$(dirname "$(realpath "$0")")

# The Dockerfile takes the package from a directory with just this .deb
package_dir=$(mktemp -d)
trap 'rm -rf "$package_dir"' EXIT
ln "$deb" "$package_dir/" 2>/dev/null || cp "$deb" "$package_dir/"

docker build --build-context package="$package_dir" -t desktop-smoke-tests "$here"

mkdir -p "$results"
chmod 777 "$results"
# --init reaps the helper processes the tests stop
docker run --rm --init --network none -v "$results:/results" desktop-smoke-tests
