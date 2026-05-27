# Euro-Office Desktop Editors Builds

This directory contains the reproducible build entrypoints for Euro-Office
Desktop Editors.

## Clone

Clone the repository with submodules:

```sh
git clone --recurse-submodules https://github.com/Euro-Office/DesktopEditors.git
```

If the repository was cloned without submodules, initialize them before
building:

```sh
git submodule update --init --recursive
```

## Linux

Linux builds continue to use Docker Buildx Bake:

```sh
cd DesktopEditors/build
docker buildx bake
```

The exported desktop build is written to:

```text
DesktopEditors/build/deploy/desktop
```

## macOS

macOS builds must run on a macOS host with Xcode installed. Xcode application
builds are not wrapped in Docker; the host build entrypoint lives next to the
Linux bake file:

```sh
cd DesktopEditors/build
./macos/build.sh --check
./macos/build.sh --dry-run arm64
./macos/build.sh arm64
```

The default macOS output is one Euro-Office suite application:

```text
DesktopEditors/build/deploy/macos/arm64/Euro-Office.app
```

The macOS build currently targets Apple Silicon first. Intel and universal
builds can be added later using the same `build/macos` layout.

## macOS Requirements

- macOS on Apple Silicon
- Xcode command line tools selected with `xcode-select`
- Python 3
- Git
- Qt available through `QT_DIR` or a Homebrew Qt install
- Enough free space for native dependencies and the Xcode build

Optional release tooling:

- `gh` for PR and release workflows
- Developer ID signing identity for distributable builds
- notarization credentials for a future signed release flow

## macOS Environment

The script has conservative defaults and can be tuned with environment
variables:

```sh
MIN_FREE_GIB=150                    # minimum free disk space check
EO_SKIP_SPACE_CHECK=1               # bypass the free-space guard
QT_DIR=/path/to/qt-root             # contains <version>/macos/bin/qmake or <version>/clang_64/bin/qmake
DESKTOP_APPS_DIR=/path/to/desktop-apps
EO_MACOS_PRODUCTS=suite             # this Euro-Office branch exports one suite app
BUILD_TOOLS_REV_FILE=build/macos/build_tools.sha
BUILD_TOOLS_REV=<commit>            # explicit override for ONLYOFFICE/build_tools
EO_ALLOW_GIT_HTTPS_FALLBACK=1       # opt in to git@github.com: -> https://github.com/ rewrite
CODESIGNING_IDENTITY="Developer ID Application: ..."
DEVELOPMENT_TEAM=<team-id>
EO_SKIP_LAUNCH=1                    # skip the local launch smoke test
```

`build/macos/build_tools.sha` pins the default `ONLYOFFICE/build_tools`
revision. Use `BUILD_TOOLS_REV` only for local experiments or while updating
that pin in a reviewable change.

Without a Developer ID identity the app build is ad-hoc signed and suitable for
local testing. Release DMG signing and notarization remain gated on Developer ID
and notarization credentials.

## macOS Dry Run

`./macos/build.sh --dry-run arm64` does not mutate the checkout. It prints the
suite app output path, pinned `build_tools` revision, Xcode project, Qt layout
decision, submodule URL behavior, and any temporary symlinks that would be used
when `DESKTOP_APPS_DIR` points at an external checkout.

This is useful before running the full native build, because upstream
`build_tools` still expects `desktop-apps/common/loginpage` under the
`DesktopEditors` root, while Xcode build phases resolve sibling paths such as
`../../build_tools`, `../../core`, `../../desktop-sdk`, and
`../../dictionaries` from the `desktop-apps/macos` checkout. The wrapper creates
those symlinks only for the build and removes them on exit.

The script does not change contributor git URL configuration by default. If a
local environment cannot fetch `git@github.com:` submodules, set
`EO_ALLOW_GIT_HTTPS_FALLBACK=1` to opt in to the local HTTPS rewrite.

## macOS Compatibility Patches

Current Xcode/Clang rejects a few older Boost 1.72 numeric conversion paths used
by the pinned native dependencies. The wrapper applies reviewable patch files
from `build/macos/patches` with `git apply --unidiff-zero`, records the applied
patches, and reverts them during normal cleanup:

- `boost-date-time-duration.patch`
- `boost-date-time-duration-installed.patch`
- `libetonyek-clang-compat.patch`
- `odf-border-width-clang-compat.patch`

If the patch is already present, the script detects that with
`git apply --reverse --check` and continues without dirtying the tree again.

## macOS Local Tooling Notes

Some upstream `build_tools` steps still call `python`. When macOS only provides
`python3`, the wrapper adds a local `python` shim under
`build/deploy/macos/tools/bin` for the duration of the build.

The JavaScript build steps call `grunt` directly after `npm install`. The macOS
wrapper adds a local `grunt` shim under `build/deploy/macos/tools/bin` that
executes the `node_modules/.bin/grunt` from the current project directory,
avoiding any global npm dependency. `build_tools` sets `NODE_ENV=production`
before those installs, so the wrapper sets `NPM_CONFIG_INCLUDE=dev` and
`NPM_CONFIG_PRODUCTION=false`; this keeps npm from omitting Gruntfile helper
packages such as `time-grunt`.

The HEIF dependency path in `build_tools` currently requires CMake `>= 3.21`
and `< 4`. If the host only has CMake 4 or no CMake, the script creates a local
CMake venv under `build/deploy/macos/tools/cmake-venv`.

If `QT_DIR` points at a root directory and Homebrew Qt is available, the script
creates a build-tools compatible layout such as `<QT_DIR>/5.15.18/macos`.

## macOS Verification

`build/macos/build.sh arm64` verifies the generated application by checking the
main executable architecture and running strict codesign verification. Unless
`EO_SKIP_LAUNCH=1` is set, it opens the app once and waits up to 30 seconds for
the app process before quitting it again.

The lightweight GitHub Actions check for this path runs:

```sh
bash -n build/macos/build.sh
./build/macos/build.sh --check
./build/macos/build.sh --dry-run arm64
```
