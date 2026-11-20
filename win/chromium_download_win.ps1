# ============================================================================
#  chromium_download_win.ps1
#  ---------------------------------------------------------------------------
#  Download and prepare Chromium on Windows 10/11 (x64).
#  Building is done by chromium_build_win.ps1/.bat, which needs no network.
#
#  What it does
#    1. Bootstraps git (portable Git, if git is not installed) and depot_tools.
#    2. Shallow-fetches the Chromium source tree and its dependencies.
#    3. Optionally checks out a requested version / milestone / branch
#       (falls back to the latest stable release when the request does not
#       exist).
#    4. Runs gclient hooks. Chromium's clang is downloaded by the sync; the
#       Windows SDK/MSVC headers+libs come from either a locally installed
#       Visual Studio (DEPOT_TOOLS_WIN_TOOLCHAIN=0) or the prebuilt toolchain
#       (DEPOT_TOOLS_WIN_TOOLCHAIN=1). NOTE: the prebuilt toolchain is
#       Google-internal, so EXTERNAL users must have Visual Studio installed.
#    5. With --make-offline-repo: backs up all .git dirs (.gitignore files
#       too), wipes them, and builds ONE fresh repository: commit 1/2 is the
#       original source tree, commit 2/2 folds depot_tools, the gclient config,
#       sccache and this script set into <src>\init_tools (plus env.bat/env.ps1).
#       The result is self-contained: copying it elsewhere is enough to build.
#       The download workspace is KEPT by default (pass --cleanup to delete it),
#       and <src>\init_tools\.offline_repo.state (hidden) records the completed
#       export so a later run with the same version/toolchain archive skips all
#       network work (the marker is committed with commit 2/2).
#
#  Requirements
#    - Windows 10/11 x64, 8+ GB RAM (16+ recommended)
#    - 100+ GB free NTFS disk space (FAT32 will not work)
#    - Internet access
#    - Git for Windows is used when present; if it is missing, a portable
#      copy is downloaded automatically (disable with --no-bootstrap-git).
#    - Visual Studio 2026 (or Build Tools) with "Desktop development with C++"
#      and the "MFC/ATL" component. This is REQUIRED for external users: the
#      prebuilt win_toolchain is Google-internal. The script auto-detects VS
#      (--win-toolchain auto) and sets DEPOT_TOOLS_WIN_TOOLCHAIN accordingly.
#      ALTERNATIVE without installing VS: --win-toolchain-url <dir URL> pointing
#      at a folder containing "<toolchain-hash>.zip" (file:// or http/https).
#
#  Notes
#    - The download root defaults to THIS SCRIPT'S directory. Use --dir PATH
#      to put everything somewhere else.
#    - The full path must NOT contain spaces (Chromium requirement).
#    - The source is ALWAYS fetched with --no-history (shallow, depth 1) to
#      keep every .git directory as small as possible.
#
#  Examples
#    .\chromium_download_win.ps1
#    .\chromium_download_win.ps1 --dir D:\chromium
#    .\chromium_download_win.ps1 --version 131
#    .\chromium_download_win.ps1 --version 131.0.6778.85 --release
#    .\chromium_download_win.ps1 --version main
#    .\chromium_download_win.ps1 --targets chrome,content_shell
#    .\chromium_download_win.ps1 --dir D:\chromium --version 7871  --win-toolchain-url "file://D:/win_toolchain_archive"
#    .\chromium_download_win.ps1 --dir D:\chromium --version 7871  --win-toolchain-url "file://D:/win_toolchain_archive" --dest-name chromium150
#    .\chromium_download_win.ps1 --dir D:\chromium --version 7871  --win-toolchain-url "file://D:/win_toolchain_archive" --make-offline-repo
#    .\chromium_download_win.ps1 --dir D:\chromium --version 7871  --win-toolchain-url "file://D:/win_toolchain_archive" --make-offline-repo --cleanup
# ============================================================================

$ErrorActionPreference = 'Stop'
$runStart = Get-Date

# ---------------------------------------------------------------------------
#  Console helpers (defined before ANY other code that may log; the paths
#  section below can call Write-Ok when reusing an exported depot_tools).
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
    # [int] rounds doubles in PowerShell, so only divide exact multiples.
    $rem = $TotalSeconds % 3600
    $h = [int](($TotalSeconds - $rem) / 3600)
    $m = [int](($rem - ($rem % 60)) / 60)
    $s = $rem % 60
    return ('{0}h {1}m {2}s' -f $h, $m, $s)
}

# Print a final, timestamped line even when the script aborts, so two runs can
# never look identical in the logs.
trap {
    $now = Get-Date
    Write-Host ''
    Write-Host ("FAILED at {0} (elapsed {1})" -f (Format-Stamp $now), (Format-Elapsed ([int](($now - $runStart).TotalSeconds)))) -ForegroundColor Red
    Write-Host ("Error: " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
#  Environment sanity checks (helpful hints when PowerShell is locked down)
# ---------------------------------------------------------------------------
function Test-PowerShellEnvironment {
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        Write-Host "ERROR: Windows PowerShell 5.1 or newer is required (found $($PSVersionTable.PSVersion))." -ForegroundColor Red
        Write-Host 'It ships with Windows 10/11; no separate install should be needed.'
        exit 3
    }

    $mode = $ExecutionContext.SessionState.LanguageMode
    if ($mode -ne 'FullLanguage') {
        Write-Host ''
        Write-Host "NOTE: PowerShell language mode is '$mode'." -ForegroundColor Yellow
        Write-Host '  ConstrainedLanguage is normally enforced by WDAC / AppLocker / Device Guard'
        Write-Host '  (typical on managed corporate machines). Some operations may be blocked.'
        Write-Host '  There is no single command to turn it off; the policy must be relaxed:'
        Write-Host '    Get-AppLockerPolicy -Effective -Xml'
        Write-Host '    Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard'
        Write-Host '  If you own the machine, remove the WDAC/AppLocker policy, or build on an'
        Write-Host '  unmanaged PC. Ask your administrator otherwise.'
        Write-Host ''
    }

    $ep = Get-ExecutionPolicy
    if ($ep -eq 'Restricted' -or $ep -eq 'AllSigned') {
        Write-Host ''
        Write-Host "NOTE: PowerShell execution policy is '$ep'." -ForegroundColor Yellow
        Write-Host '  This run is fine (it was launched with -ExecutionPolicy Bypass), but to run'
        Write-Host '  .ps1 files normally, either:'
        Write-Host '    Set-ExecutionPolicy -Scope CurrentUser RemoteSigned'
        Write-Host '  or always start through chromium_build_win.bat (it passes Bypass for you).'
        Write-Host ''
    }
}

Test-PowerShellEnvironment

# ---------------------------------------------------------------------------
#  Defaults
# ---------------------------------------------------------------------------
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }

# Shared git/depot_tools/bootstrap logic (also used by prepare_win_toolchain.ps1).
$BootstrapScript = Join-Path $ScriptDir 'bootstrap_depot_tools.ps1'
if (-not (Test-Path -LiteralPath $BootstrapScript)) {
    throw "Could not find $BootstrapScript (required for git/depot_tools bootstrap)."
}
. $BootstrapScript

$Root          = if ($env:CHROMIUM_OFFLINE_ROOT) { $env:CHROMIUM_OFFLINE_ROOT } else { $ScriptDir }  # download root
$SrcDirName    = 'src'                            # --dest-name: repository directory name under <root>
$DestNameExplicit = $false                        # true when the user passed --dest-name
$VersionReq    = 'stable'                         # stable | <tag> | <branch>
$MilestoneReq  = ''                               # optional: --milestone N
$ExplicitTargets = @()                            # empty -> use default targets
$DefaultTargets  = @('chrome', 'content_shell', 'headless_shell', 'mini_installer')
$BuildDir      = 'out\Default'
$Jobs          = 0                                # 0 -> let autoninja decide
$SkipFetch     = $false
$SkipHooks     = $false
$DepotToolsOnly = $false                          # only set up depot_tools, then stop
$Release       = $false                           # is_debug=false
$BootstrapGit  = $true
$DepotToolsVersion = ''              # optional depot_tools ref/commit to pin
$NoPinDepotTools = $false            # do not auto-pin depot_tools to Chromium DEPS
$MakeOfflineRepo = $false            # export a self-contained offline repo
$Cleanup        = $false             # after a successful export, delete the download workspace (opt-in)
$SccacheUrl = ''                     # optional sccache archive/exe URL override
$SccacheSha256 = ''                  # optional expected sccache archive SHA-256
$Retries       = 10                               # retries on transient failures (429/timeouts): fetch, sync, runhooks
$WithBranchHeads = $false                         # gclient --with_branch_heads (heavy!)
$WithTags        = $false                         # gclient --with_tags (heavy!)
$Pinned        = $false                           # fetch ONLY the requested revision
$RunGc         = $false                           # git gc --prune=now after checkout
$Pgo           = $false                           # download + use Windows PGO profiles
$Arch          = ''                               # target_cpu: '' (host) | x64 | x86 | arm64
$FullDeps      = $false                           # preset: download extra optional deps
$NoExtraDeps   = $false                           # skip the always-on extra custom_vars
$DepsRaw       = ''                               # raw custom_vars: "key=value,key=value"
$WinToolchain  = 'auto'                           # auto | 0 (local VS) | 1 (internal prebuilt)
$WinToolchainUrl = ''                             # DEPOT_TOOLS_WIN_TOOLCHAIN_BASE_URL (file|http)
$WinToolchainHash = ''                            # local <hash>.zip is mapped via GYP_MSVS_HASH_*
$AddDefenderExclusions = $false
$ExtraGnArgs   = ''
$ShowHelp      = $false

# ---------------------------------------------------------------------------
#  Argument parsing (accepts both --name value and --name=value)
# ---------------------------------------------------------------------------
$argv = @($args)
$i = 0
while ($i -lt $argv.Count) {
    $raw = [string]$argv[$i]
    $opt = $raw
    $inline = $null
    if ($raw -match '^(--?[^=]+)=(.*)$') {
        $opt = $matches[1]
        $inline = $matches[2]
    }

    switch ($opt) {
        '--help'             { $ShowHelp = $true }
        '-h'                 { $ShowHelp = $true }
        '/?'                 { $ShowHelp = $true }
        '--release'          { $Release = $true }
        '--debug'            { $Release = $false }
        '--skip-fetch'       { $SkipFetch = $true }
        '--skip-hooks'       { $SkipHooks = $true }
        '--depot-tools-only' { $DepotToolsOnly = $true }
        '--only-depot-tools' { $DepotToolsOnly = $true }
        '--no-bootstrap-git' { $BootstrapGit = $false }
        '--no-pin-depot-tools' { $NoPinDepotTools = $true }
        '--make-offline-repo' { $MakeOfflineRepo = $true }
        '--offline-repo'      { $MakeOfflineRepo = $true }
        '--keep-original'     { Write-Warn2 '--keep-original is gone: the workspace is now KEPT by default (no flag needed).' }
        '--no-cleanup'        { Write-Warn2 '--no-cleanup is gone: the workspace is now KEPT by default (no flag needed).' }
        '--cleanup'           { $Cleanup = $true }
        '--no-win-toolchain' { $WinToolchain = '0' }
        '--with-branch-heads' { $WithBranchHeads = $true }
        '--with-tags'         { $WithTags = $true }
        '--pinned'            { $Pinned = $true }
        '--gc'                { $RunGc = $true }
        '--pgo'               { $Pgo = $true }
        '--full-deps'         { $FullDeps = $true }
        '--no-extra-deps'     { $NoExtraDeps = $true }
        '--add-defender-exclusions' { $AddDefenderExclusions = $true }
        '--src-dir' {
            Write-Host ''
            Write-Host ' ERROR: --src-dir was renamed to --dest-name (no alias is kept).' -ForegroundColor Red
            Write-Host ' Use: --dest-name <name>   (default: src)'
            Write-Host ''
            exit 3
        }
        default {
            $valueOptions = @('--dir', '--dest-name', '--version', '--milestone', '--target', '--targets', '--build-dir', '--jobs', '--gn-args', '--win-toolchain', '--win-toolchain-url', '--win-toolchain-hash', '--retries', '--arch', '--deps', '--depot-tools-version', '--sccache-url', '--sccache-sha256')
            if ($valueOptions -contains $opt) {
                $value = $inline
                if ($null -eq $value) {
                    $i++
                    if ($i -ge $argv.Count) { throw "Option $opt requires a value." }
                    $value = [string]$argv[$i]
                }
                switch ($opt) {
                    '--dir'       { $Root = $value }
                    '--dest-name' { $SrcDirName = $value; $DestNameExplicit = $true }
                    '--version'   { $VersionReq = $value }
                    '--milestone' { $MilestoneReq = $value }
                    '--target'    { $ExplicitTargets += $value }
                    '--targets'   { $ExplicitTargets += ($value -split ',' | Where-Object { $_ -ne '' }) }
                    '--build-dir' { $BuildDir = $value }
                    '--jobs'      { $Jobs = [int]$value }
                    '--gn-args'   { $ExtraGnArgs = $value }
                    '--win-toolchain' { $WinToolchain = $value }
                    '--win-toolchain-url' { $WinToolchainUrl = $value }
                    '--win-toolchain-hash' { $WinToolchainHash = $value }
                    '--retries'   { $Retries = [int]$value }
                    '--arch'      { $Arch = $value }
                    '--deps'      { $DepsRaw = $value }
                    '--depot-tools-version' { $DepotToolsVersion = $value }
                    '--sccache-url' { $SccacheUrl = $value }
                    '--sccache-sha256' { $SccacheSha256 = $value }
                }
            } else {
                Write-Host ''
                Write-Host " ERROR: unknown option: $raw" -ForegroundColor Red
                Write-Host ' Run --help to see the supported options.' -ForegroundColor Red
                Write-Host ''
                exit 3
            }
        }
    }
    $i++
}

if ($ExplicitTargets.Count -gt 0) { $Targets = $ExplicitTargets } else { $Targets = $DefaultTargets }

$WinToolchain = ([string]$WinToolchain).ToLowerInvariant()
if (@('auto', '0', '1') -notcontains $WinToolchain) {
    Write-Warning "Invalid --win-toolchain value '$WinToolchain' (expected auto, 0 or 1); using auto."
    $WinToolchain = 'auto'
}
if ($WinToolchainUrl) {
    # A toolchain archive URL is only honored by the prebuilt-toolchain code
    # path (DEPOT_TOOLS_WIN_TOOLCHAIN=1), so imply it.
    $WinToolchain = '1'
}

# Normalize/validate --arch. Empty means "let GN pick the host default" (x64 on
# an x64 host). Setting target_cpu lets an x64 host cross-compile for x86/arm64.
if ($Arch) {
    $Arch = $Arch.ToLowerInvariant()
    if (@('x64', 'x86', 'arm64') -notcontains $Arch) {
        Write-Warning "Invalid --arch value '$Arch' (expected x64, x86 or arm64); using the host default."
        $Arch = ''
    }
}

if ($Pgo) {
    # PGO profile data only applies to optimized builds, so keep the intent as
    # release (the build script still needs chrome_pgo_phase=2 explicitly).
    $Release = $true
    if ($SkipHooks) {
        Write-Warning '--pgo needs "gclient runhooks" to download the profiles; --skip-hooks prevents that.'
    }
}

function Show-Help {
    Write-Host @"
Usage: chromium_download_win.ps1 [options]

Downloads Chromium, its dependencies and the complete Windows toolchain
(no Visual Studio required). This script NEVER builds; use
chromium_build_win.bat afterwards (it works without network access).

Options:
  --dir PATH            Download under PATH.
                        Default: this script's directory.
                        Layout: <PATH>\src (source) and <PATH>\depot_tools.
  --dest-name NAME      Repository directory name under --dir (default: src).
                        If omitted and <dir>\src is not a checkout, the script
                        uses <dir>\.gclient's solution name, the only directory
                        with init_tools\.offline_repo.state, or the only one
                        with chrome\VERSION. Multiple candidates -> error.
                        The offline repository is rooted at <PATH>\NAME.
                        It NEVER renames an existing <dir>\src: if NAME is
                        missing and src is a checkout, the script exits and
                        prints the manual Move-Item command (rename it yourself).
  --version VER         Chromium revision (branch or tag) to download:
                          stable / latest      latest stable release (default)
                          131.0.6778.85        an exact release tag
                          7871                 a branch (refs/branch-heads/7871)
                          main / refs/heads/...  a branch/ref
                        If the requested revision cannot be found, the latest
                        stable release is used instead.
  --milestone N         Instead of --version, pick the latest stable release of
                        milestone N (e.g. --milestone 131).
  (--target/--targets/--build-dir/--release/--debug/--jobs/--gn-args/--arch
   are accepted for compatibility but ignored: this script does not build.)
  --retries N           Retry fetch/sync/runhooks N times on transient failures
                        such as HTTP 429 rate limiting (default: 10).
  --win-toolchain V     DEPOT_TOOLS_WIN_TOOLCHAIN: auto (default), 0 or 1.
                        auto -> 0 if a local Visual Studio is present, else 1.
                        0 = use a locally installed Visual Studio. REQUIRED for
                            external users, because the prebuilt toolchain is
                            Google-internal.
                        1 = Google-internal prebuilt toolchain (internal network
                            or authenticated gsutil only).
  --no-win-toolchain    Shortcut for --win-toolchain 0.
  --win-toolchain-url URL
                        Use a prebuilt toolchain archive instead of a local
                        Visual Studio or the Google-internal bucket. This sets
                        DEPOT_TOOLS_WIN_TOOLCHAIN_BASE_URL and implies
                        --win-toolchain 1, so NO Visual Studio is needed.
                        URL is a DIRECTORY that contains "<toolchain-hash>.zip":
                          file://D:/win_toolchain/       (local folder)
                          https://host/win_toolchain/    (http/https mirror)
                        The required <toolchain-hash> is printed by a failing
                        run as "desired_hash: <hash>"; place <hash>.zip in that
                        folder. Obtain the .zip once from a machine that already
                        has the toolchain (copy
                        src\third_party\depot_tools\win_toolchain\vs_files) or
                        from your internal mirror. Example:
                          --win-toolchain-url "file://D:/win_toolchain/"
                        Note: get_toolchain_if_necessary.py also strips a
                        leading "file://", so "file:///D:/win_toolchain/" works.
                        If the archive was built locally with
                        prepare_win_toolchain.ps1 (its name is not the canonical
                        hash), the script maps it automatically for local dirs,
                        or pass --win-toolchain-hash <local-hash> (e.g. for
                        http). Build such an archive with:
                          prepare_win_toolchain.bat --dir D:\wt --chromium-src <src>
  --with-branch-heads   Pass --with_branch_heads to gclient when switching to a
                        branch. This fetches EVERY release branch and can add
                        many GB to src\.git - leave it off unless gclient fails.
  --with-tags           Pass --with_tags to gclient when switching to a tag
                        (fetches EVERY tag: potentially many GB). Not needed
                        for a normal build, and not needed when --version is a
                        single release tag: only that tag is fetched then.
                        Also see PIT-016: the default is git's "--no-tags".
  --pinned              Fetch ONLY the requested revision (skip the intermediate
                        shallow sync of main). Smallest possible .git when you
                        know the version up front.
  --gc                  Run "git gc --prune=now" in src after checkout to
                        reclaim unreachable objects.
  --pgo                 Keep the Windows PGO profiles and mark the build as PGO.
                          * checkout_pgo_profiles=True is ALREADY the default, so
                            the gclient runhooks hook downloads src/chrome/build/
                            pgo_profiles/*.profdata (several hundred MB);
                          * this flag only overrides --no-extra-deps /
                            --deps checkout_pgo_profiles=False, or makes the
                            intent explicit;
                          * for the build step pass --args
                            "chrome_pgo_phase=2" (and is_debug=false) to use them.
  --arch ARCH           Output CPU architecture: x64 (host default), x86 or
                        arm64. Sets GN target_cpu; x86/arm64 are cross-compiled
                        on an x64 host. arm64 output runs only on Windows on Arm.
  --full-deps           Enable a curated set of extra optional downloads so the
                        checkout works offline later: clang-tidy, clangd, clang
                        coverage tools, PGO profiles, bazelisk, libaom/libvpx
                        test data, WPR archives (the last is large).
  --no-extra-deps       Do not force the always-on extra custom_vars
                        (checkout_pgo_profiles, checkout_clang_coverage_tools).
                        Individual ones can also be disabled with
                        --deps "checkout_pgo_profiles=False".
  --deps K=V,K=V        Set arbitrary .gclient custom_vars (DEPS variables),
                        e.g. --deps "checkout_clangd=True,checkout_wpr_archives=True".
                        Applied before sync; --deps overrides the defaults above.
  --add-defender-exclusions
                        Add this download root to Windows Defender exclusions
                        (needs Administrator). Helps prevent Defender from
                        quarantining CIPD packages during fetch.
  --skip-fetch          Do not fetch; use an existing checkout.
  --skip-hooks          Do not run gclient hooks (skips toolchain download).
  --depot-tools-only    Only clone + bootstrap depot_tools to a usable state
                        (git config, python/CIPD bootstrap) and stop; do NOT
                        download Chromium, sync deps or run hooks.
                        Combine with --dir to choose where it lands.
  --no-bootstrap-git    Never auto-download PortableGit.
  --depot-tools-version VER
                        Pin depot_tools to VER (commit/tag/branch) using the
                        shared bootstrap_depot_tools.ps1.
                        If omitted, the script resolves the exact depot_tools
                        commit pinned by the requested Chromium version's DEPS
                        and checks out that commit before building.
  --no-pin-depot-tools  Do not auto-resolve/pin depot_tools to the Chromium
                        DEPS commit. Existing depot_tools is left as-is; a
                        missing one is cloned at latest main.
  --make-offline-repo   After fetch + gclient runhooks, export a self-contained
                        offline repository (the remaining steps still apply):
                          * back up ALL .git dirs to <root>\src_git_bak and all
                            .gitignore files to <root>\src_gitignore_bak,
                            then wipe them and git init a FRESH repository
                            (no Chromium history, no submodule pointers)
                          * commit 1/2: original source tree
                          * re-extract the pristine win_toolchain from
                            <hash>.zip and mark that path "-text -diff" in
                            .gitattributes (otherwise *.h text eol=lf rewrites
                            CRLF and the toolchain hash check deletes it;
                            see PIT-020)
                          * name the branch after the version: main / b<BUILD>
                            (e.g. b7871; see ADR-008)
                          * copy gclient config into <src>\init_tools/<MAJOR>/config
                          * copy depot_tools into <src>\init_tools/<MAJOR>/depot_tools
                            (the original is kept unless --cleanup is given)
                          * download sccache into <src>\init_tools/<MAJOR>/scache
                          * copy the Windows scripts + README + args_default.gn
                            into <src>\init_tools/win
                          * generate <src>\init_tools/win/env.bat + env.ps1
                          * append an ignore block to <src>\.gitignore
                          * git add (including downloaded deps) and commit 2/2:
                            init_tools
                          * write <src>\init_tools\.offline_repo.state (hidden
                            completion marker, committed with commit 2/2).
                            A later run with the same branch/version - and, when
                            --win-toolchain-url is given, the same toolchain
                            archive - skips fetch/sync/hooks/export entirely.
                            This check runs even WITHOUT --make-offline-repo.
                            If the snapshot exists but the request differs, the
                            script refuses to update it (exit 3) unless
                            --make-offline-repo is given: an implicit update
                            would checkout the real branch and delete init_tools.
                          (paths are derived from the script location, so the
                           whole tree can be moved or renamed)
  --cleanup             After BOTH commits succeed, delete the download
                        workspace: src_git_bak / src_gitignore_bak, the root
                        .gclient*/.gcs* files, <root>\.cipd, <root>\depot_tools
                        and the sccache build cache. OFF by default: without
                        --cleanup everything is kept, so a later run can resume
                        or re-export cheaply. On failure nothing is deleted.
  --sccache-url URL     Override the sccache archive/exe URL (default: latest
                        Mozilla GitHub release, Windows x86_64 zip).
  --sccache-sha256 H    Expected SHA-256 for --sccache-url (optional).
  -h, --help            Show this help.

Examples:
  # Download and prepare a normal build workspace
  .\chromium_download_win.bat --dir D:\build --version 7871

  # Download + hooks + export a self-contained offline repo (branch 7871)
  .\chromium_download_win.bat --dir D:\offline --version 7871 --make-offline-repo

  # Same, but delete the reusable download workspace after BOTH commits
  .\chromium_download_win.bat --dir D:\offline --version 7871 --make-offline-repo --cleanup

  # Exact tag + custom sccache archive
  .\chromium_download_win.bat --dir D:\offline --version 150.0.7871.290 ^
      --make-offline-repo --sccache-url "https://github.com/mozilla/sccache/releases/download/v0.19.0/sccache-v0.19.0-x86_64-pc-windows-msvc.zip"

  # Only prepare depot_tools (no source download)
  .\chromium_download_win.bat --dir D:\tools --depot-tools-only
  
  .\chromium_download_win.bat --dir D:\chromium --version 7871  --win-toolchain-url "file://D:/win_toolchain_archive"
  .\chromium_download_win.bat --dir D:\chromium --version 7871  --win-toolchain-url "file://D:/win_toolchain_archive" --dest-name chromium150
  .\chromium_download_win.bat --dir D:\chromium --version 7871  --win-toolchain-url "file://D:/win_toolchain_archive" --make-offline-repo
  .\chromium_download_win.bat --dir D:\chromium --version 7871  --win-toolchain-url "file://D:/win_toolchain_archive" --make-offline-repo --cleanup
  .\chromium_download_win.ps1 --dir D:\chromium --version 7871  --win-toolchain-url "file://D:/win_toolchain_archive"
  .\chromium_download_win.ps1 --dir D:\chromium --version 7871  --win-toolchain-url "file://D:/win_toolchain_archive" --dest-name chromium150
  .\chromium_download_win.ps1 --dir D:\chromium --version 7871  --win-toolchain-url "file://D:/win_toolchain_archive" --make-offline-repo
  .\chromium_download_win.ps1 --dir D:\chromium --version 7871  --win-toolchain-url "file://D:/win_toolchain_archive" --make-offline-repo --cleanup

Then build (no network access needed):
  .\chromium_build_win.bat --dir D:\build --release --targets content_shell

If PowerShell refuses to run this script:
  * "running scripts is disabled on this system"
        Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
    or launch via chromium_download_win.bat (which uses -ExecutionPolicy Bypass).
  * File came from the Internet / "not digitally signed"
        Unblock-File -Path .\chromium_download_win.ps1
  * ConstrainedLanguage / AppLocker / WDAC on a managed PC
        Scripting may be blocked by policy and can only be changed by an
        administrator; otherwise run on an unmanaged machine.
"@
}

if ($ShowHelp) { Show-Help; exit 0 }

# ---------------------------------------------------------------------------
#  Paths / constants
# ---------------------------------------------------------------------------
$Root       = $Root.TrimEnd('\', '/')
$DepotTools = if ($env:DEPOT_TOOLS_PATH) { $env:DEPOT_TOOLS_PATH } else { Join-Path $Root 'depot_tools' }
$Chromium   = $Root                                      # gclient root (.gclient lives here)
$SrcDirName = $SrcDirName.Trim().TrimEnd('\', '/')
if (-not $SrcDirName -or $SrcDirName -match '[\\/]' -or $SrcDirName -eq '.' -or $SrcDirName -eq '..') {
    throw "Invalid --dest-name '$SrcDirName': it must be a single directory name, not a path."
}
$Src = Join-Path $Root $SrcDirName

# Resolve the repository directory when --dest-name was NOT given.
# Order (A):
#   1. <root>\.gclient solution name (kept by default, absent after --cleanup)
#   2. the ONLY <root>\*\init_tools\.offline_repo.state (also the legacy name)
#   3. the ONLY <root>\*\chrome\VERSION
#   4. default <root>\src (fresh download)
# Multiple candidates are a hard error: never fall back to src and create a
# second checkout.
if (-not $DestNameExplicit) {
    $resolvedDir = ''
    $resolvedHow = ''

    # 1. workspace config (.gclient is deleted by --cleanup)
    $rootGclient = Join-Path $Root '.gclient'
    if (Test-Path -LiteralPath $rootGclient -PathType Leaf) {
        $cfgText = Get-Content -LiteralPath $rootGclient -Raw -ErrorAction SilentlyContinue
        $gname = ''
        if ($cfgText -match '"name"\s*:\s*"([^"]+)"') { $gname = $matches[1] }
        elseif ($cfgText -match "'name'\s*:\s*'([^']+)'") { $gname = $matches[1] }
        if ($gname -and $gname -notmatch '[\\/]' -and $gname -ne '.' -and $gname -ne '..') {
            $cand = Join-Path $Root $gname
            if (Test-Path -LiteralPath (Join-Path $cand 'chrome\VERSION')) {
                $resolvedDir = $cand
                $resolvedHow = '.gclient'
            }
        }
    }

    # 2. the completion marker survives --cleanup (it is committed in init_tools)
    if (-not $resolvedDir) {
        $markerDirs = @()
        foreach ($d in @(Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue)) {
            $hasMarker = (Test-Path -LiteralPath (Join-Path $d.FullName 'init_tools\.offline_repo.state')) -or
                         (Test-Path -LiteralPath (Join-Path $d.FullName 'init_tools\offline_repo.state'))
            if ($hasMarker -and (Test-Path -LiteralPath (Join-Path $d.FullName 'chrome\VERSION'))) {
                $markerDirs += $d.FullName
            }
        }
        if ($markerDirs.Count -eq 1) {
            $resolvedDir = $markerDirs[0]
            $resolvedHow = 'completion marker'
        } elseif ($markerDirs.Count -gt 1) {
            Write-Err "Multiple exported repositories found under $Root; pass --dest-name <name>:"
            foreach ($m in $markerDirs) { Write-Host "    $m" }
            exit 3
        }
    }

    # 3. a single Chromium checkout with any directory name
    if (-not $resolvedDir) {
        $checkoutDirs = @(Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue |
                          Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'chrome\VERSION') } |
                          ForEach-Object { $_.FullName })
        if ($checkoutDirs.Count -eq 1) {
            $resolvedDir = $checkoutDirs[0]
            $resolvedHow = 'chrome\VERSION'
        } elseif ($checkoutDirs.Count -gt 1) {
            Write-Err "Multiple Chromium checkouts found under $Root; pass --dest-name <name>:"
            foreach ($c in $checkoutDirs) { Write-Host "    $c" }
            exit 3
        }
    }

    if ($resolvedDir) {
        $SrcDirName = Split-Path -Leaf $resolvedDir
        $Src = $resolvedDir
        if ($resolvedHow -ne '.gclient' -and $SrcDirName -ne 'src') {
            Write-Warn2 "Using detected repository directory ($resolvedHow): $Src"
            Write-Warn2 'Pass --dest-name <name> to make this explicit.'
        }
    }
}

# --dest-name is a NEW destination name, never an instruction to rename an
# existing checkout. Moving a completed snapshot is a manual operation (it can
# be locked by Explorer/IDE/AV, and changes the repo identity).
if ($DestNameExplicit -and $SrcDirName -ne 'src') {
    $legacySrc = Join-Path $Root 'src'
    $legacyIsCheckout = Test-Path -LiteralPath (Join-Path $legacySrc 'chrome\VERSION')
    if (-not (Test-Path -LiteralPath $Src) -and $legacyIsCheckout) {
        Write-Host ''
        Write-Host '============================================================================' -ForegroundColor Yellow
        Write-Host ' Existing checkout found at <root>\src' -ForegroundColor Yellow
        Write-Host '============================================================================' -ForegroundColor Yellow
        Write-Host " --dest-name '$SrcDirName' means a DIFFERENT destination; it does not"
        Write-Host ' rename an existing checkout (that is a manual operation).'
        Write-Host ''
        Write-Host ' Options:'
        Write-Host '   * reuse it          : omit --dest-name (or use --dest-name src)'
        Write-Host '   * rename it manual  : close anything using it, then run'
        Write-Host ('       Move-Item "{0}" "{1}"' -f $legacySrc, $Src)
        Write-Host '   * use another root  : --dir <other-root>'
        Write-Host ''
        Write-Host ' Nothing was changed.'
        Write-Host '============================================================================' -ForegroundColor Yellow
        exit 3
    }
    if (-not (Test-Path -LiteralPath $Src) -and (Test-Path -LiteralPath $legacySrc) -and -not $legacyIsCheckout) {
        Write-Warn2 "<root>\src exists but is not a Chromium checkout; leaving it untouched (new repository: $Src)."
    }
}
$SrcName    = Split-Path -Leaf $Src                      # never hardcode "src" anywhere below
$srcPrefix  = $Src.TrimEnd('\') + '\'
$rootPrefix = $Root.TrimEnd('\') + '\'
$srcHasVersion = Test-Path -LiteralPath (Join-Path $Src 'chrome\VERSION')

# An activated env.bat also prepends <root>\<repo>\init_tools\...\depot_tools and
# \scache to PATH. Bootstrap would then use the OLD snapshot's git.bat. Drop
# those entries; the new depot_tools is prepended after bootstrapping.
$pathKept = @()
foreach ($p in @($env:PATH -split ';')) {
    if (-not $p) { continue }
    $pTrim = $p.TrimEnd('\')
    if ($pTrim -like ($rootPrefix + '*\init_tools*')) { continue }
    if ($pTrim -like ($rootPrefix + '*\scache*')) { continue }
    $pathKept += $p
}
$env:PATH = ($pathKept -join ';')

# A build-time env value = inside <src>, or under <root>\*\init_tools (covers a
# renamed --dest-name). These describe the exported snapshot, not the workspace.
$dtEnv = if ($env:DEPOT_TOOLS_PATH) { $env:DEPOT_TOOLS_PATH.TrimEnd('\') } else { '' }
$gcEnv = if ($env:GCLIENT_FILE) { $env:GCLIENT_FILE.TrimEnd('\') } else { '' }
$dtBuildEnv = [bool]$dtEnv -and (($dtEnv -like ($srcPrefix + '*')) -or
              (($dtEnv -like ($rootPrefix + '*')) -and ($dtEnv -like '*\init_tools\*')))
$gcBuildEnv = [bool]$gcEnv -and (($gcEnv -like ($srcPrefix + '*')) -or
              (($gcEnv -like ($rootPrefix + '*')) -and ($gcEnv -like '*\init_tools\*')))

# init_tools\win\env.bat exports DEPOT_TOOLS_PATH / GCLIENT_FILE for BUILDING.
# fetch.bat/gclient follow those variables themselves; using them for a download
# writes configs into <src>\init_tools (or fails when that directory is gone).
if ($dtBuildEnv) {
    Write-Warn2 "Ignoring DEPOT_TOOLS_PATH (build-time value inside the source tree): $($env:DEPOT_TOOLS_PATH)"
    Write-Warn2 "Using $Root\depot_tools instead."
    $DepotTools = Join-Path $Root 'depot_tools'
}

# A previous --make-offline-repo run moves depot_tools into
# <src>\init_tools\<MAJOR>\depot_tools (materialized snapshot, no .git).
# Reuse it instead of cloning depot_tools again when <root>\depot_tools is gone
# AND the source really is a checkout.
if (-not (Test-Path -LiteralPath $DepotTools) -and $srcHasVersion) {
    $exportedDt = @(Get-ChildItem -Path (Join-Path $Src 'init_tools\*\depot_tools') -Directory -ErrorAction SilentlyContinue |
                      Sort-Object Name -Descending)
    if ($exportedDt.Count -gt 0) {
        $DepotTools = $exportedDt[0].FullName
        Write-Ok "Reusing exported depot_tools: $DepotTools"
    }
}
$LegacyChromium = Join-Path $Root 'chromium'             # old layout, migrated after fetch
$GclientFile = if ($env:GCLIENT_FILE) { $env:GCLIENT_FILE } else { Join-Path $Root '.gclient' }
if ($gcBuildEnv) {
    Write-Warn2 "Ignoring GCLIENT_FILE (build-time value inside the source tree): $($env:GCLIENT_FILE)"
    Write-Warn2 "Using $Root\.gclient instead."
    $GclientFile = Join-Path $Root '.gclient'
}
# fetch.bat / gclient.py read these environment variables themselves. Keep the
# child environment in sync with the resolved workspace paths, otherwise fetch
# still writes to the old init_tools config (this exact failure) or the wrong
# depot_tools.
$env:DEPOT_TOOLS_PATH = $DepotTools
$env:GCLIENT_FILE     = $GclientFile

# fetch.bat/gclient also need the config DIRECTORY to exist; an external
# GCLIENT_FILE may point at a folder that was never created.
$gclientDir = Split-Path -Parent $GclientFile
if ($gclientDir -and -not (Test-Path -LiteralPath $gclientDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $gclientDir | Out-Null
}
$ToolsDir   = Join-Path $Root 'tools'

$FetchBat     = Join-Path $DepotTools 'fetch.bat'
$GclientBat   = Join-Path $DepotTools 'gclient.bat'
$GnBat        = Join-Path $DepotTools 'gn.bat'
$AutoninjaBat = Join-Path $DepotTools 'autoninja.bat'

$DashApi  = 'https://chromiumdash.appspot.com/fetch_releases?channel=Stable&platform=Windows&num={0}'
$GitRepoUrl    = 'https://chromium.googlesource.com/chromium/tools/depot_tools.git'
$ChromiumUrl   = 'https://chromium.googlesource.com/chromium/src.git'

# ---------------------------------------------------------------------------
#  External process helper (throws on non-zero exit code)
# ---------------------------------------------------------------------------
function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory
    )
    $display = "$FilePath $($ArgumentList -join ' ')"
    Write-Host "  > $display" -ForegroundColor DarkGray

    if ($WorkingDirectory) { Push-Location -LiteralPath $WorkingDirectory }
    try {
        & $FilePath @ArgumentList
    } finally {
        if ($WorkingDirectory) { Pop-Location }
    }

    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE`: $display"
    }
}

# gclient's --gclientfile accepts a FILE NAME only ("--gclientfile target must be
# a filename, not a path"), so run gclient from the directory that holds the
# file and pass just the leaf name.
function Invoke-Gclient {
    param(
        [Parameter(Mandatory = $true)][string]$GclientFile,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $dir = Split-Path -Parent $GclientFile
    if (-not $dir) { $dir = $Chromium }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        # Never fail with a raw "path not found" from Push-Location; a config
        # directory can be missing after a partial/cleaned export.
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $name = Split-Path -Leaf $GclientFile
    Invoke-Native -FilePath $GclientBat -ArgumentList (@($Arguments) + @('--gclientfile', $name)) -WorkingDirectory $dir
}

# git/depot_tools bootstrap now lives in bootstrap_depot_tools.ps1 (shared with
# prepare_win_toolchain.ps1). The legacy Ensure-Git/Get-RemoteFile functions
# were removed to keep a single implementation.

# ---------------------------------------------------------------------------
#  Optional Windows Defender exclusions (avoids quarantine of CIPD packages)
# ---------------------------------------------------------------------------
function Add-DefenderExclusions {
    if (-not (Get-Command Add-MpPreference -ErrorAction SilentlyContinue)) {
        Write-Warn2 'Windows Defender cmdlets are not available; skipping exclusions.'
        return
    }
    $paths = @($Root, $Chromium, (Join-Path $env:USERPROFILE '.cipd'))
    foreach ($p in $paths) {
        try {
            Add-MpPreference -ExclusionPath $p -ErrorAction Stop
            Write-Ok "Defender exclusion added: $p"
        } catch {
            Write-Warn2 "Could not add Defender exclusion for '$p' (run as Administrator): $($_.Exception.Message)"
        }
    }
}

# ---------------------------------------------------------------------------
#  Detect a locally installed Visual Studio with the MSVC C++ tools.
#  Required when DEPOT_TOOLS_WIN_TOOLCHAIN=0 (the external-user path, because
#  the prebuilt toolchain at gs://chrome-wintoolchain is Google-internal).
# ---------------------------------------------------------------------------
function Test-VisualStudio {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        $out = & $vswhere -latest -products '*' `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) { return $true }
    }
    if ($env:VSINSTALLDIR -or $env:VCINSTALLDIR) { return $true }
    if (Test-Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\SxS\VS7') { return $true }
    return $false
}

# ---------------------------------------------------------------------------
#  Read the canonical toolchain hash from the checked-out Chromium revision.
#  vs_toolchain.py maps it to our own hash via GYP_MSVS_HASH_<canonical>.
# ---------------------------------------------------------------------------
function Get-CanonicalToolchainHash {
    $f = Join-Path $Src 'build\vs_toolchain.py'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    $txt = Get-Content -LiteralPath $f -Raw
    if ($txt -match "TOOLCHAIN_HASH\s*=\s*'([0-9a-fA-F]+)'") { return $matches[1] }
    return $null
}

# ---------------------------------------------------------------------------
#  Version resolution via Chromium Dash
# ---------------------------------------------------------------------------
function Get-StableReleases {
    param([int]$Num = 50, [int]$Milestone = 0)
    $uri = $DashApi -f $Num
    if ($Milestone -gt 0) { $uri = "$uri&milestone=$Milestone" }
    try {
        $data = Invoke-RestMethod -UseBasicParsing -Uri $uri -TimeoutSec 60
    } catch {
        Write-Warn2 "Could not reach Chromium Dash: $($_.Exception.Message)"
        return @()
    }
    $list = @($data)
    if ($Milestone -gt 0) {
        $list = @($list | Where-Object { [int]$_.milestone -eq $Milestone })
    }
    return $list
}

function Resolve-RequestedVersion {
    param([string]$Requested)

    $r = $Requested.Trim()
    $resolved = [ordered]@{ Kind = 'main'; Ref = 'main'; Note = 'main branch'; Display = 'main' }

    if ($r -eq '' -or $r -match '^(stable|latest|release)$') {
        $rel = Get-StableReleases -Num 5
        if ($rel.Count -gt 0) {
            $resolved.Kind = 'tag'; $resolved.Ref = $rel[0].version
            $resolved.Note = 'latest stable release'; $resolved.Display = $rel[0].version
        } else {
            $resolved.Note = 'stable lookup failed, using main'
        }
        return $resolved
    }

    # Exact release tag, e.g. 131.0.6778.85
    if ($r -match '^\d+\.\d+\.\d+\.\d+$') {
        $resolved.Kind = 'tag'; $resolved.Ref = $r; $resolved.Note = 'release tag'; $resolved.Display = $r
        return $resolved
    }

    # A bare number is a Chromium branch number, e.g. 7871 -> refs/branch-heads/7871
    if ($r -match '^\d+$') {
        $resolved.Kind = 'branch'; $resolved.Ref = "refs/branch-heads/$r"; $resolved.Note = "branch-heads/$r"; $resolved.Display = $r
        return $resolved
    }

    if ($r -match '^branch-heads/') {
        $resolved.Kind = 'branch'; $resolved.Ref = "refs/$r"; $resolved.Note = $r; $resolved.Display = $r
        return $resolved
    }

    # main / beta / refs/heads/... / any other ref
    $resolved.Kind = 'branch'; $resolved.Ref = $r; $resolved.Note = 'branch/ref'; $resolved.Display = $r
    return $resolved
}

function Resolve-Milestone {
    param([int]$Milestone)

    $resolved = [ordered]@{ Kind = 'tag'; Ref = 'main'; Note = ''; Display = '' }
    $rel = Get-StableReleases -Num 50 -Milestone $Milestone
    if ($rel.Count -gt 0) {
        $resolved.Ref = $rel[0].version
        $resolved.Note = "latest stable of milestone $Milestone"
        $resolved.Display = $rel[0].version
        return $resolved
    }

    Write-Warn2 "Milestone $Milestone not found in the stable channel - falling back to latest stable."
    $rel = Get-StableReleases -Num 5
    if ($rel.Count -gt 0) {
        $resolved.Ref = $rel[0].version
        $resolved.Note = 'latest stable (milestone fallback)'
        $resolved.Display = $rel[0].version
    } else {
        $resolved.Kind = 'main'; $resolved.Ref = 'main'; $resolved.Note = 'stable lookup failed, using main'; $resolved.Display = 'main'
    }
    return $resolved
}

# ---------------------------------------------------------------------------
#  Check whether a ref actually exists upstream.
#  Uses the gitiles +log endpoint (tiny HTTP request, no git objects):
#    200 with a commit -> found
#    404               -> missing
#    anything else     -> unknown (network problem; do NOT treat as missing)
# ---------------------------------------------------------------------------
function Get-ChromiumRefStatus {
    param([Parameter(Mandatory = $true)][string]$Ref)
    $uri = 'https://chromium.googlesource.com/chromium/src/+log/' + $Ref + '?format=JSON&n=1'
    try {
        $resp = Invoke-WebRequest -UseBasicParsing -Uri $uri -TimeoutSec 60
        $json = ($resp.Content -replace "^\)\]\}'\s*", "") | ConvertFrom-Json
        if ($json.log -and @($json.log).Count -gt 0 -and $json.log[0].commit) { return 'found' }
        return 'unknown'
    } catch {
        $code = $null
        try { $code = [int]$_.Exception.Response.StatusCode } catch { $code = $null }
        if ($code -eq 404) { return 'missing' }
        return 'unknown'
    }
}

# ---------------------------------------------------------------------------
#  Check out a resolved revision + sync dependencies
# ---------------------------------------------------------------------------
# Return the 40-hex sha of the current HEAD, or '' when it cannot be resolved.
# Used to pin "gclient sync --revision <name>@<sha>": a ref name (e.g.
# refs/remotes/origin/main) fails gclient's sha_only check and triggers a
# depth-less full fetch on a shallow repo (PIT-016).
# ---------------------------------------------------------------------------
function Get-HeadSha {
    param([Parameter(Mandatory = $true)][string]$SourceDir)
    try {
        $sha = ((& git -C $SourceDir rev-parse HEAD 2>$null) | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and $sha -match '^[0-9a-fA-F]{40}$') { return $sha }
    } catch { }
    return ''
}

# ---------------------------------------------------------------------------
# Move dependency repos that gclient's "-D" cleanup cannot handle.
#
# A previously interrupted/429-failed fetch can leave a dependency directory
# with an empty .git (no commits), while .gclient_entries still records its
# expected revision. When the target DEPS no longer contains that dependency,
# gclient's excess-deps cleanup runs "git diff --name-status <recorded-sha>" to
# look for local modifications and dies with:
#   fatal: bad object <sha>
# which aborts the whole sync (PIT-021).
#
# The same happens when the repo has a HEAD but is too shallow to contain the
# recorded revision. In both cases the checkout is unusable for the cleanup:
# move it to <root>\_bad_deps\ and let gclient re-clone it if the target DEPS
# still needs it.
# ---------------------------------------------------------------------------
function Remove-BrokenDependencyRepos {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Src,
        [Parameter(Mandatory = $true)][string]$SrcName
    )
    # Native git commands write to stderr for the EXPECTED "missing object" case.
    # With $ErrorActionPreference = 'Stop' (set at script scope) PowerShell turns
    # that into a terminating NativeCommandError, which aborted the whole sync
    # attempt. Keep this helper non-terminating for native stderr; cmdlet failures
    # below request -ErrorAction Stop explicitly.
    $ErrorActionPreference = 'Continue'
    $entries = Join-Path $Root '.gclient_entries'
    if (-not (Test-Path -LiteralPath $entries)) { return }
    $content = Get-Content -LiteralPath $entries -Raw
    $badRoot = Join-Path $Root '_bad_deps'
    $moved = 0
    $prefix = '^' + [regex]::Escape($SrcName) + '/'
    # Dependencies still referenced by the checked-out DEPS are NOT touched:
    # gclient fetches/updates those itself (even when the local repo is empty).
    # Only deps that the target revision dropped (excess deps) hit the -D cleanup
    # path that cannot diff an empty repo (PIT-021).
    $depsFile = Join-Path $Src 'DEPS'
    $depsText = if (Test-Path -LiteralPath $depsFile) { Get-Content -LiteralPath $depsFile -Raw } else { '' }
    foreach ($m in [regex]::Matches($content, "'([^']+)'\s*:\s*'([^']*)'")) {
        $key = $m.Groups[1].Value
        $url = $m.Groups[2].Value
        if ($key -match ':') { continue }                 # CIPD single-file entry
        if ($key -notmatch $prefix) { continue }
        $rel = $key.Substring($SrcName.Length + 1).Replace('/', '\')
        # Match the DEPS entry whose path ENDS with /<rel> (the key is quoted
        # and always carries a solution prefix like 'src/'), so a same-prefix
        # path (e.g. src/third_party/foobar) cannot be mistaken for this dep.
        $relKey = '/' + [regex]::Escape($rel.Replace('\', '/')) + "'\s*:"
        if ($depsText -and ($depsText -match $relKey)) {
            continue                                       # still in DEPS -> let gclient update it
        }
        $full = Join-Path $Src $rel
        if (-not (Test-Path -LiteralPath $full -PathType Container)) { continue }
        if (-not (Test-Path -LiteralPath (Join-Path $full '.git'))) { continue }

        $ok = $false
        & git -C $full rev-parse --verify HEAD 1>$null 2>$null
        if ($LASTEXITCODE -eq 0) {
            $ok = $true
            $sm = [regex]::Match($url, '@([0-9a-fA-F]{40})')
            if ($sm.Success) {
                $sha = $sm.Groups[1].Value
                & git -C $full cat-file -e $sha 1>$null 2>$null
                if ($LASTEXITCODE -ne 0) { $ok = $false }
            }
        }
        if ($ok) { continue }

        $dest = Join-Path $badRoot $rel
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) -ErrorAction Stop | Out-Null
        if (Test-Path -LiteralPath $dest) {
            $dest = $dest + '.' + [guid]::NewGuid().ToString('N')
        }
        Move-PathWithRetry -Source $full -Destination $dest
        $moved++
        Write-Warn2 ("Moved unusable dependency repo: {0} -> {1}" -f $rel, $dest)
    }
    if ($moved -gt 0) {
        Write-Ok ("Unusable dependency repo(s) moved: {0} (see {1})" -f $moved, $badRoot)
    }
}

# ---------------------------------------------------------------------------
# Remove Python bytecode caches everywhere under $SourceDir. Must run BEFORE
# every commit: init_tools contains a fresh copy of depot_tools, whose own
# __pycache__/*.pyc would otherwise be force-added by "git add -A -f".
# ---------------------------------------------------------------------------
function Remove-PythonCaches {
    param([Parameter(Mandatory = $true)][string]$SourceDir)
    Write-Step 'Removing __pycache__ directories and *.pyc files'
    $dirs = @(Get-ChildItem -LiteralPath $SourceDir -Recurse -Force -Directory -Filter '__pycache__' -ErrorAction SilentlyContinue)
    foreach ($d in $dirs) {
        Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $d.FullName) { & cmd /c "rmdir /s /q `"$($d.FullName)`"" 2>$null | Out-Null }
    }
    $files = @(Get-ChildItem -LiteralPath $SourceDir -Recurse -Force -File -Filter '*.pyc' -ErrorAction SilentlyContinue)
    foreach ($f in $files) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
    Write-Ok ("Removed {0} __pycache__ dir(s) and {1} *.pyc file(s)." -f $dirs.Count, $files.Count)
}

# ---------------------------------------------------------------------------
# Belt-and-braces: drop any Python cache paths that still made it into the git
# INDEX (e.g. created between the cleanup and "git add" by a hook/tool).
# ---------------------------------------------------------------------------
function Remove-CachedPythonFiles {
    param([Parameter(Mandatory = $true)][string]$SourceDir)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & git -C $SourceDir rm -r --cached --ignore-unmatch ':(glob)**/__pycache__/**' ':(glob)**/*.pyc' 1>$null 2>$null
    $remaining = @(& git -C $SourceDir ls-files | Where-Object { $_ -match '(^|/)__pycache__/|\.pyc$' })
    if ($remaining.Count -gt 0) {
        foreach ($p in $remaining) { & git -C $SourceDir rm --cached -q -- $p 2>$null }
        Write-Ok ("Removed {0} Python cache path(s) from the index." -f $remaining.Count)
    }
    $ErrorActionPreference = $prev
}

# ---------------------------------------------------------------------------
# Remove the transient directories created by recovery/cleanup:
#   <root>\_bad_deps              (unusable dependency repos moved aside)
#   <root>\_bad_scm               (gclient's store for broken SCM checkouts)
#   <root>\_failed_export_git_*   (abandoned commit-1 repos from failed exports)
# They are outside the source tree and never part of the offline repository,
# so they are dropped after EVERY successful run (even without --cleanup).
# ---------------------------------------------------------------------------
function Remove-TransientDirs {
    param([Parameter(Mandatory = $true)][string]$Root)
    $targets = @()
    foreach ($name in @('_bad_deps', '_bad_scm')) {
        $p = Join-Path $Root $name
        if (Test-Path -LiteralPath $p) { $targets += $p }
    }
    foreach ($d in @(Get-ChildItem -LiteralPath $Root -Directory -Force -Filter '_failed_export_git_*' -ErrorAction SilentlyContinue)) {
        $targets += $d.FullName
    }
    foreach ($t in $targets) {
        Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $t) { & cmd /c "rmdir /s /q `"$t`"" 2>$null | Out-Null }
        if (Test-Path -LiteralPath $t) { Write-Warn2 "Could not fully remove: $t" }
        else { Write-Ok ("Removed transient directory: {0}" -f $t) }
    }
}

# ---------------------------------------------------------------------------
# OPT-IN cleanup of the download workspace (--cleanup). Called only after BOTH
# commits succeeded. Without --cleanup everything is kept, so a later run can
# reuse depot_tools/.gclient and resume or re-export cheaply.
# ---------------------------------------------------------------------------
function Remove-ExportScratch {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Src,
        [Parameter(Mandatory = $true)][string]$Major,
        [string]$GclientFile = ''
    )
    Write-Step 'Cleaning the download workspace (--cleanup)'

    foreach ($bak in @((Join-Path $Root 'src_git_bak'), (Join-Path $Root 'src_gitignore_bak'))) {
        if (Test-Path -LiteralPath $bak) {
            Remove-Item -LiteralPath $bak -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $bak) { & cmd /c "rmdir /s /q `"$bak`"" 2>$null | Out-Null }
            if (Test-Path -LiteralPath $bak) { Write-Warn2 "Could not fully remove backup: $bak" }
            else { Write-Ok "Removed backup: $bak" }
        }
    }

    # gclient state belongs to the download workspace, not to the repository.
    # Never delete the copy inside <src>\init_tools (GCLIENT_FILE may point at
    # it when reusing an exported repo).
    $configFiles = @('.gclient', '.gclient_entries', '.gclient_previous_custom_vars',
                     '.gclient_previous_sync_commits', '.gcs_entries')
    $srcPrefix = $Src.TrimEnd('\') + '\'
    foreach ($f in $configFiles) {
        $p = Join-Path $Root $f
        if ($f -eq '.gclient' -and $GclientFile -and ($GclientFile -ne $p) -and
            ($GclientFile -notlike ($srcPrefix + '*'))) {
            $p = $GclientFile
        }
        if (Test-Path -LiteralPath $p) {
            Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $p) { Write-Warn2 "Could not remove: $p" }
        }
    }
    Write-Ok "Removed .gclient*/.gcs* from $Root"

    $cipdDir = Join-Path $Root '.cipd'
    if (Test-Path -LiteralPath $cipdDir) {
        Remove-Item -LiteralPath $cipdDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $cipdDir) { & cmd /c "rmdir /s /q `"$cipdDir`"" 2>$null | Out-Null }
        if (Test-Path -LiteralPath $cipdDir) { Write-Warn2 "Could not fully remove: $cipdDir" }
        else { Write-Ok 'Removed .cipd' }
    }

    # The offline repo carries its own depot_tools snapshot; the download
    # workspace clone is only needed while exporting.
    $rootDt = Join-Path $Root 'depot_tools'
    if (Test-Path -LiteralPath $rootDt -PathType Container) {
        Remove-Item -LiteralPath $rootDt -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $rootDt) { & cmd /c "rmdir /s /q `"$rootDt`"" 2>$null | Out-Null }
        if (Test-Path -LiteralPath $rootDt) { Write-Warn2 "Could not fully remove: $rootDt" }
        else { Write-Ok "Removed original depot_tools: $rootDt" }
    }

    # sccache.exe is committed (part of the offline repo); its build cache is not.
    # Current location: <src>\out\.cache<MAJOR> (gitignored). The old location
    # (init_tools\<MAJOR>\scache\cache) is still removed for older snapshots.
    foreach ($scacheCacheDir in @(
        (Join-Path $Src ('init_tools\' + $Major + '\scache\cache')),
        (Join-Path $Src ('out\.cache' + $Major))
    )) {
        if (Test-Path -LiteralPath $scacheCacheDir) {
            Remove-Item -LiteralPath $scacheCacheDir -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $scacheCacheDir) { & cmd /c "rmdir /s /q `"$scacheCacheDir`"" 2>$null | Out-Null }
            if (Test-Path -LiteralPath $scacheCacheDir) { Write-Warn2 "Could not fully remove: $scacheCacheDir" }
            else { Write-Ok 'Removed sccache build cache (it is regenerated on the next build).' }
        }
    }

    Remove-TransientDirs -Root $Root
}

# ---------------------------------------------------------------------------
# Completion marker (<src>\init_tools\.offline_repo.state, hidden on Windows).
# It is committed with commit 2/2, so:
#   * the offline repo is self-describing and the marker travels with it;
#   * --cleanup leaves nothing behind in <root>;
#   * amending commit 2 (e.g. refreshing the scripts) does NOT invalidate it,
#     because the marker stores commit 1 only (never its own commit hash).
# Older locations (<src>\init_tools\offline_repo.state and
# <root>\.offline_repo.state) are still read for migration.
# The hidden attribute is cosmetic (git does not track it); the file itself is
# committed, so a fresh clone still gets the marker.
# ---------------------------------------------------------------------------
function Get-OfflineMarkerPath {
    param([Parameter(Mandatory = $true)][string]$Src)
    return (Join-Path $Src 'init_tools\.offline_repo.state')
}

function Get-LegacyOfflineMarkerPath {
    param([Parameter(Mandatory = $true)][string]$Root)
    return (Join-Path $Root '.offline_repo.state')
}

function Read-OfflineMarker {
    param(
        [Parameter(Mandatory = $true)][string]$Src,
        [string]$Root = ''
    )
    $candidates = @(
        (Get-OfflineMarkerPath -Src $Src),
        (Join-Path $Src 'init_tools\offline_repo.state')
    )
    if ($Root) { $candidates += (Get-LegacyOfflineMarkerPath -Root $Root) }
    $path = ''
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { $path = $c; break }
    }
    if (-not $path) { return $null }
    $m = @{}
    foreach ($line in @(Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)) {
        $line = $line -replace '^\uFEFF', ''
        if ($line -match '^([A-Za-z0-9_]+)=(.*)$') { $m[$matches[1]] = $matches[2] }
    }
    if (-not $m.ContainsKey('format')) { return $null }
    $m['_path'] = $path
    return $m
}

function Write-OfflineMarker {
    param(
        [Parameter(Mandatory = $true)][string]$Src,
        [Parameter(Mandatory = $true)][hashtable]$Values
    )
    $path = Get-OfflineMarkerPath -Src $Src
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    $keys = @('format', 'branch', 'kind', 'version', 'request', 'deps', 'ref',
              'commit1', 'toolchain_url', 'toolchain_hash',
              'toolchain_zip_size', 'toolchain_zip_mtime', 'canonical_hash',
              'finished')
    $lines = @()
    foreach ($k in $keys) {
        if ($Values.ContainsKey($k)) { $lines += ('{0}={1}' -f $k, $Values[$k]) }
    }
    Set-Content -LiteralPath $path -Value ($lines -join "`n") -Encoding UTF8
    # Hidden on Windows (cosmetic; not tracked by git). attrib is used because
    # FileAttributes would need System.IO, which ConstrainedLanguage blocks.
    & cmd /c "attrib +h `"$path`"" 2>$null | Out-Null
    return $path
}

# file:///D:/dir -> D:/dir ; http base gets a trailing slash (same as gclient).
function Resolve-ToolchainBaseUrl {
    param([string]$Url)
    if (-not $Url) { return '' }
    $u = $Url
    if ($u -match '^file://') {
        $u = $u.Substring(7)
        if ($u -match '^/[A-Za-z]:') { $u = $u.Substring(1) }
    } elseif ($u -match '^https?://' -and -not $u.EndsWith('/')) {
        $u = "$u/"
    }
    return $u
}

# Local <hash>.zip name: explicit --win-toolchain-hash, or the only *.zip in a
# local --win-toolchain-url directory.
function Get-LocalToolchainHash {
    param([string]$ExplicitHash, [string]$BaseUrl)
    if ($ExplicitHash) { return $ExplicitHash }
    if ($BaseUrl -and $BaseUrl -notmatch '^https?://' -and
        (Test-Path -LiteralPath $BaseUrl -PathType Container)) {
        $zips = @(Get-ChildItem -LiteralPath $BaseUrl -Filter '*.zip' -File -ErrorAction SilentlyContinue)
        if ($zips.Count -eq 1) { return $zips[0].BaseName }
    }
    return ''
}

function Get-ToolchainZipInfo {
    param([string]$BaseUrl, [string]$Hash)
    $info = @{ size = ''; mtime = '' }
    if (-not $BaseUrl -or -not $Hash) { return $info }
    if ($BaseUrl -match '^https?://') { return $info }
    $zip = Join-Path $BaseUrl ($Hash + '.zip')
    if (Test-Path -LiteralPath $zip -PathType Leaf) {
        $f = Get-Item -LiteralPath $zip
        $info.size = [string]$f.Length
        $info.mtime = '{0:yyyy-MM-ddTHH:mm:ss}' -f $f.LastWriteTime
    }
    return $info
}

function Get-ChromiumVersionInfo {
    param([Parameter(Mandatory = $true)][string]$Src)
    $info = @{ Major = ''; Build = ''; Version = '' }
    $p = Join-Path $Src 'chrome\VERSION'
    if (-not (Test-Path -LiteralPath $p)) { return $info }
    $v = @{}
    foreach ($line in @(Get-Content -LiteralPath $p -ErrorAction SilentlyContinue)) {
        if ($line -match '^(\w+)=(\d+)') { $v[$matches[1]] = $matches[2] }
    }
    if ($v.ContainsKey('MAJOR')) {
        $info.Major = [string]$v['MAJOR']
        $info.Build = [string]$v['BUILD']
        if ($v.ContainsKey('MINOR') -and $v.ContainsKey('BUILD') -and $v.ContainsKey('PATCH')) {
            $info.Version = "$($v['MAJOR']).$($v['MINOR']).$($v['BUILD']).$($v['PATCH'])"
        }
    }
    return $info
}

# Stable, order-independent fingerprint of .gclient custom_vars (they decide
# which dependencies are downloaded, so a change must force a full run).
function Get-DepsFingerprint {
    param($Vars)
    $parts = @()
    foreach ($k in @($Vars.Keys | Sort-Object)) { $parts += ($k + '=' + $Vars[$k]) }
    return ($parts -join ',')
}

# Same rule as Invoke-MakeOfflineRepo: main -> "main", otherwise "b<BUILD>".
function Get-OfflineBranchName {
    param([Parameter(Mandatory = $true)][string]$Src, [string]$Kind)
    if ($Kind -eq 'main') { return 'main' }
    $vi = Get-ChromiumVersionInfo -Src $Src
    if ($vi.Build) { return ('b' + $vi.Build) }
    return ''
}

# True only when the repository still matches a completed-export marker.
function Test-OfflineRepoComplete {
    param(
        [Parameter(Mandatory = $true)][string]$Src,
        [Parameter(Mandatory = $true)][string]$ExpectedBranch,
        [Parameter(Mandatory = $true)][string]$ExpectedRef,
        [string]$DepsFingerprint = '',
        [string]$ToolchainUrl = '',
        [string]$ToolchainHash = '',
        [Parameter(Mandatory = $true)][hashtable]$Marker
    )

    if ($Marker['format'] -ne '1') { return $false }
    if ($Marker['branch'] -ne $ExpectedBranch) { return $false }
    if ($Marker['ref'] -ne $ExpectedRef) { return $false }
    if ([string]$Marker['deps'] -ne $DepsFingerprint) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $Src '.git'))) { return $false }

    $vi = Get-ChromiumVersionInfo -Src $Src
    if (-not $vi.Version) { return $false }
    if ($Marker['version'] -ne $vi.Version) { return $false }

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $parent = (& git -C $Src rev-parse 'HEAD~1' 2>$null | Out-String).Trim()
    $count  = (& git -C $Src rev-list --count HEAD 2>$null | Out-String).Trim()
    $branch = (& git -C $Src rev-parse --abbrev-ref HEAD 2>$null | Out-String).Trim()
    $status = (& git -C $Src status --porcelain 2>$null | Out-String).Trim()
    $ErrorActionPreference = $prev

    # Exactly 2 commits, and HEAD's parent is the recorded commit 1/2. The
    # marker never records its own commit (2/2), so amending commit 2 is fine.
    if ($count -ne '2') { return $false }
    if ($parent -ne $Marker['commit1']) { return $false }
    if ($branch -ne $ExpectedBranch) { return $false }
    if ($status) { return $false }

    $depot = Join-Path $Src ('init_tools\' + $vi.Major + '\depot_tools')
    if (-not (Test-Path -LiteralPath $depot -PathType Container)) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $Src 'init_tools\win\env.bat'))) { return $false }

    # Toolchain identity is compared only when --win-toolchain-url is given:
    # the URL, the local <hash>.zip name, and the zip's size + mtime.
    if ($ToolchainUrl) {
        if (-not $ToolchainHash) { return $false }   # cannot verify -> full run
        if ($Marker['toolchain_url'] -ne $ToolchainUrl) { return $false }
        if ($Marker['toolchain_hash'] -ne $ToolchainHash) { return $false }
        $zip = Get-ToolchainZipInfo -BaseUrl $ToolchainUrl -Hash $ToolchainHash
        if ($zip.size) {
            if ($Marker['toolchain_zip_size'] -ne $zip.size) { return $false }
            if ($Marker['toolchain_zip_mtime'] -ne $zip.mtime) { return $false }
        }
        $canonical = Get-CanonicalToolchainHash
        if ($canonical -and $Marker['canonical_hash'] -and
            ($Marker['canonical_hash'] -ne $canonical)) { return $false }
    }
    return $true
}

# ---------------------------------------------------------------------------
# Structural fallback: recognize an exported snapshot even if its marker file
# was deleted. An export leaves exactly 2 commits with our commit subjects.
# ---------------------------------------------------------------------------
function Test-OfflineSnapshotRepo {
    param([Parameter(Mandatory = $true)][string]$Src)
    if (-not (Test-Path -LiteralPath (Join-Path $Src '.git'))) { return $false }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $count = (& git -C $Src rev-list --count HEAD 2>$null | Out-String).Trim()
    $s1 = ''
    $s2 = ''
    if ($count -eq '2') {
        $s1 = (& git -C $Src log -1 --pretty=%s 'HEAD~1' 2>$null | Out-String).Trim()
        $s2 = (& git -C $Src log -1 --pretty=%s HEAD 2>$null | Out-String).Trim()
    }
    $ErrorActionPreference = $prev
    if ($count -ne '2') { return $false }
    return (($s1 -match '^offline repo: Chromium .+ \(original source\)$') -and
            ($s2 -match '^offline repo: Chromium .+ \(init_tools'))
}

# ---------------------------------------------------------------------------
# Stop the processes that typically block a rename of .git: long-running
# READ-ONLY git commands (status/log/diff/.../fsmonitor--daemon) started by a
# Git Bash / IDE / stale terminal.
#
# Safety rules:
#   * only ALLOWLISTED read-only subcommands are stopped; writers (fetch, clone,
#     pull, push, commit, checkout, reset, gc, repack, index-pack, maintenance,
#     ...) are never touched;
#   * the subcommand is parsed positionally (git [-C <dir>]... <cmd>), so a
#     directory name such as "status" or "log" cannot be mistaken for a command;
#   * a process that names its repository via -C/--git-dir is stopped ONLY when
#     that path is on the moved path (or contains it); a process without any
#     repo argument (cwd-based) cannot be located, so it is still stopped.
# ---------------------------------------------------------------------------
function Get-GitSubcommand {
    param([Parameter(Mandatory = $true)][string]$CommandLine)
    $tokens = @([regex]::Matches($CommandLine, '"[^"]*"|[^\s"]+') | ForEach-Object { $_.Value.Trim('"') })
    if ($tokens.Count -eq 0 -or $tokens[0] -notmatch '^(?i)(?:[A-Za-z]:[\\/].*[\\/])?git(\.exe)?$') { return '' }
    $i = 1
    while ($i -lt $tokens.Count) {
        $tok = $tokens[$i]
        if ($tok -eq '-C' -or $tok -eq '-c') { $i += 2; continue }
        if ($tok -match '^--(git-dir|work-tree|exec-path|namespace)(=|$)') {
            $i++
            if ($tok -notmatch '=' -and $i -lt $tokens.Count) { $i++ }
            continue
        }
        return $tok
    }
    return ''
}

function Stop-BlockingGitReaders {
    param(
        [int]$MinAgeSeconds = 60,
        [string]$Path = ''
    )
    $readers = '^(?i)(status|diff|log|show|ls-files|rev-parse|cat-file|grep|blame|describe|name-rev|fsmonitor--daemon|for-each-ref|show-ref|symbolic-ref|fsck|count-objects)$'
    $pathLower = if ($Path) { $Path.TrimEnd('\', '/').Replace('/', '\').ToLowerInvariant() } else { '' }
    $stopped = 0
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='git.exe'" -ErrorAction SilentlyContinue)) {
        if (-not $p.CommandLine) { continue }
        $sub = Get-GitSubcommand -CommandLine $p.CommandLine
        if (-not $sub -or $sub -notmatch $readers) { continue }
        if ($pathLower) {
            # Repos named explicitly on the command line must overlap with the
            # moved path; processes that name an unrelated repo are left alone.
            $explicit = 0
            $related = $false
            foreach ($m in [regex]::Matches($p.CommandLine, '(?:-C\s+|--git-dir(?:\s+|=))(?:"([^"]+)"|([^\s"]+))')) {
                $explicit++
                $rp = if ($m.Groups[1].Value) { $m.Groups[1].Value } else { $m.Groups[2].Value }
                $rpLower = $rp.TrimEnd('\', '/').Replace('/', '\').ToLowerInvariant()
                if ($rpLower -eq $pathLower -or $rpLower.StartsWith($pathLower + '\') -or $pathLower.StartsWith($rpLower + '\')) {
                    $related = $true
                    break
                }
            }
            if ($explicit -gt 0 -and -not $related) { continue }
        }
        if (-not $p.CreationDate) { continue }
        $age = ((Get-Date) - $p.CreationDate).TotalSeconds
        if ($age -lt $MinAgeSeconds) { continue }
        try {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
            $stopped++
            Write-Warn2 ("Stopped long-running read-only git process: pid {0} ({1})" -f $p.ProcessId, ($p.CommandLine -replace '\s+', ' '))
        } catch { }
    }
    if ($stopped -gt 0) {
        Write-Ok ("Stopped {0} blocking git process(es); retrying the move." -f $stopped)
    }
}

# ---------------------------------------------------------------------------
# Move a file/directory with retries. Windows returns "Access is denied" when
# another process (a lingering `git status`, an IDE, Explorer preview, antivirus)
# holds a handle inside the tree - e.g. when phase 1 moves src\.git aside.
# ---------------------------------------------------------------------------
function Move-PathWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [int]$Attempts = 10,
        [int]$DelaySeconds = 2
    )
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            if (Test-Path -LiteralPath $Destination) {
                Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue
            }
            Move-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
            return
        } catch {
            $msg = $_.Exception.Message
            # Long-running read-only git commands are the usual culprits; stop them
            # after a couple of retries (and again with no age limit near the end).
            if ($i -eq 2 -or $i -eq 5) { Stop-BlockingGitReaders -Path $Source -MinAgeSeconds 60 }
            if ($i -eq 8) { Stop-BlockingGitReaders -Path $Source -MinAgeSeconds 0 }
            if ($i -lt $Attempts) {
                Start-Sleep -Seconds $DelaySeconds
                continue
            }
            $holders = @(Get-CimInstance Win32_Process -Filter "Name='git.exe'" -ErrorAction SilentlyContinue)
            $hint = ''
            if ($holders.Count -gt 0) {
                $hint = ' Running git process(es): ' + (($holders | ForEach-Object {
                    'pid ' + $_.ProcessId + ' (' + (($_.CommandLine -replace '\s+', ' ')) + ')'
                }) -join '; ') + '.'
            }
            throw ("Could not move '{0}' -> '{1}': {2}. Close any 'git status', IDE or Explorer window watching the repository and re-run.{3}" -f $Source, $Destination, $msg, $hint)
        }
    }
}

# ---------------------------------------------------------------------------
# Recover a workspace left behind by a FAILED --make-offline-repo run.
#
# Phase 1 of the export moves every .git (including src\.git and all dependency
# repos) into <root>\src_git_bak and replaces src\.git with a brand-new snapshot
# repository (no "origin" remote). If the export then fails (e.g. the sccache
# download hits a network error), re-running the download script cannot fetch:
#   fatal: 'origin' does not appear to be a git repository
# The backups are still there (they are only deleted after BOTH commits), so
# restore them and let the run continue instead of forcing a full re-download.
# ---------------------------------------------------------------------------
function Restore-FailedExport {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Src
    )
    $gitBak    = Join-Path $Root 'src_git_bak'
    $ignoreBak = Join-Path $Root 'src_gitignore_bak'
    $srcGit    = Join-Path $Src '.git'
    if (-not (Test-Path -LiteralPath $gitBak)) { return }
    $bakGit = Join-Path $gitBak '.git'
    if (-not (Test-Path -LiteralPath $bakGit)) { return }

    # Only when src\.git is the fresh export repo (no origin remote) or missing.
    if (Test-Path -LiteralPath $srcGit) {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $origin = ((& git -C $Src remote get-url origin 2>$null) | Out-String).Trim()
        $commitCount = ((& git -C $Src rev-list --count HEAD 2>$null) | Out-String).Trim()
        $ErrorActionPreference = $prev
        if ($origin) { return }
        # A COMPLETED export has exactly 2 commits (source + init_tools). Only a
        # run that died after commit 1 leaves 1 commit. (A plain Chromium
        # checkout was already excluded by the "origin" check above.)
        if ($commitCount -match '^\d+$' -and [int]$commitCount -ge 2) { return }
    }

    Write-Step 'Restoring the pre-export Chromium checkout (failed --make-offline-repo)'
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & git -C $Src fsmonitor--daemon stop 1>$null 2>$null
    $ErrorActionPreference = $prev
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $aside = Join-Path $Root ('_failed_export_git_' + $stamp)
    if (Test-Path -LiteralPath $srcGit) {
        Move-PathWithRetry -Source $srcGit -Destination $aside
    }
    $restored = 0
    foreach ($g in @(Get-ChildItem -LiteralPath $gitBak -Recurse -Force -Directory -Filter '.git' -ErrorAction SilentlyContinue)) {
        $rel  = $g.FullName.Substring($gitBak.Length + 1)
        $dest = Join-Path $Src $rel
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) -ErrorAction Stop | Out-Null
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue }
        Move-PathWithRetry -Source $g.FullName -Destination $dest
        $restored++
    }
    foreach ($g in @(Get-ChildItem -LiteralPath $gitBak -Recurse -Force -File -Filter '.git' -ErrorAction SilentlyContinue)) {
        $rel  = $g.FullName.Substring($gitBak.Length + 1)
        $dest = Join-Path $Src $rel
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) -ErrorAction Stop | Out-Null
        Move-PathWithRetry -Source $g.FullName -Destination $dest
        $restored++
    }
    if (Test-Path -LiteralPath $ignoreBak) {
        foreach ($f in @(Get-ChildItem -LiteralPath $ignoreBak -Recurse -Force -File -ErrorAction SilentlyContinue)) {
            $rel  = $f.FullName.Substring($ignoreBak.Length + 1)
            $dest = Join-Path $Src $rel
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) -ErrorAction Stop | Out-Null
            Copy-Item -LiteralPath $f.FullName -Destination $dest -Force -ErrorAction Stop
        }
    }
    # The export appended a "-text -diff" rule to .gitattributes; restore the
    # tracked version from the restored index.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & git -C $Src checkout -- .gitattributes 1>$null 2>$null
    $ErrorActionPreference = $prev

    Write-Ok ("Restored {0} .git entr(ies); failed export repo kept at: {1}" -f $restored, $aside)
    Write-Ok 'Re-run will continue from the restored checkout (no full re-download needed).'
}

# ---------------------------------------------------------------------------
function Set-ChromiumRevision {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Resolved)

    if ($Resolved.Kind -eq 'main') { return }

    # IMPORTANT: do NOT use "gclient sync --revision src@<ref>". For the main
    # solution gclient ignores --no-history and runs a *full*
    # "git fetch origin --no-tags", pulling gigabytes of history (and stalling).
    # Instead we shallow-fetch + check out the requested revision ourselves,
    # then sync dependencies with "--revision <name>@<sha>" (a 40-hex sha, not a
    # ref): that keeps gclient from re-fetching src at all (see PIT-016).
    # managed=False also protects us (gclient skips src outright, see
    # gclient_scm.py:878), and Set-GclientCustomVars forces --unmanaged; the sha
    # pin is the second line of defence for a .gclient that says managed=True.

    # If src is missing entirely (fresh --pinned checkout), initialise a bare
    # repo so the shallow fetch below has somewhere to go.
    if (-not (Test-Path -LiteralPath (Join-Path $Src '.git'))) {
        Write-Step "Initializing $Src"
        New-Item -ItemType Directory -Force -Path $Src | Out-Null
        Invoke-Native -FilePath 'git' -ArgumentList @('-C', $Src, 'init')
        Invoke-Native -FilePath 'git' -ArgumentList @('-C', $Src, 'remote', 'add', 'origin', $ChromiumUrl)
    } else {
        # A finished --make-offline-repo leaves src\.git as the snapshot repo.
        # It must still be fetchable, otherwise the next download run dies with
        # "'origin' does not appear to be a git repository" (PIT-022).
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & git -C $Src remote get-url origin 1>$null 2>$null
        $hasOrigin = ($LASTEXITCODE -eq 0)
        $ErrorActionPreference = $prev
        if (-not $hasOrigin) {
            Write-Ok "Adding 'origin' remote to $Src"
            Invoke-Native -FilePath 'git' -ArgumentList @('-C', $Src, 'remote', 'add', 'origin', $ChromiumUrl)
        }
    }

    # Shallow-fetch the exact ref (depth 1 keeps .git small).
    Write-Step "Shallow-fetching $($Resolved.Ref) (depth 1)"
    Invoke-Native -FilePath 'git' -ArgumentList @('-C', $Src, 'fetch', '--depth', '1', 'origin', $Resolved.Ref)

    # Detach HEAD onto exactly what we fetched.
    $sha = ((& git -C $Src rev-parse FETCH_HEAD 2>$null) | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $sha) {
        throw "Could not resolve FETCH_HEAD for '$($Resolved.Ref)'."
    }
    Write-Step "Checking out $sha ($($Resolved.Ref))"
    Invoke-Native -FilePath 'git' -ArgumentList @('-C', $Src, 'checkout', '--detach', $sha)

    # Provide a LOCAL default-branch ref. With an unmanaged solution gclient
    # still calls GetRemoteHeadRef() before it decides to skip src; without a
    # local refs/remotes/origin/HEAD it runs "git remote set-head -a origin",
    # a network round trip that can hang. Point origin/main at the commit we
    # just checked out so the lookup resolves locally.
    Invoke-Native -FilePath 'git' -ArgumentList @('-C', $Src, 'update-ref', 'refs/remotes/origin/main', $sha)
    Invoke-Native -FilePath 'git' -ArgumentList @('-C', $Src, 'symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main')

    # Now sync dependencies for the checked-out revision.
    #
    # IMPORTANT: pass "--revision <name>@<sha>" even though HEAD already is that
    # sha. Without it gclient treats the solution as "unmanaged" and resolves the
    # default branch ('refs/remotes/origin/main') via IsValidRevision(sha_only),
    # which can never match a ref name -> it runs "git fetch origin --no-tags"
    # WITHOUT --depth. On a shallow repo that means the FULL Chromium history
    # (28M+ objects / tens of GB / hours). An explicit 40-hex sha satisfies the
    # sha_only check, so the src checkout is left alone and only DEPS sub-repos
    # are synced (see PIT-016).
    # --with_branch_heads / --with_tags fetch every branch/tag and can be huge,
    # so they stay opt-in.
    #
    # "-D" (--delete_unversioned_trees) removes dependencies that vanished with
    # the new revision (e.g. "no longer part of this client" after switching
    # main -> 7871) and deletes them only when they have no local modifications.
    # It does NOT touch untracked files inside dependencies that are still
    # listed (that is --reset), so things like
    # third_party/depot_tools/win_toolchain/vs_files survive. This keeps the
    # working copy clean without the user running "gclient sync -D" by hand.
    $syncArgs = @('sync', '--nohooks', '--no-history', '-D', '--revision', ($SrcName + '@' + $sha))
    if ($WithTags -and $Resolved.Kind -eq 'tag') { $syncArgs += '--with_tags' }
    if ($WithBranchHeads -and $Resolved.Kind -eq 'branch') { $syncArgs += '--with_branch_heads' }

    # gclient sync can fail on transient dependency errors (e.g. HTTP 429 on a
    # third_party repo), so retry a few times before giving up.
    # Before each attempt, move dependency repos left unusable by an earlier
    # interruption (empty .git / missing recorded revision): gclient's "-D"
    # cleanup cannot diff them and would fail with "fatal: bad object" (PIT-021).
    Write-Step "Syncing dependencies for $($Resolved.Ref)"
    $attempts = $Retries + 1
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        try {
            Remove-BrokenDependencyRepos -Root $Root -Src $Src -SrcName $SrcName
            Invoke-Gclient -GclientFile $GclientFile -Arguments $syncArgs
            break
        } catch {
            Write-Warn2 ("sync attempt {0}/{1} error: {2}" -f $attempt, $attempts, $_.Exception.Message)
            if ($attempt -lt $attempts) {
                $wait = 30 * $attempt
                Write-Warn2 "sync attempt $attempt/$attempts failed; retrying in $wait s..."
                Write-Warn2 '(dependency fetches are often rate-limited; this is usually transient.)'
                Start-Sleep -Seconds $wait
                continue
            }
            throw
        }
    }

    Write-Ok "Now at revision: $($Resolved.Ref)"
}

# ---------------------------------------------------------------------------
#  Optional dependency gates.
#
#  Chromium gates many extra downloads behind DEPS variables that default to
#  False (see the "vars" block in //DEPS). A plain "gclient sync" does NOT
#  download them, so enable the ones you may need while you still have Internet
#  access - handy when the build machine is later offline.
#
#    (default)    -> checkout_pgo_profiles, checkout_clang_coverage_tools
#                    (always on, unless --no-extra-deps)
#    --pgo        -> checkout_pgo_profiles
#    --full-deps  -> the curated Windows dev/test set below
#    --deps k=v   -> any raw variable; overrides the defaults above
#                    (e.g. --deps checkout_pgo_profiles=False)
#
#  Intentionally NOT auto-enabled: Google-internal gates
#  (checkout_src_internal / checkout_google_internal), Googler-only captured
#  site test data (checkout_chromium_*_test_dependencies), other platforms
#  (checkout_android / fuchsia / chromeos / ios), and
#  checkout_telemetry_dependencies (partly private).
# ---------------------------------------------------------------------------
function Get-RequestedCustomVars {    $vars = [ordered]@{}

    # ALWAYS ON: keep the snapshot self-contained enough that later offline
    # builds don't fail on missing optional deps (PIT-011/PIT-012).
    # --no-extra-deps turns these off; --deps key=False overrides individually.
    if (-not $NoExtraDeps) {
        $vars['checkout_pgo_profiles']         = 'True'  # Windows PGO profiles
        $vars['checkout_clang_coverage_tools'] = 'True'  # llvm-cov / llvm-profdata
    }

    # --full-deps: a self-contained Windows development/test environment.
    if ($FullDeps) {
        $vars['checkout_clang_tidy']            = 'True'  # clang-tidy beside clang
        $vars['checkout_clangd']                = 'True'  # clangd language server
        $vars['checkout_clang_coverage_tools']  = 'True'  # llvm-cov / llvm-profdata
        $vars['checkout_pgo_profiles']          = 'True'  # Windows PGO profiles
        $vars['checkout_bazelisk']              = 'True'  # for rust-toolchain packaging
        $vars['download_libaom_testdata']       = 'True'  # AV1 codec test data
        $vars['download_libvpx_testdata']       = 'True'  # VP8/VP9 codec test data
        $vars['checkout_wpr_archives']          = 'True'  # web page replay archives (large)
    }

    # --pgo (also implied by --full-deps).
    if ($Pgo) {
        $vars['checkout_pgo_profiles'] = 'True'
    }

    # --deps key=value,key=value  -> raw custom_vars overrides.
    if ($DepsRaw) {
        foreach ($pair in ($DepsRaw -split ',')) {
            $p = $pair.Trim()
            if (-not $p) { continue }
            if ($p -notmatch '=') {
                Write-Warning "Ignoring --deps entry without '=': $p"
                continue
            }
            $kv = $p -split '=', 2
            $vars[$kv[0].Trim()] = $kv[1].Trim()
        }
    }

    return $vars
}

# ---------------------------------------------------------------------------
#  Report the PGO profile state for the current target platform.
#  The authoritative file name is in <src>\chrome\build\<target>.pgo.txt
#  (win32 / win64 / win-arm64); a profile for another milestone is NOT usable.
# ---------------------------------------------------------------------------
function Show-PgoStatus {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [string]$ArchName = '',
        [bool]$Requested = $true
    )
    $target = 'win64'
    if ($ArchName -eq 'x86') { $target = 'win32' } elseif ($ArchName -eq 'arm64') { $target = 'win-arm64' }
    $pgoDir = Join-Path $SourceDir 'chrome\build\pgo_profiles'
    $statePath = Join-Path $SourceDir ('chrome\build\' + $target + '.pgo.txt')
    $name = ''
    if (Test-Path -LiteralPath $statePath) {
        $name = (Get-Content -LiteralPath $statePath -Raw).Trim()
    }
    $files = @(Get-ChildItem -LiteralPath $pgoDir -Filter '*.profdata' -File -ErrorAction SilentlyContinue)
    if ($name) {
        $path = Join-Path $pgoDir $name
        if (Test-Path -LiteralPath $path) {
            $mb = [int]((Get-Item -LiteralPath $path).Length / 1MB)
            Write-Host (" PGO        : {0} present ({1} MB) - build with --args `"chrome_pgo_phase=2`"" -f $name, $mb)
            return
        }
        if ($files.Count -gt 0) {
            Write-Host (" PGO        : expected {0} is MISSING ({1} stale profile(s)); refetch the profiles" -f $name, $files.Count)
            return
        }
    } elseif ($files.Count -gt 0) {
        Write-Host (" PGO        : {0} profile(s) present - build with --args `"chrome_pgo_phase=2`"" -f $files.Count)
        return
    }
    if ($Requested) {
        Write-Host ' PGO        : profiles requested but none found (hooks skipped or fetch failed)'
    } else {
        Write-Host ' PGO        : profiles not downloaded (official builds will use chrome_pgo_phase=0)'
    }
}

# ---------------------------------------------------------------------------
#  Write the requested variables into the .gclient "custom_vars" section.
#  gclient's "config" command accepts repeated --custom-var key=value flags and
#  rewrites .gclient. This MUST run before the gclient sync that installs the
#  matching deps (and before runhooks for hook-based ones like PGO).
# ---------------------------------------------------------------------------
function Set-GclientCustomVars {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Vars)
    if ($Vars.Count -eq 0) { return }

    $gclientFile = $GclientFile
    $content = ''
    if (Test-Path -LiteralPath $gclientFile) {
        $content = Get-Content -LiteralPath $gclientFile -Raw
    }

    $pending = @()
    foreach ($key in $Vars.Keys) {
        # Match key AND requested value, so an existing "False" is corrected.
        $expected = [string]$Vars[$key]
        $pat = '[",'']' + [regex]::Escape($key) + '["'']\s*:\s*' + [regex]::Escape($expected)
        if ($content -notmatch $pat) { $pending += $key }
    }

    # The script checks out src itself, so the solution MUST stay unmanaged:
    # gclient_scm.update() returns early for managed=False ("unmanaged solution;
    # skipping src"), but for managed=True it resolves the default branch ref and
    # can run a depth-less "git fetch origin --no-tags" - on a shallow repo that
    # downloads the FULL history (PIT-016). "gclient config" defaults to
    # managed=True, so pass --unmanaged and repair a file that already says True.
    $managedOk = ($content -match 'managed["'']\s*:\s*False')
    if ($pending.Count -eq 0 -and $managedOk) {
        Write-Ok '.gclient already has all requested custom_vars (and is unmanaged).'
        return
    }

    if ($pending.Count -gt 0) {
        Write-Step ('Enabling .gclient custom_vars: ' + (($pending | Sort-Object) -join ', '))
    } else {
        Write-Step 'Marking the src solution unmanaged (.gclient managed=False)'
    }
    $cfgArgs = @('config', '--name', $SrcName, '--unmanaged')
    foreach ($key in ($Vars.Keys | Sort-Object)) {
        $cfgArgs += @('--custom-var', ('{0}={1}' -f $key, $Vars[$key]))
    }
    $cfgArgs += $ChromiumUrl
    Invoke-Gclient -GclientFile $GclientFile -Arguments $cfgArgs
}

# ---------------------------------------------------------------------------
#  Remove leftover git temporary packs (tmp_pack_* etc.)
#  These are written while git fetches/repacks. A completed fetch renames them
#  into pack-*; if a fetch was interrupted/crashed they are left behind, are
#  never read by later git commands, and can be many GB. Windows file locking
#  protects a pack that is still being written (Remove-Item then fails safely).
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
#  Dependency integrity check (warn only)
#  A failed fetch (HTTP 429 etc.) can leave a dependency directory present but
#  empty; `gn gen` doesn't notice until the link step (PIT-011 / PIT-012).
# ---------------------------------------------------------------------------
function Test-DependencyIntegrity {
    param(
        [Parameter(Mandatory = $true)][string]$Src,
        [string]$GclientRoot = ''
    )
    if (-not $GclientRoot) { $GclientRoot = Split-Path -Parent $Src }
    $solutionName = Split-Path -Leaf $Src
    $entriesPath = Join-Path $GclientRoot '.gclient_entries'

    # Preferred source of truth: gclient writes .gclient_entries after a
    # successful sync, listing exactly the dependencies it manages for THIS
    # configuration. Platform-conditional deps (checkout_linux / checkout_android)
    # and empty submodule placeholders inside a checked-out dep are NOT listed,
    # so they no longer produce false "empty dir" warnings. A genuinely missing
    # dependency (e.g. HTTP 429 leftovers, PIT-011/012) IS listed and shows up.
    if (Test-Path -LiteralPath $entriesPath) {
        $content = Get-Content -LiteralPath $entriesPath -Raw
        $checked = 0
        $bad = @()
        foreach ($m in [regex]::Matches($content, "'([^']+)'\s*:")) {
            $key = $m.Groups[1].Value
            # CIPD entries look like
            #   'src/base/tracing/test/data:test_data/<file>-<sha>'
            # - single files, not dependency checkouts. Skip them.
            if ($key -match ':') { continue }
            if ($key -notmatch ('^' + [regex]::Escape($solutionName) + '/')) { continue }
            $rel = $key.Substring($solutionName.Length + 1).Replace('/', '\')
            $path = Join-Path $Src $rel
            $checked++
            if (-not (Test-Path -LiteralPath $path -PathType Container)) {
                $bad += ('MISSING  ' + $rel)
                continue
            }
            # A checked-out repo always has at least one entry at its root.
            $first = @(Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue |
                         Select-Object -First 1)
            if ($first.Count -eq 0) { $bad += ('EMPTY    ' + $rel) }
        }

        if ($checked -eq 0) {
            Write-Warn2 "Dependency check skipped: no managed dependencies listed in $entriesPath."
            return
        }
        if ($bad.Count -eq 0) {
            Write-Ok ("Dependency check: all {0} managed dependencies are present." -f $checked)
            return
        }
        Write-Warn2 ("Dependency check: {0} of {1} managed dependencies are empty/missing:" -f $bad.Count, $checked)
        Write-Warn2 'They must be re-fetched (usually HTTP 429 leftovers) - PIT-011 / PIT-012:'
        foreach ($b in ($bad | Select-Object -First 8)) { Write-Warn2 ('  ' + $b) }
        if ($bad.Count -gt 8) { Write-Warn2 ('  ... and ' + ($bad.Count - 8) + ' more') }
        return
    }

    # Fallback for trees without .gclient_entries (interrupted/old checkouts):
    # the filesystem heuristic. It CAN report platform-conditional placeholders,
    # hence the wording below.
    $patterns = @(
        (Join-Path $Src 'third_party\*\src'),
        (Join-Path $Src 'third_party\*\*\src'),
        (Join-Path $Src 'third_party\dawn\third_party\*\src')
    )
    $empty = @()
    foreach ($pat in $patterns) {
        foreach ($d in @(Get-ChildItem -Path $pat -Directory -Force -ErrorAction SilentlyContinue)) {
            if (Test-Path -LiteralPath (Join-Path $d.FullName '.git')) { continue }
            $n = @(Get-ChildItem -LiteralPath $d.FullName -Recurse -File -Force -ErrorAction SilentlyContinue).Count
            if ($n -eq 0) { $empty += $d.FullName }
        }
    }
    if ($empty.Count -eq 0) { return }
    Write-Warn2 ("Dependency check: no .gclient_entries; {0} empty '*\src' dir(s) found." -f $empty.Count)
    Write-Warn2 'Some are platform-conditional; any that your build needs must be'
    Write-Warn2 're-fetched (PIT-011 / PIT-012):'
    foreach ($e in ($empty | Select-Object -First 8)) {
        Write-Warn2 ('  ' + $e.Replace($Src + '\', ''))
    }
    if ($empty.Count -gt 8) { Write-Warn2 ('  ... and ' + ($empty.Count - 8) + ' more') }
}

function Remove-StaleTmpPacks {
    $packDir = Join-Path $Src '.git\objects\pack'
    if (-not (Test-Path -LiteralPath $packDir)) { return }
    $tmp = @(Get-ChildItem -LiteralPath $packDir -File -Filter 'tmp_*' -ErrorAction SilentlyContinue)
    if ($tmp.Count -eq 0) { return }
    foreach ($f in $tmp) {
        try {
            $sizeGb = $f.Length / 1GB
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
            Write-Ok ('Removed stale temp pack {0} ({1:N2} GB)' -f $f.Name, $sizeGb)
        } catch {
            Write-Warn2 "Left in place (probably still in use): $($f.Name)"
        }
    }
}

# ===========================================================================
#  Offline repository export (--make-offline-repo)
# ===========================================================================
function Test-OfflinePeFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if ((Get-Item -LiteralPath $Path).Length -lt 100KB) { return $false }
    # 'MZ' magic via cmdlets: System.IO.File is blocked in ConstrainedLanguage.
    $head = @(Read-FileBytes -Path $Path -Count 2)
    if ($head.Count -lt 2) { return $false }
    return ($head[0] -eq 0x4D -and $head[1] -eq 0x5A)
}

function Get-OfflineSha256 {
    param([string]$Path)
    # Get-FileHash instead of SHA256.Create()/BitConverter (non-core types).
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-SccacheExe {
    param([string]$Dir, [string]$Url = '', [string]$ExpectedSha256 = '')
    $exe = Join-Path $Dir 'sccache.exe'
    if (Test-OfflinePeFile -Path $exe) {
        Write-Ok "sccache already present: $exe"
        return $exe
    }

    $tmp = Join-Path $env:TEMP ('sccache_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        if (-not $Url) {
            Write-Step 'Resolving latest sccache release from GitHub'
            $rel = Invoke-RestMethod -UseBasicParsing -TimeoutSec 60 `
                -Headers @{ 'User-Agent' = 'chromium-offline-repo' } `
                -Uri 'https://api.github.com/repos/mozilla/sccache/releases/latest'
            $asset = @($rel.assets | Where-Object {
                $_.name -match '^sccache-v.*-x86_64-pc-windows-msvc\.zip$'
            }) | Select-Object -First 1
            if (-not $asset) { throw 'Could not find sccache Windows x86_64 zip in the latest GitHub release.' }
            $Url = $asset.browser_download_url
            $shaAsset = @($rel.assets | Where-Object { $_.name -eq ($asset.name + '.sha256') }) | Select-Object -First 1
            if ($shaAsset) {
                $shaResp = Invoke-WebRequest -UseBasicParsing -Uri $shaAsset.browser_download_url -TimeoutSec 60
                $shaText = if ($shaResp.Content -is [byte[]]) {
                    Get-TextFromUtf8Bytes -Bytes $shaResp.Content
                } else {
                    [string]$shaResp.Content
                }
                $m = [regex]::Match($shaText, '([0-9a-fA-F]{64})')
                if ($m.Success) { $ExpectedSha256 = $m.Groups[1].Value.ToLowerInvariant() }
            }
        }

        $archiveName = (($Url -split '/')[-1])
        if (-not $archiveName) { $archiveName = 'sccache.zip' }
        $archive = Join-Path $tmp $archiveName
        Write-Step "Downloading sccache: $Url"
        Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $archive -TimeoutSec 600

        if ($ExpectedSha256) {
            $actual = Get-OfflineSha256 -Path $archive
            if ($actual -ne $ExpectedSha256.ToLowerInvariant()) {
                throw "sccache SHA-256 mismatch: expected $ExpectedSha256, got $actual"
            }
            Write-Ok "sccache SHA-256 verified: $actual"
        }

        if ($archive -match '\.zip$') {
            # Expand-Archive only: Add-Type and System.IO.Compression.ZipFile
            # are unavailable in ConstrainedLanguage mode.
            Expand-Archive -Path $archive -DestinationPath $tmp -Force
        } elseif ($archive -match '\.tar\.gz$') {
            & tar -xzf $archive -C $tmp
            if ($LASTEXITCODE -ne 0) { throw "Failed to extract $archive" }
        } elseif ($archive -match '\.exe$') {
            Copy-Item -LiteralPath $archive -Destination $exe -Force
        }

        if (-not (Test-Path -LiteralPath $exe)) {
            $found = @(Get-ChildItem -LiteralPath $tmp -Recurse -File -Filter 'sccache.exe' -ErrorAction SilentlyContinue) |
                     Select-Object -First 1
            if (-not $found) { throw "Could not find sccache.exe after extracting $Url" }
            Copy-Item -LiteralPath $found.FullName -Destination $exe -Force
        }
        if (-not (Test-OfflinePeFile -Path $exe)) { throw "Downloaded sccache.exe is not a valid PE file: $exe" }
        Write-Ok "sccache: $exe"
        return $exe
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-MakeOfflineRepo {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Src,
        [Parameter(Mandatory = $true)][string]$DepotTools,
        [Parameter(Mandatory = $true)][string]$ScriptDir,
        [Parameter(Mandatory = $true)][string]$GclientFile,
        [string]$SccacheUrl = '',
        [string]$SccacheSha256 = '',
        [string]$VersionKind = '',        # main | branch | tag | ref
        [string]$VersionDisplay = '',     # e.g. 7871 (branch) or 150.0.7871.290 (tag)
        [string]$VersionRequest = '',     # raw --version (marker/diagnostics)
        [string]$VersionRef = '',         # resolved ref (marker)
        [string]$DepsFingerprint = '',    # .gclient custom_vars fingerprint (marker)
        [string]$ToolchainArchiveDir = '',# local dir containing <hash>.zip (win_toolchain)
        [string]$ToolchainHash = '',      # local toolchain hash (vs_files\<hash>)
        [string]$ToolchainUrl = '',       # normalized --win-toolchain-url (marker)
        [switch]$Cleanup = $false         # delete the download workspace after success
    )

    $versionPath = Join-Path $Src 'chrome\VERSION'
    if (-not (Test-Path -LiteralPath $versionPath)) {
        throw "Cannot make an offline repo: $versionPath not found."
    }
    $v = @{}
    foreach ($line in (Get-Content -LiteralPath $versionPath)) {
        if ($line -match '^(\w+)=(\d+)') { $v[$matches[1]] = $matches[2] }
    }
    if (-not $v.ContainsKey('MAJOR')) { throw "Could not parse MAJOR from $versionPath" }
    $major = [string]$v['MAJOR']
    $versionText = "$($v['MAJOR']).$($v['MINOR']).$($v['BUILD']).$($v['PATCH'])"

    # Offline repo branch name (ADR-008): main -> "main"; branch "7871" -> "b7871";
    # tag/ref (e.g. 150.0.7871.290) -> "b<BUILD>" (= b7871).
    $buildNum = [string]$v['BUILD']
    $branchName = 'b' + $buildNum
    if ($VersionKind -eq 'main') { $branchName = 'main' }
    elseif ($VersionDisplay -match '^\d+$') { $branchName = 'b' + $VersionDisplay }

    $initRoot = Join-Path $Src 'init_tools'
    $majorRoot = Join-Path $initRoot $major
    $configDir = Join-Path $majorRoot 'config'
    $depotDest = Join-Path $majorRoot 'depot_tools'
    $scacheDir = Join-Path $majorRoot 'scache'
    $winDir = Join-Path $initRoot 'win'
    New-Item -ItemType Directory -Force -Path $configDir, $scacheDir, $winDir | Out-Null

    Write-Step "Creating offline repository layout for Chromium $versionText (major $major)"

    # ------------------------------------------------------------------
    #  Fetch sccache BEFORE phase 1 / commit 1.
    #
    #  sccache belongs to init_tools (commit 2/2), but downloading it after the
    #  multi-GB commit 1 means a transient GitHub failure forces a full redo of
    #  that commit (PIT-023). Doing it first keeps a failure cheap: nothing has
    #  been backed up or committed yet. Retries reuse --retries (default 10).
    # ------------------------------------------------------------------
    $sccacheAttempts = if ($Retries -gt 0) { $Retries } else { 1 }
    for ($i = 1; $i -le $sccacheAttempts; $i++) {
        try {
            Get-SccacheExe -Dir $scacheDir -Url $SccacheUrl -ExpectedSha256 $SccacheSha256 | Out-Null
            break
        } catch {
            if ($i -lt $sccacheAttempts) {
                $wait = 10 * $i
                if ($wait -gt 120) { $wait = 120 }
                Write-Warn2 ("sccache attempt {0}/{1} failed: {2}" -f $i, $sccacheAttempts, $_.Exception.Message)
                Write-Warn2 ("retrying in {0}s (before any repository commit)" -f $wait)
                Start-Sleep -Seconds $wait
                continue
            }
            throw
        }
    }

    # ------------------------------------------------------------------
    #  Phase 1: wipe EVERY .git (including src\.git) and build ONE fresh
    #  repository from scratch, so the snapshot contains real files instead
    #  of submodule pointers (PIT-018 / PIT-019).
    #
    #  Safety net:
    #    * all .git dirs are MOVED to <root>\src_git_bak\ (same relative layout)
    #    * all .gitignore files are COPIED to <root>\src_gitignore_bak\
    #      and then removed (so nothing is hidden from the commit)
    #  Both backup dirs are deleted only after BOTH commits succeed; if the
    #  export fails, they stay in place for manual recovery.
    # ------------------------------------------------------------------
    $gitBak    = Join-Path $Root 'src_git_bak'
    $ignoreBak = Join-Path $Root 'src_gitignore_bak'
    foreach ($bak in @($gitBak, $ignoreBak)) {
        if (Test-Path -LiteralPath $bak) {
            Write-Warn2 "Removing stale backup directory: $bak"
            & cmd /c "rmdir /s /q `"$bak`"" 2>$null | Out-Null
        }
    }
    New-Item -ItemType Directory -Force -Path $gitBak, $ignoreBak | Out-Null
    Write-Ok "Backups (kept on failure): $gitBak , $ignoreBak"

    # NOTE: 8.3 short names (e.g. C:\Users\ZHANGF~1.ZFJ) vs the long path
    # returned by Get-ChildItem would break Substring-based relative paths, so
    # normalise the source path first.
    $srcFull = (Get-Item -LiteralPath $Src).FullName

    Write-Step 'Backing up and removing all .git repositories'
    # Warn (do not kill) when a git status is running: it can hold .git and make
    # the move below fail with "Access is denied".
    $statusProcs = @(Get-CimInstance Win32_Process -Filter "Name='git.exe'" -ErrorAction SilentlyContinue |
                     Where-Object { $_.CommandLine -match '\bstatus\b' })
    if ($statusProcs.Count -gt 0) {
        Write-Warn2 ('A git status process is running (pid {0}). It can lock .git;' -f (($statusProcs | ForEach-Object { $_.ProcessId }) -join ','))
        Write-Warn2 'long-running read-only git processes will be stopped automatically if the move is blocked.'
    }
    $movedGit = 0
    $mainGit = Join-Path $Src '.git'
    if (Test-Path -LiteralPath $mainGit) {
        # Stop a possible fsmonitor daemon for this repo before renaming .git.
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & git -C $Src fsmonitor--daemon stop 1>$null 2>$null
        $ErrorActionPreference = $prev
        # Move the main repo FIRST: it also stops the recursive scan below from
        # walking hundreds of thousands of object files.
        Move-PathWithRetry -Source $mainGit -Destination (Join-Path $gitBak '.git')
        $movedGit++
    }
    $gitDirs = @(Get-ChildItem -LiteralPath $Src -Recurse -Force -Directory -Filter '.git' -ErrorAction SilentlyContinue)
    foreach ($g in $gitDirs) {
        $rel  = $g.FullName.Substring($srcFull.Length + 1)
        $dest = Join-Path $gitBak $rel
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
        Move-PathWithRetry -Source $g.FullName -Destination $dest
        $movedGit++
    }
    $gitFiles = @(Get-ChildItem -LiteralPath $Src -Recurse -Force -File -Filter '.git' -ErrorAction SilentlyContinue)
    foreach ($g in $gitFiles) {
        $rel  = $g.FullName.Substring($srcFull.Length + 1)
        $dest = Join-Path $gitBak $rel
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
        Move-PathWithRetry -Source $g.FullName -Destination $dest
        $movedGit++
    }
    Write-Ok ("Backed up {0} .git entr(ies)." -f $movedGit)

    Write-Step 'Backing up and removing .gitignore files'
    $ignores = @(Get-ChildItem -LiteralPath $Src -Recurse -Force -File -Filter '.gitignore' -ErrorAction SilentlyContinue)
    foreach ($f in $ignores) {
        $rel  = $f.FullName.Substring($srcFull.Length + 1)
        $dest = Join-Path $ignoreBak $rel
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
        Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
        Remove-Item -LiteralPath $f.FullName -Force
    }
    Write-Ok ("Backed up and removed {0} .gitignore file(s)." -f $ignores.Count)

    # ---- win_toolchain: preserve the exact bytes ------------------------------
    # Chromium's .gitattributes forces LF for *.h / *.idl / *.c ... repo-wide.
    # If the toolchain is committed through those rules, its contents change and
    # get_toolchain_if_necessary.py computes a different content hash, deletes
    # the "corrupt" toolchain, and gn gen fails (PIT-020). So:
    #   1) re-materialise the toolchain from the pristine <hash>.zip (a previous
    #      checkout may already have rewritten CRLF -> LF);
    #   2) mark the path "-text -diff" BEFORE staging so blobs keep CRLF.
    $vsRoot = Join-Path $Src 'third_party\depot_tools\win_toolchain\vs_files'
    $chainHash = $ToolchainHash
    if (-not $chainHash -and (Test-Path -LiteralPath $vsRoot -PathType Container)) {
        $chainDirs = @(Get-ChildItem -LiteralPath $vsRoot -Directory -Force -ErrorAction SilentlyContinue)
        if ($chainDirs.Count -eq 1) { $chainHash = $chainDirs[0].Name }
    }
    if ($chainHash) {
        $chainZip = ''
        if ($ToolchainArchiveDir) { $chainZip = Join-Path $ToolchainArchiveDir ($chainHash + '.zip') }
        if ($chainZip -and (Test-Path -LiteralPath $chainZip -PathType Leaf)) {
            if (-not (Get-Command tar.exe -ErrorAction SilentlyContinue)) {
                throw 'tar.exe not found: cannot re-extract the pristine win_toolchain.'
            }
            Write-Step "Re-extracting pristine win_toolchain from $chainZip"
            $stage = Join-Path $Root ('_win_toolchain_stage_' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force -Path $stage | Out-Null
            & tar -xf $chainZip -C $stage
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to extract $chainZip (tar exit $LASTEXITCODE)."
            }
            $chainDest = Join-Path $vsRoot $chainHash
            if (Test-Path -LiteralPath $chainDest) {
                Remove-Item -LiteralPath $chainDest -Recurse -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $chainDest) {
                    & cmd /c "rmdir /s /q `"$chainDest`"" 2>$null | Out-Null
                }
            }
            New-Item -ItemType Directory -Force -Path $vsRoot | Out-Null
            Move-PathWithRetry -Source $stage -Destination $chainDest
            Write-Ok "win_toolchain re-extracted: $chainDest"
        } else {
            Write-Warn2 "Toolchain archive not found ($chainZip); keeping the current files."
            Write-Warn2 'If they were ever checked out through git, their content hash is already wrong.'
        }

        # Refresh the SHORT <hash>.timestamps so the first vs_toolchain.py run
        # does not re-hash (stdout noise -> gn "Invalid token") and does not
        # delete the toolchain via RemoveUnusedToolchains (PIT-020). The build
        # script does this again after a checkout because mtimes change.
        $tcDest = Join-Path $vsRoot $chainHash
        $tcWinRoot = Split-Path -Parent $vsRoot
        $tcScript = Join-Path $tcWinRoot 'get_toolchain_if_necessary.py'
        $tcPython = Join-Path $DepotTools 'python3.bat'
        if ((Test-Path -LiteralPath $tcDest) -and
            (Test-Path -LiteralPath $tcPython) -and (Test-Path -LiteralPath $tcScript)) {
            $tmpPy = Join-Path $env:TEMP ('warm_tc_' + [guid]::NewGuid().ToString('N') + '.py')
            $code = @(
                'import importlib.util, os, sys'
                'script, rootdir, h = sys.argv[1], sys.argv[2], sys.argv[3]'
                'spec = importlib.util.spec_from_file_location("gt", script)'
                'm = importlib.util.module_from_spec(spec)'
                'spec.loader.exec_module(m)'
                'os.chdir(rootdir)'
                'm.SaveTimestampsAndHash("vs_files", h)'
            ) -join "`n"
            Set-Content -LiteralPath $tmpPy -Value $code -Encoding ASCII
            try {
                $out = & $tcPython $tmpPy $tcScript $tcWinRoot $chainHash 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Ok "Refreshed toolchain timestamps: $chainHash.timestamps"
                } else {
                    Write-Warn2 ("Toolchain timestamps refresh failed: {0}" -f ($out -join ' '))
                }
            } finally {
                Remove-Item -LiteralPath $tmpPy -Force -ErrorAction SilentlyContinue
            }
        }
    } else {
        Write-Warn2 'win_toolchain not found; skipping pristine re-extraction.'
    }

    # Must be in the worktree BEFORE "git add" so the attributes apply.
    $gaPath = Join-Path $Src '.gitattributes'
    $gaMarker = '# === offline repo: preserve win_toolchain bytes ==='
    $gaBlock = @(
        '',
        $gaMarker,
        'third_party/depot_tools/win_toolchain/** -text -diff',
        ''
    ) -join "`n"
    if (-not (Test-Path -LiteralPath $gaPath)) {
        Set-Content -LiteralPath $gaPath -Value '' -Encoding ASCII
    }
    $ga = Get-Content -LiteralPath $gaPath -Raw
    if ($ga -notmatch [regex]::Escape($gaMarker)) {
        Add-Content -LiteralPath $gaPath -Value $gaBlock -Encoding ASCII
        Write-Ok 'Added "-text -diff" rule for third_party/depot_tools/win_toolchain'
    }

    # Fresh repository: commit 1 = pristine source tree (init_tools not yet).
    Write-Step 'Initializing a fresh offline git repository'
    Invoke-Native -FilePath 'git' -ArgumentList @('-C', $Src, 'init')
    Invoke-Native -FilePath 'git' -ArgumentList @('-C', $Src, 'symbolic-ref', 'HEAD', ('refs/heads/' + $branchName))
    Write-Ok "Branch: $branchName"

    # Exactly one .gitignore remains: ours, for build transients.
    $ignoreBlock = @(
        '# === offline repo transient files ===',
        '/out/',
        '# build/win_toolchain.json stores absolute toolchain paths; gn regenerates it',
        '/build/win_toolchain.json',
        '*.log',
        '*.tmp',
        '**/__pycache__/',
        '**/*.pyc',
        '# legacy sccache cache (older snapshots); current default is out\.cache<MAJOR>',
        'init_tools/*/scache/cache/',
        '.DS_Store',
        'Thumbs.db',
        ''
    ) -join "`n"
    Set-Content -LiteralPath (Join-Path $Src '.gitignore') -Value $ignoreBlock -Encoding ASCII

    # Clean Python caches AFTER the toolchain steps above: the timestamp refresh
    # runs python and re-creates __pycache__ under third_party/depot_tools.
    Remove-PythonCaches -SourceDir $Src

    Write-Step 'Committing original source tree (commit 1/2)'
    # init_tools is excluded here on purpose: it belongs to commit 2/2 (a
    # re-export may already have it on disk from a previous run).
    Invoke-Native -FilePath 'git' -ArgumentList @('-C', $Src, 'add', '-A', '-f', '--', '.', ':(exclude)out', ':(exclude)build/win_toolchain.json', ':(exclude)init_tools', ':(exclude,glob)**/__pycache__/**', ':(exclude,glob)**/*.pyc')
    Remove-CachedPythonFiles -SourceDir $Src
    Invoke-Native -FilePath 'git' -ArgumentList @(
        '-C', $Src,
        '-c', 'user.name=offline-repo',
        '-c', 'user.email=offline-repo@localhost',
        'commit', '-m', "offline repo: Chromium $versionText (original source)"
    )
    $commit1 = ((& git -C $Src rev-parse --short HEAD) | Out-String).Trim()
    Write-Ok "Commit 1/2: $commit1"

    # 1. Copy gclient config/state into init_tools/<MAJOR>/config.
    #    Always COPY here: the root originals are only deleted with --cleanup,
    #    so a failed export leaves the download workspace reusable.
    $configFiles = @('.gclient', '.gclient_entries', '.gclient_previous_custom_vars',
                     '.gclient_previous_sync_commits', '.gcs_entries')
    foreach ($f in $configFiles) {
        $srcFile = if ($f -eq '.gclient') { $GclientFile } else { Join-Path $Root $f }
        $destFile = Join-Path $configDir $f
        if ((Test-Path -LiteralPath $srcFile) -and ($srcFile -ne $destFile)) {
            Copy-Item -LiteralPath $srcFile -Destination $destFile -Force
        }
    }
    $newGclient = Join-Path $configDir '.gclient'
    if (Test-Path -LiteralPath $newGclient) {
        # The repository is now rooted at $Src, so init_tools/<MAJOR>/config is
        # three levels below it (config -> <MAJOR> -> init_tools -> $Src).
        # Rewrite the solution name regardless of what it currently is, so a
        # renamed source directory (--dest-name) keeps working.
        $content = Get-Content -LiteralPath $newGclient -Raw
        $content = $content -replace '("name"\s*:\s*")[^"]+(")', '${1}../../..${2}'
        $content = $content -replace "('name'\s*:\s*')[^']+(')", '${1}../../..${2}'
        Set-Content -LiteralPath $newGclient -Value $content -Encoding ASCII
        Write-Ok "gclient config: $newGclient"
    } else {
        Write-Warn2 "No .gclient found at $GclientFile; config directory will be incomplete."
    }

    # 2. Put depot_tools into init_tools/<MAJOR>/depot_tools.
    #    Default: COPY it and leave the original in place (with its .git), so a
    #    later/failed run can still reuse the real depot_tools checkout.
    #    --cleanup: MOVE it (the download workspace is consumed by the export).
    if ($DepotTools -and (Test-Path -LiteralPath $DepotTools) -and
        ($DepotTools -ne $depotDest)) {
        if (-not $Cleanup) {
            Write-Step "Copying depot_tools -> $depotDest (original kept)"
            New-Item -ItemType Directory -Force -Path $depotDest | Out-Null
            foreach ($item in @(Get-ChildItem -LiteralPath $DepotTools -Force)) {
                # Skip the VCS metadata: the committed snapshot must contain plain
                # files, while the ORIGINAL keeps its .git (that is the point).
                if ($item.Name -eq '.git') { continue }
                Copy-Item -LiteralPath $item.FullName -Destination $depotDest -Recurse -Force
            }
        } elseif (Test-Path -LiteralPath $depotDest) {
            Write-Warn2 "depot_tools destination already exists; leaving $DepotTools in place."
        } else {
            Write-Step "Moving depot_tools -> $depotDest"
            Move-PathWithRetry -Source $DepotTools -Destination $depotDest
        }
    }
    if (Test-Path -LiteralPath $depotDest) {
        Write-Ok "depot_tools: $depotDest"
    } else {
        Write-Warn2 "depot_tools not found; offline repo will not include it."
    }

    # depot_tools arrives AFTER the backup phase, so drop its own .git here;
    # otherwise the second commit would store a gitlink instead of files.
    $dtGit = Join-Path $depotDest '.git'
    if (Test-Path -LiteralPath $dtGit) {
        Remove-Item -LiteralPath $dtGit -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $dtGit) { & cmd /c "rmdir /s /q `"$dtGit`"" 2>$null | Out-Null }
        Write-Ok 'Removed depot_tools .git (materialized snapshot).'
    }

    # 3. sccache: already fetched before phase 1 (PIT-023); this is a cheap
    #    re-check that only downloads again if the file disappeared.
    Get-SccacheExe -Dir $scacheDir -Url $SccacheUrl -ExpectedSha256 $SccacheSha256 | Out-Null

    # 4. Copy the Windows scripts + README + args_default.gn into init_tools/win.
    $scriptNames = @(
        'chromium_build_win.ps1', 'chromium_build_win.bat',
        'chromium_download_win.ps1', 'chromium_download_win.bat',
        'prepare_win_toolchain.ps1', 'prepare_win_toolchain.bat',
        'bootstrap_depot_tools.ps1', 'bootstrap_depot_tools.bat',
        'find_depot_tools_version.ps1', 'find_depot_tools_version.bat'
    )
    foreach ($name in $scriptNames) {
        $from = Join-Path $ScriptDir $name
        if (Test-Path -LiteralPath $from) {
            Copy-Item -LiteralPath $from -Destination (Join-Path $winDir $name) -Force
        } else {
            Write-Warn2 "Script not found, skipped: $from"
        }
    }
    $readme = Join-Path $ScriptDir 'README.md'
    if (Test-Path -LiteralPath $readme) {
        Copy-Item -LiteralPath $readme -Destination (Join-Path $winDir 'README.md') -Force
    }
    # Default GN args (used via --args-file; keeps long arg sets shell-quoting-free).
    $argsDefault = Join-Path $ScriptDir 'args_default.gn'
    if (Test-Path -LiteralPath $argsDefault) {
        Copy-Item -LiteralPath $argsDefault -Destination (Join-Path $winDir 'args_default.gn') -Force
        Write-Ok 'Copied args_default.gn'
    } else {
        Write-Warn2 "args_default.gn not found: $argsDefault"
    }
    Write-Ok "Scripts copied to $winDir"

    # 4b. Bundle the project knowledge base and agent assets so the offline
    #     repository is self-describing: .opencode\, docs\, AGENTS.md and the
    #     user's notes file (win*.md, e.g. win<form...>.md).
    foreach ($name in @('.opencode', 'docs')) {
        $from = Join-Path $ScriptDir $name
        if (Test-Path -LiteralPath $from -PathType Container) {
            Copy-Item -LiteralPath $from -Destination $winDir -Recurse -Force
            Write-Ok "Copied $name -> $winDir\$name"
        }
    }
    $agentsFile = Join-Path $ScriptDir 'AGENTS.md'
    if (Test-Path -LiteralPath $agentsFile -PathType Leaf) {
        Copy-Item -LiteralPath $agentsFile -Destination (Join-Path $winDir 'AGENTS.md') -Force
        Write-Ok 'Copied AGENTS.md'
    }
    # Locate by pattern instead of embedding a non-ASCII literal: these .ps1
    # files have no BOM, and PowerShell 5.1 would read a UTF-8 literal as ANSI.
    $notes = @(Get-ChildItem -LiteralPath $ScriptDir -File -Filter 'win*.md' -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -ne 'README.md' } | Sort-Object Name)
    if ($notes.Count -gt 0) {
        Copy-Item -LiteralPath $notes[0].FullName -Destination (Join-Path $winDir $notes[0].Name) -Force
        Write-Ok ("Copied {0}" -f $notes[0].Name)
    }

    # 5. env.bat / env.ps1.
    #    Paths are derived from the script's own location at RUNTIME, so the
    #    whole tree can be moved, renamed or put on another drive without
    #    regenerating anything. (%~dp0 / $PSScriptRoot are absolute.)
    #    NOTE: build the "major"-interpolated lines as variables first: inside
    #    an array literal the comma operator binds tighter than "+", so
    #    'a' + $x + 'b', 'c' + $x + 'd' would collapse into one element.
    $dtLine  = 'set "DEPOT_TOOLS_PATH=%INIT%\' + $major + '\depot_tools"'
    $cfgLine = 'set "GCLIENT_FILE=%INIT%\' + $major + '\config\.gclient"'
    $sccLine = 'set "SCCACHE_DIR=%SRC%\out\.cache' + $major + '"'
    $patLine = 'set "PATH=%INIT%\' + $major + '\depot_tools;%INIT%\' + $major + '\scache;%PATH%"'
    $envBat = @(
        '@echo off',
        "rem Offline Chromium environment for major $major",
        'rem Paths are derived from this file location; moving the tree is fine.',
        'set "INIT=%~dp0.."',
        'set "SRC=%~dp0..\.."',
        'set "ROOT=%~dp0..\..\.."',
        'for %%I in ("%INIT%") do set "INIT=%%~fI"',
        'for %%I in ("%SRC%") do set "SRC=%%~fI"',
        'for %%I in ("%ROOT%") do set "ROOT=%%~fI"',
        'set "CHROMIUM_OFFLINE_ROOT=%ROOT%"',
        'set "CHROMIUM_OFFLINE_SRC=%SRC%"',
        "set `"CHROMIUM_OFFLINE_MAJOR=$major`"",
        $dtLine,
        $cfgLine,
        $sccLine,
        'set "DEPOT_TOOLS_UPDATE=0"',
        'set "DEPOT_TOOLS_WIN_TOOLCHAIN=1"',
        $patLine
    )
    Set-Content -LiteralPath (Join-Path $winDir 'env.bat') -Value $envBat -Encoding ASCII

    $depotPs  = '$Depot = Join-Path $Init "' + $major + '\depot_tools"'
    $cachePs  = '$Cache = Join-Path $Init "' + $major + '\scache"'
    $gclientPs = '$env:GCLIENT_FILE = (Join-Path $Init "' + $major + '\config\.gclient")'
    $sccachePs = '$env:SCCACHE_DIR = (Join-Path $Src "out\.cache' + $major + '")'
    $envPs1 = @(
        "# Offline Chromium environment for major $major",
        '# Paths are derived from this file location; moving the tree is fine.',
        '$Here = $PSScriptRoot',
        '$Init = (Resolve-Path (Join-Path $Here "..")).Path',
        '$Src  = (Resolve-Path (Join-Path $Here "..\..")).Path',
        '$Root = (Resolve-Path (Join-Path $Here "..\..\..")).Path',
        $depotPs,
        $cachePs,
        '$env:CHROMIUM_OFFLINE_ROOT = $Root',
        '$env:CHROMIUM_OFFLINE_SRC = $Src',
        "`$env:CHROMIUM_OFFLINE_MAJOR = '$major'",
        '$env:DEPOT_TOOLS_PATH = $Depot',
        $gclientPs,
        $sccachePs,
        '$env:DEPOT_TOOLS_UPDATE = ''0''',
        '$env:DEPOT_TOOLS_WIN_TOOLCHAIN = ''1''',
        '$env:PATH = "$Depot;$Cache;$env:PATH"'
    )
    Set-Content -LiteralPath (Join-Path $winDir 'env.ps1') -Value $envPs1 -Encoding ASCII
    Write-Ok "Environment: call $winDir\env.bat  (cmd)  or  . $winDir\env.ps1  (PowerShell)"

    # ---- Second commit: init_tools ------------------------------------------
    # (Nested .git / gitlink / .gitignore handling happens in phase 1, before
    # the first commit, so here only the newly assembled init_tools changes.)
    # The copied depot_tools can carry its own __pycache__/*.pyc; clean again.
    Remove-PythonCaches -SourceDir $Src
    # Completion marker: committed WITH init_tools (commit 2/2), so the repo is
    # self-describing and <root> can be cleaned completely (--cleanup). It
    # records commit 1/2 only: recording commit 2 would be self-referential and
    # would break whenever commit 2 is amended.
    # Marker is written BEFORE commit 2, so HEAD is still commit 1/2.
    $full1 = ((& git -C $Src rev-parse HEAD) | Out-String).Trim()
    if ($full1 -notmatch '^[0-9a-f]{40}$') {
        throw ("Could not resolve commit 1/2 for the completion marker (got '{0}')." -f $full1)
    }
    $zipInfo = @{ size = ''; mtime = '' }
    if ($ToolchainArchiveDir -and $chainHash) {
        $zipInfo = Get-ToolchainZipInfo -BaseUrl $ToolchainArchiveDir -Hash $chainHash
    }
    $canonicalHash = [string](Get-CanonicalToolchainHash)
    if (-not $canonicalHash) { $canonicalHash = '' }
    $markerPath = Write-OfflineMarker -Src $Src -Values @{
        format             = '1'
        branch             = $branchName
        kind               = $VersionKind
        version            = $versionText
        request            = $VersionRequest
        deps               = $DepsFingerprint
        ref                = $VersionRef
        commit1            = $full1
        toolchain_url      = $ToolchainUrl
        toolchain_hash     = $chainHash
        toolchain_zip_size = $zipInfo.size
        toolchain_zip_mtime= $zipInfo.mtime
        canonical_hash     = $canonicalHash
        finished           = (Format-Stamp (Get-Date))
    }
    Write-Ok "Completion marker: $markerPath (goes into commit 2/2)"

    Write-Step 'Committing init_tools (commit 2/2, this may take a while)'
    # Never commit sccache's build cache (can be several GB); only the exe belongs
    # in the offline repo. The cache lives at init_tools/<MAJOR>/scache/cache.
    $scacheCacheExclude = ':(exclude)init_tools/' + $major + '/scache/cache'
    Invoke-Native -FilePath 'git' -ArgumentList @('-C', $Src, 'add', '-A', '-f', '--', '.', ':(exclude)out', ':(exclude)build/win_toolchain.json', $scacheCacheExclude, ':(exclude,glob)**/__pycache__/**', ':(exclude,glob)**/*.pyc')
    Remove-CachedPythonFiles -SourceDir $Src
    Invoke-Native -FilePath 'git' -ArgumentList @('-C', $Src, 'rm', '-r', '--cached', '--ignore-unmatch', 'out', 'build/win_toolchain.json', ('init_tools/' + $major + '/scache/cache'))
    $status = ((& git -C $Src status --porcelain) | Out-String).Trim()
    $commit2 = $commit1
    if ($status) {
        Invoke-Native -FilePath 'git' -ArgumentList @(
            '-C', $Src,
            '-c', 'user.name=offline-repo',
            '-c', 'user.email=offline-repo@localhost',
            'commit', '-m', "offline repo: Chromium $versionText (init_tools + full deps)"
        )
        $commit2 = ((& git -C $Src rev-parse --short HEAD) | Out-String).Trim()
        Write-Ok "Commit 2/2: $commit2"
    } else {
        Write-Ok 'No changes in init_tools to commit.'
    }

    # The snapshot repo must stay fetchable: future download runs do
    # "git fetch --depth 1 origin <ref>" (PIT-022).
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & git -C $Src remote get-url origin 1>$null 2>$null
    $hasOrigin = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prev
    if (-not $hasOrigin) {
        Invoke-Native -FilePath 'git' -ArgumentList @('-C', $Src, 'remote', 'add', 'origin', $ChromiumUrl)
        Write-Ok "Added 'origin' remote: $ChromiumUrl"
    }

    # ---- Success: verify the two commits, drop the legacy root marker --------
    $commitCount = ((& git -C $Src rev-list --count HEAD) | Out-String).Trim()
    if ($commitCount -eq '2') {
        Write-Ok "Completion marker: $markerPath (committed in init_tools)"
    } else {
        Write-Warn2 "Unexpected commit count ($commitCount); completion marker not verified."
    }
    $legacyMarker = Get-LegacyOfflineMarkerPath -Root $Root
    if (Test-Path -LiteralPath $legacyMarker) {
        Remove-Item -LiteralPath $legacyMarker -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $legacyMarker) { Write-Warn2 "Could not remove legacy marker: $legacyMarker" }
        else { Write-Ok "Removed legacy root marker: $legacyMarker" }
    }

    if (-not $Cleanup) {
        Write-Ok "Keeping backups: $gitBak"
        Write-Ok "Keeping backups: $ignoreBak"
        Write-Ok "Keeping .gclient*/.gcs* at $Root and .cipd (reusable workspace)."
        Write-Ok "Keeping original depot_tools (if present)."
        Write-Ok 'Keeping sccache.exe (committed in init_tools) and its build cache.'
    } else {
        Remove-ExportScratch -Root $Root -Src $Src -Major $major -GclientFile $GclientFile
    }

    Write-Host ''
    Write-Host '============================================================================'
    Write-Host " Offline Chromium repository ready: $Src"
    Write-Host '============================================================================'
    Write-Host " Repository   : $Src"
    Write-Host " Branch       : $branchName"
    Write-Host " Commits      : $commit1 (source) -> $commit2 (init_tools)"
    Write-Host " Major        : $major"
    Write-Host " Config       : $configDir"
    Write-Host " depot_tools  : $depotDest"
    Write-Host " sccache      : $scacheDir"
    Write-Host " Windows tools: $winDir"
    $finishTime = Get-Date
    Write-Host " Started      : $(Format-Stamp $runStart)"
    Write-Host " Finished     : $(Format-Stamp $finishTime)"
    Write-Host (" Elapsed      : {0}" -f (Format-Elapsed ([int](($finishTime - $runStart).TotalSeconds))))
    Write-Host ''
    Write-Host ' Activate in cmd.exe:'
    Write-Host "   call `"$winDir\env.bat`""
    Write-Host ' Activate in PowerShell:'
    Write-Host "   . `"$winDir\env.ps1`""
    Write-Host '============================================================================'
}

# ===========================================================================
#  Main                                                                       
# ===========================================================================
# Resolve --win-toolchain=auto. The prebuilt toolchain (gs://chrome-wintoolchain)
# is Google-internal and NOT anonymously downloadable, so external users must use
# a locally installed Visual Studio (0). Prefer that when VS is present.
if ($WinToolchain -eq 'auto') {
    if (Test-VisualStudio) {
        $WinToolchain = '0'
        Write-Ok 'Visual Studio found -> DEPOT_TOOLS_WIN_TOOLCHAIN=0 (local VS).'
    } else {
        $WinToolchain = '1'
        Write-Warn2 'No Visual Studio found -> trying DEPOT_TOOLS_WIN_TOOLCHAIN=1 (Google-internal toolchain).'
    }
}
if ($WinToolchain -eq '0' -and -not (Test-VisualStudio)) {
    Write-Warn2 'DEPOT_TOOLS_WIN_TOOLCHAIN=0 requires Visual Studio, but none was found.'
    Write-Warn2 'Install Visual Studio 2026 (or Build Tools) with "Desktop development'
    Write-Warn2 'with C++" and the "MFC/ATL" component, then re-run.'
}
if ($WinToolchain -eq '1' -and -not (Test-VisualStudio) -and -not $WinToolchainUrl) {
    Write-Warn2 'DEPOT_TOOLS_WIN_TOOLCHAIN=1 downloads a Google-internal prebuilt toolchain'
    Write-Warn2 'and only works on Google''s internal network. External users should install'
    Write-Warn2 'Visual Studio and use --win-toolchain 0, or provide --win-toolchain-url.'
}

$requestedVars = Get-RequestedCustomVars
$depsFingerprint = Get-DepsFingerprint -Vars $requestedVars
$pgoProfilesOn = ($requestedVars['checkout_pgo_profiles'] -eq 'True')

Write-Host '============================================================================'
Write-Host ' Chromium Windows download (build is a separate step)'
Write-Host '============================================================================'
Write-Host " Root        : $Root"
Write-Host " depot_tools : $DepotTools"
Write-Host " Source      : $Src"
Write-Host " Version     : $VersionReq"
Write-Host " Started     : $(Format-Stamp $runStart)"
Write-Host " History     : shallow (--no-history, depth 1)"
Write-Host " Export      : $(if ($MakeOfflineRepo) { if ($Cleanup) { 'yes (--make-offline-repo, --cleanup)' } else { 'yes (--make-offline-repo, workspace kept)' } } else { 'no (workspace only)' })"
Write-Host " Pinned      : $(if ($Pinned) { 'yes (fetch only this revision)' } else { 'no (fetch main, then switch)' })"
if ($pgoProfilesOn) {
    Write-Host ' PGO profiles: yes (checkout_pgo_profiles=True; hooks fetch the .profdata)'
} else {
    Write-Host ' PGO profiles: no (--no-extra-deps or --deps checkout_pgo_profiles=False)'
}
if ($Pgo) {
    Write-Host ' PGO build   : chrome_pgo_phase=2 (release; pass it to the build script)'
} else {
    Write-Host ' PGO build   : not forced (build auto-disables PGO when the profile is missing)'
}
Write-Host " Arch        : $(if ($Arch) { $Arch } else { 'host default (x64)' })"
Write-Host " WinToolchain: DEPOT_TOOLS_WIN_TOOLCHAIN=$WinToolchain"
Write-Host '============================================================================'

# ---- 0. exported snapshot: skip, or refuse an implicit update ---------------
# A successful export commits <src>\init_tools\.offline_repo.state and leaves
# exactly 2 commits with our subjects. Such a tree is a READ-ONLY deliverable:
#   * same branch/version/deps/toolchain -> nothing to do (no network at all)
#   * anything else without --make-offline-repo -> refuse BEFORE fetch/checkout
#     (a normal "version update" would replace init_tools with the real tree)
if (-not $DepotToolsOnly) {
    $marker = Read-OfflineMarker -Src $Src -Root $Root
    $snapshot = [bool]$marker
    if (-not $snapshot) { $snapshot = Test-OfflineSnapshotRepo -Src $Src }
    if ($snapshot) {
        # "stable" still needs one network lookup, so a newly released stable is
        # not skipped; tagged/numeric requests resolve locally.
        $checkResolved = $null
        try {
            if ($MilestoneReq) { $checkResolved = Resolve-Milestone -Milestone ([int]$MilestoneReq) }
            else { $checkResolved = Resolve-RequestedVersion -Requested $VersionReq }
        } catch {
            $checkResolved = $null
        }
        $checkUrl  = Resolve-ToolchainBaseUrl -Url $WinToolchainUrl
        $checkHash = if ($checkUrl) { Get-LocalToolchainHash -ExplicitHash $WinToolchainHash -BaseUrl $checkUrl } else { '' }
        $checkBranch = ''
        if ($checkResolved) { $checkBranch = Get-OfflineBranchName -Src $Src -Kind $checkResolved.Kind }
        $upToDate = $false
        if ($marker -and $checkResolved -and $checkBranch) {
            $upToDate = Test-OfflineRepoComplete -Src $Src -ExpectedBranch $checkBranch `
                -ExpectedRef $checkResolved.Ref -DepsFingerprint $depsFingerprint `
                -ToolchainUrl $checkUrl -ToolchainHash $checkHash -Marker $marker
        }
        if ($upToDate) {
            $vi = Get-ChromiumVersionInfo -Src $Src
            $c1 = [string]$marker['commit1']
            if ($c1.Length -gt 10) { $c1 = $c1.Substring(0, 10) }
            $c2 = ((& git -C $Src rev-parse --short HEAD) | Out-String).Trim()
            Write-Host ''
            Write-Host '============================================================================'
            Write-Host ' Offline repository already complete - nothing to update'
            Write-Host '============================================================================'
            Write-Host " Repository   : $Src"
            Write-Host " Branch       : $checkBranch"
            Write-Host " Commits      : $c1 (source) -> $c2 (init_tools)"
            Write-Host " Marker       : $($marker['_path'])"
            if ($checkUrl) { Write-Host " WinToolchain : $checkUrl ($checkHash)" }
            Write-Host ' Skip         : fetch / gclient sync / runhooks / export'
            Write-Host '============================================================================'
            if ($Cleanup) {
                Remove-ExportScratch -Root $Root -Src $Src -Major $vi.Major -GclientFile $GclientFile
            } else {
                $scratch = @('src_git_bak', 'src_gitignore_bak', '.gclient', '.cipd', 'depot_tools') |
                    Where-Object { Test-Path -LiteralPath (Join-Path $Root $_) }
                if (@($scratch).Count -gt 0) {
                    Write-Ok 'Workspace kept (default). Pass --cleanup to remove backups/.gclient/.cipd/depot_tools.'
                } else {
                    Write-Ok 'Workspace already clean (previous --cleanup); nothing to keep.'
                }
            }
            Write-Host ''
            Write-Host ' To force a re-export: delete the marker and add --make-offline-repo'
            Write-Host ('   Remove-Item "{0}"' -f (Get-OfflineMarkerPath -Src $Src))
            Write-Host '   (or dirty the worktree / add a commit, then add --make-offline-repo)'
            Write-Host ' Activate in cmd.exe:'
            Write-Host ('   call "{0}"' -f (Join-Path $Src 'init_tools\win\env.bat'))
            Write-Host '============================================================================'
            exit 0
        }

        # Snapshot exists but the request/deps/toolchain do not match (or the
        # marker is gone). Never "update" it implicitly.
        if (-not $MakeOfflineRepo -and -not $SkipFetch) {
            Write-Host ''
            Write-Host '============================================================================'
            Write-Host ' Exported offline snapshot detected - refusing to update it'
            Write-Host '============================================================================'
            Write-Host " Repository   : $Src"
            if ($checkResolved) { Write-Host " Requested    : $($checkResolved.Ref)" }
            if ($marker) {
                Write-Host " Marker       : $($marker['_path'])"
            } else {
                Write-Host ' Marker       : (missing; detected by the 2 snapshot commits)'
            }
            Write-Host ' Why          : without --make-offline-repo this run would do a'
            Write-Host '                "git fetch + checkout" of the real Chromium branch,'
            Write-Host '                which deletes init_tools (not in that tree).'
            Write-Host ' Nothing was changed.'
            Write-Host ''
            Write-Host ' Options:'
            Write-Host '   * build it          : chromium_build_win.bat --dir <root> ...'
            Write-Host '   * refresh/re-export : add --make-offline-repo'
            Write-Host '   * another version   : use a different --dir or --dest-name'
            Write-Host '============================================================================'
            exit 3
        }
        # --make-offline-repo : refresh the snapshot (fall through)
        # --skip-fetch        : use the tree as-is (no fetch/checkout)
    }
}

if ($Root -match '\s') {
    Write-Warn2 "WARNING: the path '$Root' contains spaces. Chromium builds can fail with spaces in the path."
}

if ($AddDefenderExclusions) {
    Write-Step 'Adding Windows Defender exclusions'
    Add-DefenderExclusions
}

# ---- 1. git + depot_tools (shared bootstrap script) -------------------------
# For a specific Chromium version, resolve the exact depot_tools commit from
# Chromium DEPS and make sure the local checkout is at that commit BEFORE any
# gclient/fetch operation. DEPOT_TOOLS_UPDATE=0 is set only after verification.
$bootstrapChromiumVersion = ''
$preResolved = $null
if (-not $NoPinDepotTools -and -not $DepotToolsVersion) {
    try {
        if ($MilestoneReq) {
            $preResolved = Resolve-Milestone -Milestone ([int]$MilestoneReq)
        } else {
            $preResolved = Resolve-RequestedVersion -Requested $VersionReq
        }
        $bootstrapChromiumVersion = $preResolved.Ref
    } catch {
        Write-Warn2 "Could not pre-resolve Chromium version for depot_tools pinning: $($_.Exception.Message)"
    }
}

Write-Step 'Bootstrapping git + depot_tools'
$bootstrapArgs = @{
    Root         = $Root
    DepotTools   = $DepotTools
    BootstrapGit = $BootstrapGit
}
if ($DepotToolsVersion) {
    $bootstrapArgs.Version = $DepotToolsVersion
} elseif ($bootstrapChromiumVersion) {
    $bootstrapArgs.ChromiumVersion = $bootstrapChromiumVersion
    Write-Ok "Chromium version for depot_tools pin: $bootstrapChromiumVersion"
}
try {
    $depotInfo = Initialize-DepotTools @bootstrapArgs
} catch {
    if ($bootstrapChromiumVersion -and -not $DepotToolsVersion) {
        Write-Warn2 "Could not pin depot_tools to Chromium '$bootstrapChromiumVersion': $($_.Exception.Message)"
        Write-Warn2 'Falling back to existing/latest depot_tools.'
        $bootstrapArgs.Remove('ChromiumVersion')
        $depotInfo = Initialize-DepotTools @bootstrapArgs
    } else {
        throw
    }
}
$DepotTools = $depotInfo.DepotTools
# Children (fetch.bat/gclient, python helpers) inherit this; keep it pointing
# at the depot_tools we actually bootstrapped, never at the old env value.
$env:DEPOT_TOOLS_PATH = $DepotTools
# depot_tools must be at the FRONT of PATH.
$env:PATH = "$DepotTools;$env:PATH"
Write-Ok "depot_tools: $DepotTools"
Write-Ok "git        : $($depotInfo.Git)"
Write-Ok "python     : $($depotInfo.Python3)"
if ($depotInfo.Current) { Write-Ok "HEAD       : $($depotInfo.Current)" }
# depot_tools is already pinned/bootstrapped. Never let fetch/gclient
# self-update it mid-run: that needs network, can move it off the pin, and is
# the source of the "Updating depot_tools..." messages.
$env:DEPOT_TOOLS_UPDATE = '0'

# ---- 2. environment ---------------------------------------------------------
# 1 = prebuilt win_toolchain (internal bucket, or a mirror via the URL below);
# 0 = use a locally installed Visual Studio.
$env:DEPOT_TOOLS_WIN_TOOLCHAIN = $WinToolchain
if ($WinToolchainUrl) {
    # get_toolchain_if_necessary.py accepts a directory that contains
    # "<toolchain-hash>.zip", either a local path (file://) or an http(s) URL.
    $u = Resolve-ToolchainBaseUrl -Url $WinToolchainUrl
    $env:DEPOT_TOOLS_WIN_TOOLCHAIN_BASE_URL = $u
    Write-Ok "Win toolchain archive base URL: $u"
    if ($u -notmatch '^https?://') { $ToolchainUrlLocalDir = $u }   # local dir -> can auto-detect the zip
}

# gclient itself is ready to use: Initialize-DepotTools validated/bootstrapped
# Python and CIPD. Do not run "gclient" with no arguments here, because that can
# trigger a depot_tools self-update even when the local checkout is already OK.

# ---- 3b. stop here for --depot-tools-only ----------------------------------
# depot_tools is now cloned, configured and bootstrapped (python/CIPD). Nothing
# else is downloaded. Print how to use it and exit.
if ($DepotToolsOnly) {
    Write-Host ''
    Write-Host '============================================================================'
    Write-Host ' depot_tools is ready'
    Write-Host '============================================================================'
    Write-Host " Location : $DepotTools"
    Write-Host " gclient  : $GclientBat"
    Write-Host ''
    Write-Host ' To use it in your own shell (cmd.exe):'
    Write-Host "   set PATH=$DepotTools;%PATH%"
    Write-Host '   set DEPOT_TOOLS_WIN_TOOLCHAIN=1     & rem (or 0 to use local VS)'
    Write-Host ' (PowerShell)'
    Write-Host "   `$env:PATH = `"$DepotTools;`$env:PATH`""
    Write-Host '   gclient'
    Write-Host ''
    Write-Host ' Then, to get Chromium later, run this script WITHOUT --depot-tools-only,'
    Write-Host ' or:  mkdir <root>\chromium && fetch --nohooks --no-history chromium'
    Write-Host '============================================================================'
    exit 0
}

# ---- 7. resolve requested version (before fetch: needed by --pinned) --------
if ($preResolved) {
    $resolved = $preResolved
    $reqLabel = if ($MilestoneReq) { "milestone '$MilestoneReq'" } else { "version '$VersionReq'" }
    Write-Step "Resolved $reqLabel -> $($resolved.Ref) [$($resolved.Note)]"
} elseif ($MilestoneReq) {
    $resolved = Resolve-Milestone -Milestone ([int]$MilestoneReq)
    Write-Step "Resolved milestone '$MilestoneReq' -> $($resolved.Ref) [$($resolved.Note)]"
} else {
    $resolved = Resolve-RequestedVersion -Requested $VersionReq
    Write-Step "Resolved version '$VersionReq' -> $($resolved.Ref) [$($resolved.Note)]"
}

# ---- 8. fetch source --------------------------------------------------------
# A checkout is only "present" if BOTH .gclient and the source directory exist.
# (.gclient can remain after the source dir is deleted, e.g. when starting over
# for a minimal pinned checkout.)
#
# --dest-name NEVER renames an existing checkout: that case was rejected early
# with a manual Move-Item instruction. Everything below derives from
# $Src / $SrcName, never the literal "src".

if (-not (Test-Path -LiteralPath $Src) -and (Test-Path -LiteralPath (Join-Path $LegacyChromium 'src'))) {
    # Migrate the old <root>\chromium\src layout to <root>\<dest-name>; .gclient and
    # its state files move up one level and keep their relative solution name.
    Write-Step 'Migrating legacy chromium\src to the source directory'
    Move-PathWithRetry -Source (Join-Path $LegacyChromium 'src') -Destination $Src
    foreach ($f in @('.gclient', '.gclient_entries', '.gclient_previous_custom_vars',
                     '.gclient_previous_sync_commits', '.gcs_entries')) {
        $legacy = Join-Path $LegacyChromium $f
        $dest = Join-Path $Root $f
        if ((Test-Path -LiteralPath $legacy) -and -not (Test-Path -LiteralPath $dest)) {
            Move-PathWithRetry -Source $legacy -Destination $dest
        }
    }
    Write-Ok "Source is now $Src"
}

$hasGclient = Test-Path -LiteralPath $GclientFile

# A failed --make-offline-repo leaves src\.git as the new snapshot repo (no
# "origin") and the real checkout under src_git_bak. Recover it automatically so
# simply re-running the script repairs the workspace (PIT-022).
Restore-FailedExport -Root $Root -Src $Src

# A "source" directory without chrome\VERSION is not a Chromium checkout (e.g.
# only init_tools left after the tree was deleted, or an interrupted export).
# Move it aside so a fresh fetch can run; never delete user data.
$srcVersionFile = Join-Path $Src 'chrome\VERSION'
if ((Test-Path -LiteralPath $Src) -and
    -not (Test-Path -LiteralPath $srcVersionFile) -and
    -not $SkipFetch) {
    $staleSrc = Join-Path $Root ('_stale_src_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
    Write-Warn2 "Source directory is not a Chromium checkout (chrome\VERSION missing): $Src"
    Write-Warn2 "Moving it aside to: $staleSrc"
    Move-PathWithRetry -Source $Src -Destination $staleSrc
    Write-Ok "Stale source moved aside (delete it when no longer needed)."
}
$hasSrc = Test-Path -LiteralPath $srcVersionFile

# --skip-fetch only requires the SOURCE to exist. A missing .gclient is fine
# (e.g. re-exporting a checkout whose config was already moved into
# init_tools\<MAJOR>\config): the export step handles this case.
if ($hasSrc) {
    if ($hasGclient) {
        Write-Ok 'Chromium source already present, skipping fetch.'
    } else {
        Write-Ok "Source present but no .gclient at $GclientFile; continuing without one."
    }
} elseif ($SkipFetch) {
    throw "Source directory not found: $Src (and --skip-fetch was given)."
} elseif ($hasGclient) {
    Write-Ok 'Existing .gclient found but src is missing; gclient sync will recreate it.'
} else {
    New-Item -ItemType Directory -Force -Path $Chromium | Out-Null
    if ($Pinned) {
        # Smallest .git: configure gclient, then sync ONLY the requested
        # revision (no intermediate shallow sync of main).
        Write-Step 'Configuring gclient for a single pinned checkout'
        Invoke-Gclient -GclientFile $GclientFile -Arguments @('config', '--name', $SrcName, '--unmanaged', $ChromiumUrl)
    } else {
        Write-Step 'Fetching Chromium source (this can take a very long time)'
        # --no-history = shallow (depth 1) checkout: smallest possible .git
        $fetchArgs = @('--nohooks', '--no-history', 'chromium')
        $attempts = $Retries + 1
        for ($attempt = 1; $attempt -le $attempts; $attempt++) {
            try {
                # "fetch" only works on an empty directory: once the first attempt
                # has created .gclient/src, every retry must resume with
                # "gclient sync" (otherwise attempts 2..N always fail with
                # "Your current directory appears to already contain ... a checkout").
                $legacyGclient = Join-Path $LegacyChromium '.gclient'
                if (-not (Test-Path -LiteralPath $GclientFile) -and -not (Test-Path -LiteralPath $legacyGclient)) {
                    Invoke-Native -FilePath $FetchBat -ArgumentList $fetchArgs -WorkingDirectory $Chromium
                } else {
                    $resumeGclient = if (Test-Path -LiteralPath $GclientFile) { $GclientFile } else { $legacyGclient }
                    Write-Warn2 'Partial checkout found; resuming with "gclient sync" instead of "fetch".'
                    # Pin the sha when src already has a valid HEAD; otherwise the
                    # ref-based revision can trigger a full fetch (PIT-016).
                    $resumeSyncArgs = @('sync', '--nohooks', '--no-history')
                    $resumeSha = if (Test-Path -LiteralPath $Src) { Get-HeadSha -SourceDir $Src } else { '' }
                    if ($resumeSha) { $resumeSyncArgs += @('--revision', ($SrcName + '@' + $resumeSha)) }
                    Invoke-Gclient -GclientFile $resumeGclient -Arguments $resumeSyncArgs
                }
                # fetch creates <root>\chromium\{src,.gclient,...}; move them up
                # to the requested <root>\src layout.
                $fetchedSrc = Join-Path $LegacyChromium 'src'
                if ((Test-Path -LiteralPath $fetchedSrc) -and -not (Test-Path -LiteralPath $Src)) {
                    Move-PathWithRetry -Source $fetchedSrc -Destination $Src
                }
                foreach ($f in @('.gclient', '.gclient_entries', '.gclient_previous_custom_vars',
                                 '.gclient_previous_sync_commits', '.gcs_entries')) {
                    $legacy = Join-Path $LegacyChromium $f
                    $dest = Join-Path $Root $f
                    if ((Test-Path -LiteralPath $legacy) -and -not (Test-Path -LiteralPath $dest)) {
                        Move-PathWithRetry -Source $legacy -Destination $dest
                    }
                }
                break
            } catch {
                if ($attempt -lt $attempts) {
                    $wait = 30 * $attempt
                    Write-Warn2 "fetch attempt $attempt/$attempts failed; retrying in $wait s..."
                    Write-Warn2 '(429/network errors are usually transient; path/config errors are not - see the output above.)'
                    Start-Sleep -Seconds $wait
                    continue
                }
                Write-Host ''
                Write-Warn2 'fetch failed. Common causes:'
                Write-Warn2 '  * Google source servers rate-limited you:'
                Write-Warn2 '    "RESOURCE_EXHAUSTED ... HTTP 429" / "expected packfile"'
                Write-Warn2 '  * a download stalled (look for "STALL DETECTED")'
                Write-Warn2 '  * Windows Defender quarantined a CIPD package:'
                Write-Warn2 '    "contains a virus or potentially unwanted software"'
                Write-Warn2 '  * flaky network / proxy / disk space'
                Write-Host ''
                Write-Warn2 'You can simply re-run this script: an existing .gclient makes it'
                Write-Warn2 'resume with "gclient sync" instead of fetching from scratch.'
                Write-Warn2 'For Defender, run as Administrator:'
                Write-Warn2 "  Add-MpPreference -ExclusionPath `"$Root`""
                Write-Warn2 'or re-run with --add-defender-exclusions. Manual resume:'
                Write-Warn2 "  cd `"$Src`"; gclient sync --nohooks --no-history"
                throw
            }
        }
    }
}

# Leftover git temp packs from an interrupted fetch are never reused - drop them.
# (No-op when src does not exist yet; gclient sync will create it below.)
Remove-StaleTmpPacks

# ---- 9. enable optional dependency gates (before sync / runhooks) -----------
# Writing custom_vars before the sync makes gclient fetch the extra deps now,
# while the network is available.
Set-GclientCustomVars -Vars $requestedVars

# ---- 10. apply the requested revision ---------------------------------------
if ($resolved.Kind -eq 'main') {
    # Complete/repair the checkout (also recovers from a previous aborted fetch).
    if (-not $SkipFetch) {
        Write-Step 'Syncing dependencies (gclient sync --nohooks --no-history)'
        # Same guard as Set-ChromiumRevision: pin the solution to the current
        # 40-hex sha, otherwise gclient may run a full (non-shallow) fetch of
        # Chromium history on an already-shallow repo (PIT-016). "-D" drops
        # dependencies that are no longer in DEPS (see Set-ChromiumRevision).
        $mainSyncArgs = @('sync', '--nohooks', '--no-history', '-D')
        $headSha = Get-HeadSha -SourceDir $Src
        if ($headSha) {
            $mainSyncArgs += @('--revision', ($SrcName + '@' + $headSha))
        }
        Remove-BrokenDependencyRepos -Root $Root -Src $Src -SrcName $SrcName
        Invoke-Gclient -GclientFile $GclientFile -Arguments $mainSyncArgs
    }
} elseif ($SkipFetch) {
    Write-Ok 'Skipping revision application (--skip-fetch); using existing source.'
} else {
    # Only fall back to the latest stable when the requested ref truly does not
    # exist upstream. A failed sync (e.g. transient HTTP 429 on a dependency)
    # must NOT silently change the requested version.
    $status = Get-ChromiumRefStatus -Ref $resolved.Ref
    Write-Ok "Revision check: $($resolved.Ref) -> $status upstream"

    if ($status -eq 'missing') {
        Write-Warn2 "Revision '$($resolved.Ref)' does not exist upstream - falling back to latest stable."
        $fallback = Resolve-RequestedVersion -Requested 'stable'
        if ($fallback.Ref -ne $resolved.Ref -and (Get-ChromiumRefStatus -Ref $fallback.Ref) -eq 'found') {
            Set-ChromiumRevision -Resolved $fallback
            $resolved = $fallback
            Write-Ok "Checked out fallback $($resolved.Ref)"
        } else {
            throw "Requested revision '$($resolved.Ref)' was not found and no fallback is available."
        }
    } else {
        try {
            Set-ChromiumRevision -Resolved $resolved
            Write-Ok "Checked out $($resolved.Ref)"
        } catch {
            Write-Warn2 "Sync of '$($resolved.Ref)' failed: $($_.Exception.Message)"
            if ($status -eq 'unknown') {
                Write-Warn2 'The revision could not be verified (network problem?).'
            } else {
                Write-Warn2 'The revision DOES exist - this was most likely a transient'
                Write-Warn2 'failure (HTTP 429 rate limiting / network). The version was NOT'
                Write-Warn2 'changed. Simply re-run this script to resume.'
            }
            throw
        }
    }
}

if ($RunGc) {
    Write-Step 'Running git gc (prunes unreachable objects to shrink .git)'
    Invoke-Native -FilePath 'git' -ArgumentList @('-C', $Src, 'gc', '--prune=now')
}

# ---- dependency integrity check (warn only) --------------------------------
Test-DependencyIntegrity -Src $Src -GclientRoot $Root

# ---- map a self-built toolchain archive to the canonical hash ---------------
# Chromium's build/vs_toolchain.py does:
#   os.environ.get('GYP_MSVS_HASH_' + TOOLCHAIN_HASH, TOOLCHAIN_HASH)
# so a locally packaged archive (<local-hash>.zip) can satisfy the canonical
# <TOOLCHAIN_HASH>.zip request. With a local --win-toolchain-url directory the
# local hash is auto-detected; for http pass --win-toolchain-hash explicitly.
if ($WinToolchainUrl) {
    $localHash = $WinToolchainHash
    if (-not $localHash -and $ToolchainUrlLocalDir -and (Test-Path -LiteralPath $ToolchainUrlLocalDir -PathType Container)) {
        $zips = @(Get-ChildItem -LiteralPath $ToolchainUrlLocalDir -Filter '*.zip' -File -ErrorAction SilentlyContinue)
        if ($zips.Count -eq 1) {
            $localHash = $zips[0].BaseName
        } elseif ($zips.Count -gt 1) {
            Write-Warn2 "Multiple .zip files found in $ToolchainUrlLocalDir; pass --win-toolchain-hash."
        }
    }
    if ($localHash) {
        $canonical = Get-CanonicalToolchainHash
        if ($canonical) {
            Set-Item -Path ("Env:GYP_MSVS_HASH_" + $canonical) -Value $localHash
            Write-Ok "Toolchain hash mapping: GYP_MSVS_HASH_$canonical=$localHash"
        } else {
            Write-Warn2 'Could not read TOOLCHAIN_HASH from build/vs_toolchain.py.'
            Write-Warn2 'Set GYP_MSVS_HASH_<canonical> manually if the download 404s.'
        }
    }
}

# ---- hooks -> download complete toolchain (+ PGO profiles when enabled) -----
if (-not $SkipHooks) {
    Write-Step 'Running gclient runhooks (downloads the complete win_toolchain)'
    # The first vpython venv build is occasionally blocked/rolled back by
    # antivirus, so retry like the other network steps.
    $attempts = $Retries + 1
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        try {
            Invoke-Gclient -GclientFile $GclientFile -Arguments @('runhooks')
            break
        } catch {
            if ($attempt -lt $attempts) {
                $wait = 30 * $attempt
                Write-Warn2 "runhooks attempt $attempt/$attempts failed; retrying in $wait s..."
                Start-Sleep -Seconds $wait
                continue
            }
            Write-Host ''
            Write-Warn2 'gclient runhooks failed. Common causes:'
            Write-Warn2 '  * "401"/"403" or "chrome-wintoolchain": the prebuilt toolchain is'
            Write-Warn2 '    Google-internal. Install Visual Studio / Build Tools with'
            Write-Warn2 '    "Desktop development with C++" + "MFC/ATL", then run with'
            Write-Warn2 '    --win-toolchain 0.'
            Write-Warn2 '  * vpython/venv creation error: usually transient; re-run the script.'
            throw
        }
    }
} else {
    Write-Warn2 'Skipping gclient runhooks (--skip-hooks). The toolchain may be missing.'
}

if ($MakeOfflineRepo) {
    if ($SkipHooks) {
        Write-Warn2 '--make-offline-repo with --skip-hooks: dependencies may be incomplete.'
    }
    Invoke-MakeOfflineRepo -Root $Root -Src $Src -DepotTools $DepotTools `
        -ScriptDir $ScriptDir -GclientFile $GclientFile `
        -SccacheUrl $SccacheUrl -SccacheSha256 $SccacheSha256 `
        -VersionKind $resolved.Kind -VersionDisplay $resolved.Display `
        -VersionRequest $VersionReq -VersionRef $resolved.Ref `
        -DepsFingerprint $depsFingerprint `
        -ToolchainArchiveDir $ToolchainUrlLocalDir -ToolchainHash $WinToolchainHash `
        -ToolchainUrl (Resolve-ToolchainBaseUrl -Url $WinToolchainUrl) `
        -Cleanup:$Cleanup
    # PGO profiles live in <src>\chrome\build\pgo_profiles and are part of the export.
    Show-PgoStatus -SourceDir $Src -ArchName $Arch -Requested $pgoProfilesOn
    exit 0
}

# ---- download-only finish ---------------------------------------------------
# This script never builds. chromium_build_win.bat does that and needs no
# network access, so the workspace above stays untouched for it.
Remove-TransientDirs -Root $Root
Write-Host ''
Write-Host '============================================================================'
Write-Host ' Download complete (nothing built)'
Write-Host '============================================================================'
Write-Host " Root       : $Root"
Write-Host " Source     : $Src"
Write-Host " Revision   : $($resolved.Ref)"
Write-Host " Toolchain  : DEPOT_TOOLS_WIN_TOOLCHAIN=$($env:DEPOT_TOOLS_WIN_TOOLCHAIN)"
Show-PgoStatus -SourceDir $Src -ArchName $Arch -Requested $pgoProfilesOn
$finishTime = Get-Date
Write-Host " Started    : $(Format-Stamp $runStart)"
Write-Host " Finished   : $(Format-Stamp $finishTime)"
Write-Host (" Elapsed    : {0}" -f (Format-Elapsed ([int](($finishTime - $runStart).TotalSeconds))))
Write-Host ''
Write-Host ' Next:'
Write-Host "   $(Join-Path $ScriptDir 'chromium_build_win.bat') --release --targets content_shell"
Write-Host '   (or add --make-offline-repo above to produce a self-contained repo)'
Write-Host '============================================================================'
exit 0
