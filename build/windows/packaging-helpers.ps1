#Requires -Version 5.1
<#
.SYNOPSIS
    Helpers shared by build.ps1 (CI build) and sign-package.ps1 (signing
    server). Dot-source it:  . (Join-Path $PSScriptRoot 'packaging-helpers.ps1')
#>

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

# Windows' own bsdtar. Always by full path: on the build PATH, Cygwin's GNU tar
# comes first (and Git's can shadow it elsewhere), and GNU tar parses "D:\..."
# as a remote host:path archive ("Cannot connect to D: resolve failed").
function Get-WindowsTar {
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (-not (Test-Path $tar)) { throw "$tar not found (ships with Windows 10 1803+)." }
    return $tar
}

# Locate the Inno Setup program directory (the folder with iscc.exe and its
# Languages\ subfolder). Prefer a real install (it carries the compiler support
# files) over a Chocolatey shim, then any iscc.exe on PATH, then -InnoRoot.
# Returns $null if none found. Used by both the dependency install (to stage
# language files) and the packaging step (to set INNOPATH).
function Get-InnoRoot([string]$Fallback) {
    $isccItem = Get-ChildItem 'C:\Program Files (x86)\Inno Setup*','C:\Program Files\Inno Setup*' `
                    -Recurse -Filter iscc.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($isccItem) { return Split-Path $isccItem.FullName }
    $iscc = Get-Command iscc.exe -ErrorAction SilentlyContinue
    if ($iscc) { return Split-Path $iscc.Source }
    if ($Fallback -and (Test-Path (Join-Path $Fallback 'iscc.exe'))) { return $Fallback }
    return $null
}

# Stage jrsoftware's "unofficial" Inno translations (Greek, etc.) that
# common.iss references but that ship in NO stock Inno install - they live in a
# separate translations collection. This is a PACKAGING INPUT (like the
# vc_redist pre-stage), not a heavy tool install, so it must run on every
# packaging build regardless of -InstallDeps - which is why it's called from the
# packaging step, not gated behind -InstallDeps (CI doesn't pass that). It's
# idempotent (skips files already present). It writes into the Inno install's
# Languages dir, so it needs write access there: fine on CI (admin); a plain
# local packaging run may need elevation.
function Sync-InnoLanguages([string]$LanguagesDir) {
    if (-not (Test-Path $LanguagesDir)) {
        Write-Warning "Inno Languages dir not found ($LanguagesDir) - skipping unofficial language staging."
        return
    }
    # Pin $issTag to the tag matching your Inno version to avoid message-version
    # mismatches (e.g. 'is-6_7_1'); 'main' = latest.
    $issTag  = 'is-6_7_1'
    $apiUrl  = "https://api.github.com/repos/jrsoftware/issrc/contents/Files/Languages/Unofficial?ref=$issTag"
    $headers = @{ 'User-Agent' = 'eo-build' }
    # Authenticate the API call when a token is available (CI, or the signing
    # server's gh token) so the single contents listing doesn't trip the 60/hr
    # anonymous limit on shared IPs.
    $token = if ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } else { $env:GH_TOKEN }
    if ($token) { $headers['Authorization'] = "Bearer $token" }
    $unofficial = Invoke-RestMethod -Uri $apiUrl -Headers $headers
    foreach ($f in ($unofficial | Where-Object { $_.name -match '\.islu?$' })) {
        $langDest = Join-Path $LanguagesDir $f.name
        if (-not (Test-Path $langDest)) {
            Invoke-WebRequest -Uri $f.download_url -OutFile $langDest
            Write-Host "Staged unofficial language: $($f.name)"
        }
    }
}

# make_inno.ps1 bundles the VC++ redistributable, fetching it at package time
# via WebClient from aka.ms (which failed on the runner). It SKIPS that
# download when inno\vc_redist.<arch>.exe already exists with a valid
# ProductVersion, so pre-stage it here with a modern, redirect-following,
# retrying fetch and let make_inno reuse it.
function Save-VcRedist([string]$PackageDir, [string]$Arch) {
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
}
