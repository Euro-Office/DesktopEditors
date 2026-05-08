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
QT_DIR=/path/to/qt-layout        # contains macos/bin/qmake or clang_64/bin/qmake
DESKTOP_APPS_DIR=/path/to/desktop-apps
BUILD_TOOLS_REV=<commit>         # ONLYOFFICE/build_tools revision
CODESIGNING_IDENTITY="Developer ID Application: ..."
DEVELOPMENT_TEAM=<team-id>
EO_SKIP_LAUNCH=1                 # skip the local launch smoke test
```

`DESKTOP_APPS_DIR` is optional. It is useful while the matching `desktop-apps`
macOS branding branch is still under review; after that branch is merged,
`DesktopEditors` can point its `desktop-apps` submodule at the upstream commit.

Without a Developer ID identity the app build is ad-hoc signed and suitable for
local testing. Release DMG signing and notarization remain gated on Developer ID
and notarization credentials.

### macOS Verification

`build/macos/build.sh arm64` verifies the generated application by checking the
main executable architecture and running strict codesign verification. Unless
`EO_SKIP_LAUNCH=1` is set, it also opens the app once as a local launch smoke
test.
