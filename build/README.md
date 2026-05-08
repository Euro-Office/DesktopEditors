# Euro-Office Desktop Editors Builds

This directory contains the reproducible build entrypoints for Euro-Office
Desktop Editors.

## Clone

Clone the repository with submodules:

```sh
git clone --recurse-submodules https://github.com/Euro-Office/DesktopEditors.git
```

If the repository was cloned without submodules, initialize them before building:

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
./macos/build.sh arm64
```

The default output is:

```text
DesktopEditors/build/deploy/macos/arm64/Euro-Office.app
```

The macOS build currently targets Apple Silicon first. Intel and universal
builds can be added later using the same `build/macos` layout.

### macOS Requirements

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

### macOS Environment

The script has conservative defaults and can be tuned with environment
variables:

```sh
MIN_FREE_GIB=150                 # minimum free disk space check
EO_SKIP_SPACE_CHECK=1            # bypass the free-space guard
QT_DIR=/path/to/qt-root          # contains <version>/macos/bin/qmake or <version>/clang_64/bin/qmake
DESKTOP_APPS_DIR=/path/to/desktop-apps
BUILD_TOOLS_REV=<commit>         # ONLYOFFICE/build_tools revision
CODESIGNING_IDENTITY="Developer ID Application: ..."
DEVELOPMENT_TEAM=<team-id>
EO_SKIP_LAUNCH=1                 # skip the local launch smoke test
```

If `QT_DIR` points at a root directory and Homebrew Qt is available, the script
creates a build-tools compatible layout such as `<QT_DIR>/5.15.18/macos`.

`DESKTOP_APPS_DIR` is optional. It is useful while the matching `desktop-apps`
macOS branding branch is still under review; after that branch is merged,
`DesktopEditors` can point its `desktop-apps` submodule at the upstream commit.
Upstream `build_tools` still reads `desktop-apps/common/loginpage` from the
`DesktopEditors` repo root, so the wrapper temporarily links the external
checkout into that submodule path during the build and restores the empty path
on exit. Xcode build phases also resolve `../../build_tools`, `../../core`,
`../../desktop-sdk`, and the dictionaries folder from the `desktop-apps/macos`
checkout, so the wrapper temporarily links those sibling paths under
`<desktop-apps-parent>` back to the matching `DesktopEditors` directories while
using an external checkout.

Without a Developer ID identity the app build is ad-hoc signed and suitable for
local testing. Release DMG signing and notarization remain gated on Developer ID
and notarization credentials.

Some upstream `build_tools` steps still call `python`. When macOS only provides
`python3`, `build/macos/build.sh` adds a local `python` shim under
`build/deploy/macos/tools/bin` for the duration of the build.

The JavaScript build steps call `grunt` directly after `npm install`. The macOS
wrapper adds a local `grunt` shim under `build/deploy/macos/tools/bin` that
executes the `node_modules/.bin/grunt` from the current project directory,
avoiding any global npm dependency. `build_tools` sets `NODE_ENV=production`
before those installs, so the wrapper also sets `NPM_CONFIG_INCLUDE=dev`; this
keeps npm 10+ from omitting Gruntfile helper packages such as `time-grunt`.

The HEIF dependency path in `build_tools` currently requires CMake `>= 3.21`
and `< 4`. If the host only has CMake 4 or no CMake, the script creates a
temporary local CMake venv under `build/deploy/macos/tools/cmake-venv`.

The macOS wrapper also exports fetched `katana-parser/src`, `gumbo-parser/src`,
`hyphen`, and `hunspell/hunspell/src` include paths for the qmake build, which
otherwise cannot resolve headers such as `katana.h`, `gumbo.h`,
`hyphen/hnjalloc.h`, and `hunspell/hunspell.h`.

If a previous run left an incomplete Boost output under
`core/Common/3dParty/boost/build/mac_arm64`, the wrapper removes that generated
directory before calling `build_tools` so `libboost_filesystem.a`,
`libboost_date_time.a`, and `libboost_regex.a` are rebuilt.

For current Xcode/Clang compatibility with the pinned Boost 1.72 headers, the
wrapper also patches the local Boost.DateTime `hours`, `minutes`, and `seconds`
helper constructors that otherwise instantiate Boost numeric conversion paths
rejected by current Clang.

For current Xcode/Clang compatibility with the pinned Boost 1.72 and iWork
sources, the wrapper prefetches the generated iWork third-party sources and
patches a small set of `libetonyek` `numeric_cast<int>` and
`numeric_cast<unsigned>` calls that otherwise trip Boost MPL enum constant
evaluation.

The same compatibility pass patches the ODF table border width casts used by
the PPTX and XLSX converters from `boost::lexical_cast<int>` to a direct cast,
avoiding another Boost numeric conversion instantiation rejected by current
Clang.

### macOS Verification

`build/macos/build.sh arm64` verifies the generated application by checking the
main executable architecture and running strict codesign verification. Unless
`EO_SKIP_LAUNCH=1` is set, it also opens the app once as a local launch smoke
test.
