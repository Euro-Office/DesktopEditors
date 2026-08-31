# Building on macOS

A host build, like [Windows](../windows/README.md) and unlike
[Linux](../linux/README.md)

```sh
cd DesktopEditors
./build/macos/build.sh --check      # check what's missing
./build/macos/build.sh --dry-run    # see what would happen
./build/macos/build.sh arm64        # actually build
```

Output is in `build/deploy/macos/arm64/Euro-Office.app`.

## macOS differences

AppShell: Cocoa, CMake entry point: build/macos/CMakeLists.txt, JS: JavaScriptCore, Orchestration: build.sh

`doctrenderer` already carries a JavaScriptCore backend (`js_internal/jsc/jsc_base.mm`),
selected by `USE_JAVASCRIPT_CORE`, which `core/common.cmake` turns on automatically for macOS.
Everything below the shell stays the same. Editors js/wasm payload is common between platforms.

build.sh will check, in order:

1. `COMMON_DIR`, if it points at an existing directory;
2. `<repo>/common`, if present — e.g. an unpacked `common-files` CI artifact;
3. otherwise it builds desktop-common build target
   
```sh
./build/macos/build.sh arm64
```

To reuse a CI artifact instead, unpack it and point at it:

```sh
COMMON_DIR=/path/to/common ./build/macos/build.sh arm64
```

`EO_SKIP_COMMON=1` disables the Docker build. Without a payload from any source
the `.app` still links, but has no editors and will not run usefully.

## Prerequisites

* macOS 13+ with Xcode and its command line tools (`xcode-select -p` must resolve)
* `cmake`, `ninja`, `pkg-config`, `python3`, `git`
* `autoconf`, `automake`, `libtool` — vcpkg builds hunspell through autotools on
  macOS (it uses CMake for the same port on Windows), so these are a host
  requirement here that the other platforms don't have. Missing `automake`
  shows up as an opaque `failed to run aclocal` inside a vcpkg port log.
* `ccache` (optional but recommended — same role as `sccache` on Windows)
* Recommended: Docker
* ~60 GiB free disk apce

## Signing

Ad-hoc by default — enough to run locally, not to distribute:

```sh
CODESIGNING_IDENTITY="Developer ID Application: Example (TEAMID)" \
DEVELOPMENT_TEAM=TEAMID \
./build/macos/build.sh arm64
```

Notarization is not wired up, so  `spctl --assess` is expected to fail.

## Intel Macs

Not tested so far