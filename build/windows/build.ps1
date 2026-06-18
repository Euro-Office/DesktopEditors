#Requires -Version 5.1
<#
.SYNOPSIS
    Local Windows build for Euro-Office DesktopEditors.

    This mirrors the "build-windows" job of the "Build (Windows/Linux)" GitHub
    Actions workflow, step for step, so a developer can reproduce a CI build on
    their own machine.

.DESCRIPTION
    The CI pipeline has two jobs:

      build-common  (Linux / Docker / WASM)  -> produces the editors web payload
      build-windows (Windows / MSVC / CMake) -> compiles the desktop app & packages

    Only the second job can run natively on Windows. The first job builds the
    JS/WASM "common" editors content inside a Linux container, so locally you
    must SUPPLY that content. Three ways to get it:

      1. Download the "common-files" artifact from a CI run and unzip it, then
         pass its folder via -CommonDir.
      2. Build it yourself with Docker Desktop (Linux containers) via -BuildCommon.
      3. Place it at .\common (the default location) and run with no extra flags.

    The expected layout of the common folder is:
        <common>\index.html
        <common>\editors\webext\noconnect.html
        <common>\editors\...           (the full editors payload)

.PARAMETER RepoRoot
    Root of the checked-out fork (with submodules). This script lives at
    <repo>\build\windows\, so the default is two levels up from the script -
    meaning it works no matter which directory you launch it from.

.PARAMETER CommonDir
    Folder holding the Linux-built "common" editors content. Defaults to
    "<RepoRoot>\common".

.PARAMETER BuildCommon
    Build the common content locally with Docker (requires Docker Desktop in
    Linux-container mode). Slow; only needed if you can't grab the CI artifact.

.PARAMETER InstallDeps
    Install build/packaging dependencies (Cygwin, MSVC v141 + Win10 SDK + ATL/MFC,
    Inno Setup, 7-Zip, and optionally Advanced Installer). Requires admin and,
    for the packaging tools, Chocolatey. Omit if you already have everything.

.PARAMETER BuildMsi
    Also build the MSI with Advanced Installer. Off by default to match the
    workflow, where the MSI step is currently commented out. Requires a license.

.EXAMPLE
    # Common content already at .\common, all tools installed:
    .\build-windows.ps1

.EXAMPLE
    # First-time machine: install everything, build common via Docker:
    .\build-windows.ps1 -InstallDeps -BuildCommon

.EXAMPLE
    # Point at a downloaded CI artifact:
    .\build-windows.ps1 -CommonDir C:\downloads\common-files
#>
[CmdletBinding()]
param(
    [string]$RepoRoot       = '',
    [string]$CommonDir      = '',                       # default: <RepoRoot>\common
    [switch]$BuildCommon,

    # Values that the workflow takes from its top-level env block.
    [string]$ProductVersion = '9.3.1',
    [string]$BuildNumber    = 'dev.1',
    [string]$Arch           = 'x64',
    [string]$Target         = 'standalone',
    [string]$CompanyName    = 'Euro-Office',
    [string]$ProductName    = 'DesktopEditors',
    [string]$WinSdkVersion  = '10.0.19041.0',

    # Tool locations / install knobs.
    [string]$VcpkgRoot      = $env:VCPKG_ROOT,
    [string]$CygwinRoot     = 'C:\cygwin64',
    [string]$InnoRoot       = "${env:ProgramFiles(x86)}\Inno Setup 6",
    [string]$SevenZipRoot   = 'C:\Program Files\7-Zip',
    [string]$AdvInstLicense = '',

    [switch]$InstallDeps,
    [switch]$BuildMsi,
    [switch]$SkipPackaging
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # speeds up Invoke-WebRequest

# Match the workflow env.
$env:PYTHONUTF8 = '1'

# This script lives at <repo>\build\windows\, but the build must run from the
# repo root (where the workflow operates). Derive the root from the script's
# own location so it works regardless of the current directory; -RepoRoot
# still overrides.
if (-not $RepoRoot) {
    if ($PSScriptRoot) {
        $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    } else {
        $RepoRoot = (Get-Location).Path
    }
}

if (-not $CommonDir) { $CommonDir = Join-Path $RepoRoot 'common' }
$VersionFull = "$ProductVersion.0"            # make.ps1 wants a 4-part System.Version
$InstallDir  = Join-Path $RepoRoot 'desktopeditors'
$PackageDir  = Join-Path $RepoRoot 'desktop-apps\package'

# ───────────────────────────── helpers ──────────────────────────────────────
# When this runs inside GitHub Actions, emit ::group::/::endgroup:: so each
# phase is a collapsible, individually-timed section in the Actions log -
# recovering the per-step UI you'd otherwise lose by calling one script.
# Locally it prints a plain banner instead.
$script:InActions = ($env:GITHUB_ACTIONS -eq 'true')
$script:GroupOpen = $false

function Write-Step([string]$Msg) {
    if ($script:InActions) {
        if ($script:GroupOpen) { Write-Host '::endgroup::' }
        Write-Host "::group::$Msg"
        $script:GroupOpen = $true
    } else {
        Write-Host ''
        Write-Host ('=' * 78) -ForegroundColor Cyan
        Write-Host "  $Msg" -ForegroundColor Cyan
        Write-Host ('=' * 78) -ForegroundColor Cyan
    }
}

function Close-StepGroup {
    if ($script:InActions -and $script:GroupOpen) {
        Write-Host '::endgroup::'
        $script:GroupOpen = $false
    }
}

function Assert-LastExit([string]$What) {
    if ($LASTEXITCODE -ne 0) { throw "$What failed (exit $LASTEXITCODE)." }
}

function Get-VsInstallPath {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) { throw "vswhere.exe not found - is Visual Studio 2022 installed?" }
    $p = & $vswhere -latest -products * `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath
    if (-not $p) { throw "No Visual Studio install with the C++ x64 toolset was found." }
    return $p
}

# Run vcvars in a child cmd and import the resulting environment into THIS
# PowerShell process. vcvars only prepends MSVC/SDK dirs, so it preserves the
# deterministic PATH ordering we set up below (native tools > Cygwin > rest).
function Import-VcVars([string]$Arch, [string]$SdkVersion) {
    $batName = if ($Arch -eq 'x86') { 'vcvars32.bat' } else { 'vcvars64.bat' }
    $vcvars  = Join-Path (Get-VsInstallPath) "VC\Auxiliary\Build\$batName"
    if (-not (Test-Path $vcvars)) { throw "vcvars not found at $vcvars" }

    $capture = & cmd /c "`"$vcvars`" $SdkVersion >NUL 2>&1 && set"
    foreach ($line in $capture) {
        $i = $line.IndexOf('=')
        if ($i -gt 0) {
            $name  = $line.Substring(0, $i)
            $value = $line.Substring($i + 1)
            [Environment]::SetEnvironmentVariable($name, $value, 'Process')
        }
    }
    if (-not $env:VCINSTALLDIR) { throw "vcvars import failed (VCINSTALLDIR empty)." }
    Write-Host "Imported MSVC environment from $batName ($SdkVersion)."
}

# ───────────────────────── 0. sanity checks ─────────────────────────────────
Write-Step "0. Validating repository layout"
Push-Location $RepoRoot
try {
    foreach ($p in @('desktop-apps\win-linux\CMakeLists.txt', 'core\vcpkg.json', 'build\docker-bake.hcl')) {
        if (-not (Test-Path (Join-Path $RepoRoot $p))) {
            throw "Expected '$p' under RepoRoot. Run from the repo root and make sure submodules are checked out (git submodule update --init --recursive)."
        }
    }
    Write-Host "RepoRoot : $RepoRoot"
    Write-Host "CommonDir: $CommonDir"

    # ──────────────────── 1. install dependencies (optional) ────────────────
    if ($InstallDeps) {
        Write-Step "1. Installing dependencies"

        # 1a. Cygwin -> C:\cygwin64 (NOT added to PATH; we order PATH ourselves).
        if (Test-Path (Join-Path $CygwinRoot 'bin\bash.exe')) {
            Write-Host "Cygwin already present at $CygwinRoot - skipping."
        } else {
            Write-Host "Installing Cygwin to $CygwinRoot ..."
            $setup = Join-Path $env:TEMP 'cygwin-setup-x86_64.exe'
            Invoke-WebRequest 'https://www.cygwin.com/setup-x86_64.exe' -OutFile $setup
            $pkgs = 'automake,cmake,make,git,python3,python3-devel'
            $args = @('-q','-n','-N','-d','-B',
                      '-R', $CygwinRoot,
                      '-s','https://mirrors.kernel.org/sourceware/cygwin/',
                      '-l', (Join-Path $env:TEMP 'cygwin-pkgs'),
                      '-P', $pkgs)
            Start-Process -FilePath $setup -ArgumentList $args -Wait -NoNewWindow
        }

        # 1b. Windows 10 SDK + MSVC v141 toolset + ATL + MFC (x86 & x64).
        Write-Host "Adding Win10 SDK 19041 + VC v141 + ATL + MFC ..."
        $vsInstaller = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vs_installer.exe"
        $installPath = Get-VsInstallPath
        & $vsInstaller modify `
            --installPath $installPath `
            --add Microsoft.VisualStudio.Component.Windows10SDK.19041 `
            --add Microsoft.VisualStudio.Component.VC.v141.x86.x64 `
            --add Microsoft.VisualStudio.Component.VC.v141.ATL `
            --add Microsoft.VisualStudio.Component.VC.v141.MFC `
            --quiet --norestart --force
        if ($LASTEXITCODE -notin @(0, 3010)) {
            Write-Warning "vs_installer returned $LASTEXITCODE - components may already be installed, continuing."
        }

        # 1c. Packaging tools via Chocolatey.
        if (Get-Command choco -ErrorAction SilentlyContinue) {
            choco install innosetup --version=6.2.2 -y --no-progress
            choco install 7zip -y --no-progress
            if ($BuildMsi) {
                choco install advanced-installer -y --no-progress
                if ($AdvInstLicense) {
                    $ai    = "${env:ProgramFiles(x86)}\Caphyon\Advanced Installer*\bin\x86\AdvancedInstaller.com"
                    $aiExe = (Get-Item $ai | Select-Object -First 1).FullName
                    & $aiExe /RegisterCI $AdvInstLicense
                }
            }
        } else {
            Write-Warning "Chocolatey not found - skipping Inno Setup / 7-Zip / Advanced Installer install. Install them manually or install choco first."
        }
    }

    # ───────────────── 2. obtain the Linux-built common content ──────────────
    Write-Step "2. Resolving 'common' editors content"
    if ($BuildCommon) {
        Write-Host "Building common content with Docker (this is slow) ..."
        if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
            throw "-BuildCommon requires Docker Desktop on PATH (Linux containers)."
        }
        # The bake graph reads these (euro-office brand needs no Nextcloud creds).
        $env:PRODUCT_VERSION = $ProductVersion
        $env:BUILD_NUMBER    = $BuildNumber
        $env:BUILD_ROOT      = '/package'
        $env:NUGET_CACHE     = 'local'

        Push-Location (Join-Path $RepoRoot 'build')
        try {
            docker buildx bake -f ./docker-bake.hcl desktop-common `
                --set "desktop-common.tags=desktop-common:local" `
                --set "desktop-common.output=type=docker"
            Assert-LastExit "docker bake"
        } finally { Pop-Location }

        if (Test-Path $CommonDir) { Remove-Item -Recurse -Force $CommonDir }
        docker create --name eo_common_tmp desktop-common:local true | Out-Null
        docker cp eo_common_tmp:/ $CommonDir
        docker rm eo_common_tmp | Out-Null
    }

    if (-not (Test-Path (Join-Path $CommonDir 'index.html')) -or
        -not (Test-Path (Join-Path $CommonDir 'editors'))) {
        throw @"
Common content not found at: $CommonDir
Expected '$CommonDir\index.html' and '$CommonDir\editors\'.
Either download the 'common-files' CI artifact and pass -CommonDir, or rerun with -BuildCommon.
"@
    }
    Write-Host "Common content OK."

    # ─────────── 3. copy login-page assets into place (workflow step) ────────
    Write-Step "3. Copying common files into the loginpage deploy folder"
    $dest = Join-Path $RepoRoot 'desktop-apps\common\loginpage\deploy'
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item (Join-Path $CommonDir 'index.html')                 (Join-Path $dest 'index.html')     -Force
    Copy-Item (Join-Path $CommonDir 'editors\webext\noconnect.html') (Join-Path $dest 'noconnect.html') -Force

    # ─────────── 4. deterministic PATH (native tools > Cygwin > rest) ────────
    #
    # Why: parts of the native build (e.g. ICU pulled in through vcpkg) shell
    # out to Cygwin's bash/make/sh, but the build BREAKS if perl/python/git/
    # cmake resolve to Cygwin copies. So we front-load the Windows-native dirs
    # for those four, then Cygwin's bin (so bash/sh/make are Cygwin's, not Git's
    # MSYS ones), then the rest of PATH.
    Write-Step "4. Setting up PATH ordering + CYGWIN_ROOT"
    $nativeDirs = @()
    foreach ($tool in 'perl','python','git','cmake') {
        $cmd = Get-Command $tool -ErrorAction SilentlyContinue
        if ($cmd -and ($cmd.Source -notlike "$CygwinRoot\*")) {
            $dir = Split-Path $cmd.Source
            # Git\bin also ships bash.exe/sh.exe which would shadow Cygwin's;
            # the sibling Git\cmd has only the git launcher, so prefer it.
            if ($tool -eq 'git' -and $dir -like '*\Git\bin') {
                $cmdDir = Join-Path (Split-Path $dir) 'cmd'
                if (Test-Path (Join-Path $cmdDir 'git.exe')) { $dir = $cmdDir }
            }
            if ($nativeDirs -notcontains $dir) { $nativeDirs += $dir }
            Write-Host ("native {0,-8} -> {1}  (PATH dir: {2})" -f $tool, $cmd.Source, $dir)
        }
    }
    $env:PATH        = ($nativeDirs + "$CygwinRoot\bin" + $env:PATH) -join ';'
    $env:CYGWIN_ROOT = $CygwinRoot

    # ─────────────────────── 5. verify tool resolution ──────────────────────
    Write-Step "5. Verifying tool versions"
    foreach ($tool in 'perl','python','git','cmake') {
        $cmd = Get-Command $tool -ErrorAction SilentlyContinue
        if ($cmd) {
            Write-Host ("{0,-8} -> {1}" -f $tool, $cmd.Source)
            if ($cmd.Source -like "$CygwinRoot\*") { throw "ERROR: '$tool' resolves to the Cygwin copy at $($cmd.Source)." }
        } else {
            throw "ERROR: '$tool' not found in PATH."
        }
    }
    foreach ($tool in 'bash','sh','make') {
        $cmd = Get-Command $tool -ErrorAction SilentlyContinue
        if ($cmd) {
            Write-Host ("{0,-8} -> {1}" -f $tool, $cmd.Source)
            if ($cmd.Source -notlike "$CygwinRoot\*") { throw "ERROR: '$tool' resolves to a non-Cygwin copy at $($cmd.Source)." }
        } else {
            throw "ERROR: '$tool' not found in PATH (need Cygwin's)."
        }
    }
    $perlOut = (perl --version) -join ''
    if ($perlOut -match 'cygwin') { throw "ERROR: 'perl' is Cygwin Perl." }

    # ───────────────────────────── 6. vcpkg ─────────────────────────────────
    Write-Step "6. Setting up vcpkg"
    if ($VcpkgRoot -and (Test-Path (Join-Path $VcpkgRoot 'vcpkg.exe'))) {
        $env:VCPKG_ROOT = $VcpkgRoot
    } else {
        $VcpkgRoot = Join-Path $RepoRoot '.vcpkg'
        if (-not (Test-Path (Join-Path $VcpkgRoot 'vcpkg.exe'))) {
            if (-not (Test-Path $VcpkgRoot)) {
                git clone https://github.com/microsoft/vcpkg.git $VcpkgRoot
                Assert-LastExit "git clone vcpkg"
            }
            & (Join-Path $VcpkgRoot 'bootstrap-vcpkg.bat') -disableMetrics
            Assert-LastExit "bootstrap-vcpkg"
        }
        $env:VCPKG_ROOT = $VcpkgRoot
    }
    Write-Host "VCPKG_ROOT = $env:VCPKG_ROOT"
    Write-Host "NOTE: manifest mode pins versions via core\vcpkg.json's builtin-baseline. If a fresh vcpkg HEAD misbehaves, check out the baseline commit referenced there."

    # ─────────── load MSVC env (vcvars) on top of our ordered PATH ───────────
    Write-Step "Loading MSVC environment (vcvars)"
    Import-VcVars -Arch $Arch -SdkVersion $WinSdkVersion

    # ───────────────────────── 7. CMake Configure ───────────────────────────
    Write-Step "7. CMake Configure"
    $cmakeArgs = @(
        '-G', 'Visual Studio 17 2022'
    )
    if ($Arch -eq 'x86') { $cmakeArgs += @('-A', 'Win32') }
    $cmakeArgs += @(
        "-DCMAKE_TOOLCHAIN_FILE=$($env:VCPKG_ROOT)\scripts\buildsystems\vcpkg.cmake",
        '-DVCPKG_MANIFEST_MODE=ON',
        '-DVCPKG_MANIFEST_DIR=core',
        '-DABOUT_PAGE_APP_NAME=Desktop Editors',
        'desktop-apps/win-linux/'
    )
    cmake @cmakeArgs
    Assert-LastExit "CMake configure"

    # ─────────────────────── 8. CMake Build + Install ───────────────────────
    Write-Step "8. CMake Build"
    cmake --build . --config Release --parallel -- /p:UseMultiToolTask=true /p:EnforceProcessCountAcrossBuilds=true
    Assert-LastExit "CMake build"

    Write-Step "8b. CMake Install"
    cmake --install . --config Release
    Assert-LastExit "CMake install"

    # ─────────────── 9. overlay the common tree onto the install dir ────────
    # Mirror the entire common payload over the installed tree (matches the
    # workflow's robocopy). robocopy uses exit codes 0-7 for success and >=8
    # for real errors, so don't treat any nonzero code as failure - and reset
    # $LASTEXITCODE afterward so later Assert-LastExit checks aren't tripped.
    Write-Step "9. Overlaying common content onto the install dir"
    robocopy $CommonDir $InstallDir /E /IS /IT /NFL /NDL /NJH /NJS
    $rc = $LASTEXITCODE
    if ($rc -ge 8) { throw "robocopy overlay failed (exit $rc)." }
    $global:LASTEXITCODE = 0

    # ─────────── 9b. generate fonts + slide-theme thumbnails ────────────────
    # allfontsgen builds AllFonts.js + font_selection.bin from the installed
    # and core fonts; allthemesgen then uses AllFonts.js to render the slide-
    # theme thumbnails. Order matters - themes consume the fonts output - and
    # both tools are deleted afterward so they don't ship in the package.
    Write-Step "9b. Generate fonts and theme thumbnails"
    $converter = Join-Path $InstallDir 'converter'

    & "$converter\allfontsgen.exe" `
        --use-system=1 `
        "--input=$InstallDir\fonts" `
        "--input=$RepoRoot\core-fonts" `
        "--allfonts=$converter\AllFonts.js" `
        "--selection=$converter\font_selection.bin"
    Assert-LastExit "allfontsgen"

    & "$converter\allthemesgen.exe" `
        "--converter-dir=$converter" `
        "--src=$InstallDir\editors\sdkjs\slide\themes" `
        "--allfonts=$converter\AllFonts.js" `
        "--output=$InstallDir\editors\sdkjs\common\Images"
    Assert-LastExit "allthemesgen"

    Remove-Item -Force "$converter\allfontsgen.exe", "$converter\allthemesgen.exe"

    # ───────────────────────── 10/11. packaging ─────────────────────────────
    if ($SkipPackaging) {
        Write-Step "Packaging skipped (-SkipPackaging). Build output is at: $InstallDir"
    } else {
        Push-Location $PackageDir
        try {
            Write-Step "10. Stage build (make.ps1)"
            .\make.ps1 `
                -Version     $VersionFull `
                -Arch        $Arch `
                -Target      $Target `
                -CompanyName $CompanyName `
                -ProductName $ProductName `
                -SourceDir   $InstallDir
            Assert-LastExit "make.ps1"

            Write-Step "11a. Build ZIP (make_zip.ps1)"
            $env:PATH = "$SevenZipRoot;$env:PATH"
            .\make_zip.ps1 -Version $VersionFull -Arch $Arch -Target $Target
            Assert-LastExit "make_zip.ps1"

            Write-Step "11b. Build Inno installer (make_inno.ps1)"
            # INNOPATH must point at the Inno Setup program directory. Prefer
            # the real install dir (it carries the compiler's support files)
            # over a Chocolatey shim, then any iscc.exe on PATH, then -InnoRoot.
            $isccItem = Get-ChildItem 'C:\Program Files (x86)\Inno Setup*','C:\Program Files\Inno Setup*' `
                            -Recurse -Filter iscc.exe -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($isccItem) {
                $env:INNOPATH = Split-Path $isccItem.FullName
            } else {
                $iscc = Get-Command iscc.exe -ErrorAction SilentlyContinue
                if ($iscc) {
                    $env:INNOPATH = Split-Path $iscc.Source
                } elseif (Test-Path (Join-Path $InnoRoot 'iscc.exe')) {
                    $env:INNOPATH = $InnoRoot
                } else {
                    throw "Inno Setup (iscc.exe) not found. Install it or pass -InnoRoot."
                }
            }
            Write-Host "INNOPATH=$env:INNOPATH"

            # make_inno.ps1 bundles the VC++ redistributable, fetching it at
            # package time via WebClient from aka.ms (which failed on the
            # runner). It SKIPS that download when inno\vc_redist.<arch>.exe
            # already exists with a valid ProductVersion, so pre-stage it here
            # with a modern, redirect-following, retrying fetch and let
            # make_inno reuse it.
            $vcRedist = Join-Path $PackageDir "inno\vc_redist.$Arch.exe"
            $vcValid  = (Test-Path $vcRedist) -and (Get-Item $vcRedist).VersionInfo.ProductVersion
            if (-not $vcValid) {
                $vcUrl = "https://aka.ms/vs/17/release/vc_redist.$Arch.exe"
                New-Item -ItemType Directory -Force -Path (Split-Path $vcRedist) | Out-Null
                $got = $false
                for ($i = 1; $i -le 5 -and -not $got; $i++) {
                    try {
                        Write-Host "Pre-fetching VCRedist (attempt $i): $vcUrl"
                        Invoke-WebRequest -Uri $vcUrl -OutFile $vcRedist
                        if ((Get-Item $vcRedist).VersionInfo.ProductVersion) { $got = $true }
                        else { Write-Warning "Downloaded file has no ProductVersion; retrying." }
                    } catch {
                        Write-Warning "VCRedist fetch failed (attempt $i): $($_.Exception.Message)"
                    }
                    if (-not $got) { Start-Sleep -Seconds 5 }
                }
                if (-not $got) { throw "Could not obtain a valid vc_redist.$Arch.exe after 5 attempts." }
            }
            Write-Host "VCRedist staged: $((Get-Item $vcRedist).VersionInfo.ProductVersion)"

            # common.iss's [Languages] section also references some "unofficial"
            # Inno translations (Greek, and likely others) that ship in NO stock
            # Inno install of any version - they live in jrsoftware's separate
            # translations collection. Stage the full unofficial set into the
            # compiler's Languages folder so every "compiler:Languages\*.isl"
            # reference resolves. NB: this writes into the Inno install dir, so
            # it needs write access there - fine on the CI runner (admin); run
            # elevated locally, or vendor the .isl files in your fork instead.
            $innoLangs = Join-Path $env:INNOPATH 'Languages'
            if (Test-Path $innoLangs) {
                # Pin $issTag to the tag matching your Inno version to avoid
                # message-version mismatches (e.g. 'is-6_7_1'); 'main' = latest.
                $issTag = 'main'
                $apiUrl = "https://api.github.com/repos/jrsoftware/issrc/contents/Files/Languages/Unofficial?ref=$issTag"
                $unofficial = Invoke-RestMethod -Uri $apiUrl -Headers @{ 'User-Agent' = 'eo-build' }
                foreach ($f in ($unofficial | Where-Object { $_.name -like '*.isl' })) {
                    $dest = Join-Path $innoLangs $f.name
                    if (-not (Test-Path $dest)) {
                        Invoke-WebRequest -Uri $f.download_url -OutFile $dest
                        Write-Host "Staged unofficial language: $($f.name)"
                    }
                }
            }

            .\make_inno.ps1 -Version $VersionFull -Arch $Arch -Target $Target
            Assert-LastExit "make_inno.ps1"

            if ($BuildMsi) {
                Write-Step "11c. Build MSI (make_advinst.ps1)"
                $aiRoot = (Get-Item "${env:ProgramFiles(x86)}\Caphyon\Advanced Installer*").FullName
                $env:ADVINSTPATH = Join-Path $aiRoot 'bin\x86'
                .\make_advinst.ps1 -Version $VersionFull -Arch $Arch
                Assert-LastExit "make_advinst.ps1"
            }
        } finally { Pop-Location }

        Write-Step "DONE - artifacts:"
        Write-Host "  ZIP : $PackageDir\zip\*.zip"
        Write-Host "  EXE : $PackageDir\inno\*.exe"
        if ($BuildMsi) { Write-Host "  MSI : $PackageDir\advinst\*.msi" }
    }
}
finally {
    Close-StepGroup
    Pop-Location
}