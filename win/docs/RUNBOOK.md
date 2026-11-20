# 最小路径 RUNBOOK

> 目标：从零到「可构建的离线仓库」，以及「搬移后仍能构建」。
> 每条命令都可直接复制；失败分支引用 `PITFALLS.md` 的编号。
> 状态：**未验证**（首次完整跑通后改为 `verified @ <版本> / <日期>`）

---

## 0. 前置检查（1 分钟）

```powershell
cd D:\git\x2
git --version
opencode --version
```

- 期望：两条都返回版本号。
- 失败：`git` 不在 PATH → 用仓库脚本自动下载 PortableGit（`--no-bootstrap-git` 可关闭）。

---

## 1. 下载（联网）

```powershell
.\chromium_download_win.bat --dir D:\offline --version 7871
```

- 期望最后一行：`Download complete (nothing built)`，并打印下一步命令。
- 头部有 `Started : <时间>`，结束摘要有 `Started / Finished / Elapsed`；
  失败时会打印 `FAILED at <时间> (elapsed ...)` + `Error: ...`（PIT-021 补充）。
- 产物：`D:\offline\{depot_tools,.gclient,src}`。
- 默认会给 `.gclient` 设置 `checkout_pgo_profiles=True` + `checkout_clang_coverage_tools=True`
  （`--no-extra-deps` 可关；`--deps key=False` 可单独覆盖），所以 **PGO profile 默认就会下载**。
- 结束摘要里的 `PGO` 行会说明结果，例如
  `PGO : chrome-win64-150.0.7871.290-<hash>.profdata present (xxx MB) - build with --args "chrome_pgo_phase=2"`；
  若显示 `none found`，见 PIT-013（`--skip-hooks` 或 runhooks 失败）。
- 同步后会打印**依赖体检**：以 `<root>\.gclient_entries`（gclient 本次实际管理的依赖清单）为准，
  正常应显示
  `Dependency check: all 150 managed dependencies are present.`；
  只有清单里的依赖为空/缺失时才告警并列出（`EMPTY` / `MISSING`），按 PIT-011/012 处理。
  平台条件性目录（Linux/Android/Java 等）和子模块占位目录不再误报。
- 切换到其它版本（如 main → 7871）时，脚本会自动给 `gclient sync` 加 **`-D`**
  （`--delete_unversioned_trees`），把新 `DEPS` 里已不存在的依赖目录删掉，
  不会再出现 `'...' is no longer part of this client` 需要手工清理；
  有本地修改的目录会被跳过并打印警告（不会误删）。它**不会**动
  仍然在 `DEPS` 里的依赖中的未跟踪文件（如 `third_party/depot_tools/win_toolchain/vs_files`）。
- 失败分支：
  - `429` / `RESOURCE_EXHAUSTED` → **PIT-002**（等 10–30 分钟重跑；脚本默认重试 10 次、累计约 27 分钟；
    仍失败就用 `gclient sync ... -j 1` 降并发）
  - `CIPD`/`vpython` 报 `Access ... policy rule` → **PIT-001**
  - `fatal: bad object <sha>`（`gclient sync -D` 清理过期依赖时）→ **PIT-021**；
    脚本会自动把不可用依赖移到 `<root>\_bad_deps`，重跑即可
  - `对路径 "...\src\.git" 的访问被拒绝` → **PIT-024**；脚本会重试并自动停止
    运行超过 60 秒的只读 git 进程（`status`/`log`/`diff`/...）；
    若是 IDE/资源管理器/杀毒占用，仍需关闭对应窗口
  - `--gclientfile target must be a filename` → **PIT-003**（用脚本就自动规避）
  - 目录里已有 `.gclient`/`src` → 会自动续跑，不用删目录

> 只想准备工具链/依赖、不编译，这条就结束了（下载脚本本来不编译）。

---

## 2. 导出离线仓库（联网，一次性）

```powershell
.\chromium_download_win.bat --dir D:\offline --version 7871 --make-offline-repo
```

- 期望：`Offline Chromium repository ready: D:\offline\src`、
  `Commit 1/2: <hash>`、`Commit 2/2: <hash>`、`Commits: <h1> (source) -> <h2> (init_tools)`
- 产物：`D:\offline\src\init_tools\{150\{config,depot_tools,scache},win}`
  - **导出策略（ADR-012 / PIT-019）**：先把所有 `.git`（含 `src\.git`）移动到
    `D:\offline\src_git_bak\`，把所有 `.gitignore` 复制到 `D:\offline\src_gitignore_bak\`
    后删除；再新建仓库，**提交 1/2 = 原始源码**，**提交 2/2 = init_tools**。
    完成标记 `<dir>\src\init_tools\.offline_repo.state`（Windows 隐藏属性）随 commit 2/2 一起提交；
    再运行时若分支/版本/依赖变量一致（且给了 `--win-toolchain-url` 时归档未变），会打印
    `Offline repository already complete - nothing to update` 并**直接退出**。
    （标记不记录 commit 2 自身，因此 amend commit 2 不会让它失效。）
    恢复残留 `_bad_deps` / `_bad_scm` / `_failed_export_git_*` 每次成功都会清理（PIT-025）。
  - `.gclient*` / `.gcs_entries` 在导出时只**复制**到 `init_tools\<MAJOR>\config`；根目录原件
    **默认保留**，只有显式 `--cleanup` 才在两次提交成功后删除。
  - **`win_toolchain` 字节保护（PIT-020）**：导出前从 `<hash>.zip` 重新解压，
    刷新短哈希缓存 `<hash>.timestamps`，并在 `git add` 前追加
    `third_party/depot_tools/win_toolchain/** -text -diff`；
    否则 `.gitattributes` 的 `*.h text eol=lf` 会改掉工具链字节，构建时哈希不符被删除。
    日志：`Re-extracting pristine win_toolchain ...` /
    `Refreshed toolchain timestamps: ...` / `Added "-text -diff" rule ...`。
  - **默认（不加 `--cleanup`）保留下载现场**：`depot_tools` **复制**（原目录与 `.git` 保留）、
    两个备份目录、根目录 `.gclient*` / `.gcs_entries`、`.cipd`、sccache 构建缓存都保留。
  - **`--cleanup`（可选）**：两次提交成功后删除上述现场（`depot_tools` 改为移动，
    并删除备份、`.gclient*`、`.cipd`、`init_tools\<MAJOR>\scache\cache`）。
  - `init_tools\win\` 除脚本/README/env 外，还带 `.opencode\`、`docs\`、`AGENTS.md`、`win*.md`
  - 导出前会删除所有 `__pycache__\` 与 `*.pyc`（日志 `Removed N __pycache__ dir(s) ...`）
- 分支名规则：`main` → `main`；分支 `7871` → `b7871`；tag `150.0.7871.289` → `b<BUILD>` = `b7871`（见 ADR-008）
- 关键校验（应全部为 True / 计数符合预期）：
  ```powershell
  Test-Path D:\offline\src\.git
  Test-Path D:\offline\src\init_tools\150\depot_tools\gclient.py
  Test-Path D:\offline\src\init_tools\win\env.bat
  Test-Path D:\offline\src\init_tools\win\docs
  Test-Path D:\offline\src\init_tools\win\AGENTS.md
  git -C D:\offline\src status --porcelain   # 期望：输出为空
  git -C D:\offline\src log --oneline         # 期望：恰好 2 条
  Test-Path D:\offline\src_git_bak            # 默认 True；--cleanup 成功后 False
  Test-Path D:\offline\src_gitignore_bak      # 同上
  Test-Path D:\offline\depot_tools\.git       # 默认 True（原始检出保留）；--cleanup 后 False
  Test-Path D:\offline\.gclient               # 默认 True；--cleanup 后 False
  Test-Path D:\offline\.cipd                  # 同上
  Test-Path D:\offline\src\init_tools\.offline_repo.state   # 成功导出后 True（已被 git 跟踪）
  Test-Path D:\offline\.offline_repo.state                 # 旧位置：迁移后应为 False
  git -C D:\offline\src ls-files | Select-String '__pycache__|\.pyc$'   # 期望：无输出

  # 依赖内容确实入库（PIT-018/019）
  (git -C D:\offline\src ls-files third_party/depot_tools | Measure-Object -Line).Lines        # 期望 2 万+
  (git -C D:\offline\src ls-files third_party/depot_tools/win_toolchain | Measure-Object -Line).Lines  # 期望 1 万+

  # 工具链按二进制入库（PIT-020），text 属性应为 unset
  git -C D:\offline\src check-attr text -- 'third_party/depot_tools/win_toolchain/vs_files/<hash>/DIA SDK/include/cvconst.h'
  ```
- **重复运行**：成功后 `<dir>\src\init_tools\.offline_repo.state` 存在（已提交）；
  同分支/版本/依赖变量（且工具链归档未变）再跑会打印
  `Offline repository already complete - nothing to update` 并直接退出。
  强制重导：
  ```powershell
  Remove-Item D:\offline\src\init_tools\.offline_repo.state
  ```
- 再加 `--cleanup` 会在这条"已完整"路径上只做清理（不更新代码/仓库）。
- 失败分支：
  - `No .gclient found ... config directory will be incomplete` → 见「场景 B」
  - 体积过大 / gc 很慢 → **PIT-009**

---

## 3. 构建（不联网）

```powershell
# 可选：激活仓库自带环境（不激活也能按脚本相对位置找到源码）
call D:\offline\src\init_tools\win\env.bat

# 先只检查解析结果
D:\offline\src\init_tools\win\chromium_build_win.bat --check

# 真正构建
D:\offline\src\init_tools\win\chromium_build_win.bat --release --targets content_shell

# 用仓库自带的默认 GN 参数（sccache/official/symbol_level 等，PowerShell 下无引号问题）
D:\offline\src\init_tools\win\chromium_build_win.bat --dir D:\offline\src --ide vs2022 -j16 --targets chrome --args-file D:\offline\src\init_tools\win\args_default.gn
```

- `--check` 期望包含：
  - `Source : D:\offline\src`
  - `Mode : offline repo (no gclient/network)`
  - `Toolchain : absent (gn will create it)` 或 `ok (...)`  → 见 **PIT-007**
  - `GN args : is_debug=false cc_wrapper="sccache"`（仓库内有 sccache 时）
- 构建期望：`Toolchain cache: refreshed fab72fa52c`（构建脚本在 gn 之前刷新
  短哈希 timestamps，见 **PIT-020**；`--check` 不做这一步），然后
  `content_shell  OK  (0h 12m 3s)` + `Build summary`，摘要末尾含
  `Started` / `Finished` / `Elapsed : gn gen …, build …, total …`（总耗时 ≈ 两段之和）
- 失败分支：
  - `Could not locate a Chromium source tree` → 用 `--dir` 指向**仓库根**（含 `chrome\VERSION`，目录名任意）；给父目录时，若只有一个含 `chrome\VERSION` 的子目录会自动识别，多个则直接 `--dir <repo-root>`（父目录兼容形式才用构建脚本的 `--src-dir`）
  - `Could not locate depot_tools` → 先 `call ...\env.bat`
  - `Missing build\config\gclient_args.gni` → 下载阶段没跑 hooks，回到步骤 1/2
  - `Toolchain : stale -> will regenerate` → 正常（脚本会删掉旧 json）
  - `Invalid token` + `Calculating hash ...` → **PIT-020 第二层**（短 timestamps 缺失）；
    构建脚本已自动刷新，若仍出现请删除 `win_toolchain\*.timestamps` 后重跑

---

## 4. 搬移 / 改名（验证相对路径）

```powershell
# 新位置（可换盘、可改名）：robocopy 能处理 git 的只读对象
robocopy D:\offline\src D:\new\chromium2 /E /COPY:DAT /DCOPY:T /R:1 /W:1

# 只用脚本自身相对位置定位（不激活 env）
D:\new\chromium2\init_tools\win\chromium_build_win.bat --check
```

- 期望：`Source : D:\new\chromium2`、`Toolchain : stale -> will regenerate`（或 absent）
- 失败分支：
  - `Move-Item` 跨盘报 `insufficient privileges`（只读对象）→ 用 `robocopy`
  - 路径过长报错 → 目标路径尽量短（`D:\cr2`）

---

## 5. 进度与产物

```powershell
# 构建产物（默认输出目录 out\<os><cpu><r|d>，见 ADR-009）
Get-ChildItem D:\offline\src\out\winx64r\content_shell.exe

# 仓库状态（构建后应仍然干净：out/ 与 win_toolchain.json 已忽略）
git -C D:\offline\src status --porcelain
```

---

## 场景 B：已有源码但缺 `.gclient` / `src\.git`（存量目录再导出）

适用：`D:\chromium` 当前的形态（`src` 在、`.gclient` 不在、`src\.git` 已丢）。

```powershell
# 1) 删掉旧布局遗留的根仓库（新流程不使用）
Remove-Item D:\chromium\.git -Recurse -Force

# 2)（建议）重建 .gclient，让导出的 config 目录有版本记录
Push-Location D:\chromium
D:\chromium\depot_tools\gclient.bat config --name src https://chromium.googlesource.com/chromium/src.git
Pop-Location

# 3) 重新导出（跳过网络步骤）
.\chromium_download_win.bat --dir D:\chromium --version 7871 `
    --skip-fetch --skip-hooks --make-offline-repo

# 4) 构建
D:\chromium\src\init_tools\win\chromium_build_win.bat --release --targets content_shell
```

- 预期：`Source present but no .gclient ... continuing without one.`（若跳过第 2 步）
- 注意：`src\.git` 已不存在时会新建 root commit（无 Chromium 历史），不影响构建。
- sccache 默认从 GitHub 下载；完全离线可加 `--sccache-url <本地归档>`，或预先放好
  `src\init_tools\<MAJOR>\scache\sccache.exe`。

---

## 维护约定

- 本文件由 `/distill` 生成/更新；手工只做小修。
- 每次完整验证后，把状态行改为 `verified @ <Chromium 版本> / <日期>`，并在 `docs/VERIFY.md` 追加一行。
