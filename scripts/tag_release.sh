#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION_FILE="$REPO_ROOT/VERSION.txt"

if [ ! -f "$VERSION_FILE" ]; then
    echo "ERROR: VERSION.txt file not found at $VERSION_FILE"
    exit 1
fi

VERSION_FILE_CONTENT="$(cat "$VERSION_FILE" | tr -d '[:space:]')"

# Strip optional suffix (e.g. -rc.1)
VERSION="${VERSION_FILE_CONTENT%%-*}"

# Validate semver format (major.minor.patch)
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: VERSION '$VERSION' is not valid semver (expected X.Y.Z)"
    exit 1
fi

# Parse arguments
DRY_RUN=0
BUILD_NUMBER=""
PUSH=0

usage() {
    echo "Usage: $0 [-b BUILD_NUMBER] [--dry-run] [--push]"
    echo ""
    echo "Tags the main repo as v\$VERSION-\$BUILD_NUMBER and all submodules"
    echo "as v\$VERSION-\$BUILD_NUMBER-desktop."
    echo ""
    echo "Options:"
    echo "  -b, --build BUILD_NUMBER   Build number (default: auto-detected; 1 if no prior tags, highest existing + 1 otherwise)"
    echo "  --dry-run                  Print tags without creating them"
    echo "  --push                     Push tags to remote after creating"
    echo "  -h, --help                 Show this help"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -b|--build)
            BUILD_NUMBER="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --push)
            PUSH=1
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

if [ -z "$BUILD_NUMBER" ]; then
    # Find the highest existing build number for this version on the main repo.
    # Filter to exactly vX.Y.Z-N to exclude -desktop and pre-release tags.
    LAST_BUILD=$(git -C "$REPO_ROOT" tag --list "v${VERSION}-[0-9]*" \
        | grep -E "^v${VERSION}-[0-9]+$" \
        | sed "s|^v${VERSION}-||" \
        | sort -n \
        | tail -1 || true)
    if [ -z "$LAST_BUILD" ]; then
        BUILD_NUMBER=1
    else
        BUILD_NUMBER=$((LAST_BUILD + 1))
    fi
    echo "Auto-detected build number: $BUILD_NUMBER (last: ${LAST_BUILD:-none})"
fi

if ! [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Build number must be a positive integer"
    exit 1
fi

TAG="v${VERSION}-${BUILD_NUMBER}"
SUBMODULE_TAG="v${VERSION}-${BUILD_NUMBER}-desktop"

tag_repo() {
    local repo_path="$1"
    local repo_name="$2"
    local tag="$3"

    if git -C "$repo_path" rev-parse "$tag" >/dev/null 2>&1; then
        echo "  SKIP $repo_name — tag $tag already exists"
    else
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "  [DRY RUN] Would tag $repo_name at $(git -C "$repo_path" rev-parse --short HEAD) as $tag"
        else
            git -C "$repo_path" tag -a "$tag" -m "Release $tag"
            echo "  Tagged $repo_name at $(git -C "$repo_path" rev-parse --short HEAD) as $tag"
        fi
    fi

    if [ "$PUSH" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
        git -C "$repo_path" push origin "$tag"
        echo "  Pushed $tag for $repo_name"
    fi
}

echo "Main repo tag:   $TAG"
echo "Submodule tag:   $SUBMODULE_TAG"
echo ""

# Tag main repository
echo "Main repository:"
tag_repo "$REPO_ROOT" "DesktopEditors" "$TAG"
echo ""

# Tag each submodule
echo "Submodules:"
git -C "$REPO_ROOT" submodule foreach --quiet 'echo $sm_path' | while read -r sm_path; do
    sm_full_path="$REPO_ROOT/$sm_path"
    tag_repo "$sm_full_path" "$sm_path" "$SUBMODULE_TAG"
done

echo ""
echo "Done."
