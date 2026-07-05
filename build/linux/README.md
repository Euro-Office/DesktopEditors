# Building on Linux

The Linux build runs entirely in Docker via `docker buildx bake`. It compiles the
desktop application, overlays the common editors payload, generates fonts and
theme thumbnails, and produces the installable packages — all inside containers,
so it needs almost nothing installed on the host.

> New here? Read the **[build overview](../README.md)** first — it explains the
> three CI jobs, the common payload, vcpkg, and caching, none of which are
> repeated below.

## Prerequisites

- A container engine — **either**:
  - **Docker** with the **Buildx** plugin (Docker Desktop, or `docker buildx`
    available on a Docker Engine install), **or**
  - **Podman** (4.x+). The `./build.sh` wrapper detects Podman automatically and
    replays the same build graph with `podman build` (see
    [Building with Podman](#building-with-podman) below).
- The submodules checked out (see the [overview](../README.md#prerequisites-all-platforms)).

That's it — the C++ toolchain, Qt, the WASM toolchain, and all system `-dev`
packages are installed inside the images, not on your machine.

## Quick start

Run from the **repository root**. The bake graph is defined in
`build/docker-bake.hcl`; build a target with:

```sh
cd build
docker buildx bake -f ./docker-bake.hcl <target>
```
or
```sh
cd build/linux
docker buildx bake -f ./docker-bake.hcl <target>
```

The two targets you'll care about:

- **`desktop-common`** — the shared web/WASM editors payload. This is the same
  artifact the `build-common` CI job produces, and it's what the Windows build
  consumes. Build it on its own when you only need the common content:

  ```sh
  cd build
  docker buildx bake -f ./docker-bake.hcl desktop-common
  ```

- **`desktop-linux`** — the full desktop application build (depends on
  `desktop-common`), which compiles the native app and runs the font/theme
  post-steps.

Check `docker-bake.hcl` for the authoritative list of targets, their outputs,
and any overrides the workflow uses (version, branding, output type).

You can also use the build.sh script in this directory to build **`desktop-common`** and **`desktop-linux`** at once:

```sh
cd build/linux
./build.sh
```

## Building with Podman

`docker buildx bake` has no Podman equivalent — Podman ships a `podman buildx`
shim but it implements only `build`/`inspect`/`prune`/`version`, not `bake`. So
you cannot run the `docker buildx bake …` commands under Podman directly.

Instead, run the wrapper:

```sh
cd build/linux
./build.sh
```

`build.sh` detects the available engine: if `docker buildx bake` is present it
delegates to it unchanged; otherwise it falls back to **Podman** and replays the
exact same target graph as ordered `podman build` calls. Each bake
cross-target context (`contexts = { name = "target:X" }`) is reproduced by
building that target to a tagged image first and passing it with
`--build-context name=docker-image://<tag>`, so every `COPY --from=<name>`
resolves the same way. The BuildKit Dockerfile features these images use —
`--mount=type=cache`, `--mount=type=secret`, bind mounts and heredocs — are all
supported by Podman's Buildah backend, so the Dockerfiles are used verbatim.

The final packages land in `build/linux/deploy/packages` either way.

**Differences vs. the Docker path**

- The bake `cache-from`/`cache-to` `type=local` layer caches are a Buildx
  feature and are skipped under Podman. The in-build caches
  (`RUN --mount=type=cache` for ccache/npm/emscripten) and Podman's own layer
  cache still apply, so incremental rebuilds remain fast.
- To supply the Nextcloud secrets, export `NEXTCLOUD_USER` / `NEXTCLOUD_PASS`
  before running; the wrapper only wires the `--secret` mounts when they are set.
- All other knobs (`REGISTRY`, `TAG`, `PRODUCT_VERSION`, `BUILD_NUMBER`,
  `BRANDING_DIR`, `COMPANY_NAME`, `PRODUCT_NAME`, `GIT_COMMIT`) are read from the
  environment with the same defaults the HCL uses.

## How the desktop image is built

The desktop stage (in the bake Dockerfile) follows the standard sequence:

1. Install the build/system dependencies into the image.
2. Copy in the relevant submodules (`desktop-sdk`, `desktop-apps`, `core-fonts`)
   plus branding overlays.
3. Configure CMake with the vcpkg toolchain, Ninja, and `ccache`, then
   `cmake --build` / `cmake --install`.
4. Overlay the `desktop-common` payload onto the installed tree
   (`COPY --from=desktop-common`).
5. Run `allfontsgen` (fonts) and `allthemesgen` (slide-theme thumbnails), then
   remove the generator binaries so they don't ship.

## Caching

Compilation is cached with **ccache** via a BuildKit cache mount. If you're
working on the build itself, a few things are worth knowing:

- The ccache mount uses a **stable id** (`id=ccache`), so it persists and is
  reused across builds.
- Some other cache mounts (the build and NuGet caches) currently fold a
  `CACHE_BUST` arg into their mount **id**. Changing that arg starts a fresh
  cache rather than reusing the old one — so don't expect those two to persist
  across a bust. ccache is unaffected.
- The compile step builds inside a cache mount and copies the result out. That
  buys fast incremental rebuilds at the cost of strict layer reproducibility —
  fine for development and CI, worth knowing if you need a bit-reproducible
  release.

## Output

The build produces the installed application tree and the Linux packages inside
the image / bake output, default is `build/linux/deploy`. Use the bake `output` setting (e.g.
`type=docker`, `type=local,dest=...`) to control where artifacts land; see
`docker-bake.hcl`.
