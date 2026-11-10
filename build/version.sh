#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Euro-Office contributors
# SPDX-License-Identifier: AGPL-3.0-only

# Prints product_version=, build_number= and update_version= lines for a
# release tag, or for a build of no tag (VERSION.txt). The build workflow and
# the update feeds use it, so the version an app has is the one its feed names.
#
# Usage: build/version.sh --tag v9.3.8-rc.1
#        build/version.sh --dev <run number>   (reads VERSION.txt)
#
#   tag            product_version build_number update_version
#   v9.3.8         9.3.8           0            9.3.8
#   v9.3.8-1       9.3.8           1            9.3.8.1
#   v9.3.8-rc.1    9.3.8           0~rc.1       9.3.8rc.1
#   (no tag, run 42, VERSION.txt 9.3.8-rc.1)     9.3.8rc.1dev.42
#
# The "0~" prefix sorts a prerelease before the final release
# (9.3.8-0~rc.1 < 9.3.8-0) in both dpkg and rpm; a patch build sorts after it.
# update_version is what Sparkle and WinSparkle compare. It has no dashes,
# because Sparkle ignores everything after one, and sorts the same way.
# Builds of no tag add dev.<run number>, so a later run is an update.

set -euo pipefail

split() {   # <version> <what> -> product_version, build_number
    if [[ "$1" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-([1-9][0-9]*)$ ]]; then
        product_version=${BASH_REMATCH[1]} build_number=${BASH_REMATCH[2]}
    elif [[ "$1" =~ ^([^-]+)-(.+)$ ]]; then
        product_version=${BASH_REMATCH[1]} build_number="0~${BASH_REMATCH[2]}"
    elif [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [ "$2" = dev ]; then
        product_version=$1 build_number=$3
    else
        echo "Unsupported tag format: v$1 (expected vX.Y.Z or vX.Y.Z-ID)" >&2
        exit 1
    fi
}

case "${1:-}" in
    --tag)
        [[ "${2:-}" == v* ]] || { echo "tag must start with v: ${2:-}" >&2; exit 1; }
        split "${2#v}" tag 0
        ;;
    --dev)
        [[ "${2:-}" =~ ^[0-9]+$ ]] || { echo "--dev needs the run number" >&2; exit 1; }
        version_file="$(dirname "${BASH_SOURCE[0]}")/../VERSION.txt"
        split "$(tr -d '[:space:]' < "$version_file")" dev "${BUILD_NUMBER:-dev.1}"
        ;;
    *)
        sed -n '/^# Usage/,/^#   (no tag/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
        exit 1
        ;;
esac

case "$build_number" in
    0|dev.*) update_version=$product_version ;;
    0~*)     update_version="$product_version${build_number#0~}" ;;
    *)       update_version="$product_version.$build_number" ;;
esac
update_version=${update_version//-/.}
[ "$1" = --dev ] && update_version="${update_version}dev.$2"

echo "product_version=$product_version"
echo "build_number=$build_number"
echo "update_version=$update_version"
