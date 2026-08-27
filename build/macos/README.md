# Building on macOS

Building on macOS is three separate steps: build `desktop-sdk` natively, stage
the result, then build the Xcode project. `build/macos/stage.sh` handles the
middle step — overlaying the web payload onto a built `desktop-sdk` tree and
generating fonts/theme thumbnails. It does **not** build `desktop-sdk` itself,
and it does **not** run the Xcode build.

> New here? Read the **[build overview](../README.md)** first — it explains the
> three CI jobs, the common payload, vcpkg, and caching, none of which are
> repeated below.

## Prerequisites

- Xcode with the `Euro-Office-arm` scheme (`desktop-apps/macos/Euro-Office.xcodeproj`).
- **CMake**, **Ninja**, and **vcpkg** (bootstrapped) on `PATH`.
- Homebrew `autoconf`, `automake`, GNU `libtool` (not Apple's `/usr/bin/libtool`),
  and `pkg-config` — needed by vcpkg's `hunspell` port.
- The submodules checked out (see the [overview](../README.md#prerequisites-all-platforms)),
  including `core-fonts`.
- Docker, for building the [common payload](../README.md#the-common-payload-again)
  locally. Use `type=tar`, not the default `type=local` — `type=local` is known
  to hang indefinitely on Docker Desktop's macOS/virtiofs backend for this many
  small files (confirmed stuck, not just slow), and `type=tar` is also what CI
  already uses:
  ```bash
  docker buildx bake desktop-common --set desktop-common.output=type=tar,dest=./build/deploy/common.tar
  mkdir -p build/deploy/common && tar -xf build/deploy/common.tar -C build/deploy/common
  ```

## The three steps

Set these once and reuse them across all three steps:
```bash
REPO=/path/to/your/checkout
VCPKG=/path/to/vcpkg
EO_3RDPARTY=/path/to/3rdparty-cache
STAGE=/path/to/staging-root
```

1. **Build `desktop-sdk`** (the native `ascdocumentscore.framework`,
   `ooxmlsignature.framework`, the 3 `editors_helper*.app` bundles, `x2t`, and
   every converter — all one CMake project):
   ```bash
   cmake -S "${REPO}/desktop-sdk/ChromiumBasedEditors/lib" -B build-mac-sdk \
     -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_DESKTOP=1 \
     -DCMAKE_TOOLCHAIN_FILE="${VCPKG}/scripts/buildsystems/vcpkg.cmake" \
     -DVCPKG_TARGET_TRIPLET=arm64-osx \
     -DVCPKG_MANIFEST_MODE=ON \
     -DVCPKG_MANIFEST_DIR="${REPO}/core" \
     -DEO_CORE_3RD_PARTY_DIR="${EO_3RDPARTY}" \
     -DEO_CORE_OUTPUT_DIR="${STAGE}/converter"

   cmake --build build-mac-sdk
   ```
   First run fetches boost/openssl/icu/v8/cef via `build_3rdparty.py` —
   expect this to take a while and need several GB free. Confirm it worked:
   `${STAGE}/ascdocumentscore.framework`, `${STAGE}/ooxmlsignature.framework`,
   `${STAGE}/editors_helper.app` (+ GPU/Renderer variants), and
   `${STAGE}/converter/x2t` should all exist.
2. **Stage it** — this is what `stage.sh` automates:
   ```bash
   ./build/macos/stage.sh \
     --stage-dir "${STAGE}" \
     --3rdparty-dir "${EO_3RDPARTY}"
   ```
   (`--payload-dir` and `--core-fonts-dir` default to `build/deploy/common` and
   `core-fonts` under the repo root — override with flags or the matching env
   vars if yours live elsewhere.)
3. **Build the Xcode project**, pointed at the staged tree:
   ```bash
   xcodebuild -project desktop-apps/macos/Euro-Office.xcodeproj \
     -scheme Euro-Office-arm -configuration Release \
     EO_MAC_STAGE_DIR="${STAGE}" build
   ```

## What `stage.sh` does

In order: merge the CMake build's `package/` output into `converter/` → merge
the web payload (`index.html`, `editors/`, `fonts/`, `providers/`, plus
`converter/`'s extra config/locale files) → build `allfontsgen`/`allthemesgen`
standalone (they're not part of the `desktop-sdk` build; rebuilt fresh every
run, ~1-2 minutes, so they're always current against whatever native code
changed) → run `allfontsgen` (native + web `AllFonts.js`, `font_selection.bin`)
→ run `allthemesgen` (slide-theme thumbnails) → delete both generator
binaries from `converter/` so they don't ship.

Mirrors the equivalent sequence in Linux's
`desktop-apps/.docker/desktop-apps.bake.Dockerfile` and Windows'
`build.ps1` (step 9/9b) — **matching Windows' version specifically**, not
Linux's: Windows passes `--allfonts-web=`/`--output-web=` to `allfontsgen`,
Linux's Dockerfile doesn't. Omitting them silently drops the web `AllFonts.js`
that `doctrenderer` needs, which then makes `allthemesgen` fault — Windows'
own comment documents this exact gotcha, and it's why this script follows
Windows' fuller flag set.

## Good to know

- **Verifies real output, not just exit codes.** `allfontsgen` can exit `0`
  while writing essentially nothing — a real failure mode, not a theoretical
  one. The script checks file sizes, not just existence or exit status, to
  catch that class of failure.
- **Safe to re-run.** Each run fully replaces `editors/`, `fonts/`, and
  `providers/` from the payload dir and regenerates the font/theme data from
  scratch, so stale content from a previous run doesn't linger.
- **`--stage-dir` must already have a built `package/`.** The script fails
  fast with a clear message if it doesn't, rather than staging a broken tree.
