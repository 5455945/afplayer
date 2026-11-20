# 架构决策记录（ADR）

> 只记录「为什么这样选」，不记录实现细节（见 `STATE.md`）。
> 编号格式 `ADR-NNN`；状态 `accepted | superseded`。

## ADR-001 下载与构建拆分为两个脚本

- **状态**：accepted（2026-11-11）
- **背景**：单脚本里 `--make-offline-repo` 必须在构建前 `exit`，否则导出会先搬走 `.gclient`/`depot_tools`、删掉所有依赖的 `.git`，构建流程随后就失去可更新性；两种生命周期混在一起无法兼顾。
- **备选**：
  - A：单脚本加开关（`--build-after-export`）
  - B：拆成 `chromium_download_win` + `chromium_build_win`
  - C：只写文档约定，不改脚本
- **决定**：B。
- **后果**：
  - 构建脚本做到**零网络、零 gclient**，可离线、可在任意拷贝/改名后的仓库里运行；
  - 参数需要迁移：`--version/--milestone/--make-offline-repo/...` 属于下载脚本，构建脚本收到会明确报错；
  - 两套入口共享 `bootstrap_depot_tools.ps1`，参数解析有少量重复。
- **验证**：`docs/VERIFY.md` 中「离线仓库 → 改名跨盘 → --check → 构建参数」演练通过。

## ADR-002 离线仓库的根目录是源码目录（而不是它的父目录）

- **状态**：accepted（2026-11-11）
- **背景**：希望「一个仓库 = 一套可构建的 Chromium」，且能整体改名/换盘；同时不想在 Chromium 父目录里散落 `.git`/`init_tools`。
- **备选**：
  - A：仓库根 = `<dir>`（`src` 只是子目录）
  - B：仓库根 = `<dir>\<srcName>`，`.git`/`.gitignore`/`init_tools` 都在里面
- **决定**：B，且**复用源码仓库已有的 `.git`**（保留浅历史，再追加一个 offline commit），而不是 `git init` 新建。
- **后果**：
  - 需要删除所有嵌套 `.git`（git 对含 `.git` 的子目录只记 gitlink，不记内容）→ 依赖变成普通文件，**不再可 `gclient sync`**；
  - 仓库体积增大（toolchain + init_tools）；
  - 旧布局 `<dir>\.git` 变成遗留物，应删除。
- **验证**：`git -C <src> log` 能看到原历史 + `offline repo: ...` 提交。

## ADR-003 `env.bat/env.ps1` 全部使用相对路径

- **状态**：accepted（2026-11-11）
- **背景**：仓库会被改名、换盘、整体拷贝；绝对路径的 env 会立刻失效（在不同盘时尤其明显）。
- **备选**：
  - A：生成时写死绝对路径（简单，但不可搬迁）
  - B：运行时按 `%~dp0` / `$PSScriptRoot` 推导（+ `%%~fI` 规范化）
- **决定**：B；同时导出 `CHROMIUM_OFFLINE_ROOT/SRC/MAJOR`。
- **后果**：
  - batch 里需要用 `for %%I in ("%VAR%") do set "VAR=%%~fI"` 规范化 `..`；
  - 想「显式指定别的盘」时，仍可通过 `--dir` 覆盖（脚本据此算绝对路径）。
- **验证**：`PIT-005` 的搬移演练。

## ADR-004 `out/` 与 `build\win_toolchain.json` 不入库

- **状态**：accepted（2026-11-11）
- **背景**：
  - `git add -f src` 会把 `src\out` 的编译产物一起加入对象库（实测单次出现 1,011,567 objects）；
  - `build\win_toolchain.json` 内容是**绝对路径**（例如 `D:\...\vs_files\<hash>`），搬移后必然失效。
- **决定**：
  - `git add -A -f -- . ":(exclude)out" ":(exclude)build/win_toolchain.json"`；
  - `.gitignore` 追加 `/out/` 与 `/build/win_toolchain.json`；
  - 构建脚本在 `gn gen` 前检查 `win_toolchain.json` 的 `path` 是否在当前源码树下，不在则删除，让 `gn` 用 `--no-download` 重建。
- **后果**：构建后 `git status` 保持干净；离线仓库不含构建产物（符合预期）。
- **验证**：`docs/VERIFY.md` 的「导出后 git status 干净」与「--check 显示 toolchain 状态」两条。

## ADR-005 sccache 通过 `cc_wrapper` 启用，而不是只放 exe

- **状态**：accepted（2026-11-11）
- **背景**：把 `sccache.exe` 放进仓库并在 PATH 里只保证「找得到」，Chromium 不会自动使用它。
- **决定**：构建脚本检测到 `init_tools\<MAJOR>\scache\sccache.exe` 时，自动追加 GN 参数 `cc_wrapper="sccache"`，并设置 `SCCACHE_DIR`（仓库内 `scache\cache`）；可用 `--no-sccache` 关闭。
- **后果**：首次构建无缓存收益；迁移后缓存按路径失效（只影响速度）。
- **验证**：`chromium_build_win.bat --check` 的 `GN args` 行包含 `cc_wrapper="sccache"`。

## ADR-006 GN 参数走 `args.gn`，命令行/文件覆盖脚本默认值

- **状态**：accepted（2026-11-11）
- **背景**：
  - 通过 `--args=...` 传 GN 参数会经历 PowerShell → cmd → `gn.bat` 的**多层引号解析**，字符串参数（如 `cc_wrapper="sccache"`）会被破坏（PIT-010）；
  - 用户又需要「命令行指定的参数覆盖脚本默认值」。
- **备选**：
  - A：继续用 `--args`，只做字符串转义（脆弱，受调用层影响）
  - B：写 `out\<build-dir>\args.gn`，并支持 `--args` / `--args-file` 合并覆盖
  - C：只支持 args 文件（最简单，但短参数也要建文件）
- **决定**：B。
  - 默认值：`is_debug`（`--release`）、`target_cpu`（`--arch`）、`chrome_pgo_phase`（`--pgo`）、`cc_wrapper`（自动 sccache）；
  - 合并顺序：默认 → `--args`/`--gn-args`/`--args-file`，**同名 key 以后者为准**；
  - GN 以 `args.gn` 为唯一输入（`gn gen out\Default` 不带 `--args`）。
- **后果**：
  - 复杂参数建议用 `--args-file`（无引号层）；
  - `--args` 可用，但转义随**入口 shell** 不同：
    - PowerShell 调 `.bat`：`--args 'target_os=\"win\"'`
    - cmd.exe 调 `.bat`：整段值必须用双引号包住，内部用 `\"`：
      `"--args=target_os=\"win\" target_cpu=\"x64\""`（cmd 不把单引号当引号）
  - 泄漏的 `key=value` 不再只是警告：构建脚本以 **exit 3** 拒绝执行，避免静默变成 debug 构建；
  - 允许 `--args` 内含引号、空格，如 `target_os=\"win\" ffmpeg_branding=\"Chrome\"`；
  - 生成后的 `args.gn` 可直接查看/复用。
- **验证**：`docs/VERIFY.md` 的「args-file 合并 + gn gen」「.bat + `\"` 转义 + gn gen」两行。

## ADR-007 `gn gen` 的 IDE/过滤开关与构建参数分开

- **状态**：accepted（2026-11-11）
- **背景**：
  - `--ide=...`、`--filters=...` 是 **`gn gen` 的命令行开关**，不是 `args.gn` 里的构建参数；混进 `--args` 会被当成 GN 变量而报错；
  - 需要为 IDE（VS2022）生成工程文件，并只包含关心的目标。
- **备选**：
  - A：让用户自己改脚本/直接调 gn
  - B：新增透传选项（`--ide` / `--filter` / `--gn-flag`）
  - C：把所有 gn 开关都塞进 `args.gn`（不可行）
- **决定**：B。
  - `--ide NAME` → `--ide=NAME`（本套 GN 支持 `vs`、`vs2013`…`vs2022`、`json`、`qtcreator`、`eclipse`、`xcode`）；
  - `--filter PATTERN`（可重复，`;`/`,` 分隔）→ **`--filters=PATTERN`**（GN 拼写是复数，分号分隔）；
  - `--gn-flag FLAG` → 原样追加（如 `--sln=my`、`--no-deps`）。
- **后果**：
  - 这些开关只影响**工程文件生成**（`all.sln`、`.vcxproj`、json），不影响 ninja 构建目标；
  - `--filter` 只缩小 IDE 工程范围，不会改变实际构建；
  - IDE 文件写在 `out\<build-dir>` 下（被 `.gitignore` 忽略）。
- **验证**：`docs/VERIFY.md` 的「`--ide=vs2022` + `--filters` + `all.sln`」一行。

## ADR-008 离线仓库的 git 分支名 = `b<BUILD>` / `main`

- **状态**：accepted（2026-11-11）
- **背景**：导出后仓库默认在 `master`，看不出对应哪个 Chromium 版本；同一台机器可能有多个版本的快照。
- **备选**：
  - A：保持 `master`
  - B：`b<版本号串>`（tag 会是长串）
  - C：`b<BUILD>`；`main` 输入则用 `main`
- **决定**：C。
  - `main` → `main`
  - 分支（如 `7871`）→ `b7871`
  - tag/ref（如 `150.0.7871.289`）→ `b<chrome/VERSION 的 BUILD>` = `b7871`
- **实现**：导出时若仓库还没有 commit，用 `git symbolic-ref HEAD refs/heads/<name>`；已有 commit 则 `git branch -M <name>`。
- **后果**：
  - `git branch -vv` 直接能看出对应版本；
  - 同一 major 的多个 tag 会落到同一个分支名（`b7871`），符合"按分支管理"的预期；
  - 旧仓库可手工改名：`git branch -M b7871`。
- **验证**：`docs/VERIFY.md` 的「分支命名（branch/tag/main）」一行（三例全过）。

## ADR-009 构建输出目录按 `<target_os><target_cpu><r|d>` 命名

- **状态**：accepted（2026-11-11）
- **背景**：`out\Default` 看不出配置，release/debug、x64/x86/arm64 并存时容易混淆。
- **决定**：
  - 默认 `out\<target_os><target_cpu><r|d>`，例如 `out\winx64r`（release）、`out\winx64d`（debug）、`out\winx86r`、`out\winarm64d`；
  - 本脚本只面向 Windows，`target_os` 固定 `win`；
  - `--build-dir` 仍可显式覆盖。
- **后果**：首次构建会新建目录（之前的 `out\Default` 不再使用）；`out/` 已被忽略，不影响仓库。
- **补充（2026-11-12）**：目录名按**合并后的实际参数**计算，而不是只看 `--release`：
  - `--args "is_debug=false"` → `r` 后缀；`is_debug=true` → `d`；
  - `--args "target_cpu=\"x86\""` → `winx86…`；
  - `--args "target_os=..."` → 对应前缀（Windows 工具链下一般仍为 `win`）；
  - 显式 `--build-dir` 永远优先。
- **验证**：`chromium_build_win.bat --check` 的 `Build dir` 行。

## ADR-010 构建工具开关透传：`-j/--jobs`、`--ninja-flag`

- **状态**：accepted（2026-11-12）
- **背景**：
  - 想限制并行度（如 `-j 16`）或给 ninja/siso 传其他开关（`-k 0`、`-v`）；
  - 这些是**构建工具**参数，不是 GN 构建参数（后者走 `--args`/`--args-file`）。
- **决定**：
  - `--jobs N` 已有；新增别名 `-j N` 与紧凑写法 `-jN`；
  - 新增 `--ninja-flag FLAG`（可重复）原样追加到 `autoninja` 命令行；
  - `--check` 打印 `Ninja flags` 便于确认。
- **后果**：
  - `autoninja` 会把 `-j` 转成 siso 的 `-local_jobs` / `-remote_jobs`（`autoninja.py:199-226`），并把 `-j` 大于 CPU 数视为误用而告警；
  - autoninja 在 Windows 上按空格重新拆分参数，所以 `-k 0` 这类「flag + 值」可用，但含真实空格的单个参数不支持（上游限制）。
- **验证**：`docs/VERIFY.md` 的「`-j 16` / `-j16` / `--ninja-flag '-k 0'`」一行。

## ADR-011 下载阶段默认开启 `checkout_pgo_profiles` / `checkout_clang_coverage_tools`，并做依赖体检

- **状态**：accepted（2026-11-12）
- **背景**：
  - 之前两次构建失败（PIT-011 空依赖、PIT-012 版本不匹配）都是"导出时依赖不完整"，而 `gclient sync` 的失败（429）被忽略后继续导出；
  - `checkout_pgo_profiles` / `checkout_clang_coverage_tools` 在 DEPS 里默认 `False`，官方/PGO 构建和覆盖率工具需要它们。
- **决定**：
  1. 下载脚本**默认**把这两个 custom_var 设为 `True`；
     - `--no-extra-deps` 关闭这两个默认；
     - `--deps key=False` 可单独覆盖（`--deps` 优先）；
     - `Set-GclientCustomVars` 改为「key+值」匹配，已存在 `False` 会被纠正。
  2. 同步之后增加 **依赖体检**：扫描 `third_party\*\src`、`third_party\*\*\src`、`third_party\dawn\third_party\*\src`，列出 0 文件的目录并提示按 PIT-011/012 重新取 pin。
- **后果**：
  - 每个离线仓库会多下载 PGO profile 与 Windows 覆盖率工具（体积增加，可接受）；
  - 依赖体检**只告警不失败**（部分目录是平台条件性为空，例如 Android/Linux 专用）；
  - 真正要保证完整，仍需"fetch 失败即视为失败"。
- **验证**：`docs/VERIFY.md` 的「custom_vars 默认值/覆盖/纠正」「依赖体检」两行。

---

## ADR-012 离线导出改为「全删 .git → 重建单一仓库 → 两次提交」

- **状态**：accepted（2026-11-17）
- **背景**：
  - 之前的导出保留 `src\.git` 并删除嵌套 `.git`，但 Chromium 索引里 `third_party/depot_tools`
    等 265 个路径是 **gitlink（`160000`）**，`git add` 不会进入它们 —— 结果工具链等
    20 GB 依赖只入库了一个 commit 指针（PIT-018）；
  - 用户要求语义更简单：**所有 `.git` 都清掉，重建一个干净的快照仓库**。
- **决定**：
  1. 导出时把**所有** `.git`（含 `src\.git`）**移动**到 `<root>\src_git_bak\`（保留相对目录结构）；
  2. 把所有 `.gitignore` **复制**到 `<root>\src_gitignore_bak\`，然后从源码树删除
     （避免任何文件被忽略；导出的仓库只保留脚本生成的根 `.gitignore`）；
  3. `git init` 一个全新仓库，分支 `b<BUILD>` / `main`；
  4. **提交 1/2**：原始源码树（排除 `out/`、`build/win_toolchain.json`、`init_tools/`）；
  4b. **`win_toolchain` 按二进制保存**：导出前从 `<hash>.zip` 重新解压到
     `third_party\depot_tools\win_toolchain\vs_files\<hash>`，刷新短哈希
     `<hash>.timestamps`，并在 `git add` 之前往 `.gitattributes` 追加
     `third_party/depot_tools/win_toolchain/** -text -diff`。
     否则 `*.h text eol=lf` 会把工具链 CRLF 改成 LF，内容哈希与目录名不符，
     `get_toolchain_if_necessary.py` 会把工具链当损坏删除（PIT-020）；
  4c. **构建脚本在 `gn gen` 前刷新短哈希 timestamps**（`Update-ToolchainTimestampCache`）：
     任何 checkout/复制都会改 mtime，不刷新时首次 gn 会把 `Calculating hash ...`
     写进 stdout 导致 `Invalid token`，并可能把工具链判为"无主"删除（PIT-020 第二层）；
  5. 组装 `init_tools/<MAJOR>` 与 `init_tools/win`（config / depot_tools / sccache / 脚本 / docs 等），
     **提交 2/2**；
  6. 完成标记 `<src>\init_tools\.offline_repo.state` **随 commit 2/2 一起提交**；
     下载现场**默认保留**，只有显式 `--cleanup` 才删除 `src_git_bak` /
     `src_gitignore_bak`、根 `.gclient*`、`.cipd`、`<root>\depot_tools` 与 sccache 缓存。
     失败则全部保留。
- **后果**：
  - 不再需要 gitlink 转换（PIT-018 的 `git rm --cached`），也不会有 submodule 残留；
  - **丢失 Chromium git 历史**（离线仓库只剩 2 个快照提交）——构建不需要历史；
  - 首次提交要写入全部内容（约 40 GB，压缩后数 GB），耗时较长；
  - 重新导出是**全量重建**（不是增量），且之后下载脚本切版本会重新 `git fetch --depth 1`；
  - 备份为**移动**（同卷瞬时、不占双份空间），`.gitignore` 为复制（很小）。
- **验证**：`docs/VERIFY.md` 的「新导出策略：备份/全删/两次提交」一行。

---

## ADR-013 导出完成标记 + 参数语义改为「默认保留、`--cleanup` 才清理」

- **状态**：accepted（2026-11-19）
- **背景**：
  - 旧参数 `--keep-original` / `--no-cleanup` 是"反向开关"：默认清理、加参数才保留，
    容易误删可复用的下载现场；
  - 一次完整导出约 1.5 小时，两个提交已经完整合入后，重复运行不应再做任何网络更新。
- **决定**：
  1. **删除** `--keep-original` / `--no-cleanup`（保留为提示性警告），新增 `--cleanup`：
     - **默认**：depot_tools 复制、`src_git_bak` / `src_gitignore_bak`、根 `.gclient*`、
       `.cipd`、sccache 缓存全部保留；
     - **`--cleanup`**：depot_tools 改为移动，成功后删除上述全部；
     - 失败时永不清理。
  2. 完成标记写到 **`<src>\init_tools\.offline_repo.state`**（Windows 隐藏属性）
     并**随 commit 2/2 提交**（ASCII/UTF-8 `key=value`）：`branch` / `kind` / `version` / `request` / `deps` /
     `ref` / `commit1` / `toolchain_url` / `toolchain_hash` / zip `size`+`mtime` /
     `canonical_hash` / `finished`。
     不记录 `commit2`（否则自我引用，且 amend commit 2 就失效）。
  3. 每次运行在 **bootstrap 之前**检测快照（标记存在，或结构上满足 2 个提交 +
     我们的提交信息）；仅当以下全部成立时直接 `exit 0`：
     - branch、ref、`chrome/VERSION` 与标记一致；
     - `.gclient` custom_vars 指纹（`--deps` / `--full-deps` / `--no-extra-deps`）一致；
     - `rev-list --count HEAD` = 2 且 `HEAD~1` 等于标记的 `commit1`
       （所以 amend/刷新 commit 2 仍然有效），`git status --porcelain` 为空，
       `init_tools/<MAJOR>/depot_tools` 与 `init_tools/win/env.bat` 存在；
     - 若给了 `--win-toolchain-url`：URL、本地 `<hash>.zip` 名称、size、mtime 与
       canonical hash 都一致（无法验证时按"不匹配"处理）。
     **该检测不依赖 `--make-offline-repo`**：不带它也会跳过同版本运行。
  4. 快照存在但请求不一致（版本/依赖/工具链变了，或标记被删）时：
     - **不带** `--make-offline-repo` 且不是 `--skip-fetch` → **拒绝执行（exit 3）**，
       打印原因和可选方案；不做任何 fetch/checkout（隐式更新会 checkout 真实分支
       并删除 `init_tools`）；
     - **带** `--make-offline-repo` → 走正常刷新/重导出流程（显式意图）。
  5. 跳过路径只打印现状（`Offline repository already complete - nothing to update`）；
     `--cleanup` 仍会执行清理，但不会更新代码/仓库。
- **后果**：
  - 重复运行从约 1.5 小时降到几秒（实测 4 秒）；
  - `stable` 仍做一次 Chromium Dash 查询（避免新 stable 被误跳过）；
    数字 / tag / branch 请求完全离线解析；
  - 标记随 commit 2 入库（Windows 隐藏属性；git 不跟踪属性）；删除它只是让
    "跳过"失效，真正重导仍需 `--make-offline-repo`；
  - 误跑下载脚本不会再破坏快照（拒绝而不是覆盖）；
  - 标记里的 branch/ref/version 与仓库实际状态双重校验，手动改过仓库不会误跳过。
- **验证**：`docs/VERIFY.md` 的「完成标记跳过重跑」「默认保留 / `--cleanup`」
  「快照拒绝隐式更新」三行。

---

## ADR-014 sccache 缓存默认放到 `out\.cache<MAJOR>`（`--sccache-dir` 可覆盖）

- **状态**：accepted（2026-11-19）
- **背景**：
  - 旧默认把构建缓存放在 `<src>\init_tools\<MAJOR>\scache\cache`，属于**已提交目录的内部**；
    构建后 `git status` 出现未跟踪目录，导致 ADR-013 的"干净工作区"判定失败，
    完成标记永远不命中；
  - 导出仓库的 `out/` 本来就忽略，是天然放构建缓存的位置。
- **决定**：
  1. 构建脚本默认 `SCCACHE_DIR=<src>\out\.cache<MAJOR>`（MAJOR 读 `chrome/VERSION`）；
  2. 新增 `--sccache-dir DIR`（别名 `--sccache-cache-dir`）覆盖；相对路径按 `<src>` 解析；
  3. 生成的 `env.bat` / `env.ps1` 也指向同一位置；
  4. 构建前读取运行中守护进程的 `Cache location`（`sccache --show-stats`）并与目标目录比较：
     **不同才** `--stop-server`；相同或没有服务则不动。无服务时 `--show-stats` 只回显
     客户端 `SCCACHE_DIR`（不会启动守护进程），因此不会误停。
  5. 旧位置的 cache 仍被 `.gitignore` 忽略，`--cleanup` 会删除新旧两处。
- **后果**：
  - 构建不再弄脏工作区，完成标记可正常跳过；
  - 缓存跨 debug/release 共享（同一 major），删除 `out/` 会同时清掉；
  - 自定义目录若在仓库内但不在 `out/`，脚本会警告。
- **验证**：`docs/VERIFY.md` 的「sccache 缓存目录」一行。

---

## ADR-015 导出受阻时只按「允许名单 + 仓库归属」停用只读 git 进程

- **状态**：accepted（2026-11-20）
- **背景**：
  - 导出阶段移动 `.git` 时，IDE / Git Bash / 残留终端的长驻只读 git 进程
    （`git status`、`fsmonitor--daemon`）会锁住文件，`Move-PathWithRetry` 反复
    `Access is denied`，需要自动停掉这些进程才能重试成功；
  - 旧实现 `Stop-BlockingGitReaders` 对**整台机器**的所有 `git.exe` 用整条命令行
    正则 `\b(status|diff|log|...)\b` 匹配后 `Stop-Process -Force`，第 8 次重试无
    年龄限制；
  - 代码审查（2026-11-20）发现两个风险：① 关键词可来自 `-C <路径>` 参数而非
    子命令本身（如 `git -C D:\repos\log push ...`），**写操作可能被误杀**；
    ② 无仓库归属过滤，无关仓库的只读进程也会被强杀。
- **备选**：
  - A：维持原实现——最简单，但会误杀无关仓库进程，且写操作路径含关键词时被中断；
  - B：不停任何进程、只提示用户手工关闭——最安全，但导出遇锁必然失败，需要人工介入；
  - C：只读允许名单 + 按位置解析子命令 + 按 `-C`/`--git-dir` 路径归属过滤（本次决定）。
- **决定**：C。
  1. 新增 `Get-GitSubcommand`：把命令行按 token 拆分，跳过 `-C <dir>` /
     `-c <k=v>` / `--git-dir[=]<dir>` 等前导选项，取第一个位置参数作为子命令；
  2. 只停**只读允许名单**内的子命令（status/diff/log/show/ls-files/rev-parse/
     cat-file/grep/blame/describe/name-rev/fsmonitor--daemon/for-each-ref/show-ref/
     symbolic-ref/fsck/count-objects）；fetch/clone/pull/push/commit/checkout/reset/
     gc/repack/index-pack/maintenance 等写类命令**绝不停止**；
  3. 新增 `-Path`（移动源路径）：进程若通过 `-C`/`--git-dir` 显式指定仓库，
     只有与被移动路径**重叠**（互为前后缀、大小写不敏感、按 `\` 边界比较，
     防止 `src` 误配 `src2`）才停止；显式指向无关仓库则跳过；
  4. 命令行无仓库路径信息（以 cwd 运行，WMI 拿不到工作目录）的进程维持原行为
     （按年龄停止）——无法定位，但已保证只可能是只读命令；
  5. 年龄策略不变：第 2/5 次重试停 ≥60 秒的进程，第 8 次无年龄限制。
- **后果**：
  - 写操作不再被误杀；显式指向其他仓库的只读进程不再被波及；
  - `git -c status.showUntrackedFiles=false diff` 这类「关键词出现在配置值里」的
    场景现在按真实子命令 `diff` 正确分类（旧实现会误杀）；
  - 子命令解析只识别标准前导选项，其他全局选项（如 `--no-optional-locks`）
    开头的进程会被跳过——宁可漏停、不可误停；
  - 残余限制：cwd 方式运行在**其他仓库**里的 `git status`/`fsmonitor--daemon`
    仍可能被停（WMI 无法获取进程工作目录）；fsmonitor 守护进程被停后会随
    下一次 git 命令自动重启，影响可控。
- **验证**：`docs/VERIFY.md` 2026-11-20「停进程机制收紧：允许名单 + 位置解析 +
  仓库归属（ADR-015）」行——9 组子命令解析（引号路径、`-c` 值内嵌关键词、
  `--git-dir` 两种写法、写操作反例）+ 6 组仓库归属（含 `src`/`src2` 前缀边界）+
  两个脚本在 ConstrainedLanguage 下 `--help` 退出码 0。修复不改变正常导出路径的
  行为（无锁可杀时原样通过）。

---

## ADR-016 下载目录名改为 `--dest-name`，未指定时按“配置/标记/唯一 checkout”发现

- **状态**：accepted（2026-11-20）
- **背景**：
  - 原参数 `--src-dir` 容易被理解为“源码目录必须叫 src”，而仓库完全可以改名
    （`chromium` / `webview` / `chromium150`）；
  - `--cleanup` 会删根 `.gclient`，此时没有现成的 solution name 可读；
  - 若未指定名字时静默回退 `src`，会新建第二份仓库或误用旧残留。
- **决定**：
  1. 下载脚本参数改为 `--dest-name NAME`（默认 `src`），**不保留 `--src-dir` 别名**；
     旧参数直接 `exit 3` 并提示改名；未知参数也 `exit 3`，不再 warning 后继续。
  2. 未指定 `--dest-name` 时的发现顺序：
     1) 根 `.gclient` 的 solution name（且 `<root>\<name>\chrome\VERSION` 存在）；
     2) `<root>\*\init_tools\.offline_repo.state`（含旧 `offline_repo.state`）恰好一个；
     3) `<root>\*\chrome\VERSION` 恰好一个；
     4) 默认 `<root>\src`（全新下载）。
     多候选 → `exit 3` 并列出候选，要求 `--dest-name`；绝不静默新建 `src`。
  3. 显式 `--dest-name` 时不做任何发现/猜测。
     它只表示**新目标目录名**，**绝不自动重命名已有 `<root>\src`**：
     若 `<root>\NAME` 不存在而 `src` 是有效 checkout，打印手动
     `Move-Item` 命令并 `exit 3`；改名由用户自己完成（关闭 Explorer/IDE/AV
     等占用后）。`src` 只是无 `chrome\VERSION` 的残留时只警告、不动它。
  4. 导出仓库保持名字无关：`init_tools\<MAJOR>\config\.gclient` 的 solution 名
     继续是 `../../..`。
  5. 启动时从 `$env:PATH` 里剔除 `<root>\*\init_tools*` 与 `<root>\*\scache*`
     的条目：`env.bat` 激活后 bootstrap 会误用旧快照的 `git.bat`。
- **后果**：
  - 改名后（包括 `--cleanup` 删掉根 `.gclient` 后）下次不指定 `--dest-name`
    也能通过完成标记找到唯一仓库；
  - 多仓库必须显式选择，避免新建第二份 checkout；
  - 旧 `--src-dir` 用户会得到明确错误，而不是静默落回 `src`；
  - `--dest-name` 不会在 bootstrap 之后隐式移动被占用的 `src`（旧行为会
    重试 48s 后失败）；改名冲突在前置检查阶段就退出。
- **验证**：`docs/VERIFY.md` 2026-11-20「`--dest-name` + 发现顺序 A（ADR-016）」
  与「`--dest-name` 不自动重命名 src」两行。
