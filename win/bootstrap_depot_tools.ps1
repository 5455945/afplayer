# ============================================================================
#  bootstrap_depot_tools.ps1
#  ---------------------------------------------------------------------------
#  Standalone bootstrap for:
#    * git (PortableGit on Windows, when git is not installed)
#    * depot_tools (clone / fetch a requested revision)
#    * depot_tools' Python/CIPD bootstrap (python3.bat)
#
#  It is designed to be used in two ways:
#
#  1) Standalone CLI:
#       .\bootstrap_depot_tools.bat --dir C:\test --version <commit>
#       .\bootstrap_depot_tools.ps1 --chromium-version 7871
#
#  2) Dot-sourced as a function library:
#       . .\bootstrap_depot_tools.ps1
#       $info = Initialize-DepotTools -Root C:\test -Version <commit>
#       $info.Git / $info.DepotTools / $info.Python3
#
#  Defaults:
#    * Root          = this script's directory
#    * DepotTools    = <Root>\depot_tools
#    * Version       = (none) -> use existing checkout as-is;
#                              if missing, clone latest main
#    * --chromium-version VER
#                    resolve the exact depot_tools commit from Chromium DEPS
#                    (src/third_party/depot_tools) and use that version.
#
#  Idempotency:
#    * git present              -> not downloaded
#    * depot_tools present and
#      requested version matches-> not fetched/checked out
#    * Python/CIPD already works-> bootstrap is not re-run
#
#  Examples:
#    .\bootstrap_depot_tools.bat --dir C:\test
#    .\bootstrap_depot_tools.bat --dir C:\test --version f4fadaf6a5ba1bced9d3d9021060667b563bf583
#    .\bootstrap_depot_tools.bat --dir C:\test --chromium-version 7871
#    .\bootstrap_depot_tools.bat --dir C:\test --chromium-version 131.0.6778.85
# ============================================================================

# NOTE: Keep all top-level code inside functions. This file is dot-sourced by
# chromium_build_win.ps1 and prepare_win_toolchain.ps1, so it must not overwrite
# caller variables.

function Write-BootStep { param([string]$Text, [bool]$Quiet = $false) if (-not $Quiet) { Write-Host "==> $Text" -ForegroundColor Cyan } }
function Write-BootOk   { param([string]$Text, [bool]$Quiet = $false) if (-not $Quiet) { Write-Host "    $Text" -ForegroundColor Green } }
function Write-BootWarn { param([string]$Text, [bool]$Quiet = $false) if (-not $Quiet) { Write-Host "    $Text" -ForegroundColor Yellow } }

function Invoke-BootNative {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory,
        [bool]$Suppress = $false
    )
    if ($WorkingDirectory) { Push-Location -LiteralPath $WorkingDirectory }
    $oldEap = $ErrorActionPreference
    if ($Suppress) { $ErrorActionPreference = 'Continue' }
    try {
        if ($Suppress) {
            & $FilePath @ArgumentList 2>&1 | Out-Null
        } else {
            & $FilePath @ArgumentList
        }
    } finally {
        $ErrorActionPreference = $oldEap
        if ($WorkingDirectory) { Pop-Location }
    }
    if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        throw "Command failed ($LASTEXITCODE): $FilePath $($ArgumentList -join ' ')"
    }
}

# ---------------------------------------------------------------------------
#  ConstrainedLanguage-safe helpers (shared with chromium_build_win.ps1 and
#  prepare_win_toolchain.ps1, which dot-source this file).
#
#  WDAC / AppLocker on a managed PC can force PowerShell into
#  ConstrainedLanguage, where scripts may only use "core" types: creating
#  [pscustomobject] values, New-Object on non-core types, and static method
#  calls such as [IO.File], [Convert], [Text.Encoding] or [Math] all throw
#  "... this language mode only supports core types". Everything below does
#  the same work with cmdlets only, so it behaves identically in
#  FullLanguage and ConstrainedLanguage.
# ---------------------------------------------------------------------------

# Windows PowerShell 5.1 spells binary file access -Encoding Byte,
# PowerShell 7+ spells it -AsByteStream.
function Read-FileBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Count = 0
    )
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        if ($Count -gt 0) { return @(Get-Content -LiteralPath $Path -AsByteStream -TotalCount $Count -ErrorAction Stop) }
        return @(Get-Content -LiteralPath $Path -AsByteStream -ErrorAction Stop)
    }
    if ($Count -gt 0) { return @(Get-Content -LiteralPath $Path -Encoding Byte -TotalCount $Count -ErrorAction Stop) }
    return @(Get-Content -LiteralPath $Path -Encoding Byte -ErrorAction Stop)
}

function Write-FileBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [byte[]]$Bytes = @()
    )
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        Set-Content -LiteralPath $Path -Value ([byte[]]$Bytes) -AsByteStream
    } else {
        Set-Content -LiteralPath $Path -Value ([byte[]]$Bytes) -Encoding Byte
    }
}

# Returns the raw UTF-8 bytes of $Text without a BOM (the exact bytes
# [Text.Encoding]::UTF8.GetBytes would return).
function Get-Utf8BytesNoBom {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $tmp = Join-Path $env:TEMP ('utf8_' + [guid]::NewGuid().ToString('N') + '.txt')
    try {
        # Set-Content -Encoding UTF8 prepends a BOM on Windows PowerShell 5.1
        # (PowerShell 7+ does not); strip it below when present.
        Set-Content -LiteralPath $tmp -Value $Text -Encoding UTF8 -NoNewline
        $bytes = [byte[]]@(Read-FileBytes -Path $tmp)
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
    $start = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $start = 3 }
    if ($start -ge $bytes.Length) { return [byte[]]@() }
    return [byte[]]$bytes[$start..($bytes.Length - 1)]
}

# Decodes UTF-8 bytes through Get-Content (which does the decoding) instead of
# the blocked [Text.Encoding]::UTF8.GetString.
function Get-TextFromUtf8Bytes {
    param([byte[]]$Bytes = @())
    $tmp = Join-Path $env:TEMP ('utf8_' + [guid]::NewGuid().ToString('N') + '.bin')
    try {
        Write-FileBytes -Path $tmp -Bytes $Bytes
        return (Get-Content -LiteralPath $tmp -Raw -Encoding UTF8)
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

# Gitiles returns "?format=TEXT" payloads as base64. [Convert]::FromBase64String
# and [Text.Encoding] are blocked in ConstrainedLanguage, so decode with
# certutil (ships with Windows) and let Get-Content do the UTF-8 decoding.
function ConvertFrom-GitilesBase64 {
    param([Parameter(Mandatory = $true)][string]$Base64)
    $dir = Join-Path $env:TEMP ('gitiles_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $inFile = Join-Path $dir 'payload.b64'
    $outFile = Join-Path $dir 'payload.bin'
    try {
        Set-Content -LiteralPath $inFile -Value ($Base64 -replace '\s', '') -Encoding ASCII
        $log = & certutil -decode -f $inFile $outFile 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $outFile)) {
            throw "certutil could not decode the base64 payload: $($log | Select-Object -Last 1)"
        }
        return (Get-Content -LiteralPath $outFile -Raw -Encoding UTF8)
    } finally {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# [Math]::Min is blocked in ConstrainedLanguage.
function Get-CommitShortName {
    param([string]$Commit, [int]$Length = 12)
    if (-not $Commit) { return '' }
    if ($Commit.Length -le $Length) { return $Commit }
    return $Commit.Substring(0, $Length)
}

function Get-BootRemoteFile {
    param([Parameter(Mandatory = $true)][string]$Uri, [Parameter(Mandatory = $true)][string]$OutFile)
    $old = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $OutFile -TimeoutSec 1800
    } finally {
        $ProgressPreference = $old
    }
}

function Test-BootPeFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if ((Get-Item -LiteralPath $Path).Length -lt 1MB) { return $false }
    # 'MZ' magic: read the first two bytes through the cmdlet (the script may
    # run in ConstrainedLanguage, where System.IO.File is not usable).
    $head = @(Read-FileBytes -Path $Path -Count 2)
    if ($head.Count -lt 2) { return $false }
    return ($head[0] -eq 0x4D -and $head[1] -eq 0x5A)
}

# ---------------------------------------------------------------------------
#  git
# ---------------------------------------------------------------------------
function Ensure-BootGit {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [bool]$BootstrapGit = $true,
        [bool]$Quiet = $false
    )
    $existing = Get-Command git -ErrorAction SilentlyContinue
    if ($existing) {
        Write-BootOk "Using git: $($existing.Source)" $Quiet
        return $existing.Source
    }

    if (-not $BootstrapGit) {
        throw 'git was not found. Install Git for Windows or omit --no-bootstrap-git.'
    }

    $toolsDir = Join-Path $Root 'tools'
    $gitDir = Join-Path $toolsDir 'git'
    $gitExe = Join-Path $gitDir 'cmd\git.exe'
    if (Test-Path -LiteralPath $gitExe) {
        $env:PATH = "$(Join-Path $gitDir 'cmd');$(Join-Path $gitDir 'bin');$env:PATH"
        Write-BootOk "Using portable git: $gitExe" $Quiet
        return $gitExe
    }

    Write-BootStep 'git not found - downloading PortableGit' $Quiet
    New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null
    $rel = Invoke-RestMethod -UseBasicParsing -TimeoutSec 60 `
        -Headers @{ 'User-Agent' = 'bootstrap-depot-tools' } `
        -Uri 'https://api.github.com/repos/git-for-windows/git/releases/latest'
    $asset = @($rel.assets | Where-Object { $_.name -match '^PortableGit-.*-64-bit\.7z\.exe$' })[0]
    if ($null -eq $asset) { throw 'Could not find a PortableGit 64-bit asset on GitHub.' }

    $dl = Join-Path $toolsDir $asset.name
    if (-not (Test-Path -LiteralPath $dl)) {
        Get-BootRemoteFile -Uri $asset.browser_download_url -OutFile $dl
    }
    if (-not (Test-BootPeFile -Path $dl)) {
        throw "Downloaded PortableGit is not a PE executable: $dl"
    }

    Write-BootStep "Extracting PortableGit into $gitDir" $Quiet
    & $dl "-o$gitDir" -y | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to extract PortableGit (exit $LASTEXITCODE)." }
    if (-not (Test-Path -LiteralPath $gitExe)) { throw "PortableGit extraction incomplete: $gitExe not found." }

    $env:PATH = "$(Join-Path $gitDir 'cmd');$(Join-Path $gitDir 'bin');$env:PATH"
    Write-BootOk "Using portable git: $gitExe" $Quiet
    return $gitExe
}

# ---------------------------------------------------------------------------
#  Chromium DEPS -> depot_tools commit
# ---------------------------------------------------------------------------
function Get-BootGitilesText {
    param([string]$Repo, [string]$Ref, [string]$Path)
    $uri = 'https://chromium.googlesource.com/' + $Repo + '/+/' + $Ref + '/' + $Path + '?format=TEXT'
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Uri $uri -TimeoutSec 120
        return (ConvertFrom-GitilesBase64 -Base64 ([string]$r.Content))
    } catch {
        $code = $null
        try { $code = [int]$_.Exception.Response.StatusCode } catch { $code = $null }
        if ($code -eq 404) { throw "Chromium path '$Path' not found at '$Ref'." }
        throw "Could not fetch '$uri': $($_.Exception.Message)"
    }
}

function Resolve-BootChromiumRef {
    param([Parameter(Mandatory = $true)][string]$Requested)
    $r = $Requested.Trim()
    if ($r -eq '' -or $r -match '^(stable|latest|release)$') {
        $uri = 'https://chromiumdash.appspot.com/fetch_releases?channel=Stable&platform=Windows&num=5'
        $rel = Invoke-RestMethod -UseBasicParsing -Uri $uri -TimeoutSec 60
        $first = @($rel)[0]
        $tag = [string]$first.version
        if (-not $tag) { throw 'Chromium Dash returned no stable Windows release.' }
        return [ordered]@{ Ref = "refs/tags/$($tag.Trim())"; Display = $tag.Trim() }
    }
    if ($r -match '^\d+\.\d+\.\d+\.\d+$') { return [ordered]@{ Ref = "refs/tags/$r"; Display = $r } }
    if ($r -match '^\d+$') { return [ordered]@{ Ref = "refs/branch-heads/$r"; Display = $r } }
    if ($r -match '^branch-heads/') { return [ordered]@{ Ref = "refs/$r"; Display = $r } }
    if ($r -match '^refs/') { return [ordered]@{ Ref = $r; Display = $r } }
    if ($r -match '^[A-Za-z0-9._/-]+$') { return [ordered]@{ Ref = "refs/heads/$r"; Display = $r } }
    throw "Unrecognized Chromium version/ref: $Requested"
}

function Get-BootDepotToolsPin {
    param([Parameter(Mandatory = $true)][string]$ChromiumVersion)
    $resolved = Resolve-BootChromiumRef -Requested $ChromiumVersion
    $uri = 'https://chromium.googlesource.com/chromium/src/+/' + $resolved.Ref + '/DEPS'
    $html = (Invoke-WebRequest -UseBasicParsing -Uri $uri -TimeoutSec 120).Content
    $m = [regex]::Match($html,
        'src/third_party/depot_tools.{0,4000}?depot_tools\.git.{0,1200}?([0-9a-f]{40})',
        [Text.RegularExpressions.RegexOptions]::Singleline)
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

# ---------------------------------------------------------------------------
#  depot_tools
# ---------------------------------------------------------------------------
function Ensure-BootDepotTools {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string]$DepotTools = '',
        [string]$Version = '',
        [bool]$Force = $false,
        [bool]$Quiet = $false
    )
    $gitRepo = 'https://chromium.googlesource.com/chromium/tools/depot_tools.git'
    $dt = if ($DepotTools) { $DepotTools.TrimEnd('\', '/') } else { Join-Path $Root 'depot_tools' }
    $changed = $false
    $isRepo = Test-Path -LiteralPath (Join-Path $dt '.git')

    # An exported offline repo ships depot_tools WITHOUT .git: git cannot store a
    # nested repository without turning it into a submodule (which would leave
    # the files out of the commit). Accept such a "materialized snapshot" when
    # it looks like a usable depot_tools tree, and never try to git-update it.
    $isMaterialized = $false
    if (-not $isRepo -and (Test-Path -LiteralPath $dt)) {
        $isMaterialized =
            (Test-Path -LiteralPath (Join-Path $dt 'gclient.py')) -and
            ((Test-Path -LiteralPath (Join-Path $dt 'python3.bat')) -or
             (Test-Path -LiteralPath (Join-Path $dt 'gn.bat')) -or
             (Test-Path -LiteralPath (Join-Path $dt 'autoninja.bat')))
    }

    if (-not $isRepo -and -not $isMaterialized) {
        if (Test-Path -LiteralPath $dt) {
            throw "depot_tools path exists but is neither a git checkout nor a usable snapshot: $dt"
        }
        Write-BootStep "Cloning depot_tools into $dt" $Quiet
        Invoke-BootNative -FilePath 'git' -ArgumentList @('clone', '--depth', '1', $gitRepo, $dt) -Suppress $true | Out-Null
        $changed = $true
        $isRepo = $true
    }

    if ($isMaterialized) {
        Write-BootWarn 'depot_tools is a materialized snapshot (no .git); skipping fetch/checkout/verification.' $Quiet
        $env:DEPOT_TOOLS_UPDATE = '0'
        Write-BootOk 'DEPOT_TOOLS_UPDATE=0' $Quiet
        return [ordered]@{
            Path = $dt
            Changed = $false
            Current = $null
            Materialized = $true
        }
    }

    if ($Version) {
        if (-not $isRepo) { throw "Not a git checkout: $dt" }
        $current = ((& git -C $dt rev-parse HEAD 2>$null) | Out-String).Trim()
        $prefixMatch = ($Version.Length -ge 7 -and $current.StartsWith($Version))
        $needCheckout = $Force -or (-not ($current -eq $Version -or $prefixMatch))
        if ($needCheckout) {
            Write-BootStep "Fetching depot_tools $Version" $Quiet
            Invoke-BootNative -FilePath 'git' -ArgumentList @('-C', $dt, 'fetch', '--depth', '1', 'origin', $Version) -Suppress $true | Out-Null
            Invoke-BootNative -FilePath 'git' -ArgumentList @('-C', $dt, 'checkout', '--detach', 'FETCH_HEAD') -Suppress $true | Out-Null
            $changed = $true
        } else {
            Write-BootOk "depot_tools already at $Version" $Quiet
        }
    } else {
        if ($changed) {
            Write-BootOk "depot_tools cloned at latest main" $Quiet
        } else {
            Write-BootOk "Using existing depot_tools: $dt" $Quiet
        }
    }

    $current = $null
    try { $current = ((& git -C $dt rev-parse HEAD 2>$null) | Out-String).Trim() } catch { $current = $null }

    if ($Version) {
        # For commit pins, verify the checkout really landed on the requested
        # revision before disabling self-update.
        if ($Version -match '^[0-9a-fA-F]{7,40}$') {
            $okPin = ($current -eq $Version) -or ($current -and $current.StartsWith($Version))
            if (-not $okPin) {
                throw "depot_tools checkout mismatch: requested $Version, current $current"
            }
        }
        # Only after the checkout is verified: prevent auto-update.
        $env:DEPOT_TOOLS_UPDATE = '0'
        Write-BootOk 'DEPOT_TOOLS_UPDATE=0' $Quiet
    }

    # A plain hashtable, not [pscustomobject]: PSCustomObject creation is a
    # non-core type conversion and throws in ConstrainedLanguage mode.
    return [ordered]@{
        Path = $dt
        Changed = $changed
        Current = $current
    }
}

function Test-BootPython {
    param([string]$PythonBat)
    if (-not $PythonBat -or -not (Test-Path -LiteralPath $PythonBat)) { return $false }
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $PythonBat -c "import sys; sys.exit(0)" 1>$null 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    } finally {
        $ErrorActionPreference = $oldEap
    }
}

function Ensure-BootPython {
    param(
        [Parameter(Mandatory = $true)][string]$DepotTools,
        [bool]$Quiet = $false
    )
    $python = Join-Path $DepotTools 'python3.bat'
    if (Test-BootPython -PythonBat $python) {
        Write-BootOk 'depot_tools Python is ready.' $Quiet
        return $python
    }

    Write-BootStep 'Bootstrapping depot_tools Python/CIPD' $Quiet
    $winTools = Join-Path $DepotTools 'bootstrap\win_tools.bat'
    if (Test-Path -LiteralPath $winTools) {
        Invoke-BootNative -FilePath $winTools -Suppress $true | Out-Null
    } else {
        $gclient = Join-Path $DepotTools 'gclient.bat'
        if (-not (Test-Path -LiteralPath $gclient)) {
            throw "Cannot bootstrap Python: neither $winTools nor $gclient exists."
        }
        Invoke-BootNative -FilePath $gclient -Suppress $true | Out-Null
    }

    if (-not (Test-BootPython -PythonBat $python)) {
        throw "depot_tools Python bootstrap failed: $python is not usable."
    }
    Write-BootOk 'depot_tools Python is ready.' $Quiet
    return $python
}

# ---------------------------------------------------------------------------
#  Public entry point
# ---------------------------------------------------------------------------
function Initialize-DepotTools {
    param(
        [string]$Root = '',
        [string]$DepotTools = '',
        [string]$Version = '',
        [string]$ChromiumVersion = '',
        [bool]$BootstrapGit = $true,
        [bool]$Force = $false,
        [bool]$Quiet = $false
    )
    if (-not $Root) { $Root = $PSScriptRoot }
    $Root = $Root.TrimEnd('\', '/')
    New-Item -ItemType Directory -Force -Path $Root | Out-Null

    $git = Ensure-BootGit -Root $Root -BootstrapGit $BootstrapGit -Quiet $Quiet

    # Offline repo: depot_tools is a materialized snapshot with no .git. Do not
    # hit the network to resolve the pin: the snapshot already matches whatever
    # Chromium revision it shipped with (see init_tools\<MAJOR>\config\manifest).
    $dtPath = if ($DepotTools) { $DepotTools.TrimEnd('\', '/') } else { Join-Path $Root 'depot_tools' }
    $offlineDt = (Test-Path -LiteralPath $dtPath) -and
                 -not (Test-Path -LiteralPath (Join-Path $dtPath '.git')) -and
                 (Test-Path -LiteralPath (Join-Path $dtPath 'gclient.py'))

    if (-not $Version -and $ChromiumVersion) {
        if ($offlineDt) {
            Write-BootWarn "Offline depot_tools snapshot: skipping remote pin resolution for $ChromiumVersion." $Quiet
        } else {
            Write-BootStep "Resolving depot_tools pin for Chromium $ChromiumVersion" $Quiet
            $pin = Get-BootDepotToolsPin -ChromiumVersion $ChromiumVersion
            if (-not $pin) {
                throw "Could not find src/third_party/depot_tools in DEPS for Chromium $ChromiumVersion."
            }
            $Version = $pin
            Write-BootOk "depot_tools pin: $Version" $Quiet
        }
    }

    $dtInfo = Ensure-BootDepotTools -Root $Root -DepotTools $DepotTools -Version $Version -Force $Force -Quiet $Quiet
    $dt = $dtInfo.Path

    $env:PATH = "$dt;$env:PATH"

    # Same global git settings as the main build script.
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & git config --global core.autocrlf false
        & git config --global core.filemode false
        & git config --global core.longpaths true
        & git config --global core.fscache true
        & git config --global core.preloadindex true
    } catch {
        Write-BootWarn "Could not apply global git config: $($_.Exception.Message)" $Quiet
    } finally {
        $ErrorActionPreference = $oldEap
    }

    $python = Ensure-BootPython -DepotTools $dt -Quiet $Quiet

    # A plain hashtable, not [pscustomobject]: see Ensure-BootDepotTools.
    return [ordered]@{
        Root = $Root
        Git = $git
        DepotTools = $dt
        Python3 = $python
        Version = $Version
        Current = $dtInfo.Current
        Changed = $dtInfo.Changed
    }
}

function Show-BootHelp {
    Write-Host @'
Usage: bootstrap_depot_tools.ps1 [options]

Ensures git (PortableGit if missing), depot_tools and depot_tools' Python/CIPD
are available. Safe to run repeatedly: existing matching pieces are skipped.

Options:
  --dir DIR              Root directory. Default: this script's directory.
  --depot-tools DIR      depot_tools path. Default: <dir>\depot_tools.
  --version VER          depot_tools revision to ensure (commit/tag/branch).
                         If omitted, an existing checkout is left as-is; a
                         missing checkout is cloned at latest main.
  --chromium-version VER Resolve the exact depot_tools commit from Chromium's
                         DEPS (src/third_party/depot_tools). Overrides --version
                         unless --version is also given.
                         7871 / 150.0.7871.289 / main / stable are accepted.
  --no-bootstrap-git     Never auto-download PortableGit.
  --force                Re-run fetch/checkout and Python bootstrap even when
                         the current state looks valid.
  --quiet                Suppress progress output.
  -h, --help             Show this help.

Examples:
  .\bootstrap_depot_tools.ps1 --dir C:\test
  .\bootstrap_depot_tools.ps1 --dir C:\test --version f4fadaf6a5ba1bced9d3d9021060667b563bf583
  .\bootstrap_depot_tools.ps1 --dir C:\test --chromium-version 7871
  .\bootstrap_depot_tools.ps1 --dir C:\test --chromium-version 131.0.6778.85

Dot-sourced use:
  . .\bootstrap_depot_tools.ps1
  $info = Initialize-DepotTools -Root C:\test -ChromiumVersion 7871
  $info.Git
  $info.DepotTools
  $info.Python3
'@
}

function Invoke-BootstrapCli {
    param([string[]]$Arguments = @())
    $Root = ''
    $DepotTools = ''
    $Version = ''
    $ChromiumVersion = ''
    $BootstrapGit = $true
    $Force = $false
    $Quiet = $false
    $Help = $false

    $i = 0
    while ($i -lt $Arguments.Count) {
        $raw = [string]$Arguments[$i]
        $opt = $raw
        $inline = $null
        if ($raw -match '^(--?[^=]+)=(.*)$') { $opt = $matches[1]; $inline = $matches[2] }
        switch ($opt) {
            '--help' { $Help = $true }
            '-h'     { $Help = $true }
            '/?'     { $Help = $true }
            '--no-bootstrap-git' { $BootstrapGit = $false }
            '--force' { $Force = $true }
            '--quiet' { $Quiet = $true }
            default {
                $valueOptions = @('--dir', '--depot-tools', '--version', '--chromium-version')
                if ($valueOptions -contains $opt) {
                    $v = $inline
                    if ($null -eq $v) {
                        $i++
                        if ($i -ge $Arguments.Count) { throw "Option $opt requires a value." }
                        $v = [string]$Arguments[$i]
                    }
                    switch ($opt) {
                        '--dir' { $Root = $v }
                        '--depot-tools' { $DepotTools = $v }
                        '--version' { $Version = $v }
                        '--chromium-version' { $ChromiumVersion = $v }
                    }
                } else {
                    Write-Warning "Unknown option: $raw"
                }
            }
        }
        $i++
    }

    if ($Help) { Show-BootHelp; return 0 }

    $info = Initialize-DepotTools -Root $Root -DepotTools $DepotTools `
        -Version $Version -ChromiumVersion $ChromiumVersion `
        -BootstrapGit $BootstrapGit -Force $Force -Quiet $Quiet

    if (-not $Quiet) {
        Write-Host ''
        Write-Host 'Bootstrap complete:'
    }
    Write-Host "GIT_PATH=$($info.Git)"
    Write-Host "DEPOT_TOOLS_PATH=$($info.DepotTools)"
    Write-Host "PYTHON3_PATH=$($info.Python3)"
    Write-Host "DEPOT_TOOLS_VERSION=$($info.Current)"
    Write-Host "CHANGED=$($info.Changed)"
    return 0
}

# Only execute the CLI when run directly (not when dot-sourced).
if ($MyInvocation.InvocationName -ne '.') {
    try {
        $code = Invoke-BootstrapCli -Arguments @($args)
        exit $code
    } catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}
