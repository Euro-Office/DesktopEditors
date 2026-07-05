# Building Euro-Office DesktopEditors

This directory holds everything needed to build **Euro-Office DesktopEditors**
(a fork of ONLYOFFICE DesktopEditors) from source, on Linux and Windows.

If you just want to build, go straight to your platform:

- **[Linux](./linux/README.md)** — a container-based build (`docker buildx bake`, or Podman via `./build.sh`)
- **[Windows](./windows/README.md)** — a PowerShell-driven MSVC build (`build.ps1`)

The rest of this page explains the model both platforms share. Read it once and
the platform guides will make a lot more sense.

## Prerequisites (all platforms)

This is a *super-repository*: almost none of the source lives here directly. The
real code is in submodules — `core`, `core-fonts`, `desktop-apps`, `desktop-sdk`,
`dictionaries`, `document-templates`, `sdkjs`, `sdkjs-forms`, `web-apps`. You
**must** check them out before building:

```sh
git clone https://github.com/Euro-Office/DesktopEditors.git
cd DesktopEditors
git submodule update --init --recursive
```

Every command in these guides assumes you are running from the **repository
root** (the directory that contains this `build/` folder), not from inside
`build/` itself.

## The big picture: three jobs, two platforms, one definition

A full release is produced by three jobs in the **"Build (Windows/Linux)"** CI
workflow:

| Job             | Runs on          | Produces                                                                       |
| --------------- | ---------------- | ------------------------------------------------------------------------------ |
| `build-common`  | Linux / Docker   | the JS + WASM **editors web payload** ("common"), published as `common-files`  |
| `build-linux`   | Linux / Docker   | the desktop app + Linux packages                                               |
| `build-windows` | Windows / MSVC   | the desktop app + ZIP and Inno installer (optionally an MSI)                   |

The single most important thing to understand:

> **Both `build-linux` and `build-windows` consume the output of `build-common`.**

`build-common` compiles the web editors (HTML/JS) and the core WASM once, on
Linux, because that part is platform-independent. The two desktop builds then
overlay that payload onto the native application they compile. So when you build
the desktop app, you don't rebuild the editors — you **supply** them. How you
supply them differs per platform and is covered in each guide.

## Build *definition* vs. build *orchestration*

The build is split into two layers, and keeping them straight is the key to
understanding why there are two very different-looking build systems here:

- **The build definition** — *what* to compile and how to link it — lives in
  **`desktop-apps/win-linux/CMakeLists.txt`**. This is a single, shared,
  cross-platform CMake project. It is the same on Linux and Windows.

- **The orchestration** — provision a toolchain, fetch dependencies, invoke
  CMake, run post-build steps, package — is **per-platform**:
  - Linux: a Dockerfile driven by `docker-bake.hcl` (see [linux/](./linux/README.md))
  - Windows: `windows/build.ps1` (see [windows/](./windows/README.md))

Both orchestrators do essentially the same sequence — configure CMake with the
vcpkg toolchain and a compiler cache, build, install, overlay the common payload,
generate fonts and theme thumbnails, package — just with platform-appropriate
tooling.

### Why not just use Docker for both?

The native Windows toolchain (MSVC, Qt, CEF, the v8 engine, the Windows SDK)
cannot be hermetically containerized on the standard hosted runners the way the
Linux toolchain can, and a Linux container obviously can't emit Windows binaries.
So the Linux build is a clean, reproducible Docker build, while the Windows build
is a script that provisions and runs against the host. The asymmetry is
deliberate, not an oversight.

## Shared concepts

These apply to both platforms; the platform guides won't repeat them.

### Dependencies via vcpkg (manifest mode)

Native third-party libraries are resolved by **vcpkg in manifest mode**. The
manifest and its version pins live in **`core/vcpkg.json`** (`VCPKG_MANIFEST_DIR`
points CMake at `core`). The exact dependency versions are pinned through the
manifest's `builtin-baseline`, so a fresh checkout of vcpkg still resolves the
same versions. If a bleeding-edge vcpkg HEAD ever misbehaves, check out the
baseline commit referenced in `core/vcpkg.json`.

### Compiler caching + the Ninja generator

Both builds use a compiler cache to avoid recompiling unchanged translation
units — **ccache** on Linux, **sccache** on Windows — wired in through
`CMAKE_C_COMPILER_LAUNCHER` / `CMAKE_CXX_COMPILER_LAUNCHER`. Because of that,
**both builds use the Ninja generator**: MSBuild ignores the compiler-launcher
variables, Ninja honours them. The cache is optional locally (the build just runs
slower without it) but strongly recommended in CI.

### Versioning and branding

These come from the workflow's top-level environment and can be overridden
locally:

| Variable                          | Meaning                                  | Default                |
| --------------------------------- | ---------------------------------------- | ---------------------- |
| `PRODUCT_VERSION`                 | marketing version                        | `9.3.1`                |
| `BUILD_NUMBER`                    | build identifier                         | `dev.1`                |
| `COMPANY_NAME` / `PRODUCT_NAME`   | shown in the app's About page            | `Euro-Office` / `DesktopEditors` |

## Where to go next

- Building on **[Linux](./linux/README.md)**
- Building on **[Windows](./windows/README.md)**
