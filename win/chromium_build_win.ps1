# ============================================================================
#  chromium_build_win.ps1
#  ---------------------------------------------------------------------------
#  Build Chromium on Windows 10/11 (x64) from an ALREADY DOWNLOADED checkout.
#  This script never touches the network and never runs gclient.
#
#  Responsibilities
#    * locate the source tree (relative to this script first, then --dir /
#      environment variables), so a copied or renamed checkout keeps working
#    * repair build\win_toolchain.json when it still points at the old location
#    * run "gn gen" and then "autoninja" for the requested targets
#
#  The download/sync/hooks/export step lives in chromium_download_win.ps1.
#
#  Requirements
#    - A prepared checkout: either
#        * an exported offline repo (chromium_download_win.bat --make-offline-repo),
#          which contains <src>\init_tools\<MAJOR>\depot_tools and env.bat/env.ps1
#        * or a normal workspace (chromium_download_win.bat) with depot_tools
#          and gclient hooks already run
#    - No network, no Visual Studio (the toolchain comes from the checkout)
# ============================================================================

$ErrorActionPreference = 'Stop'
$runStart = Get-Date

# ---------------------------------------------------------------------------
#  GN args helpers (defined before the parser, which may call Add-GnArgText)
# ---------------------------------------------------------------------------
function Add-GnArgText {
    param([string]$Existing, [string]$New)
    if (-not $Existing) { return $New }
    return $Existing + "`n" + $New
}

# Parse 'k=v k2="v 2"' into an ordered map. Values keep their original quoting
# so they can be written verbatim into args.gn.
# Note: \" is normalized to " because a .bat entry point (cmd layer) turns
# 'target_os="win"' into 'target_os=\"win\"' (see PIT-010).
function ConvertFrom-GnArgs {
    param([string]$Text)
    $map = [ordered]@{}
    if (-not $Text) { return $map }
    $Text = $Text.Replace('\"', '"')
    foreach ($m in [regex]::Matches($Text, '([A-Za-z_][A-Za-z0-9_]*)\s*=\s*("(?:[^"\\]|\\.)*"|''(?:[^''\\]|\\.)*''|[^\s]+)')) {
        $map[$m.Groups[1].Value] = $m.Groups[2].Value
    }
    return $map
}

# ---------------------------------------------------------------------------
#  Argument parsing
# ---------------------------------------------------------------------------
$ScriptDir       = $PSScriptRoot
$ShowHelp        = $false
$RootOpt         = ''
$SrcDirName      = 'src'
$ExplicitTargets = @()
$DefaultTargets  = @('chrome', 'content_shell', 'headless_shell', 'mini_installer')
$BuildDir        = ''            # derived: out\<os><cpu><r|d>, e.g. out\winx64r
$Jobs            = 0
$Release         = $false
$ExtraGnArgs     = ''
$Arch            = ''
$Pgo             = $false
$CheckOnly       = $false
$NoSccache       = $false
$SccacheCacheDir = ''        # --sccache-dir (default: <src>\out\.cache<MAJOR>)
$IdeName         = ''        # --ide=vs2022 / vs / json ...
$IdeFilters      = @()       # --filter (mapped to gn --filters, ';' separated)
$GnExtraFlags    = @()       # --gn-flag (verbatim gn gen flags, e.g. --sln=foo)
$NinjaFlags      = @()       # --ninja-flag (verbatim autoninja/ninja flags, e.g. -k 0)

$argv = $args
$LeakedGnArgs = @()
$i = 0
while ($i -lt $argv.Count) {
    $raw = [string]$argv[$i]
    $opt = $raw
    $inline = $null
    # -j16 compact form (autoninja/ninja style)
    if ($raw -match '^-j(\d+)$') { $opt = '-j'; $inline = $matches[1] }
    elseif ($raw -match '^(--?[^=]+)=(.*)$') { $opt = $matches[1]; $inline = $matches[2] }
    switch ($opt) {
        '--help' { $ShowHelp = $true }
        '-h'     { $ShowHelp = $true }
        '/?'     { $ShowHelp = $true }
        '--release' { $Release = $true }
        '--debug'   { $Release = $false }
        '--pgo'     { $Pgo = $true }
        '--check'   { $CheckOnly = $true }
        '--dry-run' { $CheckOnly = $true }
        '--no-sccache' { $NoSccache = $true }
        '--make-offline-repo' {
            throw '--make-offline-repo belongs to chromium_download_win.bat (it downloads and exports). This script only builds.'
        }
        '--offline-repo' {
            throw '--offline-repo belongs to chromium_download_win.bat (it downloads and exports). This script only builds.'
        }
        '--skip-build' {
            Write-Host ''
            Write-Host '  --skip-build is obsolete: chromium_build_win.bat only builds.' -ForegroundColor Yellow
            Write-Host '  Remove the flag (downloads are handled by chromium_download_win.bat).'
            Write-Host ''
            exit 2
        }
        default {
            # These belong to the download script; catch them early so a stale
            # command line does not silently build the wrong thing.
            $downloadOnly = @(
                '--version', '--milestone', '--pinned', '--full-deps', '--deps',
                '--win-toolchain', '--no-win-toolchain', '--win-toolchain-url', '--win-toolchain-hash',
                '--depot-tools-only', '--depot-tools-version', '--no-pin-depot-tools',
                '--no-bootstrap-git', '--add-defender-exclusions', '--retries', '--gc',
                '--skip-fetch', '--skip-hooks',
                '--sccache-url', '--sccache-sha256', '--with-tags', '--with-branch-heads'
            )
            if ($downloadOnly -contains $opt) {
                Write-Host ''
                Write-Host "  $opt is a download option; it belongs to the download step." -ForegroundColor Yellow
                Write-Host '  Run it once with the download script (no build, no gclient here):' -ForegroundColor Yellow
                Write-Host '    chromium_download_win.bat <options>' -ForegroundColor Yellow
                Write-Host ''
                exit 2
            }
            $valueOptions = @('--dir', '--src-dir', '--target', '--targets', '--build-dir',
                              '--jobs', '-j', '--gn-args', '--args', '--args-file', '--arch',
                              '--ide', '--filter', '--filters', '--gn-flag', '--ninja-flag',
                              '--sccache-dir', '--sccache-cache-dir')
            if ($valueOptions -contains $opt) {
                $value = $inline
                if ($null -eq $value) {
                    $i++
                    if ($i -ge $argv.Count) { throw "Option $opt requires a value." }
                    $value = [string]$argv[$i]
                }
                switch ($opt) {
                    '--dir'       { $RootOpt = $value }
                    '--src-dir'   { $SrcDirName = $value }
                    '--target'    { $ExplicitTargets += $value }
                    '--targets'   { $ExplicitTargets += ($value -split ',' | Where-Object { $_ -ne '' }) }
                    '--build-dir' { $BuildDir = $value }
                    '--jobs'      { $Jobs = [int]$value }
                    '-j'          { $Jobs = [int]$value }
                    '--ninja-flag' { $NinjaFlags += $value }
                    '--gn-args'   { $ExtraGnArgs = Add-GnArgText $ExtraGnArgs $value }
                    '--args'      { $ExtraGnArgs = Add-GnArgText $ExtraGnArgs $value }
                    '--args-file' {
                        if (-not (Test-Path -LiteralPath $value)) { throw "--args-file not found: $value" }
                        $fileText = Get-Content -LiteralPath $value -Raw
                        $ExtraGnArgs = Add-GnArgText $ExtraGnArgs $fileText
                    }
                    '--arch'      { $Arch = $value }
                    '--ide'       { $IdeName = $value }
                    '--filter'    { $IdeFilters += ($value -split '[;,]' | Where-Object { $_ -ne '' }) }
                    '--filters'   { $IdeFilters += ($value -split '[;,]' | Where-Object { $_ -ne '' }) }
                    '--gn-flag'   { $GnExtraFlags += $value }
                    '--sccache-dir' { $SccacheCacheDir = $value }
                    '--sccache-cache-dir' { $SccacheCacheDir = $value }
                }
            } else {
                # A bare "key=value" is almost always a GN assignment that got
                # split out of --args by cmd.exe quoting. Failing here is safer
                # than silently building a different configuration (e.g. debug
                # instead of the requested release).
                if ($raw -match '^[A-Za-z_][A-Za-z0-9_]*=') {
                    $LeakedGnArgs += $raw
                } else {
                    Write-Warning "Unknown option: $raw"
                }
            }
        }
    }
    $i++
}

if ($LeakedGnArgs.Count -gt 0) {
    Write-Host ''
    Write-Host ' ERROR: these tokens look like GN assignments, but were not part of --args:' -ForegroundColor Red
    foreach ($t in $LeakedGnArgs) { Write-Host ('   ' + $t) -ForegroundColor Red }
    Write-Host ''
    Write-Host ' cmd.exe does not treat single quotes as quotes, so'
    Write-Host " --args='...' was split at every space." 
    Write-Host ' Use one of these instead:'
    Write-Host '   1) --args-file <file>                       (recommended; one assignment per line)'
    Write-Host '   2) "--args=is_debug=false target_cpu=\"x64\""  (double quotes around the WHOLE value)'
    Write-Host ''
    Write-Host ' Nothing was built.' -ForegroundColor Red
    exit 3
}

if ($ExplicitTargets.Count -gt 0) { $Targets = $ExplicitTargets } else { $Targets = $DefaultTargets }

# Remember whether --build-dir was given explicitly; otherwise the name is
# derived AFTER the GN args are merged (so --args is_debug/target_cpu count).
$BuildDirExplicit = [bool]$BuildDir

# ---------------------------------------------------------------------------
#  Helpers (ConstrainedLanguage safe: cmdlets only, no PSCustomObject/Add-Type)
# ---------------------------------------------------------------------------
function Write-Step  { param([string]$Text) Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Ok    { param([string]$Text) Write-Host "    $Text" -ForegroundColor Green }
function Write-Warn2 { param([string]$Text) Write-Host "    $Text" -ForegroundColor Yellow }
function Write-Err   { param([string]$Text) Write-Host "    $Text" -ForegroundColor Red }

function Format-Stamp {
    param($Date)
    return ('{0:yyyy-MM-dd HH:mm:ss}' -f $Date)
}

function Format-Elapsed {
    param([int]$TotalSeconds)
    if ($TotalSeconds -lt 0) { $TotalSeconds = 0 }
    # NOTE: [int] on a double ROUNDS in PowerShell ([int]0.65 -> 1), so compute
    # the divisions only on exact multiples.
    $rem = $TotalSeconds % 3600
    $h = [int](($TotalSeconds - $rem) / 3600)
    $m = [int](($rem - ($rem % 60)) / 60)
    $s = $rem % 60
    return ('{0}h {1}m {2}s' -f $h, $m, $s)
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory
    )
    $display = "$FilePath $($ArgumentList -join ' ')"
    Write-Host "  > $display" -ForegroundColor DarkGray
    if ($WorkingDirectory) { Push-Location -LiteralPath $WorkingDirectory }
    try { & $FilePath @ArgumentList } finally { if ($WorkingDirectory) { Pop-Location } }
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE`: $display"
    }
}

# A Chromium checkout is identified by chrome/VERSION (present in every tree,
# including an exported offline repo).
function Test-ChromiumSrc {
    param([string]$Path)
    if (-not $Path) { return $false }
    return (Test-Path -LiteralPath (Join-Path $Path 'chrome\VERSION'))
}

function Get-FullPathSafe {
    param([string]$Path)
    if (-not $Path) { return '' }
    if (Test-Path -LiteralPath $Path) { return (Resolve-Path -LiteralPath $Path).Path }
    return $Path
}

function Get-NumericSubdirs {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Get-ChildItem -LiteralPath $Path -Directory -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -match '^\d+$' })
}

# ---------------------------------------------------------------------------
#  Cache directory of the RUNNING sccache daemon ('' when none is running).
#  "sccache --show-stats" prints:  Cache location  Local disk: "D:\\...\\cache"
#  The call is best-effort: no server / any error -> '' (never throws), so the
#  caller can decide whether a restart is needed instead of failing the build.
# ---------------------------------------------------------------------------
function Get-SccacheServerCacheDir {
    param([Parameter(Mandatory = $true)][string]$Exe)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = @()
    $code = -1
    try {
        $out = @(& $Exe --show-stats 2>&1)
        $code = $LASTEXITCODE
    } catch {
        $out = @()
        $code = -1
    }
    $ErrorActionPreference = $prev
    $text = ($out | Out-String)
    if ($text -match 'Cache location\s+Local disk:\s*"([^"]+)"') {
        return $matches[1].Replace('\\', '\')
    }
    if ($code -eq 0) { return 'UNKNOWN' }   # server answered, format not recognized
    return ''
}

function Normalize-CacheDir {
    param([string]$Path)
    if (-not $Path) { return '' }
    return ($Path.TrimEnd('\', '/').Replace('/', '\')).ToLowerInvariant()
}

# ---------------------------------------------------------------------------
#  Refresh the SHORT <hash>.timestamps of the win_toolchain, OUTSIDE gn.
#
#  get_toolchain_if_necessary.py re-hashes the toolchain (and prints
#  "Calculating hash ..." to stdout) when that file is missing or its mtimes are
#  stale - which happens after every git checkout / copy / re-extract. gn parses
#  vs_toolchain.py's stdout as GN code, so that message becomes
#  "ERROR at dynamically parsed input ... Invalid token". Worse, the re-hash
#  writes a 40-char <full>.timestamps, and RemoveUnusedToolchains() only accepts
#  the short <hash>.timestamps -> the toolchain is deleted (PIT-020).
#  Recreating the short file here keeps both failures away.
# ---------------------------------------------------------------------------
function Update-ToolchainTimestampCache {
    param(
        [Parameter(Mandatory = $true)][string]$Src,
        [Parameter(Mandatory = $true)][string]$DepotTools
    )
    $python = Join-Path $DepotTools 'python3.bat'
    if (-not (Test-Path -LiteralPath $python)) { return }
    $warmed = @()
    foreach ($winRoot in @((Join-Path $DepotTools 'win_toolchain'),
                           (Join-Path $Src 'third_party\depot_tools\win_toolchain'))) {
        $vsRoot = Join-Path $winRoot 'vs_files'
        if (-not (Test-Path -LiteralPath $vsRoot)) { continue }
        $script = Join-Path $winRoot 'get_toolchain_if_necessary.py'
        if (-not (Test-Path -LiteralPath $script)) { continue }
        foreach ($dir in @(Get-ChildItem -LiteralPath $vsRoot -Directory -Force -ErrorAction SilentlyContinue)) {
            $hash = $dir.Name
            $tmp = Join-Path $env:TEMP ('warm_tc_' + [guid]::NewGuid().ToString('N') + '.py')
            $code = @(
                'import importlib.util, os, sys'
                'script, rootdir, h = sys.argv[1], sys.argv[2], sys.argv[3]'
                'spec = importlib.util.spec_from_file_location("gt", script)'
                'm = importlib.util.module_from_spec(spec)'
                'spec.loader.exec_module(m)'
                'os.chdir(rootdir)'
                'm.SaveTimestampsAndHash("vs_files", h)'
                'print("ok")'
            ) -join "`n"
            Set-Content -LiteralPath $tmp -Value $code -Encoding ASCII
            try {
                $out = & $python $tmp $script $winRoot $hash 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $warmed += $hash
                } else {
                    Write-Warn2 ("Toolchain cache refresh failed for {0}: {1}" -f $hash, ($out -join ' '))
                }
            } finally {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }
        }
    }
    if ($warmed.Count -gt 0) {
        Write-Ok ("Toolchain cache: refreshed {0}" -f (($warmed | Sort-Object -Unique) -join ', '))
    }
}

function Show-Help {
    Write-Host @"
Usage: chromium_build_win.ps1 [options]

Builds Chromium from an already prepared checkout (no network, no gclient).
Run chromium_download_win.bat first if the source tree is missing.

Source discovery order (first match wins):
  1. --dir PATH            Repository root: the directory containing
                           chrome\VERSION (e.g. <repo>\src). For backward
                           compatibility a parent that contains <src-dir>\ is
                           also accepted.
  2. CHROMIUM_OFFLINE_SRC  (set by init_tools\win\env.bat)
  3. CHROMIUM_OFFLINE_ROOT (set by init_tools\win\env.bat) -> <root>\<src-dir>
  4. <this script>\..\..   (exported layout: <repo>\init_tools\win)
  5. <this script>\src, <this script>\..\src, <this script>\..\..\src

Options:
  --dir PATH            Repository root (contains chrome\VERSION; the directory
                        name can be anything: chromium, webview, chromium150...).
                        A parent directory is accepted for compatibility; if it
                        has exactly one chrome\VERSION subdirectory, that is used.
  --src-dir NAME        Only for the compatibility parent-directory form:
                        name of the source dir under --dir (default: src).
                        Not needed when --dir is the repo root itself.
  --target NAME         Add one build target (may be repeated).
  --targets A,B,C       Comma separated build targets.
                        Default: chrome,content_shell,headless_shell,mini_installer
  --build-dir DIR       GN output dir inside src.
                        Default: out\<target_os><target_cpu><r|d>
                        e.g. out\winx64r (release), out\winx64d (debug),
                             out\winx86r / out\winarm64r
  --release             Release build (is_debug=false). Default: debug.
  --debug               Debug build (default).
  --arch ARCH           target_cpu: x64 (default), x86 or arm64.
  --pgo                 Add chrome_pgo_phase=2 (requires downloaded profiles).
  --jobs N, -j N        Override parallel job count (passed as "-j N" to
                        autoninja; siso maps it to -local_jobs/-remote_jobs).
                        Also accepts the compact form -j16.
  --ninja-flag FLAG     Extra autoninja/ninja flag passed verbatim, e.g.
                        --ninja-flag "-k 0" or --ninja-flag -v (repeatable).
                        Note: autoninja splits on spaces, so "-k 0" works.
  --gn-args "ARGS"      Extra GN arguments, e.g. --gn-args 'is_component_build=true'.
                        Written into out\<build-dir>\args.gn (one per line).
                        Multiple values may be newline-separated.
                        A key given here OVERRIDES the script default
                        (is_debug / target_cpu / chrome_pgo_phase / cc_wrapper).
  --args "ARGS"         Alias of --gn-args (same merge/override behaviour).
                        Quoting matrix (tested):
                          * PowerShell -> .ps1 : --args 'target_cpu="x64"'
                          * cmd.exe     -> .bat: "--args=... target_cpu=\"x64\" ..."
                          * PowerShell  -> .bat: embedded " are removed by cmd
                            (target_cpu=x64) -> rejected (exit 3). Use
                            --args-file, or call the .ps1 directly.
                        --args-file has no quoting layer (recommended).
  --args-file PATH      Read GN args from a file (one assignment per line, or
                        the same k=v text). Most robust for long/complex args.
  --no-sccache          Do not set cc_wrapper="sccache" even if it is available.
  --sccache-dir DIR     sccache cache directory (SCCACHE_DIR). Default:
                        <src>\out\.cache<MAJOR> (inside out\, which is gitignored).
                        Alias: --sccache-cache-dir.
  --ide NAME            Pass --ide=NAME to "gn gen": vs2022 / vs2019 / vs / json /
                        qtcreator / eclipse / xcode. Generates IDE files in the
                        build dir (e.g. out\Default\all.sln).
  --filter PATTERN      Pass --filters=PATTERN (GN spells it plural). Repeatable;
                        ';' or ',' separates patterns, e.g. --filter //content/shell/*
                        Only affects IDE/project generation.
  --gn-flag FLAG        Extra "gn gen" switch passed verbatim, e.g. --gn-flag --sln=my
                        (repeatable). Not a build arg: use --args for those.
  --check, --dry-run    Only print what would be done (including the full,
                        copy-pasteable "gn gen" command); do not run gn/ninja.
  -h, --help            Show this help.

Examples:
  .\chromium_build_win.bat --release --targets content_shell
  .\chromium_build_win.bat --dir D:\chromium\src --release --targets chrome
  .\chromium_build_win.bat --check
  .\chromium_build_win.bat --release --ide vs2022 --filter '//content/shell/*' --targets content_shell
  .\init_tools\win\chromium_build_win.bat --release --ide vs2022 -j16 --targets chrome --args-file gn_args.txt

  # bundled defaults shipped inside the offline repo (no quoting layer)
  .\init_tools\win\chromium_build_win.bat --dir D:\chromium\src --ide vs2022 -j16 --targets chrome --args-file .\init_tools\win\args_default.gn

  # cmd.exe: the WHOLE --args value in double quotes, inner quotes as \"
  .\init_tools\win\chromium_build_win.bat --ide vs2022 -j16 --targets chrome "--args=is_debug=false is_official_build=true target_cpu=\"x64\""
  
  .\init_tools\win\chromium_build_win.bat --ide vs2022 -j16 --targets chrome --args="target_os=\"win\" target_cpu=\"x64\" is_component_build=false is_debug=false is_official_build=true google_api_key=false google_default_client_id=false google_default_client_secret=false proprietary_codecs=true media_use_ffmpeg=true ffmpeg_branding=\"Chrome\" enable_mse_mpeg2ts_stream_parser=true symbol_level=1 blink_symbol_level=1 v8_symbol_level=1 "

  # PowerShell: call the .ps1 directly for single-quoted --args,
  # or use --args-file with the .bat (embedded quotes survive neither cmd nor %*)
  .\init_tools\win\chromium_build_win.ps1 --ide vs2022 -j16 --targets chrome --args 'is_debug=false is_official_build=true target_cpu="x64"'
  .\init_tools\win\chromium_build_win.bat --ide vs2022 -j16 --targets chrome --args-file gn_args.txt
  
  .\init_tools\win\chromium_build_win.ps1 --ide vs2022 -j16 --targets chrome --args='target_os="win" target_cpu="x64" is_component_build=false is_debug=false is_official_build=true google_api_key=false google_default_client_id=false google_default_client_secret=false proprietary_codecs=true media_use_ffmpeg=true ffmpeg_branding="Chrome" enable_mse_mpeg2ts_stream_parser=true symbol_level=1 blink_symbol_level=1 v8_symbol_level=1 '
"@
}

if ($ShowHelp) { Show-Help; exit 0 }

# ---------------------------------------------------------------------------
#  Locate the source tree
# ---------------------------------------------------------------------------
$SrcDirName = $SrcDirName.Trim().TrimEnd('\', '/')
if (-not $SrcDirName -or $SrcDirName -match '[\\/]') {
    throw "Invalid --src-dir '$SrcDirName': it must be a single directory name, not a path."
}

$tried = @()
$Src = ''

if (-not $Src) {
    if ($RootOpt) {
        $rootFull = Get-FullPathSafe $RootOpt
        if (Test-ChromiumSrc $rootFull) {
            $Src = $rootFull
        } else {
            $cand = Join-Path $rootFull $SrcDirName
            $tried += $cand
            if (Test-ChromiumSrc $cand) {
                $Src = $cand
            } else {
                # The repository directory may have ANY name (chromium,
                # webview, chromium150, ...). If exactly one subdirectory is a
                # Chromium checkout, use it instead of insisting on <src-dir>.
                $found = @(Get-ChildItem -LiteralPath $rootFull -Directory -Force -ErrorAction SilentlyContinue |
                           Where-Object { Test-ChromiumSrc $_.FullName })
                if ($found.Count -eq 1) {
                    $Src = $found[0].FullName
                    Write-Ok "Detected repository root: $Src"
                } elseif ($found.Count -gt 1) {
                    Write-Warn2 "Multiple Chromium checkouts under $rootFull; pass --dir <repo-root> or --src-dir <name>."
                    foreach ($f in $found) { $tried += $f.FullName }
                }
            }
        }
    }
}
if (-not $Src -and $env:CHROMIUM_OFFLINE_SRC) {
    $cand = Get-FullPathSafe $env:CHROMIUM_OFFLINE_SRC
    $tried += $cand
    if (Test-ChromiumSrc $cand) { $Src = $cand }
}
if (-not $Src -and $env:CHROMIUM_OFFLINE_ROOT) {
    $cand = Join-Path (Get-FullPathSafe $env:CHROMIUM_OFFLINE_ROOT) $SrcDirName
    $tried += $cand
    if (Test-ChromiumSrc $cand) { $Src = $cand }
}
if (-not $Src) {
    foreach ($rel in @('..\..', 'src', '..\src', '..\..\src')) {
        $cand = Get-FullPathSafe (Join-Path $ScriptDir $rel)
        $tried += $cand
        if (Test-ChromiumSrc $cand) { $Src = $cand; break }
    }
}

if (-not $Src) {
    Write-Err 'Could not locate a Chromium source tree (chrome\VERSION not found).'
    Write-Err 'Tried:'
    foreach ($t in $tried) { Write-Host "    $t" }
    Write-Host ''
    Write-Err 'Download it first, then build:'
    Write-Err "  $(Join-Path $ScriptDir 'chromium_download_win.bat') --dir <download-root> --version <ver> [--make-offline-repo]"
    Write-Err 'Or point at the repository root explicitly:'
    Write-Err '  chromium_build_win.bat --dir <repo-root>    (the directory with chrome\VERSION)'
    exit 2
}

$Src  = Get-FullPathSafe $Src
$Root = Split-Path -Parent $Src
# The repo may be copied to a drive root (e.g. D:\), where -Parent is empty.
if (-not $Root) { $Root = $Src }
$SrcName = Split-Path -Leaf $Src

# ---------------------------------------------------------------------------
#  Locate depot_tools (offline layout first)
# ---------------------------------------------------------------------------
$DepotCandidates = @()
if ($env:DEPOT_TOOLS_PATH) { $DepotCandidates += $env:DEPOT_TOOLS_PATH }
$initTools = Join-Path $Src 'init_tools'
foreach ($d in Get-NumericSubdirs $initTools) {
    $DepotCandidates += (Join-Path $d.FullName 'depot_tools')
}
$DepotCandidates += (Join-Path $Root 'depot_tools')
$DepotCandidates += (Join-Path $Src 'third_party\depot_tools')

$DepotTools = ''
foreach ($c in $DepotCandidates) {
    if (-not $c) { continue }
    $c = Get-FullPathSafe $c
    if ((Test-Path -LiteralPath (Join-Path $c 'gn.bat')) -and
        (Test-Path -LiteralPath (Join-Path $c 'autoninja.bat'))) {
        $DepotTools = $c
        break
    }
}
if (-not $DepotTools) {
    Write-Err 'Could not locate depot_tools (needs gn.bat + autoninja.bat).'
    Write-Err 'Checked:'
    foreach ($c in $DepotCandidates) { if ($c) { Write-Host "    $c" } }
    Write-Err 'Activate the offline environment first:'
    Write-Err "  call `"$Src\init_tools\win\env.bat`""
    exit 2
}

$GnBat        = Join-Path $DepotTools 'gn.bat'
$AutoninjaBat = Join-Path $DepotTools 'autoninja.bat'

# depot_tools must be on PATH so gn/autoninja/python helpers resolve.
$env:PATH = "$DepotTools;$env:PATH"

# ---------------------------------------------------------------------------
#  Root\toolchain repair: win_toolchain.json stores ABSOLUTE paths, so a copied
#  or renamed checkout keeps pointing at the old location. Deleting it makes
#  vs_toolchain.py regenerate it (with --no-download) from the in-repo
#  <src>\third_party\depot_tools\win_toolchain\vs_files\<hash>.
# ---------------------------------------------------------------------------
$toolchainJson = Join-Path $Src 'build\win_toolchain.json'
$toolchainState = 'absent (gn will create it)'
if (Test-Path -LiteralPath $toolchainJson) {
    $raw = Get-Content -LiteralPath $toolchainJson -Raw
    $m = [regex]::Match($raw, '"path"\s*:\s*"((?:[^"\\]|\\.)+)"')
    if (-not $m.Success) {
        $toolchainState = 'unreadable -> will regenerate'
        if (-not $CheckOnly) { Remove-Item -LiteralPath $toolchainJson -Force -ErrorAction SilentlyContinue }
    } else {
        $recorded = $m.Groups[1].Value.Replace('\\', '\')
        # Compare case-insensitively without the StringComparison overload
        # (enum conversions are restricted in ConstrainedLanguage mode).
        $srcLower = $Src.ToLowerInvariant()
        if ($recorded.ToLowerInvariant().StartsWith($srcLower)) {
            $toolchainState = "ok ($recorded)"
        } else {
            $toolchainState = "stale -> will regenerate (was: $recorded)"
            if (-not $CheckOnly) {
                Remove-Item -LiteralPath $toolchainJson -Force -ErrorAction SilentlyContinue
                Write-Ok 'Removed stale build\win_toolchain.json (absolute paths pointed elsewhere).'
            }
        }
    }
}

# Toolchain hash mapping: with --win-toolchain-url the local dir is named after
# the LOCAL hash, while vs_toolchain.py asks for the CANONICAL one. Without the
# mapping, regenerating win_toolchain.json (after a move) fails to find it.
$toolchainMap = ''
$vsPy = Join-Path $Src 'build\vs_toolchain.py'
if (Test-Path -LiteralPath $vsPy) {
    $mt = [regex]::Match((Get-Content -LiteralPath $vsPy -Raw), "TOOLCHAIN_HASH\s*=\s*'([0-9a-fA-F]+)'")
    if ($mt.Success) {
        $canonicalHash = $mt.Groups[1].Value
        $vfDirs = @()
        foreach ($vfRoot in @((Join-Path $DepotTools 'win_toolchain\vs_files'),
                             (Join-Path $Src 'third_party\depot_tools\win_toolchain\vs_files'))) {
            if (Test-Path -LiteralPath $vfRoot) {
                $vfDirs += @(Get-ChildItem -LiteralPath $vfRoot -Directory -Force -ErrorAction SilentlyContinue)
            }
        }
        $vfNames = @($vfDirs | ForEach-Object { $_.Name } | Select-Object -Unique)
        if ($vfNames.Count -eq 1 -and $vfNames[0] -ne $canonicalHash) {
            Set-Item -Path ('Env:GYP_MSVS_HASH_' + $canonicalHash) -Value $vfNames[0]
            $toolchainMap = 'GYP_MSVS_HASH_' + $canonicalHash + '=' + $vfNames[0]
        }
    }
}

# Keep the toolchain timestamp cache fresh BEFORE gn runs (PIT-020).
if (-not $CheckOnly) {
    Update-ToolchainTimestampCache -Src $Src -DepotTools $DepotTools
}

# ---------------------------------------------------------------------------
#  Offline mode / sccache / GN args
# ---------------------------------------------------------------------------
$offline = $false
if ($env:GCLIENT_FILE) { $offline = $true }
if (Test-Path -LiteralPath $initTools) { $offline = $true }

# sccache: prefer the copy inside the exported repo.
$sccacheExe = ''
$scacheDirs = @()
foreach ($d in Get-NumericSubdirs $initTools) { $scacheDirs += (Join-Path $d.FullName 'scache') }
$localSccache = ''
foreach ($d in $scacheDirs) {
    $cand = Join-Path $d 'sccache.exe'
    if (Test-Path -LiteralPath $cand) { $localSccache = $cand; break }
}
if ($localSccache) {
    $sccacheExe = $localSccache
} else {
    $cmd = Get-Command sccache -ErrorAction SilentlyContinue
    if ($cmd) { $sccacheExe = $cmd.Source }
}

# Normalize/validate --arch (same list as chromium_download_win.ps1).
if ($Arch) {
    $Arch = $Arch.ToLowerInvariant()
    if (@('x64', 'x86', 'arm64') -notcontains $Arch) {
        Write-Warning "Invalid --arch value '$Arch' (expected x64, x86 or arm64); using the host default."
        $Arch = ''
    }
}

# Defaults first, then command-line --args/--gn-args override the same key.
# (Values keep their quoting; args.gn is written verbatim.)
$gnMap = [ordered]@{}
if ($Release) { $gnMap['is_debug'] = 'false' }
if ($Arch) { $gnMap['target_cpu'] = ('"' + $Arch + '"') }
if ($Pgo) { $gnMap['chrome_pgo_phase'] = '2' }

# If --args/--args-file already sets cc_wrapper, still enable the sccache
# PATH/cache setup when that wrapper IS sccache. The bundled args_default.gn
# contains cc_wrapper="sccache", so the old "no cc_wrapper in args" check would
# silently skip PATH/SCCACHE_DIR and the build would not find sccache.
$wrapperArg = ''
if ($ExtraGnArgs -match 'cc_wrapper\s*=\s*"?([^"\s,]+)"?') { $wrapperArg = $matches[1] }
$useSccache = ($sccacheExe -and -not $NoSccache -and (($wrapperArg -eq '') -or ($wrapperArg -eq 'sccache')))
if ($useSccache) {
    if ($wrapperArg -eq '') { $gnMap['cc_wrapper'] = '"sccache"' }
    $sccacheDir = Split-Path -Parent $sccacheExe
    $env:PATH = "$sccacheDir;$env:PATH"

    # Cache location (default: <src>\out\.cache<MAJOR>). out/ is gitignored,
    # so building never dirties the exported snapshot (the download marker
    # relies on a clean worktree). --sccache-dir overrides it.
    $cacheDir = $SccacheCacheDir
    if (-not $cacheDir) {
        $majorVer = ''
        $versionFile = Join-Path $Src 'chrome\VERSION'
        if (Test-Path -LiteralPath $versionFile) {
            foreach ($line in @(Get-Content -LiteralPath $versionFile -ErrorAction SilentlyContinue)) {
                if ($line -match '^MAJOR=(\d+)') { $majorVer = $matches[1]; break }
            }
        }
        $cacheDir = Join-Path (Join-Path $Src 'out') ('.cache' + $majorVer)
    } elseif ($cacheDir -notmatch '^[A-Za-z]:[\\/]|^\\\\') {
        $cacheDir = Join-Path $Src $cacheDir
    }
    $env:SCCACHE_DIR = $cacheDir
    if (-not $CheckOnly) {
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
        # The daemon keeps the cache dir it was started with. Compare it with
        # the requested dir and restart ONLY when they differ. No daemon, an
        # unresponsive daemon or an unparseable answer must never fail here.
        $runningDir = Get-SccacheServerCacheDir -Exe $sccacheExe
        $want = Normalize-CacheDir $cacheDir
        $have = Normalize-CacheDir $runningDir
        $needRestart = [bool]$runningDir -and (($runningDir -eq 'UNKNOWN') -or ($have -ne $want))
        if ($needRestart) {
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try { & $sccacheExe --stop-server 1>$null 2>$null } catch { }
            $ErrorActionPreference = $prevEap
            if ($runningDir -eq 'UNKNOWN') {
                Write-Ok "sccache cache: $cacheDir (daemon restarted)"
            } else {
                Write-Ok "sccache cache changed: $runningDir -> $cacheDir (daemon restarted)"
            }
        }
        # No daemon -> nothing to restart; the first compile starts one with
        # SCCACHE_DIR above.
    }
    $srcPrefix = $Src.TrimEnd('\') + '\'
    $outPrefix = (Join-Path $Src 'out').TrimEnd('\') + '\'
    $cacheLower = $cacheDir.ToLowerInvariant()
    if ($cacheLower.StartsWith($srcPrefix.ToLowerInvariant()) -and
        -not $cacheLower.StartsWith($outPrefix.ToLowerInvariant())) {
        Write-Warn2 "sccache cache is inside the repo but outside out\ ($cacheDir); git status may become dirty."
    }
}

$gnCli = ConvertFrom-GnArgs -Text $ExtraGnArgs
foreach ($k in $gnCli.Keys) { $gnMap[$k] = $gnCli[$k] }   # CLI wins

# Catch the most common cross-shell mistake before writing args.gn:
#   PowerShell: --args="target_os=\"win\""   (the cmd.exe form)
# PowerShell does not treat \" as an escape, so the quotes end the string and
# the value arrives as "target_os=\win\"; GN then fails with "Invalid token".
$aMangled = @()
foreach ($k in $gnMap.Keys) {
    $v = [string]$gnMap[$k]
    if ($v -match '^\\[A-Za-z0-9_.:/-]+\\$') { $aMangled += ('{0}={1}' -f $k, $v) }
}
if ($aMangled.Count -gt 0) {
    Write-Host ''
    Write-Host ' ERROR: GN arguments look mangled by the calling shell:' -ForegroundColor Red
    foreach ($a in $aMangled) { Write-Host ('   ' + $a) -ForegroundColor Red }
    Write-Host ''
    Write-Host ' PowerShell does not treat \" as an escape; the quote ends the string.'
    Write-Host ' Use one of these instead:'
    Write-Host '   * --args-file <file>                       (recommended, any shell)'
    Write-Host '   * PowerShell: call chromium_build_win.ps1 directly (single quotes work)'
    Write-Host '   * cmd.exe -> .bat: "--args=... target_cpu=\"x64\" ..."'
    Write-Host ''
    Write-Host ' Nothing was built.' -ForegroundColor Red
    exit 3
}

# String-valued GN args must keep their quotes. Calling a .bat from PowerShell
# with   --args 'target_cpu="x64"'   loses the embedded quotes in cmd, so the
# script receives target_cpu=x64 and GN treats x64 as an identifier.
$stringKeys = @('target_os', 'target_cpu', 'ffmpeg_branding')
$lostQuotes = @()
foreach ($k in $stringKeys) {
    $v = $gnMap[$k]
    if ($null -ne $v -and ([string]$v) -match '^[A-Za-z0-9_.:-]+$') {
        $lostQuotes += ('{0}={1}' -f $k, [string]$v)
    }
}
if ($lostQuotes.Count -gt 0) {
    Write-Host ''
    Write-Host ' ERROR: these string GN args lost their quotes:' -ForegroundColor Red
    foreach ($a in $lostQuotes) { Write-Host ('   ' + $a) -ForegroundColor Red }
    Write-Host ''
    Write-Host ' cmd removes embedded quotes when a .bat is called from PowerShell.'
    Write-Host ' Use one of these instead:'
    Write-Host '   * --args-file <file>                       (recommended, any shell)'
    Write-Host '   * PowerShell: call chromium_build_win.ps1 directly (single quotes work)'
    Write-Host '   * cmd.exe -> .bat: "--args=... target_cpu=\"x64\" ..."'
    Write-Host ''
    Write-Host ' Nothing was built.' -ForegroundColor Red
    exit 3
}

# --- official build + PGO ---------------------------------------------------
# is_official_build defaults chrome_pgo_phase=2, which needs a .profdata under
# chrome/build/pgo_profiles. Offline snapshots usually lack it, so disable PGO
# with a warning instead of letting gn gen fail mid-way.
# The EXPECTED file name lives in chrome/build/<target>.pgo.txt (e.g. win64),
# so a profile for a different milestone does not count (PIT-013).
$officialVal = $gnMap['is_official_build']
$pgoPhaseVal = $gnMap['chrome_pgo_phase']
if ($officialVal -eq 'true' -and $null -eq $pgoPhaseVal) {
    $pgoOs  = if ($null -ne $gnMap['target_os'])  { ([string]$gnMap['target_os']).Trim('"') }  else { 'win' }
    $pgoCpu = if ($null -ne $gnMap['target_cpu']) { ([string]$gnMap['target_cpu']).Trim('"') } else { 'x64' }
    $pgoTarget = 'win64'
    if ($pgoOs -eq 'win' -and $pgoCpu -eq 'x86') { $pgoTarget = 'win32' }
    if ($pgoOs -eq 'win' -and $pgoCpu -eq 'arm64') { $pgoTarget = 'win-arm64' }
    $pgoDir = Join-Path $Src 'chrome\build\pgo_profiles'
    $pgoState = Join-Path $Src ('chrome\build\' + $pgoTarget + '.pgo.txt')
    $pgoName = ''
    if (Test-Path -LiteralPath $pgoState) {
        $pgoName = (Get-Content -LiteralPath $pgoState -Raw).Trim()
    }
    $pgoOk = $false
    if ($pgoName) {
        # Authoritative: the checkout names the exact profile for this milestone.
        $pgoOk = Test-Path -LiteralPath (Join-Path $pgoDir $pgoName)
        if (-not $pgoOk) {
            $stale = @(Get-ChildItem -LiteralPath $pgoDir -Filter '*.profdata' -File -ErrorAction SilentlyContinue)
            if ($stale.Count -gt 0) {
                Write-Warn2 ("Found {0} profile(s), but not the one this revision needs." -f $stale.Count)
            }
        }
    } else {
        # Older snapshots may predate the .pgo.txt state file: accept any profile.
        $profiles = @(Get-ChildItem -LiteralPath $pgoDir -Filter '*.profdata' -File -ErrorAction SilentlyContinue)
        $pgoOk = ($profiles.Count -gt 0)
    }
    if (-not $pgoOk) {
        Write-Warn2 'is_official_build=true needs PGO profiles, but none are present.'
        if ($pgoName) { Write-Warn2 ("Expected profile: chrome\build\pgo_profiles\$pgoName") }
        Write-Warn2 'Disabling PGO (chrome_pgo_phase=0). To keep PGO, download with'
        Write-Warn2 '--pgo (profiles are fetched by default too), then rerun the build.'
        $gnMap['chrome_pgo_phase'] = '0'
    }
}

# --- build dir --------------------------------------------------------------
# out\<target_os><target_cpu><r|d>, derived from the EFFECTIVE merged args, so
# --args is_debug=false / target_cpu="x86" are reflected. --build-dir always wins.
$effDebug = -not ($gnMap['is_debug'] -eq 'false')
if (-not $BuildDirExplicit) {
    $effOs  = if ($null -ne $gnMap['target_os'])  { ([string]$gnMap['target_os']).Trim('"') }  else { 'win' }
    $effCpu = if ($null -ne $gnMap['target_cpu']) { ([string]$gnMap['target_cpu']).Trim('"') } else { 'x64' }
    $cfgSuffix = if ($effDebug) { 'd' } else { 'r' }
    $BuildDir = 'out\' + $effOs + $effCpu + $cfgSuffix
}

$gnArgs = @()
foreach ($k in $gnMap.Keys) { $gnArgs += ($k + '=' + $gnMap[$k]) }
$gnArgString = ($gnArgs -join '; ')

# --- disk space preflight ---------------------------------------------------
# Official/ThinLTO links write multi-GB outputs (chrome.dll + .pdb + LTO cache);
# failing at 99% with "no space on device" wastes hours (PIT-014).
$qualifier = Split-Path -Qualifier $Src          # e.g. "D:"
$driveName = $qualifier.TrimEnd(':')
$freeGb = -1
$drv = Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue
if ($drv) { $freeGb = [int]($drv.Free / 1GB) }
if ($freeGb -ge 0 -and $freeGb -lt 25) {
    Write-Warn2 ("Low disk space on {0} - only {1} GB free. ThinLTO links need several GB extra." -f $qualifier, $freeGb)
    Write-Warn2 'Free space first: out\<build-dir>\thinlto-cache, unused *.pdb,'
    Write-Warn2 'the sccache cache, or move the repo to a bigger drive.'
    Write-Warn2 'See PIT-014 in docs/PITFALLS.md.'
}

# Extra gn gen switches (NOT build args): --ide / --filters / --gn-flag.
# Note: GN spells it --filters (plural, ';'-separated label patterns).
$gnGenFlags = @()
if ($IdeName) { $gnGenFlags += ('--ide=' + $IdeName) }
if ($IdeFilters.Count -gt 0) { $gnGenFlags += ('--filters=' + ($IdeFilters -join ';')) }
foreach ($f in $GnExtraFlags) { $gnGenFlags += $f }
$gnGenFlagString = ($gnGenFlags -join ' ')

# Copy-pasteable full command. gn.bat goes through cmd, so inner double quotes
# must be backslash-escaped (\") or cmd strips them (PIT-010).
$argsInline = (($gnArgs | ForEach-Object { $_ -replace '"', '\"' }) -join ' ')
$fullGnCmd = $GnBat + ' gen ' + $BuildDir
if ($gnGenFlagString) { $fullGnCmd += ' ' + $gnGenFlagString }
if ($argsInline) { $fullGnCmd += ' --args="' + $argsInline + '"' }

# ---------------------------------------------------------------------------
#  Report
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '============================================================================'
Write-Host ' Chromium build (offline capable)'
Write-Host '============================================================================'
Write-Host " Source      : $Src"
if ($Root -and $Root -ne $Src) { Write-Host " Parent dir  : $Root" }
Write-Host " Started     : $(Format-Stamp $runStart)"
Write-Host " depot_tools : $DepotTools"
Write-Host " Mode        : $(if ($offline) { 'offline repo (no gclient/network)' } else { 'workspace' })"
Write-Host " Targets     : $($Targets -join ', ')"
Write-Host " Build dir   : $Src\$BuildDir"
Write-Host " Config      : $(if ($effDebug) { 'debug' } else { 'release' })"
Write-Host " Toolchain   : $toolchainState"
if ($toolchainMap) { Write-Host " Toolchain map: $toolchainMap" }
if ($freeGb -ge 0) { Write-Host " Disk free   : $freeGb GB on $qualifier" }
Write-Host " sccache     : $(if ($useSccache) { $sccacheExe } else { 'disabled' })"
if ($useSccache) { Write-Host " sccache cache: $env:SCCACHE_DIR" }
Write-Host " GN args     : $(if ($gnArgString) { $gnArgString } else { '(none)' })"
if ($gnGenFlagString) { Write-Host " GN gen flags: $gnGenFlagString" }
Write-Host " Full gn gen : $fullGnCmd"
if ($Jobs -gt 0 -or $NinjaFlags.Count -gt 0) {
    Write-Host " Ninja flags : $(if ($Jobs -gt 0) { '-j ' + $Jobs + ' ' })$($NinjaFlags -join ' ')"
}
Write-Host '============================================================================'

if ($CheckOnly) {
    Write-Host ''
    Write-Ok 'Check only (--check): nothing was generated or built.'
    exit 0
}

# gclient_args.gni is produced by "gclient sync"/hooks. Without it gn fails, so
# give an actionable message instead of a cryptic GN import error.
$gclientArgs = Join-Path $Src 'build\config\gclient_args.gni'
if (-not (Test-Path -LiteralPath $gclientArgs)) {
    Write-Warn2 "Missing $gclientArgs"
    Write-Warn2 'That file is generated by gclient. Run the download script once:'
    Write-Warn2 "  $(Join-Path $ScriptDir 'chromium_download_win.bat') --dir $Root"
}

# ---------------------------------------------------------------------------
#  gn gen + build
#
#  Write args.gn instead of passing --args on the command line: PowerShell 5.1
#  mangles embedded double quotes when it launches a .bat (gn.bat), so
#  'cc_wrapper="sccache"' reached gn as 'cc_wrapper=sccache' and failed with
#  "Undefined identifier". args.gn has no quoting layer at all (see PIT-010).
# ---------------------------------------------------------------------------
$buildDirFull = Join-Path $Src $BuildDir
New-Item -ItemType Directory -Force -Path $buildDirFull | Out-Null
$argsFile = Join-Path $buildDirFull 'args.gn'
if ($gnArgs.Count -gt 0) {
    Set-Content -LiteralPath $argsFile -Value $gnArgs -Encoding ASCII
} else {
    Set-Content -LiteralPath $argsFile -Value '' -Encoding ASCII
}
Write-Step "Generating build files with gn (args.gn written)"
Write-Ok "args.gn: $argsFile"
if ($gnGenFlagString) { Write-Ok "gn gen flags: $gnGenFlagString" }
$genArgList = @('gen', $BuildDir) + $gnGenFlags
$gnStart = Get-Date
Invoke-Native -FilePath $GnBat -ArgumentList $genArgList -WorkingDirectory $Src
$gnSeconds = [int]((Get-Date) - $gnStart).TotalSeconds
Write-Ok ("gn gen finished at {0} ({1})" -f (Format-Stamp (Get-Date)), (Format-Elapsed $gnSeconds))

$results = [ordered]@{}
$durations = [ordered]@{}
$failed = 0
$buildStart = Get-Date
Write-Host ''
Write-Step ("Building targets (started {0})" -f (Format-Stamp $buildStart))
foreach ($target in $Targets) {
    Write-Step "Building target: $target"
    $ninjaArgs = @('-C', $BuildDir)
    if ($Jobs -gt 0) { $ninjaArgs += @('-j', [string]$Jobs) }
    foreach ($nf in $NinjaFlags) { $ninjaArgs += $nf }
    $ninjaArgs += $target
    $t0 = Get-Date
    try {
        Invoke-Native -FilePath $AutoninjaBat -ArgumentList $ninjaArgs -WorkingDirectory $Src
        $tSec = [int]((Get-Date) - $t0).TotalSeconds
        $durations[$target] = $tSec
        $results[$target] = 'OK'
        Write-Ok ("Built {0} in {1}" -f $target, (Format-Elapsed $tSec))
    } catch {
        $tSec = [int]((Get-Date) - $t0).TotalSeconds
        $durations[$target] = $tSec
        $results[$target] = 'FAILED'
        $failed++
        Write-Warn2 ("Target '{0}' failed after {1}: {2}" -f $target, (Format-Elapsed $tSec), $_.Exception.Message)
    }
}

$buildEnd = Get-Date
$buildSeconds = [int]($buildEnd - $buildStart).TotalSeconds
$totalSeconds = [int]($buildEnd - $runStart).TotalSeconds

Write-Host ''
Write-Host '============================================================================'
Write-Host ' Build summary'
Write-Host '============================================================================'
foreach ($key in @($results.Keys)) {
    $value = $results[$key]
    $color = if ($value -eq 'OK') { 'Green' } else { 'Red' }
    $dur = ''
    if ($null -ne $durations[$key]) { $dur = '  (' + (Format-Elapsed $durations[$key]) + ')' }
    Write-Host ("  {0,-16} {1}{2}" -f $key, $value, $dur) -ForegroundColor $color
}
Write-Host " Output   : $Src\$BuildDir"
Write-Host " Started  : $(Format-Stamp $runStart)"
Write-Host " Finished : $(Format-Stamp $buildEnd)"
Write-Host " Elapsed  : gn gen $(Format-Elapsed $gnSeconds), build $(Format-Elapsed $buildSeconds), total $(Format-Elapsed $totalSeconds)"
Write-Host '============================================================================'

if ($failed -gt 0) { exit 1 }
exit 0
