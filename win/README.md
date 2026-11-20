# Chromium Windows 构建脚本

在 Windows 10/11 上下载并编译 Chromium。

> **重要（Windows 工具链）**：Chromium 自带的 clang 会随依赖自动下载；但 MSVC 头文件/库与
> Windows SDK 来自 **本机安装的 Visual Studio**（`DEPOT_TOOLS_WIN_TOOLCHAIN=0`）或
> **Google 内部预编译工具链**（`=1`，`gs://chrome-wintoolchain`，非公开）。经实测，该预编译
> 工具链的 bucket **拒绝匿名访问（401/403）**，官方文档也要求外部用户安装 VS 并设为 0。
> 因此**外部用户必须安装 Visual Studio / Build Tools**（见“系统要求”）。

- 下载源码、依赖、clang 及 Windows 平台所需组件。
- 强制使用 **浅拷贝**（`--no-history`，depth 1），让各仓库 `.git` 尽量小。
- 可在命令行指定 **版本分支 / tag / milestone**，找不到时回退到最新稳定版。
- 默认构建 `chrome`、`content_shell`、`headless_shell`、`mini_installer`。

## 文件说明

| 文件 | 作用 |
| --- | --- |
| `chromium_download_win.ps1` | **下载/准备脚本**：bootstrap git+depot_tools、fetch/sync（`--no-history`）、`gclient runhooks`（含 toolchain）；加 `--make-offline-repo` 时把 depot_tools/config/sccache/脚本/README 收进 `<src>\init_tools` 并提交成自包含仓库。不做编译 |
| `chromium_download_win.bat` | 上者的启动器（同 `chromium_build_win.bat` 的预检逻辑） |
| `chromium_build_win.ps1` | **编译脚本**：只编译。按“脚本自身相对位置 → 环境变量 → `--dir`”定位源码；自动修复搬移后失效的 `build\win_toolchain.json`；仓库内自带 sccache 时自动加 `cc_wrapper="sccache"`；不访问网络、不调用 gclient。`--check` 只打印解析结果 |
| `chromium_build_win.bat` | 上者的启动器 |
| `find_depot_tools_version.ps1` | 查找某个 Chromium 版本对应的 depot_tools commit |
| `find_depot_tools_version.bat` | 上者的启动器 |
| `prepare_win_toolchain.ps1` | 按需安装 Chromium 所需的 VS（2026/2022/2019/2017）和 Windows SDK/Debugging Tools，并打成 Chromium 可用的 win_toolchain 归档（供 `--win-toolchain-url` 使用，免在编译机装 VS）。`--chromium-version 7871|150.0.7871.289|main|stable|131.0.6778.85` 自动解析 hash/SDK/VS 以及 `DEPS` 里的 depot_tools pin；`--show-deps` 只查看依赖；`--pin-depot-tools` 使用同年代 packager。找不到 depot_tools 时会自动调用 `bootstrap_depot_tools.ps1`；缺安装器时从微软官网下载；无 Chromium 源码也可打包 |
| `prepare_win_toolchain.bat` | 上者的启动器 |
| `bootstrap_depot_tools.ps1` | 独立 git/depot_tools 引导：git 缺失时下载 PortableGit；depot_tools 缺失时 clone，指定了版本则 fetch/checkout 到该 commit；校验并 bootstrap Python/CIPD。可独立运行，也可被其它脚本 dot-source |
| `bootstrap_depot_tools.bat` | 上者的启动器 |

## git / depot_tools 独立引导

`bootstrap_depot_tools.ps1` 把原先分散在 `chromium_build_win.ps1` 里的
git、depot_tools、Python/CIPD 初始化独立出来，供两个主脚本共用。

独立运行：

```powershell
# 默认在脚本目录下创建 depot_tools；已有则跳过
.\bootstrap_depot_tools.bat --dir C:\test

# 指定 depot_tools commit（版本不同才 fetch/checkout）
.\bootstrap_depot_tools.bat --dir C:\test --version f4fadaf6a5ba1bced9d3d9021060667b563bf583

# 直接按 Chromium 版本解析 DEPS pin
.\bootstrap_depot_tools.bat --dir C:\test --chromium-version 7871
.\bootstrap_depot_tools.bat --dir C:\test --chromium-version 131.0.6778.85
```

行为：

- **git 已存在** → 不下载；缺失 → 下载 PortableGit 到 `<dir>\tools\git`。
- **depot_tools 已存在且未指定版本** → 原样复用，不会自动更新。
- **指定了 `--version` / `--chromium-version`** → 比较当前 HEAD；不同才
  `git fetch --depth 1` + `checkout --detach`；**checkout 完成后再次验证 HEAD**，
  通过后才设置 `DEPOT_TOOLS_UPDATE=0`。
- **Python/CIPD 已可用** → 跳过 bootstrap；不可用才运行
  `bootstrap\win_tools.bat`（或 `gclient.bat`）。
- 默认路径：`<dir>\depot_tools`（`--dir` 缺省为脚本所在目录）。

也可以被其它脚本 dot-source：

```powershell
. .\bootstrap_depot_tools.ps1
$info = Initialize-DepotTools -Root C:\test -ChromiumVersion 7871
$info.Git
$info.DepotTools
$info.Python3
```

两个主脚本（下载与构建已分离）：

- `chromium_download_win.ps1` —— **只做联网工作**：bootstrap git/depot_tools、`fetch`/`gclient sync`、`gclient runhooks`；加 `--make-offline-repo` 时把 depot_tools、config、sccache、脚本收进 `<src>\init_tools` 并提交成自包含仓库。**不编译**。
- `chromium_build_win.ps1` —— **只做编译**：定位已有源码（优先按脚本自身相对位置）、修复搬移后失效的 `build\win_toolchain.json`、`gn gen` + `autoninja`。**不联网、不调用 gclient**，带 `--check` 只打印解析结果。
- 共享引导逻辑仍在 `bootstrap_depot_tools.ps1`；`prepare_win_toolchain.ps1` 负责打包工具链。

## 快速开始

```powershell
# 1) 下载（联网）
.\chromium_download_win.bat                                     # 最新稳定版，下载到脚本目录
.\chromium_download_win.bat --dir D:\download --version 7871
.\chromium_download_win.bat --dir D:\download --version 131.0.6778.85
.\chromium_download_win.bat --dir D:\download --milestone 131
.\chromium_download_win.bat --dir D:\download --depot-tools-only  # 只准备 depot_tools

# 2) 编译（不联网、不需要 gclient）
.\chromium_build_win.bat --dir D:\download\src --release --targets chrome,content_shell
```

普通（未导出）工作区：

```
<dir>\
  depot_tools\
  .gclient
  src\                # Chromium 源码（浅拷贝）
  tools\git\          # 需要时自动下载的 PortableGit
```

导出后的离线仓库（`--make-offline-repo`，**仓库根 = 源码目录**）：

```
<dir>\<srcName>\                 # 一个 git 仓库，.git 在这里
  .gitignore                     # 追加了构建产物/临时文件规则
  <Chromium 源码...>
  init_tools\
    <MAJOR>\
      config\                    # .gclient 等配置/状态（版本↔配置对照）
      depot_tools\               # 移入的 depot_tools（作为普通文件，无 .git）
      scache\                    # sccache.exe
    win\                         # 两套脚本 + README + env.bat/env.ps1
```

`<srcName>` 默认 `src`，可用 `--dest-name NAME` 改名；`env.bat/env.ps1` 全部按
`%~dp0` / `$PSScriptRoot` 推导路径，所以整个仓库可以改名、换盘、拷贝。

旧布局 `<dir>\chromium\src` 会在启动时自动迁移。

## chromium_download_win 参数

| 参数 | 说明 |
| --- | --- |
| `--dir PATH` | 下载根目录，默认脚本所在目录。路径**不能含空格** |
| `--dest-name NAME` | 仓库目录名（默认 `src`）。可以改成 `chromium` / `webview` / `chromium150` 等；**省略时按顺序**：根 `.gclient` 的 solution 名 → 唯一 `init_tools\.offline_repo.state` → 唯一 `chrome\VERSION` → 默认 `src`；多个候选会报错，不会新建 `src`。**它不会自动重命名已有 `src`**：目标名不同且 `src` 是 checkout 时，脚本会打印手动 `Move-Item` 命令并 **exit 3** |
| `--version VER` | 版本，见下方“版本语义” |
| `--milestone N` | 改用某 milestone 的最新稳定版 |
| `--retries N` | fetch / `gclient sync` / `runhooks` 失败时的重试次数，默认 **10**（应对 429 限流等瞬时故障；`--retries 0` 关闭） |
| `--win-toolchain auto\|0\|1` | 设置 `DEPOT_TOOLS_WIN_TOOLCHAIN`，**默认 auto**：检测到本机 VS 用 `0`，否则用 `1` |
| `--no-win-toolchain` | 等价 `--win-toolchain 0`（使用本机已装的 Visual Studio） |
| `--win-toolchain-url URL` | 用预编译工具链归档替代本机 VS/内部 bucket：设置 `DEPOT_TOOLS_WIN_TOOLCHAIN_BASE_URL`，隐含 `--win-toolchain 1`，**无需安装 VS**（详见下文） |
| `--win-toolchain-hash H` | 本地打包归档的 `<H>.zip`：设置 `GYP_MSVS_HASH_<canonical>=H`，让自建工具链被接受（本地目录可自动探测，http 需显式指定） |
| `--with-branch-heads` | 切分支时给 gclient 加 `--with_branch_heads`，会抓**所有** release 分支，可能让 `src\.git` 增加十几 GB；默认关闭，仅当 gclient 报错时再开 |
| `--with-tags` | 切 tag 时给 gclient 加 `--with_tags`，会抓**所有** tag（每个 tag 一份 tree，体积可能几十 GB）；默认关闭。普通构建不需要；`--version` 是单个 release tag 时也不需要（只浅取那一个 tag） |
| `--pinned` | **只抓指定 revision**，跳过先抓 main 的浅同步——已知版本时 `.git` 最小 |
| `--gc` | checkout 后执行 `git gc --prune=now`，回收不可达对象 |
| `--pgo` | 保留 Windows PGO profile（`checkout_pgo_profiles=True` **已是默认**，本开关用于覆盖 `--no-extra-deps` / `--deps checkout_pgo_profiles=False`，或显式声明意图）；构建侧另用 `--args "chrome_pgo_phase=2"` |
| `--full-deps` | 一次性下载一整套可离线使用的可选依赖（clang-tidy、clangd、覆盖率工具、PGO profile、bazelisk、libaom/libvpx 测试数据、WPR 归档） |
| `--deps K=V,...` | 直接设置任意 `.gclient` `custom_vars`（DEPS 变量），在 sync 之前生效，如 `--deps "checkout_clangd=True"` |
| `--add-defender-exclusions` | 把下载根目录和 `~/.cipd` 加入 Windows Defender 排除（需管理员） |
| `--skip-fetch` | 不下载，使用已有 checkout |
| `--skip-hooks` | 不跑 `gclient runhooks`（也不下载工具链） |
| `--depot-tools-only` | 只把 depot_tools 克隆并 bootstrap 到可用状态（git 配置、python/CIPD），**不下载 Chromium/依赖/工具链，不编译**，随后退出。默认按 `--version` 对应的 DEPS pin；只想用最新版可加 `--no-pin-depot-tools` |
| `--depot-tools-version VER` | 用共享的 `bootstrap_depot_tools.ps1` 把 depot_tools pin 到指定 commit/tag/branch；不指定则默认按 Chromium 版本的 DEPS pin 自动解析并 checkout |
| `--no-pin-depot-tools` | 不自动按 Chromium 版本 pin depot_tools；已有 checkout 原样使用、缺失时 clone 最新 main |
| `--make-offline-repo` | 在 fetch + runhooks 之后导出**自包含离线仓库**（本脚本仍不编译）：把**所有** `.git`（含 `src\.git`）备份并清掉，重建一个全新仓库，**两次提交**（1/2 原始源码、2/2 `init_tools`）；把 config/depot_tools/sccache/脚本/docs 收进 `<src>\init_tools`，生成 `env.bat/env.ps1`（全相对路径），并忽略 `out/` 与 `build\win_toolchain.json`（ADR-012 / PIT-019）。成功后把完成标记 `<src>\init_tools\.offline_repo.state` 一起提交进 2/2：下次分支/版本/依赖变量一致（且 `--win-toolchain-url` 与工具链归档未变）时**直接跳过** fetch/sync/hooks/export。**该跳过检查不依赖本参数**；快照存在但请求不一致时，不带本参数会**拒绝执行（exit 3）**，只有本参数允许刷新/重导出 |
| `--cleanup` | **可选**。两次提交都成功后清理下载现场：`src_git_bak` / `src_gitignore_bak`、根目录 `.gclient*` / `.gcs_entries`、`<root>\.cipd`、`<root>\depot_tools`、sccache 构建缓存。**默认不加此参数 = 全部保留**（导出用复制，方便续跑/重导出）；失败时永不清理 |
| `--sccache-url URL` | 覆盖 sccache 下载地址（默认 Mozilla GitHub Releases 最新 Windows x86_64 zip） |
| `--sccache-sha256 H` | 校验自定义 sccache 包的 SHA-256（可选） |
| `--no-bootstrap-git` | 不自动下载 PortableGit |
| `-h, --help` | 帮助 |

## chromium_build_win 参数

构建脚本只做本地编译，**不联网、不调用 gclient**。传入下载参数（如 `--version`）会直接报错并提示改用 `chromium_download_win.bat`。

| 参数 | 说明 |
| --- | --- |
| `--dir PATH` | **仓库根目录**（含 `chrome\VERSION`；目录名任意：`chromium` / `webview` / `chromium150` 都行）。也兼容父目录：若其下只有一个 `chrome\VERSION` 子目录，会自动识别 |
| `--src-dir NAME` | **仅构建脚本、仅“父目录”兼容形式**：源码目录名（默认 `src`，有多个候选时显式指定）。与下载脚本的 `--dest-name` 不是同一个参数 |
| `--target NAME` | 追加一个构建目标（可重复） |
| `--targets A,B,C` | 逗号分隔的目标列表。默认 `chrome,content_shell,headless_shell,mini_installer` |
| `--build-dir DIR` | GN 输出目录，默认 `out\Default` |
| `--release` / `--debug` | `is_debug=false` / 默认 debug |
| `--arch ARCH` | `target_cpu`：`x64`（默认）、`x86`、`arm64` |
| `--jobs N` | 覆盖并行任务数（传给 `autoninja -j`） |
| `--gn-args "ARGS"` / `--args "ARGS"` | 额外 GN 参数（写入 `args.gn`）。**cmd.exe 下整段值必须用双引号包住**，内部 GN 引号写成 `\"`；长参数用 `--args-file`（无引号层）。单引号在 cmd.exe 不是引号，拆散后的 `key=value` 现在会让脚本 **exit 3** 拒绝构建（PIT-010） |
| `--args-file PATH` | 从文件读取 GN 参数（每行一个赋值），无引号层，长参数推荐 |
| `--pgo` | 追加 `chrome_pgo_phase=2`（profile 由下载阶段默认取回；缺失时脚本会自动降级为 `0` 并告警） |
| `--no-sccache` | 即使仓库内有 `sccache.exe` 也不加 `cc_wrapper="sccache"` |
| `--sccache-dir DIR` | 覆盖 sccache 缓存目录（`SCCACHE_DIR`）。默认 `<src>\out\.cache<MAJOR>`；`out/` 已被忽略，不会弄脏仓库。别名 `--sccache-cache-dir`。脚本读取运行中守护进程的 `Cache location` 与目标比较，**不同才自动重启**；手动 stop/start 都允许（无服务时首次编译会自动启动） |
| `--check` / `--dry-run` | 只打印解析结果（源码/depot_tools/模式/工具链/sccache/GN 参数），不生成、不编译 |
| `-h, --help` | 帮助 |

构建脚本的源码定位顺序：`--dir` → `CHROMIUM_OFFLINE_SRC` → `CHROMIUM_OFFLINE_ROOT` →
脚本自身 `..\..`（导出布局 `init_tools\win`）→ `.\src` → `..\src` → `..\..\src`。

### 独立离线仓库：`--make-offline-repo`

属于**下载脚本**。指定后，在 `fetch` + `gclient runhooks` 成功之后执行导出，然后退出（下载脚本本来就不编译）：

1. 读取 `<dir>\<srcName>\chrome\VERSION` 取 `MAJOR`（例如 150）；
2. **备份 + 全删 `.git`**（ADR-012 / PIT-019）：
   - 所有 `.git`（**包括 `<srcName>\.git`**）**移动**到 `<dir>\src_git_bak\`，保留相对结构；
   - 所有 `.gitignore` **复制**到 `<dir>\src_gitignore_bak\` 后从源码树删除；
   - 删除所有 `__pycache__\` 与 `*.pyc`（PIT-009）；
2b. **保护 `win_toolchain` 的原始字节**（PIT-020）：
   - 从原始 `<hash>.zip`（`--win-toolchain-url` 指定的本地目录）**重新解压**到
     `third_party\depot_tools\win_toolchain\vs_files\<hash>`；
   - 刷新短哈希缓存 `third_party\depot_tools\win_toolchain\<hash>.timestamps`
     （日志 `Refreshed toolchain timestamps: ...`）；否则 `gn gen` 会因
     `Calculating hash ...` 打到 stdout 而报 `Invalid token`，甚至把工具链当"无主"删掉；
   - 往根 `.gitattributes` 追加 `third_party/depot_tools/win_toolchain/** -text -diff`
     （必须在 `git add` 之前，否则 `*.h text eol=lf` 会把工具链 CRLF→LF，
     内容哈希与目录名不符 → 构建时被 `get_toolchain_if_necessary.py` 删除）；
3. `git init` 全新仓库，分支 `b<BUILD>`（或 `main`），写入根 `.gitignore`
   （`/out/`、`*.log`、`*.tmp`、`**/__pycache__/`、`**/*.pyc`、`/build/win_toolchain.json`）；
4. **提交 1/2**：原始源码树（排除 `out\`、`build/win_toolchain.json`、`init_tools\`）：
   ```text
   offline repo: Chromium <MAJOR>.<MINOR>.<BUILD>.<PATCH> (original source)
   ```
5. 组装 `init_tools`：
   - 在源码目录内创建 `init_tools\<MAJOR>\{config,depot_tools,scache}` 与 `init_tools\win`；
   - `.gclient` 及 `.gclient_entries` / `.gclient_previous_*` / `.gcs_entries` **复制**到
     `config`（根目录原件先保留），config 里的 solution 名称改写为 `../../..`
     （相对 config 目录指向源码根）；
   - `depot_tools` **复制**进 `init_tools\<MAJOR>\depot_tools`（并删除副本自带的 `.git`；
     原始 `<dir>\depot_tools` 默认保留，加 `--cleanup` 时改为移动）；
   - 从 **Mozilla 官方 GitHub Releases** 取 Windows x86_64 `sccache`，解压出
     `sccache.exe` 放入 `init_tools\<MAJOR>\scache\`（可校验 SHA-256）。
     **下载提前到 commit 1 之前**（失败不会白做源码提交），失败按 `--retries` 重试；
     已存在合法 `sccache.exe` 时直接复用。`scache\cache`（构建缓存）不入库，
     默认保留，只有 `--cleanup` 时删除（PIT-023）；
   - 把两套脚本 + `README.md` 复制到 `init_tools\win\`，同时带上 `.opencode\`、`docs\`、
     `AGENTS.md`、`win*.md`（如 `win下面自动化下载编译chromium代码.md`）；
   - 生成 `init_tools\win\env.bat` / `env.ps1`，**路径全部按 `%~dp0` / `$PSScriptRoot` 推导**：
     `CHROMIUM_OFFLINE_ROOT` / `CHROMIUM_OFFLINE_SRC` / `CHROMIUM_OFFLINE_MAJOR`、
     `DEPOT_TOOLS_PATH` / `GCLIENT_FILE` / `SCCACHE_DIR`、`DEPOT_TOOLS_UPDATE=0`、
     `DEPOT_TOOLS_WIN_TOOLCHAIN=1`、PATH 前置 depot_tools + scache；
6. **提交 2/2**：`init_tools` 内容：
   ```text
   offline repo: Chromium <MAJOR>.<MINOR>.<BUILD>.<PATCH> (init_tools + full deps)
   ```
7. **完成标记随 commit 2/2 一起提交**：`<src>\init_tools\.offline_repo.state`
   （Windows 隐藏属性；git 不跟踪属性，但文件本身已入库）
   （branch/version/deps/commit 1/工具链信息；**不记录 commit 2 自身**，
   所以之后 amend commit 2 也不会失效）。下次运行且分支/依赖一致
   （给了 `--win-toolchain-url` 时归档也没变）→ **直接跳过**
   fetch/sync/hooks/export，只打印现状。
   **这个检查不依赖 `--make-offline-repo`**：不带它、同版本也会跳过；
   若快照存在但请求不一致（版本/依赖/工具链变了，或标记被删），
   不带 `--make-offline-repo` 会**拒绝执行（exit 3）**，因为隐式更新会
   checkout 真实 Chromium 分支并删掉 `init_tools`。
   强制重导：删除标记文件 **并加 `--make-offline-repo`**（或弄脏工作区/加提交）。
8. **`--cleanup`（可选）**：两次提交都成功后清理下载现场：
   - 删除 `src_git_bak` 与 `src_gitignore_bak`；
   - 删除根目录的 `.gclient` / `.gclient_entries` / `.gclient_previous_custom_vars` /
     `.gclient_previous_sync_commits` / `.gcs_entries`；
   - 删除 `<dir>\.cipd`（CIPD 缓存）与 `<dir>\depot_tools`；
   - 删除 `<src>\out\.cache<MAJOR>` 与旧的 `init_tools\<MAJOR>\scache\cache`
     （构建缓存，构建时自动重建；`out/` 默认不参与导出/提交）。
   **不加 `--cleanup`（默认）以上全部保留**，方便续跑/重导出；失败时永不清理。
   无论是否 `--cleanup`，成功结束时都会删除 `<dir>\_bad_deps`、
   `<dir>\_bad_scm` 与 `<dir>\_failed_export_git_*`（恢复/清理残留，见 PIT-025）。

**默认（不加 `--cleanup`）就是可复用现场**：

- `depot_tools` **复制**进 `init_tools`，原 `<dir>\depot_tools`（含 `.git`）保留；
- `src_git_bak` / `src_gitignore_bak` 保留；
- 根目录 `.gclient*` / `.gcs_entries` **保留**（只复制一份到 `init_tools\<MAJOR>\config`）；
- `<dir>\.cipd` 与 sccache 构建缓存**保留**。

这样"并库/导出失败"后，下一轮仍能复用真正的 depot_tools 检出、`.gclient` 状态与备份，不必重新下载。

导出后仓库可以**改名/换盘/整体拷贝**，因为：`env` 全相对；`build\win_toolchain.json`
不入库且会被构建脚本自动删除重建；`gn`/`ninja`/`clang`/toolchain 全部在仓库内。
仓库只有这 2 个快照提交，**不含 Chromium 的 git 历史**（构建不需要）。

示例：

```powershell
# branch 7871，导出到 D:\offline\src（仓库根）
.\chromium_download_win.bat --dir D:\offline --version 7871 --make-offline-repo

# 精确 tag + 自定义 sccache 包
.\chromium_download_win.bat --dir D:\offline --version 150.0.7871.289 ^
    --make-offline-repo --sccache-url "https://github.com/mozilla/sccache/releases/download/v0.19.0/sccache-v0.19.0-x86_64-pc-windows-msvc.zip"

# 导出时改名仓库目录（仓库根为 chromium_src）
.\chromium_download_win.bat --dir D:\offline --dest-name chromium_src --version 7871 --make-offline-repo

# 默认保留下载现场（depot_tools 复制、备份/.gclient/.cipd 保留）
.\chromium_download_win.bat --dir D:\offline --version 7871 --make-offline-repo

# 导出成功后清理下载现场（不可复用，体积最小）
.\chromium_download_win.bat --dir D:\offline --version 7871 --make-offline-repo --cleanup
```

之后构建（不联网；`env` 可选，build 脚本也能按自身相对位置找到源码）：

```bat
:: cmd.exe（必须 call）
call D:\offline\src\init_tools\win\env.bat
D:\offline\src\init_tools\win\chromium_build_win.bat --release --targets content_shell
```

```powershell
# PowerShell（必须点号执行）
. D:\offline\src\init_tools\win\env.ps1
D:\offline\src\init_tools\win\chromium_build_win.bat --release --targets content_shell

# 用仓库自带的默认 GN 参数（sccache/official/symbol_level 等，无引号层）
D:\offline\src\init_tools\win\chromium_build_win.bat --dir D:\offline\src --ide vs2022 -j16 --targets chrome --args-file D:\offline\src\init_tools\win\args_default.gn

# 只检查解析结果：源码/depot_tools/模式/工具链/sccache/GN 参数
.\chromium_build_win.bat --check
```

> 注意：
> - 仓库体积可能达到数十 GB（含 toolchain 与 `init_tools`）；请预留磁盘并用专用 `--dir`。
> - 导出后的仓库是**只读快照**：依赖的 `.git` 已删除，不能再 `gclient sync`；
>   版本↔配置的对照关系保存在 `init_tools\<MAJOR>\config\`。
> - `build\win_toolchain.json` 不会入库；首次 `gn gen` 会按仓库内 toolchain 重新生成。

### 版本语义

| 输入 | 解释 |
| --- | --- |
| `stable` / `latest` | Chromium Dash 上的最新稳定版 tag（默认） |
| `154.0.8037.17`（四段数字） | 精确 release tag |
| `7871`（纯数字） | 分支 → `refs/branch-heads/7871` |
| `branch-heads/7871`、`refs/...`、`main` | 分支/ref 原样使用 |

纯数字是**分支号**，不是 milestone；milestone 请用 `--milestone N`。
指定的版本若拉取失败，会自动回退到最新稳定版。

## 工作原理

**下载阶段（`chromium_download_win.ps1`，联网）**

1. 调用共享的 `bootstrap_depot_tools.ps1`：
   - git 缺失时下载 PortableGit（可用 `--no-bootstrap-git` 关闭）；
   - depot_tools 缺失时浅克隆（`git clone --depth 1`）；**离线快照（无 `.git`）会被直接接受**，
     并跳过 pin 解析与 fetch/checkout 校验；
   - 校验并 bootstrap Python/CIPD。
2. `fetch --nohooks --no-history chromium` 浅拷贝源码和依赖。
3. 解析版本；自己 `git fetch --depth 1 <ref>` + `git checkout` 到目标版本，再
   `gclient sync --nohooks --no-history` **只同步依赖**（不用 `gclient sync --revision`，
   原因见“切版本时 .git 暴涨”）。
4. `gclient runhooks` —— 执行工具链相关 hook。
5. 可选：`--make-offline-repo` 导出独立仓库（见上文）。

**构建阶段（`chromium_build_win.ps1`，不联网）**

6. 定位源码 → 修正 `build\win_toolchain.json` → `gn gen` → `autoninja` 逐个构建目标
   （单个目标失败不影响其余，最后汇总）。

### 工具链在哪一步下载

- 源码**浅拷贝**发生在 `fetch`（`--no-history`）或脚本自己的浅取。
- **Chromium 自带的 clang**：由 DEPS 的 gcs 依赖在 **`gclient sync`** 阶段下载到
  `third_party/llvm-build/Release+Asserts`（公开 bucket，可正常下载）。
- **MSVC 头文件/库 + Windows SDK**（二选一）：
  - `DEPOT_TOOLS_WIN_TOOLCHAIN=0`：使用**本机已安装的 Visual Studio**（外部用户必须）。
  - `DEPOT_TOOLS_WIN_TOOLCHAIN=1`：`runhooks` 执行 `build/vs_toolchain.py update`，从
    `gs://chrome-wintoolchain` 按 SHA 拉取预编译工具链并缓存。**该 bucket 为 Google 内部，
    匿名访问会返回 401/403**，外部用户不可用（实测 `storage.googleapis.com/chrome-wintoolchain/...`
    返回 403，而公开的 clang bucket 返回 200）。
- 因此下载脚本默认 `--win-toolchain auto`：检测到本机 VS 就用 0，否则用 1。
- **离线构建**：toolchain 已在仓库内（`init_tools\<MAJOR>\depot_tools\win_toolchain\vs_files\<hash>`
  或 `third_party\depot_tools\...`），`build\win_toolchain.json` 不入库；构建脚本发现里面的
  `path` 不在当前源码树下就删除它，让 `gn` 用 `--no-download` 就地重建（不联网）。
- CIPD 包（如 `chrome_win_x86`）是在 `gclient sync` 阶段安装的，与工具链是两回事。

## 免安装 VS：使用工具链归档（`--win-toolchain-url`）

如果不想/不能在编译机上安装 Visual Studio，可以让 `runhooks` 从一份工具链归档解压使用。

原理（都是 Chromium 官方机制）：

- `build/vs_toolchain.py` 读取 `DEPOT_TOOLS_WIN_TOOLCHAIN_BASE_URL`，从该目录取 `<hash>.zip`。
- 它支持把“规范 hash”映射到你自建的 hash：
  ```python
  key = 'GYP_MSVS_HASH_%s' % TOOLCHAIN_HASH
  return [os.environ.get(key, TOOLCHAIN_HASH)]
  ```
  即设置 `GYP_MSVS_HASH_<canonical>=<your-hash>`，自建归档就会被采用。

### 一键生成归档：`prepare_win_toolchain`

`prepare_win_toolchain.ps1` 会：按需安装 **Chromium 所需的 Visual Studio**（2026/2022/2019/2017）和
Windows SDK/Debugging Tools，再用 depot_tools 自带的
`win_toolchain/package_from_installed.py` 打包成 `<local-hash>.zip`，并写出映射文件。内置：

- **VS 版本选择** `--vs-edition buildtools|community|professional|enterprise`（默认 `buildtools`）。
- **一个安装开关** `--install-deps`：只补缺失的 VS 组件、SDK 和 “Debugging Tools for Windows”，已装则跳过（幂等）。
  不传该参数（或传 `--skip-install`）时只检查和打包，**不下载、不安装**。
- **安装器查找**：`--installer-dir DIR` 先在目录里找 `vs_<Edition>.exe` 和
  `winsdksetup.exe` / `winsdksetup-<sdk-version>.exe`；`--vs-bootstrapper`、`--sdk-installer` 可显式指定
  文件/目录/URL。找不到时从脚本开头配置的微软官方地址下载，下载后校验 PE + Authenticode 签名，并缓存到
  `<work>\installers`（SDK 安装器按版本命名，例如 `winsdksetup-10.0.28000.0.exe`）。
- **Windows SDK 检查**：使用 `build/vs_toolchain.py` 的 `SDK_VERSION`（本仓库 `10.0.26100.0`）；branch 7871 默认对应
  `10.0.26100.7705` 安装器。`package_from_installed.py` 和 7871 的 `gn copy_dlls` 都要求
  `Windows Kits\10\Debuggers\<cpu>\dbghelp.dll`。
- **重复运行安全**：已安装的 VS 组件/SDK/Debuggers 会跳过；打包在临时目录完成，同名 `<hash>.zip`
  会安全覆盖，不会因为上次的归档已存在而失败。
- **归档复用**：`TOOLCHAIN_INFO.txt` 现在记录 VS 安装版本、MSVC 工具集、SDK 版本、ARM64 开关、
  packager SHA-256、源文件指纹和 zip 的 SHA-256。下次运行如果这些输入未变且 zip 完整，
  **直接复用已有归档，不再重新打包**（只做一次约 30 秒的校验）。
  - 仅 canonical hash 变化（VS/SDK 内容相同）时，只更新 `TOOLCHAIN_INFO.txt` 的映射，不重打包。
  - `--force-repack` 可强制重新生成归档。

```powershell
# 管理员运行；只指定 Chromium 版本，自动读取 hash/SDK/VS（不下载完整源码）
.\prepare_win_toolchain.bat --dir D:\wt --depot-tools D:\download\depot_tools `
    --install-deps --chromium-version 7871

# 精确 tag / main / stable 也可以
.\prepare_win_toolchain.bat --dir D:\wt --depot-tools D:\download\depot_tools `
    --install-deps --chromium-version 150.0.7871.289
.\prepare_win_toolchain.bat --dir D:\wt --depot-tools D:\download\depot_tools `
    --install-deps --chromium-version main
.\prepare_win_toolchain.bat --dir D:\wt --depot-tools D:\download\depot_tools `
    --install-deps --chromium-version stable

# 只看依赖（VS/SDK/hash/DEPS 里的 depot_tools pin），不安装、不打包
.\prepare_win_toolchain.bat --dir D:\wt --depot-tools D:\download\depot_tools `
    --chromium-version 131.0.6778.85 --show-deps

# 旧 Chromium：用 DEPS pin 的同年代 packager（VS 2022 / SDK 22621）
.\prepare_win_toolchain.bat --dir D:\wt --depot-tools D:\download\depot_tools `
    --install-deps --pin-depot-tools --chromium-version 131.0.6778.85

# 也可以显式覆盖 hash / SDK
.\prepare_win_toolchain.bat --dir D:\wt --depot-tools D:\download\depot_tools `
    --install-deps --canonical-hash e66617bc68 --sdk-version 10.0.26100.0

# 个人使用：Community；公司内部：用 buildtools 或 professional/enterprise
.\prepare_win_toolchain.bat --dir D:\wt --vs-edition community --install-deps
.\prepare_win_toolchain.bat --dir D:\wt --vs-edition professional --install-deps
.\prepare_win_toolchain.bat --dir D:\wt --no-arm64 --install-deps   # 仅 x86/x64（默认含 ARM64）

# 优先使用本地安装器目录；找不到再下载
.\prepare_win_toolchain.bat --dir D:\wt --install-deps --installer-dir C:\Downloads\installers

# 显式指定安装器 URL
.\prepare_win_toolchain.bat --dir D:\wt --install-deps `
    --vs-bootstrapper "https://aka.ms/vs/stable/vs_BuildTools.exe" `
    --sdk-installer "https://go.microsoft.com/fwlink/?linkid=2349110"

# VS 已装好，只缺 Debugging Tools
.\prepare_win_toolchain.bat --dir D:\wt --install-deps --sdk-installer C:\Downloads\winsdksetup.exe

# 只打包，不下载/不安装
.\prepare_win_toolchain.bat --dir D:\wt --skip-install

# 强制重建归档（忽略 TOOLCHAIN_INFO.txt 的复用判断）
.\prepare_win_toolchain.bat --dir D:\wt --install-deps `
    --chromium-version 7871 --force-repack
```

> **depot_tools 版本强制检查**：只要指定了 `--chromium-version`，脚本就会读取该版本
> `DEPS` 里的 `src/third_party/depot_tools` pin，并检查本机 checkout。版本不同会先
> fetch/checkout 到该 commit，**验证通过后**才设置 `DEPOT_TOOLS_UPDATE=0`。
> `--no-bootstrap-depot-tools` 时不自动更新，但仍会校验；不匹配直接报错。

**没有 Chromium 源码也能打包（必要时自动引导 depot_tools）**

打包器 `win_toolchain/package_from_installed.py` 就在 **depot_tools 本身**里，所以只打包 zip 时
**不需要 Chromium 源码**。如果本机没有可用的 depot_tools，脚本会自动调用共享的
`bootstrap_depot_tools.ps1`（可用 `--no-bootstrap-depot-tools` 关闭）。版本信息来源按优先级：

1. `--chromium-src <chromium/src>`：本地源码，读 `build/vs_toolchain.py`。
2. `--canonical-hash <hash>` / `--sdk-version <ver>`：显式覆盖。
3. `--chromium-version <ver>`：远程解析，只下载 `build/vs_toolchain.py`（必要时加 `chrome/VERSION`），
   通常几十 KB，**不下载完整源码**。支持：
   - `7871` → `refs/branch-heads/7871`
   - `150.0.7871.289` → `refs/tags/...`
   - `main` / `beta` → `refs/heads/...`
   - `stable` / `latest` → Chromium Dash 上的最新稳定 tag
   
   它会自动得到 `TOOLCHAIN_HASH`、`SDK_VERSION`、首选 VS 版本，以及 **Chromium `DEPS` 里
   `src/third_party/depot_tools` pin 的精确 commit**。branch 7871 / tag 150.0.7871.289
   是 **VS 2026 + SDK 10.0.26100.0**；当前 main 是 **VS 2026 + SDK 10.0.28000.0**；
   131.0.6778.85 是 **VS 2022 + SDK 10.0.22621.0**。
4. `--depot-tools DIR`：指定 depot_tools（提供 packager 与 `python3.bat`）。
5. `--pin-depot-tools`：按 Chromium `DEPS` 的 pin 抓取同年代的 packager 文件（只两个 Python 文件，
   不需要完整 clone/降级 depot_tools）。旧 Chromium（如 131 → VS 2022）必须用它，否则当前
   depot_tools 的 packager 只支持 VS 2026，会提前报错。
6. `--show-deps`：只打印解析结果（VS/toolset、SDK、hash、depot_tools pin、当前 HEAD、
   packager 支持的 VS），不安装、不打包。

```powershell
# 只有 depot_tools，没有 Chromium 源码；只打包
.\prepare_win_toolchain.bat --dir D:\wt --depot-tools D:\download\depot_tools `
    --canonical-hash e66617bc68 --sdk-version 10.0.26100.0 --skip-install

# 自动解析 Chromium 版本并补齐缺失的 VS/SDK/Debuggers（推荐）
.\prepare_win_toolchain.bat --dir D:\wt --depot-tools D:\download\depot_tools `
    --install-deps --chromium-version 7871
.\prepare_win_toolchain.bat --dir D:\wt --depot-tools D:\download\depot_tools `
    --install-deps --chromium-version 150.0.7871.289
.\prepare_win_toolchain.bat --dir D:\wt --depot-tools D:\download\depot_tools `
    --install-deps --chromium-version main

# 旧 Chromium：VS 2022 + SDK 22621 + DEPS pin 的同年代 packager
.\prepare_win_toolchain.bat --dir D:\wt --depot-tools D:\download\depot_tools `
    --install-deps --pin-depot-tools --chromium-version 131.0.6778.85

# 有 Chromium 源码时（自动读 hash 与 SDK 版本，可省略上面两个参数）
.\prepare_win_toolchain.bat --dir D:\wt --chromium-src D:\download\chromium\src --install-deps
```

说明：
- `--chromium-src` 现在是**可选**：给了就读 `build/vs_toolchain.py`；没给就要求 `--sdk-version`
  （`--canonical-hash` 可省，只是 `TOOLCHAIN_INFO.txt` 里不写 `GYP_MSVS_HASH_*`，之后用主脚本的
  `--win-toolchain-hash <local-hash>` 补上即可）。
- packager 查找顺序：`--depot-tools\win_toolchain\...` → `<root>\depot_tools\win_toolchain\...` →
  `<chromium-src>\third_party\depot_tools\win_toolchain\...`。

**按版本作用域 + 逐组件检查 + 只用指定版本**

脚本现在是“实例感知”的，严格按你指定的版本工作：

- **只认指定版本**：`--vs-edition` 决定 VS 产品 ID（Community/Professional/Enterprise/BuildTools）。
  只检查/安装该产品；机器上别的版本**一律忽略**，打包也**只从指定版本的这个实例**取（脚本会生成一个
  小 wrapper 强制 `package_from_installed.py` 使用该实例路径，避免它误选其它版本）。
- **逐组件检查、缺啥装啥**：对每个必需 VS 组件用 `vswhere -requires` 检查（VC 工具集、ATLMFC、ARM64
  组件（**默认包含**，用 `--no-arm64` 关闭））。已装则跳过；只把**缺失的组件**传给安装器
  （对已存在实例执行“增量添加”）；整个版本没装才全新安装。Windows SDK/Debuggers 单独由
  `winsdksetup.exe` 安装（见下）。
- **可选用系统已有**：`--prefer-installed` 时，若机器上**任意**版本的、与 Chromium 要求一致的
  VS 实例已具备全部必需组件，就直接复用它、不安装（仍会校验组件）。
- 版本范围由 Chromium 的 `MSVS_VERSIONS` 决定：2026 → productLineVersion 18，2022 → 17，
  2019 → 16，2017 → 15；不会误匹配其它大版本。

**VS 版本与许可（按许可选，不是按喜好）**

| `--vs-edition` | 说明 |
| --- | --- |
| `buildtools`（默认） | 免费、无 IDE，推荐用于 CI；个人/公司都可用（公司使用请查 EULA） |
| `community` | 免费 IDE，**仅限个人/小型组织**（约 <250 台设备且 <100 万美元收入）；大型企业**不可用** |
| `professional` / `enterprise` | 公司内部开发应使用（或公司已有的 VS 批量授权） |

**Windows SDK**

- Chromium 需要**某一个特定版本**（`build/vs_toolchain.py` 的 `SDK_VERSION`），并非越新越好。
- 安装途径：`--install-deps` 用 `winsdksetup.exe` 同时安装所需 SDK 和 “Debugging Tools for Windows”；
  也可用 `--installer-dir` / `--sdk-installer` 指定本地文件、目录或 URL。
- 官方下载页：https://learn.microsoft.com/en-us/windows/apps/windows-sdk/downloads
  脚本开头内置了两个链接：branch 7871 对应的 `10.0.26100.7705`（linkid=2349110）和 main 对应的
  `10.0.28000.2957`（linkid=2382519）；链接变化时改脚本开头或传 `--sdk-installer`。
- `package_from_installed.py` 只检查 `Debuggers` 目录存在；但 7871 的 `gn copy_dlls` 要求
  `Debuggers\<cpu>\dbghelp.dll`，所以脚本按真实文件检查，不能只建空目录。

完成后在 `<out>\`（默认 `D:\wt\win_toolchain_archive`）得到 `<local-hash>.zip` 与
`TOOLCHAIN_INFO.txt`（含 `GYP_MSVS_HASH_<canonical>=<local-hash>`、
`DEPOT_TOOLS_WIN_TOOLCHAIN_BASE_URL`，以及可复核的 `download_command=` 与 `build_command=`）。

成功后脚本会打印**两步**命令，例如：

```text
1) Download (needs network; replace <build-root> with a path without spaces):
     .\chromium_download_win.ps1 --dir <build-root> --version 7871 \
       --win-toolchain-url "file://C:/wt/win_toolchain_archive/" \
       --win-toolchain-hash 6ea3651657

2) Build (no network, no gclient):
     .\chromium_build_win.ps1 --dir <build-root> --release --targets content_shell
```

把 `<build-root>` 换成不含空格的构建根目录即可；同样的两条命令也会写进
`TOOLCHAIN_INFO.txt`（`download_command=` / `build_command=`）。

实际使用（下载脚本负责 `--win-toolchain-url`，构建脚本不再联网）：

```powershell
# 1) 下载（本地归档；脚本会自动探测 zip 并设置映射）
.\chromium_download_win.bat --dir D:\download --version 7871 --win-toolchain-url "file://D:/wt/win_toolchain_archive/"

#    http 镜像（无法列目录，需显式给 hash）
.\chromium_download_win.bat --dir D:\download --version 7871 --win-toolchain-url "https://mirror.corp/win_toolchain/" --win-toolchain-hash <local-hash>

#    想直接产出可搬迁的离线仓库：再加 --make-offline-repo

# 2) 编译（离线）
.\chromium_build_win.bat --dir D:\download\src --release --targets content_shell
#    或从导出的仓库直接跑：
#    D:\download\src\init_tools\win\chromium_build_win.bat --release --targets content_shell
```

约定与注意：

- URL 是**目录**（不是 zip 本身）；本地用 `file://D:/.../`（或 `file:///D:/.../`），http 结尾自动补 `/`。
- `--win-toolchain-url` 隐含 `--win-toolchain 1`，并设置 `DEPOT_TOOLS_WIN_TOOLCHAIN_BASE_URL`。
- “规范 hash”（canonical）来自当前 revision 的 `build/vs_toolchain.py` 的 `TOOLCHAIN_HASH`
  （本仓库为 `e66617bc68`），脚本会自动读取。
- `package_from_installed.py` 在某个 depot_tools 版本里只支持 **一个 VS 大版本**：
  当前 depot_tools 支持 VS 2026，Chromium 131 年代的 depot_tools 支持 VS 2022。
  旧 Chromium 打包时用 `--pin-depot-tools` 取 DEPS pin 的同年代 packager。
  同时要求装好 **Windows SDK 调试器**（`Windows Kits\10\Debuggers\<cpu>\dbghelp.dll`）。
- VS bootstrapper：脚本默认按 Chromium 要求的 VS 版本推导：
  - 2026 → `https://aka.ms/vs/stable/vs_<Edition>.exe`（stable = VS 2026）
  - 2022 → `https://aka.ms/vs/17/release/vs_<Edition>.exe`
  - 2019 → `https://aka.ms/vs/16/release/vs_<Edition>.exe`
  若短链不可用（下载到的是网页而非 exe，脚本会校验 PE + Authenticode 并报错），请到
  https://visualstudio.microsoft.com/downloads/ 手动下载对应的 `vs_<Edition>.exe`，
  再用 `--vs-bootstrapper <路径>` 传入。
- SDK 安装器：脚本开头内置 26100 / 28000 的 fwlink；其它版本会尝试从官方
  Windows SDK downloads 页面解析。解析失败时传 `--sdk-installer <URL/路径>`。
  这些 fwlink **不保证永久不变**，链接失效时改脚本开头或传 `--sdk-installer`。
- `--install-deps` 需要**管理员**权限。本次修改已做验证：`--help`、`--dry-run`、
  `--chromium-version 7871 / 150.0.7871.289 / main / stable / 131.0.6778.85` 解析、
  `--show-deps`、`--pin-depot-tools`（7871 用 DEPS pin 的 packager 完整打包成功；
  131 dry-run 正确解析 VS 2022 + SDK 22621 + depot_tools pin）、安装器目录/URL 解析、
  Debugging Tools 实际安装、按版本解析后完整打包（同名 zip 安全覆盖）。
  另外验证了 `bootstrap_depot_tools.ps1`：新目录 clone depot_tools 到指定 commit、
  bootstrap Python、再次运行幂等；`prepare --chromium-version 7871` 会把已有
  depot_tools 切到 `f4fadaf...`，切到 `main` 会切到 `c4cdaeeb...`；
  `--no-bootstrap-depot-tools` 下版本不匹配会直接报错；
  `chromium_build_win.ps1 --version main/7871 --depot-tools-only` 会自动在
  `c4cdaeeb...` / `f4fadaf...` 之间切换；`--depot-tools-version` 也可显式 pin。
  归档复用也已验证：第二次相同输入约 35 秒完成校验并直接复用 zip；
  仅 canonical hash 变化时只更新映射、不重打包；`--force-repack` 可强制重建。
  `--make-offline-repo` 已用**假源码树**验证（未下载完整 Chromium）：包含 5 个嵌套
  假 git 仓库，成功清理嵌套 `.git`、移动 gclient 配置/depot_tools、下载并解压
  sccache v0.19.0（SHA-256 校验通过）、复制 8 个脚本、生成 env、强制加入被
  `.gitignore` 忽略的二进制，
  并生成一条 `init: Chromium ... offline repository` 提交；旧 `chromium\src` 布局
  迁移到 `src` 也已验证。测试产物：
  `C:\wt\win_toolchain_archive\fab72fa52c.zip`（约 2.27 GB），映射
  `GYP_MSVS_HASH_e66617bc68=fab72fa52c`。

### 许可与合规提示（非法律意见）

- **Chromium 源码**是 BSD 风格许可，可自由使用/修改/分发。
- **Visual Studio / MSVC / Windows SDK** 是微软产品，受其自身许可约束；用它们“编译”你的程序
  一般是被允许的，但**再分发**（如随产品附带 DLL、或把 SDK/工具链整体拷贝分发）有额外条件。
- **VS Community 版**对**大型企业**（大致为 >250 台设备或年收入 >100 万美元）**不在授权范围内**。
  大公司内部开发通常应使用 **Professional/Enterprise**（或公司已有的批量授权），不要用 Community。
  这正是 `prepare_win_toolchain` 提供 `--vs-edition` 的原因：个人用 `community`，公司用
  `professional`/`enterprise`（或 `buildtools`）。
- **Build Tools for Visual Studio** 是官方提供、可免费下载的“无 IDE”形态，常用于 CI；其许可条款
  与对应 VS 版本一致。是否可用于你司内部，请以安装器内的 EULA 为准。
- 把工具链归档**在公司内网**用 `--win-toolchain-url` 共享，属于公司内部再分发，**需先确认你司与
  微软的授权是否允许**（很多企业授权允许内部使用，但不允许对外分发）。

> 建议：在大规模落地前，把“使用 MSVC/Build Tools + Windows SDK 编译并内部共享工具链”的合规性
> 交给公司法务/IT 许可团队确认。脚本本身不改变任何许可条款。

## 常见问题

### Windows Defender 拦截（fetch 失败）

报错示例：

```
Failed to open the instance chromium/third_party/updater/chrome_win_x86:...
Operation did not complete successfully because the file contains a virus or
potentially unwanted software.
```

这是 Defender 误判并隔离了 CIPD 包（Chrome 更新器二进制），导致 `cipd ensure` 失败。
`_bad_scm` 相关输出只是 gclient 自我恢复的警告，非致命。

处理（管理员 PowerShell）：

```powershell
Add-MpPreference -ExclusionPath "D:\download"
Add-MpPreference -ExclusionPath "$env:USERPROFILE\.cipd"   # 可选
```

然后恢复（`.gclient` 已生成，无需重新 fetch）：

```powershell
cd D:\download
gclient sync --nohooks --no-history
```

或重跑脚本并加 `--add-defender-exclusions`，它会跳过 fetch、补齐 CIPD 包后再 runhooks。

### 源站限流 HTTP 429 / 下载长时间停顿

报错示例：

```
remote: RESOURCE_EXHAUSTED: Resource has been exhausted (e.g. check quota)
remote:   subject: "shared/shared_anonymous"
remote:   description: "Short term server-time rate limit exceeded"
fatal: unable to access 'https://webrtc.googlesource.com/src.git/': The requested URL returned error: 429
error: RPC failed; HTTP 429 curl 22 The requested URL returned error: 429
fatal: expected 'packfile'
```

或：

```
STALL DETECTED: gclient has been silent for 5 minutes.
   src/third_party/rust-toolchain:Win/rust-toolchain-....tar.xz (Running for 0:41:46)
```

这是 Google 源码服务器**短时限流**或某个大文件下载**卡住**，不是脚本问题，也和 Defender 无关。

处理：**直接重跑原脚本即可**。原因：`chromium\.gclient` 已经生成，脚本检测到后会
**跳过 fetch**，改为续传：

- 默认 `--version stable` → `gclient sync --no-history --revision src@<稳定版 tag>`
- `--version main` → `gclient sync --no-history --revision src@main --with_branch_heads`
- 已存在的项目会被快速跳过，只补下失败/缺失的项目。

建议：

1. 等几分钟再跑（429 是“短时限流”）。
2. 脚本默认对 fetch / `gclient sync` / `runhooks` **各重试 10 次**，间隔递增
   （30 s、60 s、…，最后一轮约 5 分钟；10 次重试累计等待约 27 分钟）；
   可用 `--retries N` 调整（`--retries 0` 关闭）。切版本时的 `gclient sync` 同样适用。
3. 失败提示会区分：429 限流 / 下载停顿 / Defender / 网络，并给出重跑与续传命令。
4. **只有请求的 ref 确实不存在时才会回退到最新稳定版**。脚本先用
   `git ls-remote --exit-code` 判断 ref 是否存在（不下载对象）；若 ref 存在但同步失败，
   会视为瞬时故障并重试，**绝不会**因为一次 429 就偷偷换成别的版本。
4. 可选清理被隔离的冲突目录后再跑，回收磁盘（脚本现在会在**成功结束时自动**删除
   `_bad_scm`；失败现场仍保留，便于续传/诊断）：
   ```powershell
   Remove-Item -Recurse -Force D:\git\download\chromium\_bad_scm   # 立即清
   ```
   `_bad_scm` 每次失败都可能累积，属正常现象；续传会逐个项目补齐。
5. 手动续传：
   ```powershell
   cd D:\git\download
   gclient sync --nohooks --no-history
   ```

### 切版本时 `src\.git` 暴涨（出现十几 GB 的 `tmp_pack_*`）

现象：用 `--version <分支/tag>` 重跑后，`src\.git\objects\pack\` 里出现一个
十几 GB 的 `tmp_pack_xxxx`，而初始浅拷贝的 pack 只有约 1.5 GB。

例如：

```
.git\objects\pack\
  pack-31e29592....pack       1.45 GB   <- 初始浅拷贝
  tmp_pack_JEu8zY            18.18 GB   <- 切版本时的临时 fetch pack
```

原因：这是 **“浅克隆 + 事后切换版本”** 的固有矛盾，不是参数写错，也不是仓库损坏。

- `7871` 会被正确解析为 `refs/branch-heads/7871`，参数本身没错。
- 真正触发点：`gclient sync` 对**已存在**的浅仓库走 `_Update`，用
  `IsValidRevision(..., sha_only=True)` 判断 revision（`refs/remotes/origin/main`）；
  引用名永远不等于 sha → 必然执行**不带 `--depth`** 的 `git fetch origin --no-tags`
  → 浅仓库就变成下载全部历史（28M+ 对象）。详见 **PIT-016**。
- `--no-history` 只作用于 `_Clone` 和带 depth 的 `_AutoFetchRef`，救不了这条路径。
- `--with_branch_heads`/`--with_tags`（默认关）是另一个数量级的放大器：会抓所有分支/tag。
- `tmp_pack_*` 是 git 写入中的**临时** pack：fetch 正常结束后会被转正或清理；只有
  进程被中断时才会残留。

规避与处理：

1. 正在运行就让它跑完；`tmp_pack` 完成后会消失/转正。
   若明显是“全量历史”（`tmp_pack` 已几十 GB、`--pack_header=2,<数千万>`），
   停掉更划算：`taskkill /PID <脚本进程> /T /F`，再删 `tmp_pack_*` 重跑。
2. **两层保护**：
   - 让 src 保持 **unmanaged**（主修复）：`.gclient` 里 `managed: False` 时
     `gclient_scm.py:878` 会直接 `unmanaged solution; skipping src`，根本不 fetch。
     脚本的 `Set-GclientCustomVars` 现在用
     `gclient config --name src --unmanaged ...`，并会修正旧文件里的 `managed: True`
     （`gclient config` 默认写 True，正是它把 `fetch` 的 False 覆盖掉的）。
   - 再钉 **40 位 sha**（兜底），而不是引用名：
     ```powershell
     $sha = git -C <src> rev-parse HEAD
     gclient sync --nohooks --no-history --revision src@<sha>
     ```
     这样 `IsValidRevision(..., sha_only=True)` 命中，gclient 打印
     `Up-to-date; skipping checkout.`，只浅同步 DEPS 子仓库。
     注意 `--revision src@refs/branch-heads/7871` 这种**引用名仍会全量 fetch**。
     脚本在 `Set-ChromiumRevision`、main 分支 sync、fetch 失败后的 resume sync
     都已按此实现。
3. 脚本自己执行 `git fetch --depth 1 origin <ref>` + `git checkout --detach <sha>`，
   并写入本地 `refs/remotes/origin/main` 与 `refs/remotes/origin/HEAD`，
   避免 gclient 走网络的 `git remote set-head -a origin`（也会卡住）。
4. **脚本启动时会自动清理残留的临时包**：在 `src\.git\objects\pack\` 下查找 `tmp_*`
   （`tmp_pack_*`/`tmp_idx_*`/`tmp_rev_*`）并删除。这类文件 git 后续**不会读取**，是纯粹的
   磁盘垃圾；只有被中断的 fetch 才会残留。若文件正被其它 git 进程写入，Windows 会锁定，
   删除会失败并跳过（不会误删）。也可手动删除：
   ```powershell
   Remove-Item D:\git\download\src\.git\objects\pack\tmp_* -Force
   ```
5. 也可用 `--gc` 在 checkout 后执行 `git -C src gc --prune=now` 回收不可达对象。
6. **切换版本时自动清理过期依赖**：脚本给 `gclient sync` 加了 `-D`
   （`--delete_unversioned_trees`），新 `DEPS` 里已删除的依赖目录会被自动移除，
   不需要再手工处理 `'...' is no longer part of this client` 警告。
   有本地修改的目录会保留并打印警告；仍属于 `DEPS` 的依赖中的未跟踪文件
   （例如 `third_party/depot_tools/win_toolchain/vs_files`）**不会**被删。

#### 如何确保 `.git` 最小

关键是**不要让 gclient 先抓 main 再切版本**（那会多留一份 main 的对象，切不同分支还可能再拉历史）。
做法：

1. **一开始就确定版本**（branch / tag / milestone）。
2. 加 `--pinned`：脚本只做 `gclient config` + 浅 fetch 目标 ref + checkout +
   `gclient sync` 依赖，不抓 main。结果就是**只含目标版本的一份浅 pack（约 1–2 GB）**：
   ```powershell
   .\chromium_download_win.bat --dir D:\download --version 7871 --pinned
   .\chromium_download_win.bat --dir D:\download --version 154.0.8037.17 --pinned
   .\chromium_download_win.bat --dir D:\download --milestone 131 --pinned
   ```
3. 如果已有旧 checkout、想换成最小：先删掉源码目录再按上面重来（依赖的 `.git` 也会重新浅取）：
   ```powershell
   Remove-Item -Recurse -Force D:\download\src
   .\chromium_download_win.bat --dir D:\download --version 7871 --pinned
   ```
   删掉 `src` 但保留 `D:\download\.gclient` 也没关系：脚本会检测到“有 `.gclient`、没有 `src`”，
   直接复用该配置并通过 `gclient sync` 重建 `src`（不会再先抓 main）。
4. `git gc --prune=now` 只能清理**不可达**对象。若你反复来回切换版本，两个版本都可达，就删不掉；
   真正要“最小”还是按上面的方式重建。

> 注意：`--pinned` 适合“只构建一个版本”。如果你会频繁在多个版本间切换，保留 main 的浅拷贝反而
> 更省事，此时不必加 `--pinned`。

### PowerShell 被限制

脚本会自检并给出提示：

- **执行策略**为 `Restricted`/`AllSigned`：
  ```powershell
  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
  ```
  或始终通过 `.bat` 启动（它使用 `-ExecutionPolicy Bypass`）。
- **文件来自网络**（Mark of the Web）：
  ```powershell
  Unblock-File -Path .\chromium_build_win.ps1
  ```
- **ConstrainedLanguage / AppLocker / WDAC**（受管机器）：由策略强制，用户无法用单条命令
  关闭。检查：
  ```powershell
  Get-AppLockerPolicy -Effective -Xml
  Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard
  ```
  需管理员放开策略，或改用非受管机器。`.bat` 启动前会实际试跑一次脚本，失败时打印
  PowerShell 的原始报错及上述处理办法。

## depot_tools 历史版本与依赖解析

### 官方对应关系：有

Chromium 的 `DEPS` 里有一条 **`src/third_party/depot_tools`**，直接 pin 到某个 depot_tools commit：

```text
'src/third_party/depot_tools':
    Var('chromium_git') + '/chromium/tools/depot_tools.git' + '@' + '<40-hex-commit>',
```

所以“某 Chromium 版本对应某 depot_tools commit”**有官方来源**，不是只能按日期猜。实测：

| Chromium | depot_tools pin |
| --- | --- |
| `7871` / `150.0.7871.289` | `f4fadaf6a5ba1bced9d3d9021060667b563bf583` |
| `main`（2026-11） | `c4cdaeebba9b9ed92d041997317ffdbd042158ac` |
| `131.0.6778.85` | `20b9bdcace7ed561d6a75728c85373503473cb6b` |

### 用脚本查看依赖

`prepare_win_toolchain.ps1` 的 `--show-deps` 会同时解析：

- `build/vs_toolchain.py`：`MSVS_VERSIONS`、`MSVC_TOOLSET_VERSION`、`SDK_VERSION`、`TOOLCHAIN_HASH`
- `DEPS`：`src/third_party/depot_tools` 的精确 pin
- 当前 depot_tools HEAD 与 pin 的差异
- 当前 packager 支持的 VS 版本

```powershell
.\prepare_win_toolchain.bat --dir D:\wt --depot-tools D:\download\depot_tools `
    --chromium-version 7871 --show-deps

.\prepare_win_toolchain.bat --dir D:\wt --depot-tools D:\download\depot_tools `
    --chromium-version 131.0.6778.85 --show-deps
```

`131.0.6778.85` 的输出会显示：

```text
Visual Studio   : 2022 (productLineVersion 17)
MSVC toolset    : VC143
Windows SDK     : 10.0.22621.0
depot_tools pin : 20b9bdcace7ed561d6a75728c85373503473cb6b
packager VS     : 2026  (INCOMPATIBLE; use --pin-depot-tools)
```

### 为什么打包时 depot_tools 版本重要

`win_toolchain` 的 **选择** 由 Chromium 自己的 `vs_toolchain.py` 决定；但 **生成归档** 的是
depot_tools 里的 `win_toolchain/package_from_installed.py`，它只支持某一个 VS 大版本：

- 当前 depot_tools 的 packager：只支持 VS 2026
- Chromium 131 年代的 packager：只支持 VS 2022

所以旧 Chromium 如果只换 `--vs-installer` 而不换 packager，会报：

```text
Chromium requires Visual Studio 2022, but the selected packager supports VS 2026...
```

### `--pin-depot-tools`

加上该参数后，脚本会：

1. 从 Chromium `DEPS` 读取精确的 depot_tools commit；
2. 只抓取该 commit 下的两个 stdlib-only Python 文件：
   - `win_toolchain/package_from_installed.py`
   - `win_toolchain/get_toolchain_if_necessary.py`
3. 放到 `<work>\depot_tools_pinned\<short-commit>\win_toolchain\`；
4. 用当前 Python 运行这份“同年代”的 packager。

**不需要完整 clone depot_tools，也不需要 checkout/降级现有的 depot_tools。**

```powershell
# 旧 Chromium：使用 DEPS 对应的 packager + 对应 VS/SDK
.\prepare_win_toolchain.bat --dir D:\wt --depot-tools D:\download\depot_tools `
    --install-deps --pin-depot-tools --chromium-version 131.0.6778.85
```

### 日期近似查找脚本（后备）

`find_depot_tools_version.ps1` 仍可用于：

- 非常老的 Chromium（其 DEPS 没有 `src/third_party/depot_tools` pin）；
- 想按日期了解 depot_tools 历史；
- 需要手动 pin 一个完整 depot_tools checkout 的场景。

```powershell
.\find_depot_tools_version.bat --version 131.0.6778.85
.\find_depot_tools_version.bat --version 7871
.\find_depot_tools_version.bat --date 2022-12-12
.\find_depot_tools_version.bat --version 108.0.5359.125 --checkout
```

手动 pin 完整 depot_tools：

```powershell
git -C .\depot_tools fetch --depth 1 origin <commit>
git -C .\depot_tools checkout --detach <commit>
$env:DEPOT_TOOLS_UPDATE = "0"
```

恢复：

```powershell
git -C .\depot_tools fetch --depth 1 origin main
git -C .\depot_tools checkout -B main FETCH_HEAD
Remove-Item Env:\DEPOT_TOOLS_UPDATE
```

## 可选依赖开关（下载环境 ≠ 开发环境时）

Chromium 很多额外内容用 `DEPS` 里的变量做开关，**默认 False**，普通 `gclient sync` **不会**下载。
如果“联网下载”和“离线开发”是两台机器，最好在**联网阶段**把这些开关打开、一次下全。

脚本提供：

```powershell
# 一键：下载一整套可离线使用的 Windows 开发/测试依赖
.\chromium_build_win.bat --dir D:\download\src --full-deps

# 精细控制：直接写 custom_vars
.\chromium_build_win.bat --dir D:\download\src --deps "checkout_clangd=True,checkout_wpr_archives=True"
```

`--full-deps` 等价于启用下列这些（都可再单独用 `--deps` 覆盖）：

| DEPS 变量 | 内容 |
| --- | --- |
| `checkout_clang_tidy` | clang-tidy（与 clang 同目录） |
| `checkout_clangd` | clangd 语言服务器 |
| `checkout_clang_coverage_tools` | `llvm-cov` / `llvm-profdata`（`use_clang_coverage` 用） |
| `checkout_pgo_profiles` | Windows PGO profile（几百 MB，`--pgo` 也开这个） |
| `checkout_bazelisk` | 仅打包 `rust-toolchain` 用 |
| `download_libaom_testdata` | AV1 编解码测试数据 |
| `download_libvpx_testdata` | VP8/VP9 测试数据 |
| `checkout_wpr_archives` | Web Page Replay 归档（**较大**，跑 web 测试用） |

其余 Windows 相关但**默认关闭**的开关（按需用 `--deps` 开；有些需要 Google 权限，外部用户开不了）：

| DEPS 变量 | 默认 | 说明 |
| --- | --- | --- |
| `checkout_telemetry_dependencies` | False | 性能测试依赖，部分仅内部可见 |
| `checkout_clusterfuzz_data` | False | 模糊测试归档 |
| `checkout_chromium_autofill_test_dependencies` | False | 仅 Googler（超大网页捕获文件） |
| `checkout_chromium_password_manager_test_dependencies` | False | 仅 Googler（超大网页捕获文件） |
| `checkout_soda` | False | 需 `checkout_src_internal`（内部） |
| `checkout_glic_e2e_tests` | False | glic E2E 测试代码/归档 |
| `checkout_src_internal` / `checkout_google_internal` | False | Google 内部源码 |
| `download_remoteexec_cfg` / `download_reclient` | False / 依 ChromeOS | 远程执行配置/客户端 |
| `checkout_instrumented_libraries` | False | 仅 Linux MSan |
| `checkout_mutter` | False | 仅 Linux（Wayland compositor 测试） |
| `checkout_cast3p` | False | Cast3P |
| `checkout_android` / `checkout_fuchsia` / `checkout_chromeos` / `checkout_ios_*` | False | 其他平台，Windows 上无需 |

默认**已开启**（无需处理）：`checkout_js_coverage_modules`、`checkout_openxr`（Win 默认开）、
`checkout_gpu_meet_effects`、`checkout_press_benchmarks`（后两者在 `checkout_configuration="small"` 时关闭）。

补充：

- 想**减少**下载可用 `--deps "checkout_configuration=small"`（跳过一些非构建必需项）。
- 用 `--deps` 设置的值会写入 `.gclient` 的 `custom_vars`，**在 sync 之前**生效（脚本已调整顺序），
  因此当次 sync 就会把对应内容下下来。
- 真正“离线可构建”还需要：`clang`（默认会下）、`win_toolchain`（`gclient runhooks` 时下，
  脚本默认执行）、depot_tools 的 python/bootstrap。联网跑一次完整脚本（含 runhooks）即可缓存。
- 这些只是**额外**内容；**构建本身所需**的依赖在默认 sync 中已全部包含，离线构建通常无需 `--full-deps`。

## CPU 架构与交叉编译（--arch）

`--arch` 接受 `x64`、`x86`、`arm64`，脚本会转成 GN 参数 `target_cpu`：

```powershell
# 默认：按主机（x64）
.\chromium_build_win.bat --dir D:\download\src

# 32 位 x86
.\chromium_build_win.bat --dir D:\download\src --arch x86 --release

# arm64（在 x64 主机上交叉编译）
.\chromium_build_win.bat --dir D:\download\src --arch arm64 --release
```

说明：

- `--arch` 只是设置 `target_cpu`；`target_os` 仍为 `win`（我们在 Windows 上运行）。
- **工具链包含 ARM64 库**：`build/vs_toolchain.py` 注释为 “VS 2026 18 with 10.0.28000.2270 SDK
  with ARM64 libraries and UWP support”，且代码已处理 `target_cpu == 'arm64'` 的 VCRuntime 目录。
  Chromium 自带的 clang 是交叉编译器，可产出 arm64。
- 若用**本机 VS**（`DEPOT_TOOLS_WIN_TOOLCHAIN=0`，外部用户路径），需在 VS 安装器里额外勾选
  `Microsoft.VisualStudio.Component.VC.Tools.ARM64` 与 `VC.MFC.ARM64`，否则缺 arm64 库。
  （`DEPOT_TOOLS_WIN_TOOLCHAIN=1` 的 Google 内部预编译包已带 ARM64，但外部不可用。）
- **产物只能在其目标架构上运行**：arm64 产物需 Windows on Arm 才能运行（x64 Windows 不能直接跑 arm64 程序）。
- 若 `--arch` 值非法，脚本会告警并回退到主机默认。
- 也可继续用 `--gn-args "target_cpu=\"arm64\""` 达到同样效果；两者都提供时以 `--gn-args` 为准（脚本不重复添加）。

## PGO（Profile Guided Optimization）

**默认已经下载 PGO 文件。** Chromium 的 `DEPS` 里下载 PGO profile 的 hook 条件是
`checkout_pgo_profiles and checkout_win`，而该变量在 `DEPS` 中默认为 `False`。
下载脚本现在**默认**把它写进 `.gclient` 的 `custom_vars`，所以 `gclient runhooks`
会把 profile 一起拉下来，避免以后离线时才发现缺文件：

```text
custom_vars: {
  checkout_pgo_profiles: True,
  checkout_clang_coverage_tools: True,
}
```

关掉的办法：`--no-extra-deps`，或单独 `--deps "checkout_pgo_profiles=False"`。

- profile 落地位置：`src\chrome\build\pgo_profiles\*.profdata`
  （配套文本配置在 `src\chrome\build\*.pgo.txt`，例如 `win64.pgo.txt` 写明**本版本**
  需要哪个文件名）；由 `src\tools\update_pgo_profiles.py` 下载，
  win32/win64/win-arm64 各一份，通常几百 MB。
- `chrome_pgo_phase` 的默认逻辑（`build/config/compiler/pgo/pgo.gni`）：
  普通构建为 `0`；仅当 `is_official_build` 且平台为 win/mac/linux 等时才自动设为 `2`。
  并且有断言 `!is_debug || chrome_pgo_phase == 0` —— 即 **debug 构建不能用 PGO**。

下载脚本结束时会打印一行 `PGO`，三种可能：

```text
 PGO        : chrome-win64-150.0.7871.290-<hash>.profdata present (xxx MB) - build with --args "chrome_pgo_phase=2"
 PGO        : profiles requested but none found (hooks skipped or fetch failed)
 PGO        : profiles not downloaded (official builds will use chrome_pgo_phase=0)
```

构建脚本站在 `is_official_build=true` 时会读 `chrome\build\<target>.pgo.txt` 检查
**这个版本需要的那份** profile：

- 存在 → 保持默认 `chrome_pgo_phase=2`（用 PGO）；
- 缺失（包括只有其他里程碑的旧 profile）→ 打印 `Expected profile: ...` 并自动降级为
  `chrome_pgo_phase=0`，避免 `gn gen` 跑一半才报 `requested profile ... doesn't exist`。

所以下载之后再切编译参数不需要重新联网：

```powershell
# 下载（默认就带 PGO profile；加 --pgo 只是显式声明）
.\chromium_download_win.bat --dir D:\download --version 7871

# 之后离线构建，随时切换是否用 PGO
.\chromium_build_win.bat --dir D:\download\src --release --targets chrome --args "is_official_build=true"
.\chromium_build_win.bat --dir D:\download\src --release --targets chrome --args "is_official_build=true chrome_pgo_phase=0"
```

说明与注意：

- 顺序很重要：**先下载 profile（runhooks），再 `gn gen`**。若用 `--skip-hooks`，
  profile 不会下载，官方构建会自动降级为 `chrome_pgo_phase=0`。
- 想省略 profile 以省磁盘（几百 MB）：`--no-extra-deps`。

## 系统要求

- Windows 10/11 x64
- 8 GB+ 内存（建议 16 GB+）
- 100 GB+ 空闲 NTFS 磁盘（FAT32 不行，部分 Git pack 超过 4 GB）
- 联网
- Git for Windows（缺失时自动下载 PortableGit）
- **Visual Studio 2026（或 Build Tools）**，需 “Desktop development with C++” 与 “MFC/ATL” 组件。
  这是外部用户的**硬性要求**（预编译工具链为 Google 内部资源）。安装命令示例：

  ```powershell
  # 以管理员运行 VS 安装器（Community 版）
  & "$env:TEMP\vs_Community.exe" `
      --add Microsoft.VisualStudio.Workload.NativeDesktop `
      --add Microsoft.VisualStudio.Component.VC.ATLMFC `
      --includeRecommended
  ```

  安装后脚本的 `--win-toolchain auto` 会自动检测并使用本机 VS（`DEPOT_TOOLS_WIN_TOOLCHAIN=0`）。
