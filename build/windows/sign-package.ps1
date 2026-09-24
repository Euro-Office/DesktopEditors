#Requires -Version 5.1
<#
.SYNOPSIS
    Sign and package Windows builds on the signing server.

.DESCRIPTION
    The build-windows CI job compiles the app on GitHub, but the code-signing
    certificate lives on a separate signing server. Because the installer must
    contain already-signed binaries (and is signed itself), everything from
    make.ps1 onward runs here instead:

      1. download the "windows-signing-bundle-<brand>-<arch>" artifacts of a
         workflow run (gh CLI), or take local bundle tars (-BundlePath)
      2. make.ps1 -Sign      stage the install tree, sign every exe/dll,
                             regenerate the VLC plugin cache
      3. make_zip.ps1        portable ZIP from the signed tree
      4. make_inno.ps1 -Sign Inno installer; iscc signs setup + uninstaller
      5. verify the signatures and copy ZIP + EXE to -OutDir\<Company>-<arch>\
         (+ OutDir\SHA256SUMS.txt)

    The packaging scripts come from each bundle (so they match the build);
    only this script and packaging-helpers.ps1 are needed from the repo, so a
    checkout without submodules is enough.

    Requirements on the server: Windows 10+ (for tar.exe), signtool (Windows
    SDK), Inno Setup 6, 7-Zip, and - unless -BundlePath is used - the GitHub
    CLI authenticated with read access to the repo's Actions artifacts
    (GH_TOKEN or `gh auth login`).

.PARAMETER RunId
    Workflow run to take the bundles from.

.PARAMETER Tag
    Use the latest completed run of -Workflow for this tag (e.g. v9.3.1-stable.1)
    instead of -RunId.

.PARAMETER Brand
    Brand matrix name to process. Wildcards allowed. CI only produces bundles
    for brands with `sign: true` (nextcloud-office); euro-office is released
    unsigned straight from CI.

.PARAMETER Arch
    Arch matrix name to process (amd64, arm64). Wildcards allowed; default all.

.PARAMETER BundlePath
    Local bundle tar(s), or folders searched for *.tar, instead of downloading.

.PARAMETER CertThumbprint
    SHA-1 thumbprint of the signing certificate in the certificate store
    (signtool /sha1). Preferred over -CertName when both are given.

.PARAMETER CertName
    Subject name of the signing certificate (signtool /n). With neither this
    nor -CertThumbprint, signtool picks the best available certificate (/a).

.PARAMETER SignArgs
    Full signtool argument list (everything between "signtool sign" and the
    file), replacing the one built from -CertThumbprint/-CertName/
    -TimestampServer. Use it for e.g. Azure Trusted Signing (/dlib ... /dmdf ...).

.PARAMETER WorkDir
    Scratch folder for extracted bundles. Keep the path short: the editors tree
    is deeply nested and staging copies it once more.

.EXAMPLE
    # Nextcloud Office builds of the latest run for a release tag, cert by thumbprint:
    $env:GH_TOKEN = '<token with actions:read>'
    .\build\windows\sign-package.ps1 -Tag v9.3.1-stable.1 -CertThumbprint 0123...CDEF

.EXAMPLE
    # Only the x64 build of a specific run:
    .\build\windows\sign-package.ps1 -RunId 1234567890 -Arch amd64 -CertName "Nextcloud GmbH"

.EXAMPLE
    # Bundle copied over by hand:
    .\build\windows\sign-package.ps1 -BundlePath D:\incoming\windows-signing-bundle.tar -CertThumbprint 0123...CDEF
#>
[CmdletBinding()]
param(
    [string]$Repo            = 'Euro-Office/DesktopEditors',
    [string]$Workflow        = 'build.yml',
    [string]$RunId           = '',
    [string]$Tag             = '',
    [string]$Brand           = 'nextcloud-office',
    [string]$Arch            = '*',
    [string[]]$BundlePath    = @(),

    [string]$CertThumbprint  = '',
    [string]$CertName        = '',
    [string]$TimestampServer = 'http://timestamp.digicert.com',
    [string[]]$SignArgs      = @(),

    [string]$WorkDir         = "$env:SystemDrive\eo-sign",
    [string]$OutDir          = (Join-Path (Get-Location) 'signed'),
    [string]$InnoRoot        = "${env:ProgramFiles(x86)}\Inno Setup 6",
    [string]$SevenZipRoot    = 'C:\Program Files\7-Zip',
    [switch]$KeepWorkDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # speeds up Invoke-WebRequest

. (Join-Path $PSScriptRoot 'packaging-helpers.ps1')

# The packaging scripts change directory; pin these before they do.
$WorkDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($WorkDir)
$OutDir  = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutDir)

# signtool ships in the Windows SDK but is rarely on PATH. Its directory has to
# go on PATH (not just be called by full path): make.ps1 and iscc's SignTool
# both invoke plain "signtool".
function Find-SignToolDir {
    $cmd = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if ($cmd) { return Split-Path $cmd.Source }
    $hostArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    $exe = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Directory -Filter '10.*' -ErrorAction SilentlyContinue |
           Sort-Object { [version]$_.Name } -Descending |
           ForEach-Object { Join-Path $_.FullName "$hostArch\signtool.exe" } |
           Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $exe) { throw "signtool.exe not found - install the Windows SDK signing tools." }
    return Split-Path $exe
}

# Fail on anything that isn't validly signed. Get-AuthenticodeSignature also
# checks the chain, so an untrusted/test certificate fails here too.
function Assert-Signed([System.IO.FileInfo[]]$Files) {
    if (-not $Files) { throw "Assert-Signed: no files to check." }
    $bad = @($Files | Get-AuthenticodeSignature | Where-Object { $_.Status -ne 'Valid' })
    if ($bad) {
        $bad | ForEach-Object { Write-Host ("{0,-14} {1}" -f $_.Status, $_.Path) }
        throw "$($bad.Count) of $($Files.Count) file(s) are not validly signed."
    }
    Write-Host "Signature OK on $($Files.Count) file(s)."
}

try {
    # ─────────────────────────────── 0. tools ───────────────────────────────
    Write-Step "0. Locating tools"
    $env:PATH = "$(Find-SignToolDir);$SevenZipRoot;$env:PATH"
    Write-Host "signtool -> $((Get-Command signtool.exe).Source)"
    if (-not (Get-Command 7z -ErrorAction SilentlyContinue)) { throw "7z not found (looked on PATH and in $SevenZipRoot)." }
    $env:INNOPATH = Get-InnoRoot $InnoRoot
    if (-not $env:INNOPATH) { throw "Inno Setup (iscc.exe) not found. Install Inno Setup 6 or pass -InnoRoot." }
    Write-Host "INNOPATH=$env:INNOPATH"
    $tar = Get-WindowsTar

    if (-not $SignArgs) {
        $SignArgs = @('/fd', 'sha256')
        if ($CertThumbprint)  { $SignArgs += '/sha1', ($CertThumbprint -replace '\s', '') }
        elseif ($CertName)    { $SignArgs += '/n', $CertName }
        else                  { $SignArgs += '/a' }
        $SignArgs += '/tr', $TimestampServer, '/td', 'sha256'
    }
    Write-Host "signtool sign $SignArgs <file>"

    # ───────────────────────────── 1. bundles ───────────────────────────────
    Write-Step "1. Getting signing bundles"
    New-Item -ItemType Directory -Force -Path $WorkDir, $OutDir | Out-Null

    if ($BundlePath) {
        $bundles = @($BundlePath | ForEach-Object {
            if (Test-Path $_ -PathType Container) { Get-ChildItem $_ -Recurse -Filter '*.tar' }
            else { Get-Item $_ }
        })
    } else {
        if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw "GitHub CLI (gh) not found; install it or pass -BundlePath." }
        if (-not $RunId) {
            if (-not $Tag) { throw "Pass -RunId, -Tag or -BundlePath." }
            $RunId = gh run list -R $Repo -w $Workflow -b $Tag -e push --status completed `
                        --limit 1 --json databaseId -q '.[0].databaseId'
            Assert-LastExit "gh run list"
            if (-not $RunId) { throw "No completed '$Workflow' run found for tag '$Tag' in $Repo." }
        }
        Write-Host "Run: https://github.com/$Repo/actions/runs/$RunId"

        $dl = Join-Path $WorkDir 'download'
        if (Test-Path $dl) { Remove-Item -Recurse -Force $dl }
        # With --pattern, gh puts every artifact in its own <artifact-name>\ folder.
        gh run download $RunId -R $Repo -p "windows-signing-bundle-$Brand-$Arch" -D $dl
        Assert-LastExit "gh run download"
        $bundles = @(Get-ChildItem $dl -Recurse -Filter '*.tar')
    }
    if (-not $bundles) { throw "No signing bundles found." }
    $bundles | ForEach-Object { Write-Host ("{0} ({1:N0} MB)" -f $_.FullName, ($_.Length / 1MB)) }

    # ────────────────────── 2-5. per bundle: sign + package ─────────────────
    $outputs = @()
    $n = 0
    foreach ($bundle in $bundles) {
        $n++
        $dir = Join-Path $WorkDir "b$n"
        if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
        New-Item -ItemType Directory -Force -Path $dir | Out-Null

        Write-Step "[$n/$($bundles.Count)] Extracting $($bundle.FullName)"
        & $tar -xf $bundle.FullName -C $dir
        Assert-LastExit "tar extract"
        $m = Get-Content -Raw (Join-Path $dir 'signing-bundle.json') | ConvertFrom-Json
        $m | Format-List | Out-String | Write-Host

        $pkg = Join-Path $dir 'desktop-apps\package'
        Push-Location $pkg
        try {
            Save-VcRedist $pkg $m.Arch   # no-op when the bundle carries it

            Write-Step "[$n] Stage + sign binaries (make.ps1 -Sign)"
            .\make.ps1 `
                -Version     $m.Version `
                -Arch        $m.Arch `
                -Target      $m.Target `
                -CompanyName $m.CompanyName `
                -ProductName $m.ProductName `
                -SourceDir   (Join-Path $dir 'desktopeditors') `
                -Sign -SignArgs $SignArgs
            Assert-LastExit "make.ps1"
            Assert-Signed (Get-ChildItem "build\$($m.Arch)\desktop" -Recurse -Include *.exe, *.dll)

            Write-Step "[$n] Build ZIP (make_zip.ps1)"
            # Same arguments as build.ps1 passes, so the signed packages are
            # byte-for-byte the CI ones apart from the signatures.
            .\make_zip.ps1 -Version $m.Version -Arch $m.Arch -Target $m.Target
            Assert-LastExit "make_zip.ps1"

            Write-Step "[$n] Build + sign Inno installer (make_inno.ps1 -Sign)"
            Sync-InnoLanguages (Join-Path $env:INNOPATH 'Languages')
            .\make_inno.ps1 -Version $m.Version -Arch $m.Arch -Target $m.Target `
                -Sign -SignArgs $SignArgs
            Assert-LastExit "make_inno.ps1"

            $installers = @(Get-ChildItem 'inno\*.exe' | Where-Object { $_.Name -notlike 'vc_redist.*' })
            Assert-Signed $installers

            # One folder per bundle: the file names don't carry the brand.
            $dest = Join-Path $OutDir (("{0}-{1}" -f $m.CompanyName, $m.Arch) -replace '[^\w.-]', '-')
            New-Item -ItemType Directory -Force -Path $dest | Out-Null
            foreach ($f in @(Get-ChildItem 'zip\*.zip') + $installers) {
                Copy-Item $f.FullName $dest -Force
                $outputs += Get-Item (Join-Path $dest $f.Name)
            }
        } finally { Pop-Location }

        if (-not $KeepWorkDir) { Remove-Item -Recurse -Force $dir }
    }

    Write-Step "DONE - signed artifacts in $OutDir"
    $sums = $outputs | ForEach-Object {
        "{0}  {1}/{2}" -f (Get-FileHash -Algorithm SHA256 $_.FullName).Hash.ToLower(), $_.Directory.Name, $_.Name
    }
    Set-Content -Encoding ASCII (Join-Path $OutDir 'SHA256SUMS.txt') $sums
    $sums | ForEach-Object { Write-Host "  $_" }
}
finally {
    Close-StepGroup
}
