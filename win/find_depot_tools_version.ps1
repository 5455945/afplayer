# ============================================================================
#  find_depot_tools_version.ps1
#  ---------------------------------------------------------------------------
#  Find the depot_tools commit that was current when a given Chromium version
#  was released, so you can (optionally) pin depot_tools to that revision.
#
#  How the mapping is derived
#    Chromium's DEPS pins src/third_party/depot_tools to an exact commit. That
#    is the authoritative mapping. prepare_win_toolchain.ps1 --show-deps prints
#    it, and --pin-depot-tools fetches the era-matched packager files directly.
#
#    This script is the DATE-BASED FALLBACK for cases where the DEPS pin is not
#    available (very old revisions) or when you want a full depot_tools
#    checkout:
#      1. Resolve the Chromium version (tag / branch / milestone) to its commit
#         and commit date via gitiles / Chromium Dash.
#      2. Walk depot_tools' main-branch history (via the gitiles log API) and
#         pick the most recent depot_tools commit at or before that date.
#
#  Do you actually NEED to switch depot_tools?
#    For BUILDING with gclient, usually NO: the Windows toolchain is chosen
#    from the Chromium revision itself.
#    For PACKAGING a win_toolchain archive, the era matters: the packager
#    (package_from_installed.py) supports one VS major per depot_tools version.
#    Prefer: prepare_win_toolchain.ps1 --chromium-version <v> --show-deps
#    and --pin-depot-tools, which use the exact DEPS pin without a full clone.
#    If you do pin a full checkout, set DEPOT_TOOLS_UPDATE=0 so depot_tools
#    does not auto-update itself back to the tip.
#
#  Examples
#    .\find_depot_tools_version.ps1 --version 131.0.6778.85
#    .\find_depot_tools_version.ps1 --version 7871
#    .\find_depot_tools_version.ps1 --milestone 131
#    .\find_depot_tools_version.ps1 --date 2024-11-18
#    .\find_depot_tools_version.ps1 --version 131.0.6778.85 --checkout --depot-tools .\depot_tools
# ============================================================================

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
#  Defaults
# ---------------------------------------------------------------------------
$VersionReq  = ''
$MilestoneReq = ''
$DateReq     = ''
$HashReq     = ''
$PageSize    = 1000
$MaxPages    = 300
$DepotTools  = (Join-Path $PSScriptRoot 'depot_tools')
$DoCheckout  = $false
$ShowHelp    = $false

# ---------------------------------------------------------------------------
#  Argument parsing
# ---------------------------------------------------------------------------
$argv = @($args)
$i = 0
while ($i -lt $argv.Count) {
    $raw = [string]$argv[$i]
    $opt = $raw
    $inline = $null
    if ($raw -match '^(--?[^=]+)=(.*)$') { $opt = $matches[1]; $inline = $matches[2] }

    switch ($opt) {
        '--help'     { $ShowHelp = $true }
        '-h'         { $ShowHelp = $true }
        '/?'         { $ShowHelp = $true }
        '--checkout' { $DoCheckout = $true }
        default {
            $valueOptions = @('--version', '--milestone', '--date', '--chromium-hash', '--depot-tools', '--num', '--max-pages')
            if ($valueOptions -contains $opt) {
                $value = $inline
                if ($null -eq $value) {
                    $i++
                    if ($i -ge $argv.Count) { throw "Option $opt requires a value." }
                    $value = [string]$argv[$i]
                }
                switch ($opt) {
                    '--version'       { $VersionReq = $value }
                    '--milestone'     { $MilestoneReq = $value }
                    '--date'          { $DateReq = $value }
                    '--chromium-hash' { $HashReq = $value }
                    '--depot-tools'   { $DepotTools = $value }
                    '--num'           { $PageSize = [int]$value }
                    '--max-pages'     { $MaxPages = [int]$value }
                }
            } else {
                Write-Warning "Unknown option: $raw"
            }
        }
    }
    $i++
}

function Show-Help {
    Write-Host @"
Usage: find_depot_tools_version.ps1 [options]

Finds the depot_tools commit that matches a Chromium version's release date.

Options:
  --version VER        Chromium revision (same syntax as chromium_build_win.ps1):
                         stable / latest     latest stable release
                         131.0.6778.85       an exact release tag
                         7871                a branch (refs/branch-heads/7871)
                         main / refs/...     a branch/ref
  --milestone N        Use the latest stable release of milestone N.
  --date YYYY-MM-DD    Use an explicit date instead of deriving it from Chromium.
  --chromium-hash SHA  Use a specific chromium/src commit hash.
  --depot-tools PATH   depot_tools directory (default: .\depot_tools).
  --num N              depot_tools log page size (default 1000).
  --max-pages N        Safety cap on log pages to fetch (default 300).
  --checkout           Actually check out the found commit in --depot-tools.
  -h, --help           Show this help.
"@
}

if ($ShowHelp) { Show-Help; exit 0 }

$GitilesSrc      = 'https://chromium.googlesource.com/chromium/src/+/'
$GitilesDtLog    = 'https://chromium.googlesource.com/chromium/tools/depot_tools/+log/refs/heads/main?format=JSON&n='
$DashReleases    = 'https://chromiumdash.appspot.com/fetch_releases?channel=Stable&platform=Windows&num={0}'

function Get-GitilesJson {
    param([Parameter(Mandatory = $true)][string]$Uri)
    $resp = Invoke-WebRequest -UseBasicParsing -TimeoutSec 120 -Uri $Uri
    return (($resp.Content -replace "^\)\]\}'\s*", "") | ConvertFrom-Json)
}

function ConvertFrom-GitilesTime {
    param([string]$Text)
    if (-not $Text) { return $null }
    if ($Text -match '^\w{3} (\w{3})\s+(\d{1,2}) (\d{2}):(\d{2}):(\d{2}) (\d{4})') {
        $months = @{ Jan = 1; Feb = 2; Mar = 3; Apr = 4; May = 5; Jun = 6; Jul = 7; Aug = 8; Sep = 9; Oct = 10; Nov = 11; Dec = 12 }
        $mon = $months[$matches[1]]
        if (-not $mon) { return $null }
        return Get-Date -Year ([int]$matches[6]) -Month $mon -Day ([int]$matches[2]) `
            -Hour ([int]$matches[3]) -Minute ([int]$matches[4]) -Second ([int]$matches[5])
    }
    return $null
}

function Get-ChromiumCommitInfo {
    param([Parameter(Mandatory = $true)][string]$Ref)
    $j = Get-GitilesJson -Uri ($GitilesSrc + $Ref + '?format=JSON')
    return [ordered]@{
        Ref  = $Ref
        Sha  = $j.commit
        Date = (ConvertFrom-GitilesTime $j.committer.time)
    }
}

function Get-LatestStableVersion {
    param([int]$Milestone = 0)
    $uri = $DashReleases -f 5
    if ($Milestone -gt 0) { $uri = "$uri&milestone=$Milestone" }
    try {
        $rel = @(Invoke-RestMethod -UseBasicParsing -Uri $uri -TimeoutSec 60)
        if ($rel.Count -gt 0) { return $rel[0].version }
    } catch {
        Write-Warning "Chromium Dash lookup failed: $($_.Exception.Message)"
    }
    return $null
}

function Resolve-ChromiumRef {
    param([string]$Version, [string]$Milestone)
    if ($Milestone) {
        $v = Get-LatestStableVersion -Milestone ([int]$Milestone)
        if (-not $v) { throw "Could not resolve milestone $Milestone." }
        return $v
    }
    $r = $Version.Trim()
    if ($r -eq '' -or $r -match '^(stable|latest|release)$') {
        $v = Get-LatestStableVersion
        if (-not $v) { throw 'Could not resolve the latest stable version.' }
        return $v
    }
    if ($r -match '^\d+\.\d+\.\d+\.\d+$') { return $r }
    if ($r -match '^\d+$') { return "refs/branch-heads/$r" }
    if ($r -match '^branch-heads/') { return "refs/$r" }
    return $r
}

function Find-DepotToolsCommitBefore {
    param([Parameter(Mandatory = $true)][datetime]$Date)
    $cursor = $null
    $last = $null
    for ($p = 1; $p -le $MaxPages; $p++) {
        $uri = $GitilesDtLog + $PageSize
        if ($cursor) { $uri += "&s=$cursor" }
        Write-Host "  > reading depot_tools history (page $p) ..." -ForegroundColor DarkGray
        $j = Get-GitilesJson -Uri $uri
        foreach ($c in @($j.log)) {
            $cd = ConvertFrom-GitilesTime $c.committer.time
            if (-not $cd) { continue }
            $entry = [ordered]@{
                Commit  = $c.commit
                Date    = $cd
                Subject = (($c.message -split "`n")[0]).Trim()
            }
            if ($cd -le $Date) { return $entry }
            $last = $entry
        }
        if (-not $j.next) { break }
        $cursor = $j.next
    }
    return $last
}

# ===========================================================================
#  Main
# ===========================================================================
Write-Host '============================================================================'
Write-Host ' depot_tools version finder'
Write-Host '============================================================================'

# ---- 1. Chromium side -------------------------------------------------------
if ($DateReq) {
    $chromium = [ordered]@{ Ref = '(date)'; Sha = ''; Date = (Get-Date $DateReq) }
    Write-Host " Chromium  : explicit date $($chromium.Date.ToString('yyyy-MM-dd'))"
} elseif ($HashReq) {
    $chromium = Get-ChromiumCommitInfo -Ref $HashReq
    Write-Host " Chromium  : $($chromium.Sha.Substring(0,12)) ($($chromium.Date.ToString('yyyy-MM-dd')))"
} else {
    if (-not $VersionReq -and -not $MilestoneReq) { $VersionReq = 'stable' }
    $ref = Resolve-ChromiumRef -Version $VersionReq -Milestone $MilestoneReq
    $chromium = Get-ChromiumCommitInfo -Ref $ref
    Write-Host " Chromium  : $ref -> $($chromium.Sha.Substring(0,12)) ($($chromium.Date.ToString('yyyy-MM-dd')))"
}

# ---- 2. depot_tools side ----------------------------------------------------
Write-Host " Target    : depot_tools commit at or before $($chromium.Date.ToString('yyyy-MM-dd HH:mm:ss'))"
$dt = Find-DepotToolsCommitBefore -Date $chromium.Date
if ($null -eq $dt) { throw 'Could not find any depot_tools commit (history unavailable).' }

Write-Host ''
Write-Host '============================================================================'
Write-Host ' Result'
Write-Host '============================================================================'
Write-Host " depot_tools commit : $($dt.Commit)"
Write-Host " date               : $($dt.Date.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host " subject            : $($dt.Subject)"
Write-Host ''
Write-Host ' NOTE: Chromium DEPS pins src/third_party/depot_tools to an exact commit.'
Write-Host '       Prefer prepare_win_toolchain.ps1 --show-deps / --pin-depot-tools.'
Write-Host '       This date-based result is a fallback for old revisions or when'
Write-Host '       you want a full depot_tools checkout.'
Write-Host ''
Write-Host ' To pin (optional), run:'
Write-Host "   git -C `"$DepotTools`" fetch --depth 1 origin $($dt.Commit)"
Write-Host "   git -C `"$DepotTools`" checkout --detach $($dt.Commit)"
Write-Host '   $env:DEPOT_TOOLS_UPDATE = "0"    # keep it pinned (PowerShell)'
Write-Host '   set DEPOT_TOOLS_UPDATE=0         # keep it pinned (cmd.exe)'
Write-Host ''
Write-Host ' To restore the latest depot_tools:'
Write-Host "   git -C `"$DepotTools`" fetch --depth 1 origin main"
Write-Host "   git -C `"$DepotTools`" checkout -B main FETCH_HEAD"
Write-Host '   Remove-Item Env:\DEPOT_TOOLS_UPDATE'
Write-Host '============================================================================'

# ---- 3. optional checkout ---------------------------------------------------
if ($DoCheckout) {
    if (-not (Test-Path -LiteralPath (Join-Path $DepotTools '.git'))) {
        throw "Not a git checkout: $DepotTools"
    }
    Write-Host ''
    Write-Host "==> Checking out $($dt.Commit) in $DepotTools"
    & git -C $DepotTools fetch --depth 1 origin $dt.Commit
    if ($LASTEXITCODE -ne 0) { throw "git fetch of $($dt.Commit) failed. Try without --depth 1." }
    & git -C $DepotTools checkout --detach $dt.Commit
    if ($LASTEXITCODE -ne 0) { throw "git checkout of $($dt.Commit) failed." }
    Write-Host ' Done. Remember to set DEPOT_TOOLS_UPDATE=0 before using it.' -ForegroundColor Green
}

exit 0
