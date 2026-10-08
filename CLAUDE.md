# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

This is the **super-repo** for Euro-Office Desktop Editors — a rebrand of
ONLYOFFICE DocumentServer/DesktopEditors (see `ATTRIBUTION`, AGPL-3.0). It is a
build-orchestration meta-repo: **the actual source code lives in 9 git
submodules**, all forks under `github.com/Euro-Office`. The super-repo itself
contains only the Docker Bake build pipeline, branding/config overlays, CI, and
docs.

The only first-party source tracked here is:
- `build/docker-bake.hcl` + `build/.docker/*.Dockerfile` — the build orchestration
- `build/configs/core/DoctRenderer.config.desktop` — converter runtime config
- `.github/workflows/` — CI
- `CHANGELOG.md`, `README.md`, `ATTRIBUTION`, `LICENSE`

### Submodules must be initialized first
A bare checkout has **empty submodule directories** (no source). Before doing
anything, initialize them:
```sh
git submodule update --init --recursive
```
The submodule directories are pinned to specific commits via `git submodule
status`; the super-repo's job is to lock a consistent set of submodule SHAs and
build them together.

## Build commands

All builds run through Docker Bake from the `build/` directory:
```sh
cd build
docker buildx bake              # default target: desktop-export → ./deploy/desktop
docker buildx bake packages     # build .deb/.rpm/.tar.xz → ./deploy/packages
docker buildx bake deps         # build dependency images only (core, sdkjs, web-apps, desktop-js)
```
There is no separate compile/lint/test step at the super-repo level — building
*is* `docker buildx bake`, and per-component tests live inside the submodules.
CI here (`.github/workflows/check.yml`) only markdown-lints and spell-checks
`CHANGELOG.md` (custom dictionary: `.aspell.en.pws`); `winget.yml` publishes to
WinGet on GitHub release.

### Build-time variables (override via env or `--set`)
Defined as `variable` blocks in `build/docker-bake.hcl`; override with an env var
of the same name, e.g. `PRODUCT_VERSION=9.4.0 docker buildx bake`:
- `PRODUCT_VERSION` (e.g. `9.3.1`), `BUILD_NUMBER`
- `COMPANY_NAME` / `PRODUCT_NAME` — branding strings (`COMPANY_NAME_LOW` is derived)
- `REGISTRY`, `TAG` — image naming
- `BRANDING_DIR` (default `.`) — root of a branding overlay tree that mirrors
  submodule paths; the `packages` stage copies upstream `desktop-apps/package/`
  then overlays `${BRANDING_DIR}/desktop-apps/package/` on top
- `NUGET_CACHE` (`local`|`remote`), `CACHE_BUST`

## Build architecture (the Docker Bake DAG)

Understanding the build means reading `docker-bake.hcl` together with the
`.docker/*.bake.Dockerfile` in each submodule. Each submodule ships its own
Dockerfile under `<submodule>/.docker/`; `docker-bake.hcl` wires them together
as named build *contexts* (`contexts = { name = "target:other-target" }`), so
stages consume each other's outputs without intermediate registries.

Dependency-target images (group `deps`):
- `core-base`, `core-wasm` ← `core/.docker/` — C++ server core (native + WASM)
- `desktop-js` ← `desktop-apps/.docker/` — desktop frontend JS / login page
- `sdkjs-desktop` ← `sdkjs/.docker/` — JS editor SDK; **depends on `core-wasm`**
- `web-apps` ← `web-apps/.docker/` — document-server web frontend

Assembly:
- `desktop-builder` ← `desktop-apps/.docker/` — pulls in `core-base`,
  `desktop-js`, `sdkjs-desktop`, `web-apps`
- `desktop-export` ← `build/.docker/desktop-composer.bake.Dockerfile` — the
  **final filesystem layout** is assembled here: copies editors/web-apps/sdkjs,
  converter binaries + `DoctRenderer.config`, document templates, dictionaries,
  fonts, then regenerates `AllFonts.js`/`font_selection.bin` via `allfontsgen`
  and slide themes via `allthemesgen`. Outputs via a `FROM scratch` stage to
  `./deploy/desktop`.
- `packages` ← `build/.docker/packages.bake.Dockerfile` — on `ubuntu:24.04`,
  runs the upstream `desktop-apps/package/` Makefile (`make deb rpm tar`) over
  the `desktop-export` output. Outputs `.deb`/`.rpm`/`.tar.xz` to `./deploy/packages`.

The runtime entrypoint produced by the composer is `start_desktop.sh`, which
launches the CEF/Chromium-based `DesktopEditors` binary with
`LD_PRELOAD=libcef.so`.

## Things that are easy to get wrong

- **Only the Nextcloud cloud provider is currently bundled.** The composer
  copies `desktop-apps/common/loginpage/providers/nextcloud` only — adding other
  providers (ownCloud, Seafile, etc.) requires editing
  `desktop-composer.bake.Dockerfile`.
- Editing a Dockerfile for a *component* means editing it **in that submodule**,
  not here. Only the composer and packaging Dockerfiles live in `build/.docker/`.
- Bumping a component means committing the new submodule SHA in this super-repo
  (`chore: update submodules`-style commits) so the locked set stays consistent.
