# Building on Windows

The Windows build is driven by **`build.ps1`**, a PowerShell script that sets up the toolchain environment,
configures and builds the native app with MSVC + CMake, overlays the common
editors payload, generates fonts and theme thumbnails, and packages the result
as a ZIP and an Inno Setup installer (optionally an MSI).

> New here? Read the **[build overview](../README.md)** first — it explains the
> three CI jobs, the common payload, vcpkg, and caching, none of which are
> repeated below.

## Prerequisites

- **Windows** with **Visual Studio 2022** including the C++ x64 toolset. The
  build additionally needs the **MSVC v141 toolset**, the **Windows 10 SDK
  (10.0.19041.0)**, and **ATL + MFC**. If you don't have those components,
  `build.ps1 -InstallDeps` can add them (see below).
- **Cygwin** (parts of the native build shell out to its `bash`/`make`/`sh`).
- **CMake**, **Ninja**, and native (non-Cygwin) **perl**, **python**, and **git**
  on `PATH`.
- For packaging: **Inno Setup 6.2.2** and **7-Zip**; for the optional MSI,
  **Advanced Installer**.
- *(Optional but recommended)* **sccache** on `PATH` for a compiler cache.
- The submodules checked out (see the [overview](../README.md#prerequisites-all-platforms)).

`-InstallDeps` can install most of this for you (Cygwin, the VS components, and
the packaging tools via Chocolatey). It mutates the host and writes into
`Program Files`, so run it from an **elevated** PowerShell. You only need it
once per machine — omit it on subsequent builds.

## Getting the common payload first

`build.ps1` compiles the *native* app but does **not** build the editors web
content — that's the [common payload](../README.md#the-common-payload-again)
from the Linux `build-common` job. Supply it one of three ways:

1. **Download the `common-files` CI artifact**, and point the script at
   it with `-CommonDir <path>`.
2. **Build it locally with Docker** (Linux containers) by passing `-BuildCommon`.
   Slow; only worth it if you can't grab the artifact.
3. **Place it at `.\common`** (the default location) and pass nothing.

The expected layout is:

```
<common>\index.html
<common>\editors\webext\noconnect.html
<common>\editors\...            (the full editors payload)
```

## Quick start

Run from the **repository root** (the script derives the root from its own
location, so it works regardless of your current directory):

```powershell
# Common content already at .\common, tools already installed:
.\build\windows\build.ps1

# Point at a downloaded CI artifact:
.\build\windows\build.ps1 -CommonDir C:\downloads\common-files

# First-time machine: install everything (run elevated) and build common via Docker:
.\build\windows\build.ps1 -InstallDeps -BuildCommon
```

## Parameters

| Parameter         | Purpose                                                                 | Default                |
| ----------------- | ----------------------------------------------------------------------- | ---------------------- |
| `-RepoRoot`       | Repository root                                                         | two levels up from the script |
| `-CommonDir`      | Folder holding the Linux-built common payload                          | `<RepoRoot>\common`    |
| `-BuildCommon`    | Build the common payload locally with Docker                           | off                    |
| `-InstallDeps`    | Install Cygwin, VS components, and packaging tools (admin; one-time)   | off                    |
| `-BuildMsi`       | Also build the MSI with Advanced Installer (needs a license)          | off                    |
| `-SkipPackaging`  | Build and install only; skip ZIP / installer steps                    | off                    |
| `-ProductVersion`, `-BuildNumber`, `-CompanyName`, `-ProductName` | Version / branding | see [overview](../README.md#versioning-and-branding) |

## What the script does

In order: validate the repo layout → *(optional)* install dependencies →
resolve the common payload → set up a deterministic `PATH` (native tools ahead of
Cygwin) and import the MSVC environment → set up vcpkg → CMake configure (Ninja,
Release, vcpkg toolchain, sccache if present) → build → install → overlay the
common payload → generate fonts (`allfontsgen`) and theme thumbnails
(`allthemesgen`) → package (ZIP, Inno installer, optional MSI).

## Output

With packaging enabled (the default), artifacts land under
`desktop-apps\package\`:

- `...\zip\*.zip` — portable ZIP
- `...\inno\*.exe` — Inno Setup installer
- `...\advinst\*.msi` — MSI (only with `-BuildMsi`)

Use `-SkipPackaging` to stop after the install step; the unpackaged app tree is
then at `<RepoRoot>\desktopeditors`.

## Good to know

- **sccache is optional.** Without it on `PATH` the script just builds without a
  compiler cache (and says so). With it, object files are cached by content hash;
  embedded debug info (`/Z7`) is required for caching to work and the script sets
  it for you.
- **The packaging step pulls a couple of inputs at build time.** It stages the
  VC++ redistributable and fetches Inno Setup's "unofficial" language files (which
  no stock Inno install ships) into the Inno `Languages` folder. Both run on every
  packaging build — including CI, which does *not* pass `-InstallDeps`. Writing
  the language files into the Inno install dir needs write access there, so a
  plain local packaging run may need elevation. If that's a hassle, consider
  vendoring those files in the fork.
- **The build mutates the host** when `-InstallDeps` is used (VS components, global
  tools). That's fine on a throwaway CI runner; on your own machine, know that it
  changes your Visual Studio installation and `Program Files`.