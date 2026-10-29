# Building on macOS

Building on macOS is a few separate steps: build `desktop-sdk` natively, stage
the result, apply branding/version, then build the Xcode project.
`build/macos/stage.sh` handles the staging step — overlaying the web payload
onto a built `desktop-sdk` tree and generating fonts/theme thumbnails. It does
**not** build `desktop-sdk` itself, and it does **not** run the Xcode build.

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
  locally. Run it from inside `build/` — that's where `docker-bake.hcl` lives
  (there is no bake file at the repo root, and the output paths below are
  relative to `build/`). Use `type=tar`, not the default `type=local` —
  `type=local` is known to hang indefinitely on Docker Desktop's macOS/virtiofs
  backend for this many small files (confirmed stuck, not just slow), and
  `type=tar` is also what CI already uses:
  ```bash
  cd build
  docker buildx bake -f ./docker-bake.hcl desktop-common \
    --set desktop-common.output=type=tar,dest=./deploy/common.tar
  rm -rf deploy/common && mkdir -p deploy/common && tar -xf deploy/common.tar -C deploy/common
  cd ..
  ```
  The build runs several webpack builds in parallel, so give Docker Desktop
  plenty of memory (Settings → Resources; the default can be too low — it
  failed with out-of-memory kills at ~7.7 GiB, 12 GiB or more is safer).

## The steps

Set these once and reuse them across all the steps below:
```bash
REPO=/path/to/your/checkout
VCPKG=/path/to/vcpkg
EO_3RDPARTY=/path/to/3rdparty-cache
STAGE=/path/to/staging-root  # arbitrary, doesn't need to exist yet - step 1 creates it
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
   `${STAGE}/converter/x2t` should all exist. If they do, skip the box below.

   <details>
   <summary><b>Troubleshooting only:</b> <code>${STAGE}</code> is empty or missing after the build
   (<code>ninja: no work to do</code>, or <code>stage.sh</code> says <code>converter/x2t not found</code>)</summary>

   Not part of the normal flow. `${STAGE}` is filled by each target's
   post-build copy, so it is only (re)populated when the targets actually
   relink. If you deleted `${STAGE}` (or pointed `EO_CORE_OUTPUT_DIR`
   somewhere new) but kept `build-mac-sdk`, Ninja considers everything up to
   date and copies nothing. Force it by deleting `build-mac-sdk` too (full
   rebuild), or delete just the link products so Ninja relinks them (no
   recompiling) and re-runs the copies:
   ```bash
   find build-mac-sdk \( -path build-mac-sdk/vcpkg_installed -o -name CMakeFiles \) -prune -o \
     \( \( -type d -name '*.framework' -prune \) -o \( -type f \( -name '*.dylib' -o -name x2t -o -name editors_helper \) \) \) \
     -exec rm -rf {} +
   cmake --build build-mac-sdk
   ```
   </details>
2. **Stage it** — this is what `stage.sh` automates:
   ```bash
   "${REPO}/build/macos/stage.sh" \
     --stage-dir "${STAGE}" \
     --3rdparty-dir "${EO_3RDPARTY}"
   ```
   (`--payload-dir` and `--core-fonts-dir` default to `build/deploy/common` and
   `core-fonts` under the repo root — override with flags or the matching env
   vars if yours live elsewhere.)
3. **Apply branding/version** — patches the committed `Info.plist` in place
   with the company/product name and version to actually ship. Run this every
   time: the committed file is just whatever was last checked in, and nothing
   else keeps it in sync, so don't rely on it already being correct.
   ```bash
   "${REPO}/desktop-apps/macos/apply-branding.sh" \
     --company-name Euro-Office \
     --product-name Euro-Office \
     --version "$(cat "${REPO}/VERSION.txt")"
   ```
   This is exactly what CI's own "Apply branding" step in `build-macos` runs
   before `xcodebuild` — patches `NSHumanReadableCopyright`/`CFBundleName`/
   `CFBundleShortVersionString`. Use different `--company-name`/`--product-name`
   values to build a different brand (e.g. nextcloud-office).
4. **Build the Xcode project**, pointed at the staged tree:
   ```bash
   xcodebuild -project "${REPO}/desktop-apps/macos/Euro-Office.xcodeproj" \
     -scheme Euro-Office-arm -configuration Release \
     EO_MAC_STAGE_DIR="${STAGE}" \
     CONFIGURATION_BUILD_DIR="${REPO}/build/macos/out" \
     build
   ```
   `Euro-Office.app` lands directly at `${REPO}/build/macos/out/Euro-Office.app` —
   without `CONFIGURATION_BUILD_DIR`, Xcode uses its default DerivedData
   location instead (`~/Library/Developer/Xcode/DerivedData/Euro-Office-<hash>/Build/Products/<configuration>/`).
5. **(Optional) Package a DMG installer** — `make-dmg.sh` packages the built
   `.app` into a distributable `.dmg` (app + `/Applications` symlink,
   background graphic), using [`appdmg`](https://github.com/LinusU/node-appdmg)
   and the config/assets in `desktop-apps/macos/fastlane/resources/`. Needs
   Node/npm on `PATH` (not required for steps 1-4) — CI's macOS runners have
   it by default.
   ```bash
   "${REPO}/build/macos/make-dmg.sh" \
     --app "${REPO}/build/macos/out/Euro-Office.app" \
     --output "${REPO}/build/macos/out/Euro-Office-DesktopEditors-9.3.5-1-macos-arm64.dmg"
   ```

## What `stage.sh` does

In order: check that `converter/x2t` exists (the native build output already
lands in `converter/`, there is nothing to merge) → merge the web payload (`index.html`, `editors/`, `fonts/`, `providers/`, plus
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
- **`--stage-dir` must already have a built `converter/x2t`.** The script fails
  fast with a clear message if it doesn't, rather than staging a broken tree.
