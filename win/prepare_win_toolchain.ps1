# ============================================================================
#  prepare_win_toolchain.ps1
#  ---------------------------------------------------------------------------
#  Download + silently install the missing Windows build prerequisites, then
#  package the Chromium-required Visual Studio into a Chromium-compatible
#  win_toolchain archive so that chromium_download_win.ps1 can consume it with
#  --win-toolchain-url, WITHOUT having to install Visual Studio on the build
#  machine.
#
#  Editions (--vs-edition): buildtools (default, free, no IDE), community,
#  professional, enterprise. Choose by LICENSE: community is for individuals /
#  small orgs only; companies should use buildtools or professional/enterprise.
#
#  Single install switch:
#    --install-deps   Ensure the Chromium-required VS + components + Windows SDK
#                     + Debugging Tools for Windows. Only missing pieces are
#                     installed (idempotent). Missing installers are downloaded
#                     from the official Microsoft locations below, unless a
#                     local installer is supplied.
#
#  Installer locations (all optional):
#    --installer-dir DIR       Search DIR for vs_<Edition>.exe and
#                              winsdksetup.exe before downloading.
#    --vs-bootstrapper PATH|URL  Explicit VS bootstrapper (file, directory or
#                              https URL).
#    --sdk-installer PATH|URL|DIR Explicit winsdksetup.exe (file, directory or
#                              https URL).
#
#  If neither --install-deps nor --skip-install is given, the script only
#  checks and packages; it does not install anything.
#
#  Requirements
#    - Windows 10/11 x64, Administrator for --install-deps
#    - Several GB free disk, Internet access for downloads
#    - depot_tools (it ships win_toolchain\package_from_installed.py). A
#      Chromium checkout is OPTIONAL: it is only used to auto-read
#      TOOLCHAIN_HASH + SDK_VERSION, which you can pass via
#      --canonical-hash / --sdk-version instead.
#
#  Examples
#    # branch 7871, fully automatic (hash/SDK/VS derived from the version)
#    .\prepare_win_toolchain.ps1 --dir C:\wt --depot-tools C:\test\depot_tools `
#        --install-deps --chromium-version 7871
#
#    # Exact tag or main also work (only small metadata files are fetched)
#    .\prepare_win_toolchain.ps1 --dir C:\wt --depot-tools C:\test\depot_tools `
#        --install-deps --chromium-version 150.0.7871.289
#    .\prepare_win_toolchain.ps1 --dir C:\wt --depot-tools C:\test\depot_tools `
#        --install-deps --chromium-version main
#
#    # Use local installers first, then fall back to Microsoft downloads
#    .\prepare_win_toolchain.ps1 --dir C:\wt --depot-tools C:\test\depot_tools `
#        --install-deps --installer-dir D:\installers `
#        --canonical-hash e66617bc68 --sdk-version 10.0.26100.0
#
#    # Explicit installer URLs
#    .\prepare_win_toolchain.ps1 --dir C:\wt --depot-tools C:\test\depot_tools `
#        --install-deps `
#        --vs-bootstrapper "https://aka.ms/vs/stable/vs_BuildTools.exe" `
#        --sdk-installer "https://go.microsoft.com/fwlink/?linkid=2349110" `
#        --canonical-hash e66617bc68 --sdk-version 10.0.26100.0
#
#    # VS already installed; only Debugging Tools are missing
#    .\prepare_win_toolchain.ps1 --dir C:\wt --depot-tools C:\test\depot_tools `
#        --install-deps --sdk-installer C:\Downloads\winsdksetup.exe `
#        --canonical-hash e66617bc68 --sdk-version 10.0.26100.0
#
#    # Package only (no downloads, no installs)
#    .\prepare_win_toolchain.ps1 --dir C:\wt --depot-tools C:\test\depot_tools `
#        --skip-install --canonical-hash e66617bc68 --sdk-version 10.0.26100.0
#
#  NOTE: --install-deps performs real VS/SDK installs and needs Administrator.
# ============================================================================

$ErrorActionPreference = 'Stop'

# Shared git/depot_tools bootstrap (also used by chromium_download_win.ps1).
$BootstrapScript = Join-Path $PSScriptRoot 'bootstrap_depot_tools.ps1'
if (-not (Test-Path -LiteralPath $BootstrapScript)) {
    throw "Could not find $BootstrapScript (required for git/depot_tools bootstrap)."
}
. $BootstrapScript

# ---------------------------------------------------------------------------
#  Official Microsoft download locations.
#  Update these here if Microsoft changes a link. All can be overridden on the
#  command line with --vs-bootstrapper / --vs-boot-url / --sdk-installer.
# ---------------------------------------------------------------------------
$OfficialVsChannel         = 'stable'   # stable == VS 2026
$OfficialVsBootUrlNamed    = 'https://aka.ms/vs/{0}/vs_{1}.exe'         # named channel
$OfficialVsBootUrlNumeric  = 'https://aka.ms/vs/{0}/release/vs_{1}.exe' # numeric major
$OfficialSdkInstallerUrl   = 'https://go.microsoft.com/fwlink/?linkid=2349110'  # SDK 10.0.26100.7705
$OfficialSdkInstallerUrls  = @{
    # Chromium branch 7871 / Chrome 150 uses SDK_VERSION = 10.0.26100.0.
    # This is the official 10.0.26100.7705 installer (matching the branch's
    # "10.0.26100.7705" toolchain comment). Any 26100 servicing installer also
    # works; override with --sdk-installer if you need a different build.
    '10.0.26100.0' = 'https://go.microsoft.com/fwlink/?linkid=2349110'
    # Chromium main (2026) uses SDK_VERSION = 10.0.28000.0.
    # Official 10.0.28000.2957 installer from the Windows SDK downloads page.
    '10.0.28000.0' = 'https://go.microsoft.com/fwlink/?linkid=2382519'
}
$OfficialSdkDownloadsPage  = 'https://learn.microsoft.com/en-us/windows/apps/windows-sdk/downloads'

# ---------------------------------------------------------------------------
#  Options
# ---------------------------------------------------------------------------
$WorkDir        = $PSScriptRoot
$SrcDirName     = 'src'              # --src-dir: source dir name under --dir
$ChromiumSrc    = ''                 # optional: only needed to read TOOLCHAIN_HASH/SDK_VERSION
$ChromiumVersion = ''                # optional: e.g. 7871, 150.0.7871.289, main, stable
$CanonicalHash  = ''                 # optional: canonical TOOLCHAIN_HASH (if no chromium/src)
$OutDir         = ''
$VsInstallDir   = ''
$DepotTools     = ''                 # top-level depot_tools (packager + python3.bat)
$Bootstrapper   = ''                 # explicit VS installer: path, dir or URL
$BootUrl        = ''                 # advanced: override derived VS installer URL
$BootUrlExplicit = $false
$VsWorkload     = ''                 # '' -> derived from --vs-edition
$VsEdition      = 'buildtools'       # buildtools | community | professional | enterprise
$VsChannel      = ''                 # '' -> derived from the Chromium-preferred VS version
$VsChannelExplicit = $false
$Arm64          = $true              # ARM64 included by default (Chromium's own package does)
$SkipInstall    = $false             # package only; never install
$InstallDeps    = $false             # ensure VS + SDK + Debuggers (idempotent)
$PreferInstalled = $false            # use any existing compatible VS (any edition)
$InstallerDir   = ''                 # optional directory to search for installers
$SdkVersion     = ''
$SdkInstaller   = ''                 # explicit winsdksetup: path, dir or URL
$PinDepotTools  = $false             # use the depot_tools commit pinned by Chromium DEPS
$ShowDeps       = $false             # print resolved VS/SDK/depot_tools and exit
$BootstrapGit   = $true              # auto-download PortableGit when git is missing
$NoBootstrapDepotTools = $false      # never clone/fetch depot_tools automatically
$ForceRepack    = $false             # rebuild the archive even if inputs are unchanged
$DryRun         = $false
$Help           = $false

$argv = @($args)
$i = 0
while ($i -lt $argv.Count) {
    $raw = [string]$argv[$i]
    $opt = $raw
    $inline = $null
    if ($raw -match '^(--?[^=]+)=(.*)$') { $opt = $matches[1]; $inline = $matches[2] }

    switch ($opt) {
        '--help'       { $Help = $true }
        '-h'           { $Help = $true }
        '/?'           { $Help = $true }
        '--with-arm64' { $Arm64 = $true }
        '--no-arm64'   { $Arm64 = $false }
        '--noarm'      { $Arm64 = $false }   # matches package_from_installed.py
        '--skip-install' { $SkipInstall = $true }
        '--install-deps' { $InstallDeps = $true }
        '--install-sdk' {
            throw '--install-sdk has been replaced by --install-deps. Use --install-deps to install VS/SDK/Debugging Tools.'
        }
        '--prefer-installed' { $PreferInstalled = $true }
        '--pin-depot-tools' { $PinDepotTools = $true }
        '--show-deps'  { $ShowDeps = $true }
        '--resolve-only' { $ShowDeps = $true }
        '--no-bootstrap-git' { $BootstrapGit = $false }
        '--no-bootstrap-depot-tools' { $NoBootstrapDepotTools = $true }
        '--force-repack' { $ForceRepack = $true }
        '--repack'       { $ForceRepack = $true }
        '--dry-run'    { $DryRun = $true }
        default {
            $valueOptions = @('--dir', '--src-dir', '--chromium-src', '--chromium-version', '--version',
                              '--canonical-hash', '--out', '--vs-install-dir',
                              '--depot-tools', '--vs-bootstrapper', '--vs-boot-url', '--vs-workload',
                              '--sdk-version', '--vs-edition', '--vs-channel', '--sdk-installer',
                              '--installer-dir')
            if ($valueOptions -contains $opt) {
                $v = $inline
                if ($null -eq $v) {
                    $i++
                    if ($i -ge $argv.Count) { throw "Option $opt requires a value." }
                    $v = [string]$argv[$i]
                }
                switch ($opt) {
                    '--dir'            { $WorkDir = $v }
                    '--src-dir'        { $SrcDirName = $v }
                    '--chromium-src'   { $ChromiumSrc = $v }
                    '--chromium-version' { $ChromiumVersion = $v }
                    '--version'        { $ChromiumVersion = $v }
                    '--canonical-hash' { $CanonicalHash = $v }
                    '--out'            { $OutDir = $v }
                    '--vs-install-dir' { $VsInstallDir = $v }
                    '--depot-tools'    { $DepotTools = $v }
                    '--vs-bootstrapper'{ $Bootstrapper = $v }
                    '--vs-boot-url'    { $BootUrl = $v; $BootUrlExplicit = $true }
                    '--vs-workload'    { $VsWorkload = $v }
                    '--sdk-version'    { $SdkVersion = $v }
                    '--vs-edition'     { $VsEdition = $v }
                    '--vs-channel'     { $VsChannel = $v; $VsChannelExplicit = $true }
                    '--sdk-installer'  { $SdkInstaller = $v }
                    '--installer-dir'  { $InstallerDir = $v }
                }
            } else {
                Write-Warning "Unknown option: $raw"
            }
        }
    }
    $i++
}

if ($SkipInstall -and $InstallDeps) {
    throw '--skip-install and --install-deps are mutually exclusive.'
}
$DoInstall = $InstallDeps

function Show-Help {
    Write-Host @'
Usage: prepare_win_toolchain.ps1 [options]

Ensures the Windows build prerequisites are present, then packages the
Chromium-required Visual Studio + Windows SDK into a Chromium win_toolchain
archive usable with chromium_download_win.ps1 --win-toolchain-url.

Installation is opt-in:
  * --install-deps         install missing VS/SDK/Debugging Tools (idempotent)
  * no switch / --skip-install
                           only check and package; never install or download

Options:
  --dir DIR              Work directory. Default: this script's directory.
  --src-dir NAME         Source directory name under --dir (default: src).
                         Use it when the checkout is renamed (chromium_src).
                         Auto-detection also checks <script>\..\.. so it works
                         from an exported offline repo (<src>\init_tools\win).
  --chromium-src DIR     OPTIONAL. A chromium/src checkout. If present, the
                         canonical TOOLCHAIN_HASH and SDK_VERSION are read from
                         its build/vs_toolchain.py.
  --chromium-version VER
  --version VER          OPTIONAL. Resolve a Chromium revision remotely and
                         read only build/vs_toolchain.py (plus chrome/VERSION):
                          7871               -> refs/branch-heads/7871
                          150.0.7871.289     -> refs/tags/...
                          main / beta        -> refs/heads/...
                          stable / latest    -> latest stable tag via Chromium Dash
                         It derives TOOLCHAIN_HASH, SDK_VERSION, the preferred
                         Visual Studio version, and the exact depot_tools commit
                         pinned by Chromium's DEPS (src/third_party/depot_tools).
                         No full source download.
                         For 7871 / 150.0.7871.289: VS 2026 + SDK 10.0.26100.0.
                         For main (2026-11):       VS 2026 + SDK 10.0.28000.0.
                         For 131.0.6778.85:        VS 2022 + SDK 10.0.22621.0.
                         IMPORTANT: when this option is set, depot_tools is
                         ALWAYS checked against the DEPS pin, even if a local
                         checkout already exists. If it differs, the checkout is
                         updated to the pin, verified, then
                         DEPOT_TOOLS_UPDATE=0 is set.
                         If the selected packager is too new for the requested
                         VS, use --pin-depot-tools to fetch the DEPS-pinned
                         packager files (no full depot_tools clone needed).
  --canonical-hash H     OPTIONAL override. Canonical TOOLCHAIN_HASH of the
                         Chromium revision you will build. For branch 7871 it is
                         e66617bc68. Normally derived from --chromium-version or
                         --chromium-src. Used to write
                         GYP_MSVS_HASH_<H>=<local> into TOOLCHAIN_INFO.txt.
  --depot-tools DIR      depot_tools clone. Provides
                         win_toolchain/package_from_installed.py + python3.bat.
                         Default: <root>\depot_tools, else the chromium/src
                         vendored copy. If none is found, this script now
                         bootstraps git/depot_tools automatically via the shared
                         bootstrap_depot_tools.ps1.
  --no-bootstrap-git     Never auto-download PortableGit.
  --no-bootstrap-depot-tools
                         Never auto-clone/fetch depot_tools; require an existing
                         checkout (the old behavior).
  --out DIR              Where the resulting <hash>.zip + mapping are written.
                         Default: <dir>\win_toolchain_archive.
  --vs-install-dir DIR   Install location for VS.
                         Default: <dir>\<Edition> for VS 2026, otherwise
                         <dir>\<Edition><year> (e.g. BuildTools2022).

  --install-deps         Ensure the Chromium-required Visual Studio, its
                         components, Windows SDK and "Debugging Tools for
                         Windows" are installed. Only missing pieces are
                         installed; already valid installations are untouched.
                         Missing installers are downloaded from the official
                         Microsoft URLs at the top of this script.
                         Requires Administrator.
  --pin-depot-tools      With --chromium-version: read the exact depot_tools
                         commit pinned by Chromium's DEPS
                         (src/third_party/depot_tools) and use that era's
                         win_toolchain packager files. This is the reliable way
                         to package an old Chromium that needs an older VS.
                         Only two small Python files are fetched; no full
                         depot_tools clone/bootstrap is needed.
  --show-deps            Resolve and print Chromium version, VS/toolset, SDK,
                         canonical hash, DEPS-pinned depot_tools commit and
                         packager VS support, then exit 0.
  --force-repack         Rebuild the archive even when TOOLCHAIN_INFO.txt says
                         the VS/SDK/packager/fingerprint state is unchanged.
                         By default an up-to-date <local-hash>.zip is reused.
  --skip-install         Do not install or download anything; only check and
                         package. Mutually exclusive with --install-deps.
                         This is also the default when no install switch is
                         given.
  --installer-dir DIR    Optional. Search DIR for both installers before
                         downloading:
                           vs_<Edition>.exe
                           winsdksetup.exe / winsdksetup-<sdk-version>.exe
                         Missing files are downloaded to <work>\installers.
  --vs-bootstrapper P    Optional VS installer: a file path, a directory to
                         search, or an https URL. Default: download from
                         https://aka.ms/vs/<channel>/vs_<Edition>.exe using
                         the channel derived from the Chromium-preferred VS
                         (stable/18 for 2026, 17 for 2022, 16 for 2019).
  --vs-boot-url URL      Advanced: override the derived VS installer URL.
                         Prefer --vs-bootstrapper <URL>.
  --vs-edition E         buildtools (default) | community | professional |
                         enterprise. Pick by license, NOT by preference:
                           buildtools  - free, no IDE, recommended for CI;
                                         use for both individuals and companies
                                         (review the EULA for company use).
                           community   - free IDE, ONLY for individuals /
                                         small orgs (<250 users and <$1M
                                         revenue). NOT licensed for large
                                         enterprises.
                           professional/enterprise - use these (or your
                                         company's existing VS license) for
                                         internal company development.
  --vs-channel C         aka.ms channel. Default: derived from the
                         Chromium-preferred VS (stable for 2026, 17 for 2022,
                         16 for 2019). A numeric major also works, e.g. 17 ->
                         aka.ms/vs/17/release/...
  --vs-workload ID       Override the VS workload id. Default is derived from
                         --vs-edition (VCTools for buildtools, NativeDesktop
                         otherwise).
  --sdk-installer P      Optional winsdksetup.exe: a file path, a directory to
                         search, or an https URL. Default: download the official
                         SDK installer for --sdk-version (for 10.0.26100.0 this
                         is the 10.0.26100.7705 installer).
  --sdk-version VER      OPTIONAL override. Windows SDK version. Normally
                         derived from --chromium-version or --chromium-src
                         (SDK_VERSION), e.g. 10.0.26100.0.
  --no-arm64             EXCLUDE the ARM64 tools. By default ARM64 IS included
                         (VC.Tools.ARM64 + VC.MFC.ARM64 + the arm SDK parts),
                         matching Chromium's own toolchain. Use --no-arm64
                         (alias --noarm) for a smaller x86/x64-only package.
  --with-arm64           Kept for compatibility; ARM64 is already the default.
  --prefer-installed     If a compatible instance of the required Visual Studio
                         version already exists (ANY edition), use it instead of
                         the requested edition; components are still verified.
  --dry-run              Only print what would run; never download or install.
  -h, --help             Show this help.

Official download locations (edit at the top of the script if they change):
  VS bootstrapper : https://aka.ms/vs/stable/vs_BuildTools.exe
  SDK installer   : https://go.microsoft.com/fwlink/?linkid=2349110
                    (Windows SDK 10.0.26100.7705)
                    https://go.microsoft.com/fwlink/?linkid=2382519
                    (Windows SDK 10.0.28000.2957)
  SDK downloads   : https://learn.microsoft.com/en-us/windows/apps/windows-sdk/downloads

Windows SDK note:
  Chromium needs ONE specific SDK version (SDK_VERSION in build/vs_toolchain.py),
  not necessarily the newest. package_from_installed.py also needs the
  "Debugging Tools for Windows" feature; without it the archive packages but
  Chromium's gn copy_dlls step fails because Debuggers\<cpu>\dbghelp.dll is
  required.

Idempotency:
  Repeated runs are safe. VS components, the SDK version and
  Debuggers\<cpu>\dbghelp.dll are checked before any installer runs; only
  missing pieces are installed. Downloaded installers are cached under
  <work>\installers (SDK installers are versioned, e.g.
  winsdksetup-10.0.28000.0.exe) and validated (PE + Authenticode) before reuse.

Examples (branch 7871 = Chrome 150.0.7871.289, hash e66617bc68,
          SDK 10.0.26100.0):

  Resolve hash/SDK/VS from a Chromium version (recommended; only small files
  build/vs_toolchain.py and chrome/VERSION are fetched, not the full source):
     .\prepare_win_toolchain.ps1 --dir C:\wt --depot-tools C:\test\depot_tools --install-deps --chromium-version 7871
     .\prepare_win_toolchain.ps1 --dir C:\wt --depot-tools C:\test\depot_tools --install-deps --chromium-version 150.0.7871.289
     .\prepare_win_toolchain.ps1 --dir C:\wt --depot-tools C:\test\depot_tools --install-deps --chromium-version main
     .\prepare_win_toolchain.ps1 --dir C:\wt --depot-tools C:\test\depot_tools --install-deps --chromium-version stable

  Inspect only (no install, no package), including VS, SDK and the exact
  depot_tools commit pinned by Chromium's DEPS:
     .\prepare_win_toolchain.ps1 --dir C:\wt --depot-tools C:\test\depot_tools --chromium-version 7871 --show-deps
     .\prepare_win_toolchain.ps1 --dir C:\wt --depot-tools C:\test\depot_tools --chromium-version 131.0.6778.85 --show-deps

  Old Chromium (VS 2022): use the DEPS-pinned era-matched packager:
     .\prepare_win_toolchain.ps1 --dir C:\wt --depot-tools C:\test\depot_tools --install-deps --pin-depot-tools --chromium-version 131.0.6778.85

  1) Fully automatic with explicit hash/SDK (override):
     .\prepare_win_toolchain.ps1 --dir C:\wt --depot-tools C:\test\depot_tools --install-deps --canonical-hash e66617bc68 --sdk-version 10.0.26100.0

  2) Prefer local installers in D:\installers, fall back to downloads:
     .\prepare_win_toolchain.ps1 --dir C:\wt --depot-tools C:\test\depot_tools --install-deps --installer-dir D:\installers --canonical-hash e66617bc68 --sdk-version 10.0.26100.0

  3) Explicit official URLs:
     .\prepare_win_toolchain.ps1 --dir C:\wt --depot-tools C:\test\depot_tools --install-deps --vs-bootstrapper "https://aka.ms/vs/stable/vs_BuildTools.exe" --sdk-installer "https://go.microsoft.com/fwlink/?linkid=2349110" --canonical-hash e66617bc68 --sdk-version 10.0.26100.0

  4) VS is already installed; only Debugging Tools are missing:
     .\prepare_win_toolchain.ps1 --dir C:\wt --depot-tools C:\test\depot_tools --install-deps --sdk-installer C:\Downloads\winsdksetup.exe --canonical-hash e66617bc68 --sdk-version 10.0.26100.0

  5) Package only (no downloads, no installs):
     .\prepare_win_toolchain.ps1 --dir C:\wt --depot-tools C:\test\depot_tools --skip-install --canonical-hash e66617bc68 --sdk-version 10.0.26100.0

  6) VS Community from an explicit URL, plus a local SDK installer:
     .\prepare_win_toolchain.ps1 --dir C:\wt --depot-tools C:\test\depot_tools --install-deps --vs-edition community --vs-bootstrapper "https://aka.ms/vs/stable/vs_Community.exe" --sdk-installer C:\Downloads\winsdksetup.exe --canonical-hash e66617bc68 --sdk-version 10.0.26100.0

  7) VS 2026 numeric channel 18, with explicit URLs for both installers:
     .\prepare_win_toolchain.ps1 --dir C:\wt --depot-tools C:\test\depot_tools --install-deps --vs-channel 18 --vs-bootstrapper "https://aka.ms/vs/18/release/vs_BuildTools.exe" --sdk-installer "https://go.microsoft.com/fwlink/?linkid=2349110" --canonical-hash e66617bc68 --sdk-version 10.0.26100.0
'@
}
if ($Help) { Show-Help; exit 0 }

# ---- normalize the VS edition -----------------------------------------------
$VsEdition = ([string]$VsEdition).ToLowerInvariant()
if (@('buildtools', 'community', 'professional', 'enterprise') -notcontains $VsEdition) {
    throw "Invalid --vs-edition '$VsEdition' (expected buildtools|community|professional|enterprise)."
}
$editionExeName = @{ buildtools = 'BuildTools'; community = 'Community';
                     professional = 'Professional'; enterprise = 'Enterprise' }[$VsEdition]
$vsExeName = "vs_$editionExeName.exe"
if (-not $VsWorkload) {
    $VsWorkload = if ($VsEdition -eq 'buildtools') {
        'Microsoft.VisualStudio.Workload.VCTools'
    } else {
        'Microsoft.VisualStudio.Workload.NativeDesktop'
    }
}
function Write-Step { param([string]$T) Write-Host "==> $T" -ForegroundColor Cyan }
function Write-Ok   { param([string]$T) Write-Host "    $T" -ForegroundColor Green }
function Write-Warn2{ param([string]$T) Write-Host "    $T" -ForegroundColor Yellow }

function Invoke-Native {
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @(), [string]$WorkingDirectory)
    Write-Host "  > $FilePath $($ArgumentList -join ' ')" -ForegroundColor DarkGray
    if ($DryRun) { return }
    if ($WorkingDirectory) { Push-Location -LiteralPath $WorkingDirectory }
    try { & $FilePath @ArgumentList } finally { if ($WorkingDirectory) { Pop-Location } }
    if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        throw "Command failed ($LASTEXITCODE): $FilePath $($ArgumentList -join ' ')"
    }
}

# For GUI installers (the VS bootstrapper, winsdksetup): launch, WAIT, and read
# the real exit code. PowerShell's "&" does NOT wait for GUI apps, so
# $LASTEXITCODE can be empty and look like a failure.
function Invoke-Wait {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory,
        [int[]]$SuccessCodes = @(0, 3010)   # 3010 = success, reboot required
    )
    $quoted = $ArgumentList | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
    $argStr = ($quoted -join ' ')
    Write-Host "  > $FilePath $argStr" -ForegroundColor DarkGray
    if ($DryRun) { return }
    $sp = @{ FilePath = $FilePath; ArgumentList = $argStr; PassThru = $true; Wait = $true; NoNewWindow = $true }
    if ($WorkingDirectory) { $sp['WorkingDirectory'] = $WorkingDirectory }
    $p = Start-Process @sp
    if ($SuccessCodes -notcontains $p.ExitCode) {
        throw "Command failed ($($p.ExitCode)): $FilePath $argStr"
    }
    Write-Ok "exit code $($p.ExitCode)"
}

function Test-Administrator {
    # WindowsIdentity/WindowsPrincipal are non-core types (blocked in
    # ConstrainedLanguage), so read the integrity level from whoami instead:
    # High (S-1-16-12288) or System (S-1-16-16384) means elevated.
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $groups = (& whoami /groups 2>$null | Out-String)
    } finally {
        $ErrorActionPreference = $oldEap
    }
    return ($groups -match 'S-1-16-12288' -or $groups -match 'S-1-16-16384')
}

# True if the file exists and looks like a Windows PE executable (starts 'MZ',
# at least 1 MB). Used to reject HTML from a redirect / stale bad download.
function Test-PeFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if ((Get-Item -LiteralPath $Path).Length -lt 1MB) { return $false }
    # 'MZ' magic via cmdlets: System.IO.File is blocked in ConstrainedLanguage.
    $head = @(Read-FileBytes -Path $Path -Count 2)
    if ($head.Count -lt 2) { return $false }
    return ($head[0] -eq 0x4D -and $head[1] -eq 0x5A)   # 'MZ'
}

# Downloaded installers must be PE files signed by Microsoft.
function Test-TrustedDownload {
    param([string]$Path)
    if (-not (Test-PeFile -Path $Path)) { return $false }
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        if ($sig.Status -ne 'Valid') { return $false }
        if (-not $sig.SignerCertificate) { return $false }
        if ($sig.SignerCertificate.Subject -notmatch 'Microsoft') { return $false }
        return $true
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
#  Windows SDK / Debugging Tools state.
#  package_from_installed.py only checks that the Debuggers directory exists,
#  but Chromium's build/toolchain/win/BUILD.gn runs vs_toolchain.py copy_dlls
#  which requires Debuggers\<cpu>\dbghelp.dll. Check the real requirement.
# ---------------------------------------------------------------------------
function Test-DebuggersReady {
    param([string]$Root, [bool]$Arm64 = $true)
    if (-not $Root -or -not (Test-Path -LiteralPath $Root)) { return $false }
    $cpus = @('x64')
    if ($Arm64) { $cpus += 'arm64' }
    foreach ($cpu in $cpus) {
        $p = Join-Path $Root "Debuggers\$cpu\dbghelp.dll"
        if (-not (Test-Path -LiteralPath $p)) { return $false }
    }
    return $true
}

function Get-WindowsSdkInfo {
    param([string]$Version, [bool]$Arm64 = $true)
    $root = $null
    foreach ($reg in @('HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots',
                       'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots')) {
        if (Test-Path $reg) {
            $v = (Get-ItemProperty -Path $reg -Name KitsRoot10 -ErrorAction SilentlyContinue).KitsRoot10
            if ($v) { $root = $v.TrimEnd('\'); break }
        }
    }
    $res = [ordered]@{ Root = $root; HasVersion = $false; HasDebuggers = $false; Versions = @() }
    if ($root -and (Test-Path $root)) {
        $inc = Join-Path $root 'Include'
        if (Test-Path $inc) {
            $res.Versions = @(Get-ChildItem -LiteralPath $inc -Directory -ErrorAction SilentlyContinue |
                              ForEach-Object { $_.Name })
        }
        if ($Version -and (Test-Path (Join-Path $inc $Version))) { $res.HasVersion = $true }
        $res.HasDebuggers = Test-DebuggersReady -Root $root -Arm64:$Arm64
    }
    return $res
}

# ---------------------------------------------------------------------------
#  Chromium version resolution (remote, single-file fetch).
#
#  We only fetch build/vs_toolchain.py (and optionally chrome/VERSION) from
#  gitiles. This is enough to derive TOOLCHAIN_HASH, SDK_VERSION and the
#  preferred Visual Studio version without downloading the full source tree.
# ---------------------------------------------------------------------------
function Get-GitilesText {
    param(
        [Parameter(Mandatory = $true)][string]$Ref,
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Repo = 'chromium/src'
    )
    $uri = 'https://chromium.googlesource.com/' + $Repo + '/+/' + $Ref + '/' + $Path + '?format=TEXT'
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Uri $uri -TimeoutSec 120
        return (ConvertFrom-GitilesBase64 -Base64 ([string]$r.Content))
    } catch {
        $code = $null
        try { $code = [int]$_.Exception.Response.StatusCode } catch { $code = $null }
        if ($code -eq 404) {
            throw "Chromium path '$Path' was not found at '$Ref'."
        }
        throw "Could not fetch '$uri': $($_.Exception.Message)"
    }
}

function Get-StableChromiumTag {
    $uri = 'https://chromiumdash.appspot.com/fetch_releases?channel=Stable&platform=Windows&num=5'
    try {
        $rel = Invoke-RestMethod -UseBasicParsing -Uri $uri -TimeoutSec 60
    } catch {
        throw "Could not resolve the latest stable Chromium version: $($_.Exception.Message)"
    }
    if (@($rel).Count -eq 0) {
        throw 'Chromium Dash returned no stable Windows release.'
    }
    $first = @($rel)[0]
    $tag = [string]$first.version
    if (-not $tag) {
        throw 'Chromium Dash returned no stable Windows release.'
    }
    return $tag.Trim()
}

function Resolve-ChromiumRef {
    param([Parameter(Mandatory = $true)][string]$Requested)
    $r = $Requested.Trim()
    if ($r -eq '' -or $r -match '^(stable|latest|release)$') {
        $tag = Get-StableChromiumTag
        return [ordered]@{ Ref = "refs/tags/$tag"; Display = $tag; Kind = 'tag' }
    }
    if ($r -match '^\d+\.\d+\.\d+\.\d+$') {
        return [ordered]@{ Ref = "refs/tags/$r"; Display = $r; Kind = 'tag' }
    }
    if ($r -match '^\d+$') {
        return [ordered]@{ Ref = "refs/branch-heads/$r"; Display = $r; Kind = 'branch' }
    }
    if ($r -match '^branch-heads/') {
        return [ordered]@{ Ref = "refs/$r"; Display = $r; Kind = 'branch' }
    }
    if ($r -match '^refs/') {
        return [ordered]@{ Ref = $r; Display = $r; Kind = 'ref' }
    }
    if ($r -match '^[A-Za-z0-9._/-]+$') {
        return [ordered]@{ Ref = "refs/heads/$r"; Display = $r; Kind = 'branch' }
    }
    throw "Unrecognized Chromium version/ref: $Requested"
}

function Get-ToolchainInfoFromText {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$Request = '',
        [string]$Ref = '',
        [string]$Display = ''
    )
    $hash = $null
    $sdk = $null
    if ($Text -match "TOOLCHAIN_HASH\s*=\s*'([0-9a-fA-F]+)'") { $hash = $matches[1] }
    if ($Text -match "SDK_VERSION\s*=\s*'([0-9.]+)'") { $sdk = $matches[1] }

    $msvs = @()
    $m = [regex]::Match($Text, 'MSVS_VERSIONS\s*=\s*collections\.OrderedDict\(\s*\[(.*?)\]\s*\)',
                        [Text.RegularExpressions.RegexOptions]::Singleline)
    if ($m.Success) {
        foreach ($x in [regex]::Matches($m.Groups[1].Value, "\('([^']+)'\s*,\s*'([^']+)'\)")) {
            $msvs += [ordered]@{ Version = $x.Groups[1].Value; ProductLine = $x.Groups[2].Value }
        }
    }

    $toolsets = @{}
    $m2 = [regex]::Match($Text, 'MSVC_TOOLSET_VERSION\s*=\s*\{(.*?)\}',
                         [Text.RegularExpressions.RegexOptions]::Singleline)
    if ($m2.Success) {
        foreach ($x in [regex]::Matches($m2.Groups[1].Value, "'([^']+)'\s*:\s*'([^']+)'")) {
            $toolsets[$x.Groups[1].Value] = $x.Groups[2].Value
        }
    }

    $preferred = if ($msvs.Count -gt 0) { $msvs[0].Version } else { '' }
    $preferredToolset = if ($preferred -and $toolsets.ContainsKey($preferred)) { $toolsets[$preferred] } else { '' }
    return [ordered]@{
        Request = $Request
        Ref = $Ref
        Display = $Display
        CanonicalHash = $hash
        SdkVersion = $sdk
        MsvsVersions = $msvs
        Toolsets = $toolsets
        PreferredVs = $preferred
        PreferredToolset = $preferredToolset
        DepotToolsCommit = ''
    }
}

function Get-ChromiumToolchainInfo {
    param([Parameter(Mandatory = $true)][string]$VersionRequest)
    $resolved = Resolve-ChromiumRef -Requested $VersionRequest
    Write-Step "Resolving Chromium '$VersionRequest' -> $($resolved.Ref)"

    $text = Get-GitilesText -Ref $resolved.Ref -Path 'build/vs_toolchain.py'
    $info = Get-ToolchainInfoFromText -Text $text -Request $VersionRequest `
        -Ref $resolved.Ref -Display $resolved.Display
    if (-not $info.CanonicalHash) {
        throw "Could not parse TOOLCHAIN_HASH from $($resolved.Ref)/build/vs_toolchain.py."
    }
    if (-not $info.SdkVersion) {
        throw "Could not parse SDK_VERSION from $($resolved.Ref)/build/vs_toolchain.py."
    }

    # Best effort: show the real Chrome version for branch refs.
    try {
        $verText = Get-GitilesText -Ref $resolved.Ref -Path 'chrome/VERSION'
        $v = @{}
        foreach ($line in ($verText -split "`n")) {
            if ($line -match '^(\w+)=(\d+)') { $v[$matches[1]] = $matches[2] }
        }
        if ($v.ContainsKey('MAJOR') -and $v.ContainsKey('MINOR') -and
            $v.ContainsKey('BUILD') -and $v.ContainsKey('PATCH')) {
            $info.Display = "$($v['MAJOR']).$($v['MINOR']).$($v['BUILD']).$($v['PATCH'])"
        }
    } catch {
        # chrome/VERSION is optional; the ref-derived display is enough.
    }

    # Chromium's DEPS pins src/third_party/depot_tools to an exact commit.
    # This is the authoritative era-matched depot_tools version.
    try {
        $pin = Get-DepotToolsPin -Ref $resolved.Ref
        if ($pin) { $info.DepotToolsCommit = $pin }
    } catch {
        Write-Warn2 "Could not read the depot_tools pin from DEPS: $($_.Exception.Message)"
    }
    return $info
}

function Get-DepotToolsPinFromText {
    param([Parameter(Mandatory = $true)][string]$Text)
    $m = [regex]::Match($Text,
        'src/third_party/depot_tools.{0,4000}?depot_tools\.git.{0,1200}?([0-9a-f]{40})',
        [Text.RegularExpressions.RegexOptions]::Singleline)
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Get-DepotToolsPin {
    param([Parameter(Mandatory = $true)][string]$Ref)
    $uri = 'https://chromium.googlesource.com/chromium/src/+/' + $Ref + '/DEPS'
    try {
        $html = (Invoke-WebRequest -UseBasicParsing -Uri $uri -TimeoutSec 120).Content
    } catch {
        return $null
    }
    return (Get-DepotToolsPinFromText -Text $html)
}

# Fetch the exact era-matched packager files from the pinned depot_tools
# commit. package_from_installed.py + get_toolchain_if_necessary.py are
# stdlib-only, so no full depot_tools clone/bootstrap is required.
function Get-PinnedPackager {
    param(
        [Parameter(Mandatory = $true)][string]$Commit,
        [Parameter(Mandatory = $true)][string]$RootDir
    )
    $short = Get-CommitShortName -Commit $Commit
    $dir = Join-Path $RootDir "depot_tools_pinned\$short\win_toolchain"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    foreach ($f in @('package_from_installed.py', 'get_toolchain_if_necessary.py')) {
        $dest = Join-Path $dir $f
        $ok = (Test-Path -LiteralPath $dest) -and ((Get-Item -LiteralPath $dest).Length -gt 0)
        if (-not $ok) {
            Write-Step "Fetching pinned depot_tools/$f @ $short"
            $text = Get-GitilesText -Repo 'chromium/tools/depot_tools' -Ref $Commit -Path "win_toolchain/$f"
            # [IO.File]::WriteAllText + UTF8Encoding are blocked in
            # ConstrainedLanguage; write the exact UTF-8 bytes instead.
            Write-FileBytes -Path $dest -Bytes (Get-Utf8BytesNoBom -Text $text)
        }
    }
    return (Join-Path $dir 'package_from_installed.py')
}

function Get-PackagerSupportedVs {
    param([Parameter(Mandatory = $true)][string]$PackagerPath)
    $text = Get-Content -LiteralPath $PackagerPath -Raw
    $versions = @()
    if ($text -match 'SUPPORTED_VS_VERSIONS\s*=\s*\[([^\]]+)\]') {
        foreach ($m in [regex]::Matches($matches[1], "'([^']+)'")) {
            $versions += $m.Groups[1].Value
        }
    } elseif ($text -match "SUPPORTED_VS_VERSION\s*=\s*['""]([^'""]+)['""]") {
        $versions = @($matches[1])
    }
    return @($versions | Select-Object -Unique)
}

function Get-VsProductLineVersion {
    param([Parameter(Mandatory = $true)][string]$VsYear)
    $map = @{ '2026' = '18'; '2022' = '17'; '2019' = '16'; '2017' = '15' }
    if ($map.ContainsKey($VsYear)) { return $map[$VsYear] }
    return $null
}

function Get-OfficialSdkInstallerUrl {
    param([Parameter(Mandatory = $true)][string]$SdkVersion)
    if ($OfficialSdkInstallerUrls.ContainsKey($SdkVersion)) {
        return $OfficialSdkInstallerUrls[$SdkVersion]
    }
    if ($SdkVersion -notmatch '^10\.0\.(\d+)\.') { return $null }
    $build = $matches[1]
    $pages = @(
        $OfficialSdkDownloadsPage,
        'https://learn.microsoft.com/en-us/windows/apps/windows-sdk/downloads-archive'
    )
    foreach ($page in $pages) {
        try {
            $html = (Invoke-WebRequest -UseBasicParsing -Uri $page -TimeoutSec 120).Content
        } catch {
            continue
        }
        $m = [regex]::Match($html,
            "10\.0\.$build\.\d+[^0-9].{0,5000}?https://go\.microsoft\.com/fwlink/\?linkid=(\d+)",
            [Text.RegularExpressions.RegexOptions]::Singleline)
        if ($m.Success) {
            Write-Ok "Resolved official SDK installer from $page"
            return "https://go.microsoft.com/fwlink/?linkid=$($m.Groups[1].Value)"
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
#  Archive cache / input fingerprint.
#
#  The output zip is content-addressed (<local-hash>.zip). If the VS/SDK files,
#  packager and flags that determine the zip contents have not changed, a
#  repeated run can reuse the existing archive instead of re-zipping ~8 GB.
# ---------------------------------------------------------------------------
function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-PathFingerprint {
    param([string[]]$Paths)
    # ConstrainedLanguage has no Generic.List to grow, so stream the lines
    # through a temp file in batches, sort them, then hash the file. (Hashing a
    # multi-MB string through Get-Content -Encoding Byte would be far slower
    # than hashing a file, and this value only has to be stable per input.)
    $raw = Join-Path $env:TEMP ('fingerprint_' + [guid]::NewGuid().ToString('N') + '.raw')
    $sorted = Join-Path $env:TEMP ('fingerprint_' + [guid]::NewGuid().ToString('N') + '.txt')
    try {
        $chunk = @()
        $wrote = $false
        foreach ($p in @($Paths)) {
            if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
            $root = $p.TrimEnd('\')
            $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue)
            foreach ($f in $files) {
                $rel = $f.FullName.Substring($root.Length).TrimStart('\')
                $chunk += ($rel + '|' + $f.Length + '|' + $f.LastWriteTimeUtc.Ticks)
                if ($chunk.Count -ge 500) {
                    Add-Content -LiteralPath $raw -Value $chunk -Encoding UTF8
                    $chunk = @()
                    $wrote = $true
                }
            }
        }
        if ($chunk.Count -gt 0) {
            Add-Content -LiteralPath $raw -Value $chunk -Encoding UTF8
            $wrote = $true
        }
        if (-not $wrote) {
            Set-Content -LiteralPath $sorted -Value 'empty' -Encoding ASCII
        } else {
            $lines = @(Get-Content -LiteralPath $raw -Encoding UTF8 | Sort-Object)
            Set-Content -LiteralPath $sorted -Value $lines -Encoding UTF8
        }
        return (Get-FileHash -LiteralPath $sorted -Algorithm SHA256).Hash.ToLowerInvariant()
    } finally {
        Remove-Item -LiteralPath $raw -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $sorted -Force -ErrorAction SilentlyContinue
    }
}

function Get-PackagerFingerprint {
    param([Parameter(Mandatory = $true)][string]$PackagerPath)
    $parts = @()
    $parts += (Get-FileSha256 -Path $PackagerPath)
    $helper = Join-Path (Split-Path $PackagerPath -Parent) 'get_toolchain_if_necessary.py'
    if (Test-Path -LiteralPath $helper) {
        $parts += (Get-FileSha256 -Path $helper)
    }
    return ($parts -join ':')
}

function Write-ToolchainInfo {
    param(
        [Parameter(Mandatory = $true)][string]$InfoPath,
        [string]$CanonicalHash,
        [Parameter(Mandatory = $true)][string]$LocalHash,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$SdkVersion,
        [Parameter(Mandatory = $true)][string]$OutDir,
        [System.Collections.IDictionary]$State = @{},
        [string]$ArchiveSize = '',
        [string]$ArchiveSha256 = '',
        [string]$DownloadCommand = '',
        [string]$BuildCommand = ''
    )
    $lines = @(
        '# Generated by prepare_win_toolchain.ps1'
        "canonical_hash=$CanonicalHash"
        "local_hash=$LocalHash"
        "archive=$ArchivePath"
        "sdk_version=$SdkVersion"
        "DEPOT_TOOLS_WIN_TOOLCHAIN_BASE_URL=$OutDir\"
    )
    foreach ($k in @('vs_year', 'vs_product', 'vs_install_dir', 'vs_installation_version',
                     'msvc_toolset', 'arm64', 'packager_sha256', 'source_fingerprint')) {
        if ($State.Contains($k)) { $lines += "$k=$($State[$k])" }
    }
    if ($ArchiveSize)   { $lines += "archive_size=$ArchiveSize" }
    if ($ArchiveSha256) { $lines += "archive_sha256=$ArchiveSha256" }
    if ($DownloadCommand) { $lines += "download_command=$DownloadCommand" }
    if ($BuildCommand)    { $lines += "build_command=$BuildCommand" }
    if ($CanonicalHash) {
        $lines += "GYP_MSVS_HASH_$CanonicalHash=$LocalHash"
    } else {
        $lines += '# canonical hash unknown: set GYP_MSVS_HASH_<canonical>=' + $LocalHash + ' for your revision'
    }
    Set-Content -LiteralPath $InfoPath -Value $lines -Encoding ASCII
}

function Get-DownloadCommand {
    param(
        [Parameter(Mandatory = $true)][string]$OutDir,
        [Parameter(Mandatory = $true)][string]$LocalHash,
        [string]$ChromiumVersion = ''
    )
    $urlDir = $OutDir.Replace('\', '/').TrimEnd('/')
    $toolchainUrl = "file://$urlDir/"
    $ver = if ($ChromiumVersion) { $ChromiumVersion } else { '<version>' }
    return '.\chromium_download_win.ps1 --dir <build-root> --version ' + $ver +
        ' --win-toolchain-url "' + $toolchainUrl + '"' +
        ' --win-toolchain-hash ' + $LocalHash
}

function Get-BuildStepCommand {
    return '.\chromium_build_win.ps1 --dir <build-root> --release --targets content_shell'
}

function Show-BuildCommand {
    param(
        [Parameter(Mandatory = $true)][string]$DownloadCommand,
        [Parameter(Mandatory = $true)][string]$BuildCommand,
        [Parameter(Mandatory = $true)][string]$OutDir,
        [Parameter(Mandatory = $true)][string]$LocalHash,
        [string]$CanonicalHash = '',
        [string]$SdkVersion = '',
        $ChromiumInfo = $null
    )
    Write-Host ''
    Write-Host '============================================================================'
    Write-Host ' Use the generated toolchain (download and build are separate steps)'
    Write-Host '============================================================================'
    if ($ChromiumInfo) {
        Write-Host " Chromium : $($ChromiumInfo.Display) [$($ChromiumInfo.Ref)]"
    }
    Write-Host " Archive  : $OutDir\$LocalHash.zip"
    Write-Host " SDK      : $SdkVersion"
    if ($CanonicalHash) {
        Write-Host " Mapping  : GYP_MSVS_HASH_$CanonicalHash=$LocalHash"
    }
    Write-Host ''
    Write-Host ' 1) Download (needs network; replace <build-root> with a path without spaces):'
    Write-Host "      $DownloadCommand"
    Write-Host '    Optional: append --make-offline-repo to produce a self-contained repo.'
    Write-Host ''
    Write-Host ' 2) Build (no network, no gclient):'
    Write-Host "      $BuildCommand"
    Write-Host '    From an exported repo instead:'
    Write-Host '      <build-root>\src\init_tools\win\chromium_build_win.bat --release --targets content_shell'
    Write-Host '============================================================================'
}

# ---------------------------------------------------------------------------
#  Installer discovery / download.
# ---------------------------------------------------------------------------
function Get-InstallerFromDir {
    param([string]$Dir, [string]$ExactName, [string]$Pattern)
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir -PathType Container)) { return $null }

    if ($ExactName) {
        $exact = Join-Path $Dir $ExactName
        if (Test-Path -LiteralPath $exact -PathType Leaf) {
            if (Test-PeFile -Path $exact) { return (Resolve-Path -LiteralPath $exact).Path }
            Write-Warn2 "Ignoring invalid PE file: $exact"
        }
    }

    $files = @(Get-ChildItem -LiteralPath $Dir -File -Filter $Pattern -ErrorAction SilentlyContinue |
               Where-Object { Test-PeFile -Path $_.FullName } |
               Sort-Object LastWriteTime -Descending)
    if ($files.Count -eq 0) { return $null }
    if ($files.Count -gt 1) {
        Write-Warn2 "Multiple '$Pattern' files in $Dir; using newest: $($files[0].Name)"
    }
    return $files[0].FullName
}

function Download-Installer {
    param([string]$Name, [string]$Url, [string]$Dest, [string]$CacheDir)
    if (-not $Url) { throw "No download URL configured for $Name." }
    New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
    $tmp = "$Dest.tmp"
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }

    Write-Step "Downloading $Name"
    Write-Ok "URL : $Url"
    Write-Ok "Dest: $Dest"
    $old = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $tmp -MaximumRedirection 8 -TimeoutSec 1800
    } finally {
        $ProgressPreference = $old
    }

    if (-not (Test-TrustedDownload -Path $tmp)) {
        $len = if (Test-Path -LiteralPath $tmp) { (Get-Item -LiteralPath $tmp).Length } else { 0 }
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw @"
Downloaded file is not a trusted Microsoft installer (size=$len):
    $Url
Check the URL, proxy/firewall, or download the installer manually and pass
--vs-bootstrapper / --sdk-installer <path>.
"@
    }

    Move-Item -LiteralPath $tmp -Destination $Dest -Force
    Write-Ok "Downloaded and verified: $Dest"
    return $Dest
}

function Resolve-Installer {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Explicit,
        [string[]]$SearchDirs = @(),
        [Parameter(Mandatory = $true)][string]$ExactName,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [string]$Url,
        [Parameter(Mandatory = $true)][string]$CacheDir,
        [string]$CacheName = '',
        [bool]$DryRun = $false
    )
    if (-not $CacheName) { $CacheName = $ExactName }

    # 1. Explicit file / directory / URL.
    if ($Explicit) {
        if ($Explicit -match '^https?://') {
            $dest = Join-Path $CacheDir $CacheName
            if (Test-TrustedDownload -Path $dest) {
                Write-Ok "Using cached $Name : $dest"
                return $dest
            }
            if ($DryRun) {
                Write-Step "Would download $Name from $Explicit"
                Write-Ok "Into: $dest"
                return $dest
            }
            return Download-Installer -Name $Name -Url $Explicit -Dest $dest -CacheDir $CacheDir
        }
        if (Test-Path -LiteralPath $Explicit -PathType Container) {
            $found = Get-InstallerFromDir -Dir $Explicit -ExactName $ExactName -Pattern $Pattern
            if ($found) {
                if ($ExactName -like 'winsdksetup-*' -and (Split-Path -Leaf $found) -ne $ExactName) {
                    Write-Warn2 "Using $found; verify it matches $ExactName."
                }
                Write-Ok "Using $Name : $found"
                return $found
            }
            $looked = if ($Pattern -eq $ExactName) { $ExactName } else { "$ExactName / $Pattern" }
            Write-Warn2 "No $Name found in '$Explicit' (looked for $looked); falling back."
        } elseif (Test-Path -LiteralPath $Explicit -PathType Leaf) {
            if (-not (Test-PeFile -Path $Explicit)) {
                throw "Not a Windows PE executable: $Explicit"
            }
            Write-Ok "Using $Name : $Explicit"
            return (Resolve-Path -LiteralPath $Explicit).Path
        } else {
            throw "Installer path not found: $Explicit"
        }
    }

    # 2. Search the requested/cache directories.
    foreach ($dir in @($SearchDirs)) {
        if (-not $dir) { continue }
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        $found = Get-InstallerFromDir -Dir $dir -ExactName $ExactName -Pattern $Pattern
        if ($found) {
            if ($ExactName -like 'winsdksetup-*' -and (Split-Path -Leaf $found) -ne $ExactName) {
                Write-Warn2 "Using $found; verify it matches $ExactName."
            }
            Write-Ok "Using $Name : $found"
            return $found
        }
    }

    # 3. Cached download.
    $dest = Join-Path $CacheDir $CacheName
    if (Test-TrustedDownload -Path $dest) {
        Write-Ok "Using cached $Name : $dest"
        return $dest
    }
    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
    }

    # 4. Official download.
    if ($DryRun) {
        Write-Step "Would download $Name"
        Write-Ok "URL : $Url"
        Write-Ok "Dest: $dest"
        return $dest
    }
    return Download-Installer -Name $Name -Url $Url -Dest $dest -CacheDir $CacheDir
}

# ---------------------------------------------------------------------------
#  Visual Studio instance / component queries via vswhere.
#  Scoped to the productLineVersion derived from the Chromium revision:
#    2026 -> 18, 2022 -> 17, 2019 -> 16, 2017 -> 15
# ---------------------------------------------------------------------------
$script:Vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'

function Get-VsInstances {
    param([string]$ProductLineVersion = '18')
    if (-not (Test-Path -LiteralPath $script:Vswhere)) { return @() }
    $json = & $script:Vswhere -prerelease -products '*' -format json 2>$null
    if (-not $json) { return @() }
    try { $all = @($json | ConvertFrom-Json) } catch { return @() }
    return @($all | Where-Object {
        # vswhere -format json nests this under catalog.productLineVersion.
        # Older/newer formats may expose the flattened property; support both.
        $plv = $_.catalog.productLineVersion
        if (-not $plv) { $plv = $_.catalog_productLineVersion }
        $plv -eq $ProductLineVersion
    })
}

function Test-VsComponent {
    param(
        [Parameter(Mandatory)][string]$ProductId,
        [Parameter(Mandatory)][string]$ComponentId,
        [string]$ProductLineVersion = '18'
    )
    if (-not (Test-Path -LiteralPath $script:Vswhere)) { return $false }
    $min = "$ProductLineVersion.0"
    $max = "$([int]$ProductLineVersion + 1).0"
    $p = & $script:Vswhere -prerelease -products $ProductId -version "[$min,$max)" `
            -requires $ComponentId -property installationPath 2>$null
    return [bool]$p
}

function Test-VsLayout {
    # Fallback: some environments (e.g. Windows Sandbox/WDAG) install the files
    # but never register the instance with vswhere. A real VS layout has
    # <path>\VC\Tools\MSVC\14.* and <path>\Common7.
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $false }
    $msvc = Join-Path $Path 'VC\Tools\MSVC'
    if (-not (Test-Path -LiteralPath $msvc)) { return $false }
    $tools = @(Get-ChildItem -LiteralPath $msvc -Directory -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -like '14.*' })
    return ($tools.Count -gt 0)
}

$WorkDir = $WorkDir.TrimEnd('\','/')
if (-not $OutDir)      { $OutDir = Join-Path $WorkDir 'win_toolchain_archive' }
# $VsInstallDir default depends on the Chromium-preferred VS year; set below.
$CacheDir = Join-Path $WorkDir 'installers'

# ---- chromium/src (OPTIONAL) ------------------------------------------------
# Only used to auto-read TOOLCHAIN_HASH + SDK_VERSION. depot_tools alone is
# enough to package, if you pass --canonical-hash / --sdk-version.
if (-not $ChromiumSrc) {
    $SrcDirName = $SrcDirName.Trim().TrimEnd('\', '/')
    if (-not $SrcDirName -or $SrcDirName -match '[\\/]') {
        throw "Invalid --src-dir '$SrcDirName': it must be a single directory name, not a path."
    }
    $scriptParent = Split-Path $PSScriptRoot -Parent
    $workParent   = Split-Path $WorkDir -Parent
    $srcCands = @()
    foreach ($base in @($WorkDir, $scriptParent, $PSScriptRoot, $workParent)) {
        if ($base) { $srcCands += (Join-Path $base 'chromium\src') }
    }
    # Two-script layout: the source dir may have any name (--src-dir), and the
    # scripts may live inside <src>\init_tools\win (offline repo) or next to it.
    $srcCands += (Join-Path $WorkDir $SrcDirName)
    $srcCands += (Join-Path $WorkDir '..\..')
    $srcCands += (Join-Path $PSScriptRoot '..\..')
    foreach ($cand in $srcCands) {
        if ($cand -and (Test-Path (Join-Path $cand 'build\vs_toolchain.py'))) { $ChromiumSrc = $cand; break }
    }
}

# Auto-find depot_tools if not given (so the command line stays short).
if (-not $DepotTools) {
    $scriptParent = Split-Path $PSScriptRoot -Parent
    $workParent   = Split-Path $WorkDir -Parent
    $dtCands = @()
    foreach ($base in @($WorkDir, $scriptParent, $PSScriptRoot, $workParent)) {
        if ($base) { $dtCands += (Join-Path $base 'depot_tools') }
    }
    foreach ($dt in $dtCands) {
        if ($dt -and (Test-Path (Join-Path $dt 'win_toolchain\package_from_installed.py'))) { $DepotTools = $dt; break }
    }
}
if ($ChromiumSrc) { $ChromiumSrc = $ChromiumSrc.TrimEnd('\','/') }
$hasChromium = [bool]($ChromiumSrc -and (Test-Path (Join-Path $ChromiumSrc 'build\vs_toolchain.py')))
if ($ChromiumSrc -and -not $hasChromium) {
    Write-Warn2 "Ignoring --chromium-src '$ChromiumSrc' (no build\vs_toolchain.py found)."
    $ChromiumSrc = ''
}

# ---- depot_tools + the packager ---------------------------------------------
$dtRoot = ''                                      # <root> that contains depot_tools\ and chromium\
if ($ChromiumSrc) { $dtRoot = Split-Path (Split-Path $ChromiumSrc -Parent) -Parent }

function Find-WinToolchainPackager {
    param([string]$DepotToolsDir, [string]$DtRoot, [string]$ChromiumSrcDir)
    $cands = @()
    if ($DepotToolsDir) { $cands += (Join-Path $DepotToolsDir 'win_toolchain\package_from_installed.py') }
    if ($DtRoot)        { $cands += (Join-Path $DtRoot 'depot_tools\win_toolchain\package_from_installed.py') }
    if ($ChromiumSrcDir){ $cands += (Join-Path $ChromiumSrcDir 'third_party\depot_tools\win_toolchain\package_from_installed.py') }
    foreach ($c in $cands) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

$Packager = Find-WinToolchainPackager -DepotToolsDir $DepotTools -DtRoot $dtRoot -ChromiumSrcDir $ChromiumSrc

if ($ChromiumVersion) {
    # When a concrete Chromium version is requested, ALWAYS verify and enforce
    # the depot_tools commit pinned by its DEPS, even if a local depot_tools
    # already exists. Update first; set DEPOT_TOOLS_UPDATE=0 only after the
    # checkout has been verified.
    $pin = $null
    try {
        $preRef = Resolve-ChromiumRef -Requested $ChromiumVersion
        $pin = Get-DepotToolsPin -Ref $preRef.Ref
    } catch {
        throw "Could not resolve depot_tools pin for Chromium '$ChromiumVersion': $($_.Exception.Message)"
    }
    if (-not $pin) {
        if ($NoBootstrapDepotTools) {
            Write-Warn2 "Could not find a depot_tools pin in DEPS; skipping the version check because --no-bootstrap-depot-tools was given."
        } else {
            throw "Could not find src/third_party/depot_tools in DEPS for Chromium '$ChromiumVersion'. Re-run with --no-bootstrap-depot-tools to skip the version check."
        }
    } else {
        Write-Ok "Chromium DEPS depot_tools pin: $pin"

        if ($NoBootstrapDepotTools) {
            if (-not $DepotTools) { $DepotTools = Join-Path $WorkDir 'depot_tools' }
            if (-not (Test-Path -LiteralPath (Join-Path $DepotTools '.git'))) {
                throw "--no-bootstrap-depot-tools: no depot_tools git checkout at '$DepotTools' to verify against $pin."
            }
            $current = ((& git -C $DepotTools rev-parse HEAD 2>$null) | Out-String).Trim()
            $ok = ($current -eq $pin) -or ($current -and $current.StartsWith($pin))
            if (-not $ok) {
                throw "depot_tools version mismatch: requested $pin, current $current. Re-run without --no-bootstrap-depot-tools to update it."
            }
            $env:DEPOT_TOOLS_UPDATE = '0'
            Write-Ok "depot_tools already at $pin"
        } else {
            Write-Step 'Ensuring depot_tools matches the Chromium DEPS pin'
            $bootArgs = @{
                Root         = $WorkDir
                DepotTools   = $DepotTools
                BootstrapGit = $BootstrapGit
                Version      = $pin
            }
            $bootInfo = Initialize-DepotTools @bootArgs
            $DepotTools = $bootInfo.DepotTools
            $env:PATH = "$DepotTools;$env:PATH"
            Write-Ok "depot_tools: $DepotTools"
            Write-Ok "python     : $($bootInfo.Python3)"
            Write-Ok "pinned at  : $($bootInfo.Current)"
            if ($bootInfo.Current -and -not ($bootInfo.Current -eq $pin -or $bootInfo.Current.StartsWith($pin))) {
                throw "depot_tools checkout mismatch: requested $pin, current $($bootInfo.Current)"
            }
            $env:DEPOT_TOOLS_UPDATE = '0'
        }
    }

    if (-not $dtRoot) { $dtRoot = Split-Path $DepotTools -Parent }
    $Packager = Find-WinToolchainPackager -DepotToolsDir $DepotTools -DtRoot $dtRoot -ChromiumSrcDir $ChromiumSrc
} elseif (-not $Packager -and -not $NoBootstrapDepotTools) {
    # No Chromium version was requested: preserve the old behavior. Existing
    # depot_tools is reused; a missing one is cloned at latest main.
    Write-Step 'Bootstrapping git + depot_tools (shared script)'
    $bootArgs = @{
        Root         = $WorkDir
        DepotTools   = $DepotTools
        BootstrapGit = $BootstrapGit
    }
    $bootInfo = Initialize-DepotTools @bootArgs
    $DepotTools = $bootInfo.DepotTools
    $env:PATH = "$DepotTools;$env:PATH"
    Write-Ok "depot_tools: $DepotTools"
    Write-Ok "python     : $($bootInfo.Python3)"
    if ($bootInfo.Version) { Write-Ok "pinned at  : $($bootInfo.Version)" }

    if (-not $dtRoot) { $dtRoot = Split-Path $DepotTools -Parent }
    $Packager = Find-WinToolchainPackager -DepotToolsDir $DepotTools -DtRoot $dtRoot -ChromiumSrcDir $ChromiumSrc
}

if (-not $Packager) {
    throw @"
Could not find win_toolchain\package_from_installed.py.
Pass --depot-tools <a depot_tools clone> (it contains win_toolchain\),
or --chromium-src <chromium/src>.
Automatic bootstrap can be disabled with --no-bootstrap-depot-tools.
"@
}

# Resolve a Python launcher. package_from_installed.py + its import are
# stdlib-only, so any python3 works; python3.bat (CIPD python) is preferred
# over vpython3.bat (which builds a venv and can be blocked by antivirus).
function Resolve-Python {
    param([string]$DepotToolsDir, [string]$ChromiumSrcDir, [string]$RootDir)
    $cands = @()
    if ($DepotToolsDir)  { $cands += (Join-Path $DepotToolsDir 'python3.bat') }
    if ($RootDir)        { $cands += (Join-Path $RootDir 'depot_tools\python3.bat') }
    if ($ChromiumSrcDir) { $cands += (Join-Path $ChromiumSrcDir 'third_party\depot_tools\vpython3.bat') }
    foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    foreach ($n in @('python3', 'python')) {
        $g = Get-Command $n -ErrorAction SilentlyContinue
        if ($g) { return $g.Source }
    }
    return $null
}
$Python3 = Resolve-Python -DepotToolsDir $DepotTools -ChromiumSrcDir $ChromiumSrc -RootDir $dtRoot
if (-not $Python3) {
    throw 'No Python 3 found. Install Python 3, or pass --depot-tools <path with python3.bat>.'
}

# ---- resolve --chromium-version (remote, single-file fetch) -----------------
# 7871 / 150.0.7871.289 / main / stable are resolved to a gitiles ref. Only
# build/vs_toolchain.py (and best-effort chrome/VERSION) is downloaded.
$chromiumInfo = $null
$VsYear = '2026'
if ($ChromiumVersion) {
    if ($hasChromium) {
        Write-Warn2 'Both --chromium-version and --chromium-src were given; using the local source.'
        $vsText = Get-Content -LiteralPath (Join-Path $ChromiumSrc 'build\vs_toolchain.py') -Raw
        $chromiumInfo = Get-ToolchainInfoFromText -Text $vsText -Request $ChromiumVersion `
            -Ref '(local)' -Display '(local chromium/src)'
        $depsPath = Join-Path $ChromiumSrc 'DEPS'
        if (Test-Path -LiteralPath $depsPath) {
            $pin = Get-DepotToolsPinFromText -Text (Get-Content -LiteralPath $depsPath -Raw)
            if ($pin) { $chromiumInfo.DepotToolsCommit = $pin }
        }
    } else {
        try {
            $chromiumInfo = Get-ChromiumToolchainInfo -VersionRequest $ChromiumVersion
        } catch {
            if ($CanonicalHash -and $SdkVersion) {
                Write-Warn2 "Could not resolve Chromium '$ChromiumVersion': $($_.Exception.Message)"
                Write-Warn2 'Continuing with explicit --canonical-hash / --sdk-version.'
            } else {
                throw
            }
        }
    }
    if ($chromiumInfo) {
        Write-Ok "Chromium version : $($chromiumInfo.Display)"
        Write-Ok "Ref              : $($chromiumInfo.Ref)"
        Write-Ok "Canonical hash   : $($chromiumInfo.CanonicalHash)"
        Write-Ok "SDK version      : $($chromiumInfo.SdkVersion)"
        if ($chromiumInfo.PreferredVs) {
            Write-Ok "Preferred VS     : $($chromiumInfo.PreferredVs) (MSVC $($chromiumInfo.PreferredToolset))"
        }
        if (-not $CanonicalHash) { $CanonicalHash = $chromiumInfo.CanonicalHash }
        if (-not $SdkVersion) { $SdkVersion = $chromiumInfo.SdkVersion }
        if ($chromiumInfo.PreferredVs) { $VsYear = $chromiumInfo.PreferredVs }
        if ($chromiumInfo.DepotToolsCommit) {
            Write-Ok "depot_tools pin  : $($chromiumInfo.DepotToolsCommit)"
        }
    }
}

# ---- canonical hash + SDK version -------------------------------------------
# Explicit options win; otherwise read them from the Chromium checkout.
$canonicalHash = $CanonicalHash
if ($hasChromium) {
    $vsToolchainSrc = Get-Content -LiteralPath (Join-Path $ChromiumSrc 'build\vs_toolchain.py') -Raw
    if (-not $canonicalHash -and $vsToolchainSrc -match "TOOLCHAIN_HASH\s*=\s*'([0-9a-fA-F]+)'") { $canonicalHash = $matches[1] }
    if (-not $SdkVersion -and $vsToolchainSrc -match "SDK_VERSION\s*=\s*'([0-9.]+)'") { $SdkVersion = $matches[1] }
    $localInfo = Get-ToolchainInfoFromText -Text $vsToolchainSrc -Request '(local)' -Ref '(local)' -Display '(local chromium/src)'
    if ($localInfo.PreferredVs) { $VsYear = $localInfo.PreferredVs }
    $depsPath = Join-Path $ChromiumSrc 'DEPS'
    if (Test-Path -LiteralPath $depsPath) {
        $pin = Get-DepotToolsPinFromText -Text (Get-Content -LiteralPath $depsPath -Raw)
        if ($pin) {
            if (-not $chromiumInfo) { $chromiumInfo = $localInfo }
            $chromiumInfo.DepotToolsCommit = $pin
        }
    }
}
if (-not $SdkVersion) {
    # No Chromium: fall back to the only installed SDK, if unambiguous.
    $info = Get-WindowsSdkInfo -Version '' -Arm64:$Arm64
    if ($info.Versions.Count -eq 1) {
        $SdkVersion = $info.Versions[0]
        Write-Warn2 "No --sdk-version given; using the only installed SDK: $SdkVersion"
    }
}
if (-not $SdkVersion) {
    throw 'SDK version is required. Pass --sdk-version <ver>, or --chromium-src to read it.'
}
if (-not $canonicalHash) {
    Write-Warn2 'No canonical hash; TOOLCHAIN_INFO.txt will omit GYP_MSVS_HASH_*.'
    Write-Warn2 'Set it later for the build via: --win-toolchain-hash <local-hash>.'
}

# ---- VS version + packager compatibility ------------------------------------
$VsProductLine = Get-VsProductLineVersion -VsYear $VsYear
if (-not $VsProductLine) {
    throw "Unsupported Visual Studio version '$VsYear' (expected 2026, 2022, 2019 or 2017)."
}
if ($VsYear -eq '2017' -and $Arm64) {
    Write-Warn2 'VS 2017 does not provide the ARM64 components; disabling ARM64.'
    $Arm64 = $false
}

if (-not $VsInstallDir) {
    $VsInstallDir = if ($VsYear -eq '2026') {
        Join-Path $WorkDir $editionExeName
    } else {
        Join-Path $WorkDir "$editionExeName$VsYear"
    }
}

$packagerVsList = @(Get-PackagerSupportedVs -PackagerPath $Packager)
$currentDt = $null
if ($DepotTools -and (Test-Path -LiteralPath (Join-Path $DepotTools '.git'))) {
    try { $currentDt = ((& git -C $DepotTools rev-parse HEAD 2>$null) | Out-String).Trim() } catch { $currentDt = $null }
}

if ($PinDepotTools) {
    if (-not $chromiumInfo -or -not $chromiumInfo.DepotToolsCommit) {
        throw '--pin-depot-tools needs --chromium-version (or a local chromium/src with DEPS).'
    }
    if ($currentDt -and $currentDt -eq $chromiumInfo.DepotToolsCommit -and (Test-Path -LiteralPath $Packager)) {
        Write-Ok 'Using the already-pinned depot_tools checkout; no extra packager fetch needed.'
    } else {
        Write-Step "Pinning depot_tools packager to $($chromiumInfo.DepotToolsCommit)"
        $Packager = Get-PinnedPackager -Commit $chromiumInfo.DepotToolsCommit -RootDir $WorkDir
        Write-Ok "Pinned packager : $Packager"
    }
    $packagerVsList = @(Get-PackagerSupportedVs -PackagerPath $Packager)
    if ($packagerVsList.Count -gt 0) { Write-Ok "Packager VS     : $($packagerVsList -join ', ')" }
} elseif ($chromiumInfo -and $chromiumInfo.DepotToolsCommit) {
    if ($currentDt -and $currentDt -ne $chromiumInfo.DepotToolsCommit) {
        $curShort = Get-CommitShortName -Commit $currentDt
        $pinShort = $chromiumInfo.DepotToolsCommit.Substring(0, 12)
        Write-Warn2 "Chromium pins depot_tools $pinShort; current depot_tools is $curShort."
        Write-Warn2 'If the current packager is incompatible, re-run with --pin-depot-tools.'
    } elseif (-not $currentDt) {
        Write-Ok "Chromium pins depot_tools $($chromiumInfo.DepotToolsCommit.Substring(0,12))."
    }
}

$packagerMismatch = ($packagerVsList.Count -gt 0 -and ($packagerVsList -notcontains $VsYear))
if ($packagerMismatch -and -not $ShowDeps) {
    $toolsetTxt = if ($chromiumInfo -and $chromiumInfo.PreferredToolset) { " (MSVC $($chromiumInfo.PreferredToolset))" } else { '' }
    throw @"
Chromium requires Visual Studio $VsYear$toolsetTxt, but the selected packager supports VS $($packagerVsList -join ', '):
  $Packager
Re-run with --pin-depot-tools to fetch the Chromium-pinned depot_tools packager.
"@
}
$PackagerVs = $VsYear

# ---- VS installer URL / channel ---------------------------------------------
if (-not $VsChannelExplicit -and -not $BootUrlExplicit -and -not $Bootstrapper) {
    $VsChannel = if ($VsYear -eq '2026') { $OfficialVsChannel } else { $VsProductLine }
}
if (-not $BootUrl) {
    if ($VsChannel -match '^\d+') {
        $BootUrl = $OfficialVsBootUrlNumeric -f $VsChannel, $editionExeName
    } else {
        $BootUrl = $OfficialVsBootUrlNamed -f $VsChannel, $editionExeName
    }
}

# ---- SDK installer URL ------------------------------------------------------
$sdkUrl = Get-OfficialSdkInstallerUrl -SdkVersion $SdkVersion
if (-not $sdkUrl) {
    Write-Warn2 "No official SDK installer URL found for $SdkVersion."
    Write-Warn2 'Pass --sdk-installer <path-or-url>, or add the link at the top of this script.'
}

if ($ShowDeps) {
    Write-Host 'Dependency resolution:'
    if ($chromiumInfo) {
        Write-Host " Chromium        : $($chromiumInfo.Display) [$($chromiumInfo.Ref)]"
    } else {
        Write-Host " Chromium        : $(if ($ChromiumVersion) { $ChromiumVersion } else { '(not specified)' })"
    }
    Write-Host " Visual Studio   : $VsYear (productLineVersion $VsProductLine)"
    if ($chromiumInfo -and $chromiumInfo.PreferredToolset) {
        Write-Host " MSVC toolset    : $($chromiumInfo.PreferredToolset)"
    }
    Write-Host " Windows SDK     : $SdkVersion"
    Write-Host " Canonical hash  : $(if ($canonicalHash) { $canonicalHash } else { '(not set)' })"
    if ($chromiumInfo -and $chromiumInfo.DepotToolsCommit) {
        Write-Host " depot_tools pin : $($chromiumInfo.DepotToolsCommit)"
        if ($currentDt) { Write-Host " current dt HEAD : $currentDt" }
    } else {
        Write-Host " depot_tools pin : (not found in DEPS)"
    }
    Write-Host " packager        : $Packager"
    $pkgVsTxt = if ($packagerVsList.Count -gt 0) { $packagerVsList -join ', ' } else { '(unknown)' }
    if ($packagerMismatch) { $pkgVsTxt += '  (INCOMPATIBLE; use --pin-depot-tools)' }
    Write-Host " packager VS     : $pkgVsTxt"
    Write-Host " VS installer    : $BootUrl"
    Write-Host " SDK installer   : $(if ($sdkUrl) { $sdkUrl } else { '(not configured; use --sdk-installer)' })"
    exit 0
}

# ---- VS product id + the exact components the packager needs ----------------
$editionProduct = @{
    buildtools   = 'Microsoft.VisualStudio.Product.BuildTools'
    community    = 'Microsoft.VisualStudio.Product.Community'
    professional = 'Microsoft.VisualStudio.Product.Professional'
    enterprise   = 'Microsoft.VisualStudio.Product.Enterprise'
}[$VsEdition]

$requiredComponents = @(
    'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',   # MSVC toolset
    'Microsoft.VisualStudio.Component.VC.ATLMFC'           # ATL/MFC
)
if ($Arm64) {
    $requiredComponents += 'Microsoft.VisualStudio.Component.VC.Tools.ARM64'
    $requiredComponents += 'Microsoft.VisualStudio.Component.VC.MFC.ARM64'
}

Write-Host '============================================================================'
Write-Host ' Prepare a Chromium Windows toolchain archive'
Write-Host '============================================================================'
Write-Host " Work dir        : $WorkDir"
Write-Host " depot_tools     : $DepotTools"
Write-Host " packager        : $Packager"
Write-Host " chromium/src    : $(if ($ChromiumSrc) { $ChromiumSrc } else { '(none - depot_tools only)' })"
Write-Host " Chromium req    : $(if ($ChromiumVersion) { $ChromiumVersion } else { '(not specified)' })"
if ($chromiumInfo) {
    Write-Host " Chromium version: $($chromiumInfo.Display) [$($chromiumInfo.Ref)]"
    if ($chromiumInfo.PreferredVs) {
        Write-Host " Preferred VS    : $($chromiumInfo.PreferredVs) (MSVC $($chromiumInfo.PreferredToolset))"
    }
}
Write-Host " Output dir      : $OutDir"
Write-Host " VS edition      : $VsEdition (workload $VsWorkload)"
Write-Host " VS year         : $VsYear (productLineVersion $VsProductLine)"
Write-Host " VS install dir  : $VsInstallDir"
Write-Host " Packager VS     : $PackagerVs"
if ($chromiumInfo -and $chromiumInfo.DepotToolsCommit) {
    Write-Host " depot_tools pin : $($chromiumInfo.DepotToolsCommit)"
}
Write-Host " Canonical hash  : $(if ($canonicalHash) { $canonicalHash } else { '(not set)' })"
Write-Host " SDK version     : $SdkVersion"
Write-Host " Include ARM64   : $Arm64"
Write-Host " Install mode    : $(if ($DoInstall) { '--install-deps (install missing)' } else { 'package only (no install)' })"
Write-Host " Installer dir   : $(if ($InstallerDir) { $InstallerDir } else { '(none)' })"
Write-Host " Installer cache : $CacheDir"
Write-Host " Official VS URL : $BootUrl"
Write-Host " Official SDK URL: $sdkUrl"
Write-Host " Prefer existing : $PreferInstalled"
Write-Host " Edition product : $editionProduct"
Write-Host " Required comps  : $($requiredComponents -join ', ')"
Write-Host '============================================================================'

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null

# ---- preflight --------------------------------------------------------------
if ($DoInstall -and -not $DryRun) {
    if (-not (Test-Administrator)) {
        throw '--install-deps requires Administrator (VS/SDK installers need elevation).'
    }
}
if ($DoInstall) {
    try {
        $rootPath = (Split-Path -Qualifier (Resolve-Path -LiteralPath $WorkDir).Path) + '\'
        $driveLetter = $rootPath.Substring(0,1)
        $free = (Get-PSDrive -Name $driveLetter -ErrorAction Stop).Free
        if ($free -lt 15GB) {
            Write-Warn2 ("Low free space on {0}: {1:N1} GB free. VS + SDK + zip may need 15+ GB." -f $rootPath, ($free / 1GB))
        }
    } catch {
        Write-Warn2 'Could not determine free disk space.'
    }
} elseif ($InstallerDir -and -not (Test-Path -LiteralPath $InstallerDir -PathType Container)) {
    Write-Warn2 "Installer directory not found: $InstallerDir (will fall back to downloads)."
}

# ---- 1. Windows SDK check ---------------------------------------------------
# package_from_installed.py needs the SDK version Chromium wants AND its
# "Debugging Tools for Windows" (Windows Kits\10\Debuggers\<cpu>\dbghelp.dll).
$sdkInfo = Get-WindowsSdkInfo -Version $SdkVersion -Arm64:$Arm64
if (-not $DryRun) {
    Write-Step "Checking Windows SDK $SdkVersion"
    $rootTxt = if ($sdkInfo.Root) { $sdkInfo.Root } else { '(not found)' }
    Write-Ok "KitsRoot10 : $rootTxt"
    Write-Ok "Version    : $(if ($sdkInfo.HasVersion) { 'installed' } else { 'MISSING' })"
    Write-Ok "Debuggers  : $(if ($sdkInfo.HasDebuggers) { 'installed' } else { 'MISSING' })"
    if ($sdkInfo.Versions.Count -gt 0) { Write-Ok ("Installed SDKs: " + ($sdkInfo.Versions -join ', ')) }
}
if (-not $sdkInfo.HasVersion -or -not $sdkInfo.HasDebuggers) {
    Write-Warn2 "Windows SDK $SdkVersion with 'Debugging Tools for Windows' is REQUIRED."
    Write-Warn2 'Official ways to install it:'
    Write-Warn2 "  * --install-deps (installs SDK $SdkVersion and Debugging Tools via winsdksetup)"
    Write-Warn2 '  * Manual: https://developer.microsoft.com/windows/downloads/windows-sdk/'
    Write-Warn2 '    Enable "Debugging Tools for Windows", or pass --sdk-installer <path-or-url> with --install-deps.'
}

# ---- 2. decide the target VS instance (EDITION-SCOPED) ----------------------
$vsInstance       = $null      # @{ productId; installationPath; ... }
$missingComps     = @()
$needFreshInstall = $false
$usingLayout      = $false

$instances = Get-VsInstances -ProductLineVersion $VsProductLine
if ($instances.Count -gt 0) {
    Write-Step "Installed Visual Studio $VsYear instance(s):"
    foreach ($inst in $instances) {
        Write-Ok ("  {0}  {1}" -f $inst.productId, $inst.installationPath)
    }
}

if ($PreferInstalled) {
    foreach ($inst in $instances) {
        $miss = @()
        foreach ($c in $requiredComponents) {
            if (-not (Test-VsComponent -ProductId $inst.productId -ComponentId $c -ProductLineVersion $VsProductLine)) { $miss += $c }
        }
        if ($miss.Count -eq 0) { $vsInstance = $inst; break }
    }
    if ($vsInstance) {
        Write-Ok "Using existing instance (--prefer-installed): $($vsInstance.installationPath)"
    } else {
        Write-Warn2 "No existing VS $VsYear instance has ALL required components."
    }
}

if (-not $vsInstance) {
    $editionInst = @($instances | Where-Object { $_.productId -eq $editionProduct }) | Select-Object -First 1
    if ($editionInst) {
        $vsInstance = $editionInst
        foreach ($c in $requiredComponents) {
            if (-not (Test-VsComponent -ProductId $editionProduct -ComponentId $c -ProductLineVersion $VsProductLine)) { $missingComps += $c }
        }
        Write-Step "Using $VsEdition instance: $($vsInstance.installationPath)"
        if ($missingComps.Count -gt 0) {
            Write-Warn2 ('Missing component(s): ' + ($missingComps -join ', '))
        } else {
            Write-Ok 'All required components are already installed.'
        }
    } else {
        $needFreshInstall = $true
        if ($DoInstall) {
            Write-Step "$VsEdition is not installed -> will install it with all required components."
        } else {
            Write-Warn2 "$VsEdition is not installed (package-only mode will fail)."
        }
    }
}

if (-not $DoInstall -and -not $DryRun) {
    if (-not $vsInstance) {
        throw "No matching Visual Studio $VsYear instance. Pass --install-deps, install VS manually, or use --prefer-installed."
    }
    if ($missingComps.Count -gt 0) {
        throw ('Missing Visual Studio component(s): ' + ($missingComps -join ', ') +
               '. Pass --install-deps to install them.')
    }
}

# ---- 3. install / update VS (only when something is missing) ----------------
$installerSearchDirs = @()
if ($InstallerDir) { $installerSearchDirs += $InstallerDir }
# NOTE: $CacheDir is checked separately by Resolve-Installer so cached downloads
# must pass the stronger PE + Authenticode check.

if ($DoInstall -and ($needFreshInstall -or $missingComps.Count -gt 0)) {
    $vsExe = Resolve-Installer -Name 'VS bootstrapper' -Explicit $Bootstrapper `
        -SearchDirs $installerSearchDirs -ExactName $vsExeName -Pattern $vsExeName `
        -Url $BootUrl -CacheDir $CacheDir -DryRun $DryRun

    $installArgs = @('--quiet', '--wait', '--norestart', '--nocache')
    if ($needFreshInstall) {
        $installArgs += @('--installPath', $VsInstallDir,
                          '--add', $VsWorkload,
                          '--add', 'Microsoft.VisualStudio.Component.VC.ATLMFC',
                          '--includeRecommended')
        if ($Arm64) {
            $installArgs += @('--add', 'Microsoft.VisualStudio.Component.VC.Tools.ARM64')
            $installArgs += @('--add', 'Microsoft.VisualStudio.Component.VC.MFC.ARM64')
        }
        Write-Step "Installing $VsEdition into $VsInstallDir (needs admin; several GB)"
    } else {
        # Update the existing instance, adding ONLY the missing components.
        $installArgs += @('--installPath', $vsInstance.installationPath)
        foreach ($c in $missingComps) { $installArgs += @('--add', $c) }
        Write-Step "Adding missing component(s) to $($vsInstance.installationPath) (needs admin)"
    }

    if ($DryRun) {
        Write-Step "Would run: $vsExe $($installArgs -join ' ')"
    } else {
        Invoke-Wait -FilePath $vsExe -ArgumentList $installArgs
        Write-Ok 'VS install/update step finished.'
    }
} else {
    if ($DoInstall) { Write-Ok 'No VS install needed.' }
    else { Write-Ok 'VS installation disabled (package-only mode).' }
}

# ---- 4. install the required SDK + Debugging Tools (idempotent) -------------
# One winsdksetup install covers both: OptionId.DesktopCPPx64 installs the SDK
# headers/libs for the selected SDK version, OptionId.WindowsDesktopDebuggers
# installs Debuggers\<cpu>\dbghelp.dll. Re-run only when either is missing.
$sdkInfo = Get-WindowsSdkInfo -Version $SdkVersion -Arm64:$Arm64
if ($DoInstall) {
    $needSdk = -not $sdkInfo.HasVersion
    $needDbg = -not (Test-DebuggersReady -Root $sdkInfo.Root -Arm64:$Arm64)
    if ($needSdk -or $needDbg) {
        $sdkExe = Resolve-Installer -Name 'Windows SDK installer' -Explicit $SdkInstaller `
            -SearchDirs $installerSearchDirs -ExactName "winsdksetup-$SdkVersion.exe" -Pattern 'winsdksetup.exe' `
            -Url $sdkUrl -CacheDir $CacheDir -CacheName "winsdksetup-$SdkVersion.exe" -DryRun $DryRun

        $sdkArgs = @('/quiet', '/norestart', '/features',
                     'OptionId.DesktopCPPx64', 'OptionId.WindowsDesktopDebuggers')
        if ($DryRun) {
            Write-Step "Would run: $sdkExe $($sdkArgs -join ' ')"
        } else {
            Write-Step "Installing Windows SDK $SdkVersion / Debugging Tools (winsdksetup)"
            Invoke-Wait -FilePath $sdkExe -ArgumentList $sdkArgs

            $sdkInfo = Get-WindowsSdkInfo -Version $SdkVersion -Arm64:$Arm64
            if (-not $sdkInfo.HasVersion -or -not (Test-DebuggersReady -Root $sdkInfo.Root -Arm64:$Arm64)) {
                throw @"
Windows SDK / Debugging Tools install did not produce the expected state.
Expected SDK  : $SdkVersion  (Include\$SdkVersion)
Expected file : $($sdkInfo.Root)\Debuggers\x64\dbghelp.dll
Check the winsdksetup log in %TEMP%, or install manually:
  winsdksetup.exe /quiet /norestart /features OptionId.DesktopCPPx64 OptionId.WindowsDesktopDebuggers
"@
            }
            Write-Ok "Windows SDK $SdkVersion and Debugging Tools installed."
        }
    } else {
        Write-Ok "Windows SDK $SdkVersion and Debugging Tools already present."
    }
} else {
    Write-Ok 'Windows SDK / Debugging Tools install disabled (package-only mode).'
}

# ---- 5. resolve the target instance + final checks --------------------------
if (-not $DryRun) {
    # The VS installer can return 0 yet keep working asynchronously, so poll for
    # the instance we want (edition-scoped unless --prefer-installed).
    if ($DoInstall -and -not $vsInstance) {
        for ($w = 0; $w -lt 30 -and -not $vsInstance; $w++) {
            $cand = @((Get-VsInstances -ProductLineVersion $VsProductLine) | Where-Object {
                if ($PreferInstalled) { $true } else { $_.productId -eq $editionProduct }
            }) | Select-Object -First 1
            if ($cand) { $vsInstance = $cand; break }
            Start-Sleep -Seconds 10
        }
    }

    # Fallback: some environments (Windows Sandbox/WDAG) install the files but
    # never register the instance with vswhere. If a real VS layout exists on
    # disk, use it directly for packaging.
    if (-not $vsInstance) {
        $layoutCands = @($VsInstallDir)
        foreach ($base in @(
            'C:\Program Files\Microsoft Visual Studio',
            'C:\Program Files (x86)\Microsoft Visual Studio')) {
            foreach ($edition in @('BuildTools', 'Community', 'Professional', 'Enterprise')) {
                $layoutCands += (Join-Path (Join-Path $base $VsYear) $edition)
            }
        }
        foreach ($lp in $layoutCands) {
            if (Test-VsLayout -Path $lp) {
                Write-Warn2 "vswhere did not register an instance, but a VS layout exists at:"
                Write-Warn2 "  $lp"
                Write-Warn2 'Using it for packaging (fallback).'
                $vsInstance = [ordered]@{ productId = $editionProduct; installationPath = $lp }
                $usingLayout = $true
                break
            }
        }
    }

    if ($vsInstance) {
        Write-Ok "Target VS instance: $($vsInstance.installationPath) [$($vsInstance.productId)]"
        $still = @()
        if ($DoInstall -and -not $usingLayout) {
            # Registration can lag behind installer exit; poll briefly.
            for ($w = 0; $w -lt 12; $w++) {
                $still = @()
                foreach ($c in $requiredComponents) {
                    if (-not (Test-VsComponent -ProductId $vsInstance.productId -ComponentId $c -ProductLineVersion $VsProductLine)) { $still += $c }
                }
                if ($still.Count -eq 0) { break }
                if ($w -lt 11) { Start-Sleep -Seconds 5 }
            }
        } else {
            foreach ($c in $requiredComponents) {
                if (-not (Test-VsComponent -ProductId $vsInstance.productId -ComponentId $c -ProductLineVersion $VsProductLine)) { $still += $c }
            }
        }
        if ($still.Count -gt 0) {
            if ($usingLayout) {
                Write-Warn2 ('Component registration unavailable for layout fallback; still missing: ' + ($still -join ', '))
            } else {
                throw ('Still missing Visual Studio component(s): ' + ($still -join ', '))
            }
        } else {
            Write-Ok 'All required components present.'
        }
    } else {
        Write-Warn2 "No matching Visual Studio $VsYear instance found."
        Write-Warn2 'Common causes: cmd not elevated, not enough disk, package CDN blocked,'
        Write-Warn2 'a pending reboot, or an invalid component id.'
        # Dump the tail of the VS installer logs so the real cause is visible.
        $logs = @()
        foreach ($pat in @('dd_setup_*.log', 'dd_*.log')) {
            $logs += @(Get-ChildItem -LiteralPath $env:TEMP -Filter $pat -File -ErrorAction SilentlyContinue)
        }
        $logs = @($logs | Sort-Object LastWriteTime -Descending | Select-Object -First 2)
        foreach ($l in $logs) {
            Write-Warn2 "--- $($l.FullName) (last 25 lines) ---"
            Get-Content -LiteralPath $l.FullName -Tail 25 -ErrorAction SilentlyContinue |
                ForEach-Object { Write-Host ("    " + $_) -ForegroundColor DarkYellow }
        }
        throw 'No matching Visual Studio instance to package from.'
    }

    $sdkInfo = Get-WindowsSdkInfo -Version $SdkVersion -Arm64:$Arm64
    if (-not $sdkInfo.HasVersion) {
        throw "Windows SDK $SdkVersion not found; package_from_installed.py would fail."
    }
    if (-not $sdkInfo.HasDebuggers) {
        throw @"
Debugging Tools for Windows missing; Chromium's gn copy_dlls step requires:
  $($sdkInfo.Root)\Debuggers\x64\dbghelp.dll
Pass --install-deps (optionally with --sdk-installer), or install:
  winsdksetup.exe /quiet /norestart /features OptionId.DesktopCPPx64 OptionId.WindowsDesktopDebuggers
"@
    }
    Write-Ok "Windows SDK $SdkVersion and Debugging Tools are ready."
}

# ---- 6. package FROM THE CHOSEN INSTANCE (edition-locked) --------------------
$packagePath = if ($vsInstance) { $vsInstance.installationPath } else { $VsInstallDir }
$infoPath = Join-Path $OutDir 'TOOLCHAIN_INFO.txt'

if ($DryRun) {
    Write-Step "Would package from: $packagePath"
    Write-Ok 'Dry run complete.'
    exit 0
}

if (-not $vsInstance) {
    throw 'No matching Visual Studio instance to package from.'
}

# ---- 6a. compute the current input state ------------------------------------
$vsInstVersion = ''
if ($vsInstance.installationVersion) {
    $vsInstVersion = [string]$vsInstance.installationVersion
} elseif (Test-Path -LiteralPath $script:Vswhere) {
    try {
        $minV = "$VsProductLine.0"
        $maxV = "$([int]$VsProductLine + 1).0"
        $vsInstVersion = ((& $script:Vswhere -prerelease -products $vsInstance.productId -version "[$minV,$maxV)" -property installationVersion 2>$null) | Out-String).Trim()
    } catch { $vsInstVersion = '' }
}

$msvcToolset = ''
$msvcRoot = Join-Path $packagePath 'VC\Tools\MSVC'
if (Test-Path -LiteralPath $msvcRoot) {
    $toolDirs = @(Get-ChildItem -LiteralPath $msvcRoot -Directory -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -like '14.*' } | Sort-Object Name -Descending)
    if ($toolDirs.Count -gt 0) { $msvcToolset = $toolDirs[0].Name }
}

$msvcPath = if ($msvcToolset) { Join-Path $msvcRoot $msvcToolset } else { $msvcRoot }
$redistPath = Join-Path $packagePath 'VC\redist'
$sdkRoot = $sdkInfo.Root
$sourcePaths = @(
    (Join-Path $packagePath 'DIA SDK'),
    $msvcPath,
    $redistPath,
    (Join-Path $sdkRoot "Include\$SdkVersion"),
    (Join-Path $sdkRoot "Lib\$SdkVersion"),
    (Join-Path $sdkRoot "bin\$SdkVersion"),
    (Join-Path $sdkRoot "Source\$SdkVersion"),
    (Join-Path $sdkRoot 'Redist'),
    (Join-Path $sdkRoot 'Debuggers'),
    (Join-Path $sdkRoot 'UnionMetadata')
)
$packagerSha = Get-PackagerFingerprint -PackagerPath $Packager
$sourceFingerprint = Get-PathFingerprint -Paths $sourcePaths
$toolchainState = [ordered]@{
    sdk_version = $SdkVersion
    vs_year = $VsYear
    vs_product = [string]$vsInstance.productId
    vs_install_dir = $packagePath
    vs_installation_version = $vsInstVersion
    msvc_toolset = $msvcToolset
    arm64 = [string]$Arm64
    packager_sha256 = $packagerSha
    source_fingerprint = $sourceFingerprint
}

# ---- 6b. reuse an up-to-date archive ----------------------------------------
$zip = $null
if (-not $ForceRepack -and (Test-Path -LiteralPath $infoPath)) {
    $old = @{}
    foreach ($line in (Get-Content -LiteralPath $infoPath)) {
        if ($line -match '^([^#=]+)=(.*)$') { $old[$matches[1].Trim()] = $matches[2].Trim() }
    }
    $mismatch = @()
    foreach ($k in $toolchainState.Keys) {
        if ([string]$old[$k] -ne [string]$toolchainState[$k]) { $mismatch += $k }
    }
    $oldLocalHash = [string]$old['local_hash']
    $oldArchive = if ($oldLocalHash) { Join-Path $OutDir "$oldLocalHash.zip" } else { [string]$old['archive'] }
    if (-not $oldLocalHash -or -not $oldArchive -or -not (Test-Path -LiteralPath $oldArchive)) {
        $mismatch += 'archive_missing'
    } else {
        $oldZip = Get-Item -LiteralPath $oldArchive
        if ([string]$old['archive_size'] -and [string]$old['archive_size'] -ne [string]$oldZip.Length) {
            $mismatch += 'archive_size'
        }
        if ([string]$old['archive_sha256']) {
            $actualSha = Get-FileSha256 -Path $oldArchive
            if ($actualSha -ne [string]$old['archive_sha256']) { $mismatch += 'archive_sha256' }
        }
    }

    if ($mismatch.Count -eq 0) {
        Write-Ok 'Toolchain inputs unchanged; reusing existing archive.'
        Write-Ok "Archive: $($oldZip.FullName)"
        $buildCmd = Get-BuildStepCommand
        $downloadCmd = Get-DownloadCommand -OutDir $OutDir -LocalHash $oldLocalHash -ChromiumVersion $ChromiumVersion
        Write-ToolchainInfo -InfoPath $infoPath -CanonicalHash $canonicalHash -LocalHash $oldLocalHash `
            -ArchivePath $oldZip.FullName -SdkVersion $SdkVersion -OutDir $OutDir -State $toolchainState `
            -ArchiveSize ([string]$oldZip.Length) -ArchiveSha256 ([string]$old['archive_sha256']) `
            -DownloadCommand $downloadCmd -BuildCommand $buildCmd
        Write-Host ''
        Write-Host 'Done (reused existing archive).'
        Show-BuildCommand -DownloadCommand $downloadCmd -BuildCommand $buildCmd -OutDir $OutDir -LocalHash $oldLocalHash `
            -CanonicalHash $canonicalHash -SdkVersion $SdkVersion -ChromiumInfo $chromiumInfo
        exit 0
    }
    Write-Ok ('Toolchain inputs changed (' + (($mismatch | Sort-Object -Unique) -join ', ') + '); repackaging.')
}

# ---- 6c. repackage ----------------------------------------------------------
Write-Step "Packaging from $($vsInstance.productId): $packagePath"
# depot_tools' own GetVSPath() would pick ANY matching VS (possibly another
# edition). Generate a tiny wrapper that forces THIS instance's path.
$pkgDir  = Split-Path -Parent $Packager
# package_from_installed.py writes out.zip in the current directory and then
# renames it to <hash>.zip. Use a fresh temporary directory so a repeated
# run cannot fail because <hash>.zip already exists.
$packDir = Join-Path $OutDir ('_pack_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Force -Path $packDir | Out-Null
$legacyWrapper = Join-Path $OutDir '_package_wrapper.py'
if (Test-Path -LiteralPath $legacyWrapper) {
    Remove-Item -LiteralPath $legacyWrapper -Force -ErrorAction SilentlyContinue
}

$wrapper = Join-Path $packDir '_package_wrapper.py'
# package_from_installed.py includes arm by default; pass --noarm when the
# user asked for an x86/x64-only package.
$armArg = if ($Arm64) { '' } else { ", '--noarm'" }
$wrapperLines = @(
    'import sys'
    "sys.path.insert(0, r'$pkgDir')"
    'import package_from_installed as p'
    "p.GetVSPath = lambda: r'$packagePath'"
    "sys.argv = ['package_from_installed.py', '$PackagerVs', '-w', '$SdkVersion'$armArg]"
    'sys.exit(p.main())'
)
Set-Content -LiteralPath $wrapper -Value $wrapperLines -Encoding ASCII
try {
    Invoke-Native -FilePath $Python3 -ArgumentList @($wrapper) -WorkingDirectory $packDir

    $newZip = Get-ChildItem -LiteralPath $packDir -Filter '*.zip' -File -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $newZip) { throw "package_from_installed.py did not produce a .zip in $packDir" }

    $finalZip = Join-Path $OutDir $newZip.Name
    Move-Item -LiteralPath $newZip.FullName -Destination $finalZip -Force
    $zip = Get-Item -LiteralPath $finalZip
    Write-Ok "Archive: $($zip.FullName)"
} finally {
    Remove-Item -LiteralPath $packDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ---- 7. find the produced archive + write the mapping -----------------------
if (-not $zip) {
    throw "package_from_installed.py did not produce a .zip in $OutDir"
}

$localHash = $zip.BaseName
$buildCmd = Get-BuildStepCommand
$downloadCmd = Get-DownloadCommand -OutDir $OutDir -LocalHash $localHash -ChromiumVersion $ChromiumVersion
Write-Step 'Computing archive SHA-256 for the reuse cache'
$archiveSha = Get-FileSha256 -Path $zip.FullName
Write-Ok "Archive SHA-256: $archiveSha"
Write-ToolchainInfo -InfoPath $infoPath -CanonicalHash $canonicalHash -LocalHash $localHash `
    -ArchivePath $zip.FullName -SdkVersion $SdkVersion -OutDir $OutDir -State $toolchainState `
    -ArchiveSize ([string]$zip.Length) -ArchiveSha256 $archiveSha `
    -DownloadCommand $downloadCmd -BuildCommand $buildCmd

Write-Host ''
Write-Host 'Done.'
Show-BuildCommand -DownloadCommand $downloadCmd -BuildCommand $buildCmd -OutDir $OutDir -LocalHash $localHash `
    -CanonicalHash $canonicalHash -SdkVersion $SdkVersion -ChromiumInfo $chromiumInfo
exit 0
