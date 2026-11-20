# 验证记录（VERIFY）

> 目的：证明 `RUNBOOK.md` 不是「看起来对」，而是**能跑通**。
> 只记录结论与可复现命令，不记录密钥。

## 验收标准

| # | 标准 | 判定方式 |
| --- | --- | --- |
| A1 | 干净目录可按 RUNBOOK 从零跑通 | 每步退出码 0，关键产物存在 |
| A2 | RUNBOOK 每条命令可直接执行 | 无未定义变量、无占位符残留 |
| A3 | 每条坑可溯源且可验证 | PIT 条目含「验证」命令，执行通过 |
| A4 | 搬移后仍可构建 | 改名/换盘后 `--check` 的 Source 指向新位置 |
| A5 | 构建后仓库干净 | `git status --porcelain` 为空 |

## 验证矩阵（最后一次完整执行结果）

| 日期 | 版本 | 场景 | 结果 | 证据/备注 |
| --- | --- | --- | --- | --- |
| 2026-11-11 | 150.0.7871.290 | 导出（临时假树，真实 `Invoke-MakeOfflineRepo`） | 通过 | `init_tools` 在 src 内、`.git` 在 src、`.gitignore` 追加、commit 生成 |
| 2026-11-11 | 150.0.7871.290 | 改名 `src`→`chromium2` + 跨盘（robocopy） | 通过 | `--check` Source 指向新位置 |
| 2026-11-11 | 150.0.7871.290 | 构建参数（假 gn/autoninja 记录参数） | 通过 | `gen out\Default --args=is_debug=false cc_wrapper="sccache"`；`-C out\Default content_shell` |
| 2026-11-11 | 150.0.7871.290 | 陈旧 `win_toolchain.json` | 通过 | 自动删除；`git status` 干净 |
| 2026-11-11 | 150.0.7871.290 | 无 `.gclient` + `--skip-fetch` | 通过 | 不再误报「Source directory not found」 |
| 2026-11-11 | 150.0.7871.290 | 物化 depot_tools（无 `.git`） | 通过 | 跳过 pin 解析与 fetch/checkout 校验 |
| 2026-11-11 | 150.0.7871.290 | 真实 `gn gen`（args.gn，D:\chromium\src） | 通过 | `Done. Made 30752 targets from 4771 files in 21399ms`；args.gn = `is_debug=false` + `cc_wrapper="sccache"`（PIT-010） |
| 2026-11-11 | 150.0.7871.290 | 修复空依赖 DXC（pin `35c1b99e…`，PIT-011） | 通过 | 18275 files；`AsmParsers.def.in` 存在 |
| 2026-11-11 | 150.0.7871.290 | `--args-file` 合并 + `gn gen`（`out\ArgTest`） | 通过 | args.gn 含 17 项（`is_debug=true` 覆盖 `--release`、`cc_wrapper="sccache"`、`target_os="win"`）；`Done. Made 30566 targets` |
| 2026-11-11 | 150.0.7871.290 | `.bat` + `--args 'target_os=\"win\"'` + `gn gen` | 通过 | args.gn 保留引号（`target_os="win"`、`ffmpeg_branding="Chrome"`）；`Done. Made 30535 targets` |
| 2026-11-11 | 150.0.7871.290 | `--ide vs2022 --filter //content/shell/*` + `gn gen` | 通过 | 生成 `out\IdeTest\all.sln`；`Generating Visual Studio projects took 9544ms`；`Done. Made 30535 targets` |
| 2026-11-11 | 150.0.7871.290 | 离线仓库分支命名（branch/tag/main） | 通过 | `7871→b7871`、`150.0.7871.289→b7871`、`main→main`；`git branch -vv` 正确 |
| 2026-11-11 | 150.0.7871.290 | 构建目录命名 | 通过 | `--release→out\winx64r`、debug→`out\winx64d`、`--arch x86 --release→out\winx86r`、`--arch arm64→out\winarm64d` |
| 2026-11-12 | 150.0.7871.290 | 重新按 pin 取 `third_party/litert/src`（PIT-012） | 通过 | 8034→7987 文件；`litert_runtime_proxy.h` 不再引用 `GetLiteRtRuntimeBuiltin`；`gn gen` 30566 targets |
| 2026-11-12 | 150.0.7871.290 | `services_webnn_webnn_service.dll` 单独链接 | 通过 | exit 0；产物 42.8 MB（09:00）；日志 `The build has finished successfully.` |
| 2026-11-12 | 150.0.7871.290 | `-j 16` / `-j16` / `--ninja-flag "-k 0"` | 通过 | `--check` 显示 `Ninja flags : -j 16 -k 0`；实际调用 `autoninja.bat -C out\JTest -j 16 __nope__` |
| 2026-11-12 | 150.0.7871.290 | `is_official_build=true` 缺 PGO（PIT-013） | 通过 | 自动加 `chrome_pgo_phase=0` 并告警；`gn gen` `Done. Made 31060 targets`；args.gn 含 `chrome_pgo_phase=0` |
| 2026-11-12 | 150.0.7871.290 | 输出目录按“合并后参数”命名 | 通过 | `is_debug=false`→`out\winx64r`、`is_debug=true`→`out\winx64d`、`target_cpu="x86"+is_debug=false`→`out\winx86r`；`--build-dir` 优先 |
| 2026-11-12 | 150.0.7871.290 | custom_vars 默认/覆盖/纠正 | 通过 | 默认两项 True；`--no-extra-deps` 为空；`--deps checkout_pgo_profiles=False` 覆盖；已有 `False` 会被改回 True |
| 2026-11-12 | 150.0.7871.290 | 依赖体检（`Test-DependencyIntegrity`） | 通过（告警可用） | 真实树报告 55 个空 `*/src`（多数为平台条件性），输出前 8 个 + 提示 PIT-011/012 |
| 2026-11-12 | 150.0.7871.290 | `prepare_win_toolchain` 提示改为两步 | 通过 | 打印 `1) Download …` / `2) Build …`；`TOOLCHAIN_INFO.txt` 含 `download_command=` 与 `build_command=` |
| 2026-11-12 | 150.0.7871.290 | 构建期自动 `GYP_MSVS_HASH_*` 映射 | 通过 | `--check` 显示 `Toolchain map: GYP_MSVS_HASH_e66617bc68=fab72fa52c` |
| 2026-11-13 | 150.0.7871.290 | 磁盘预检（PIT-014） | 通过（告警可用） | `--check` 显示 `Low disk space on D: - only 18 GB free` 与 `Disk free : 18 GB on D:` |
| 2026-11-13 | 150.0.7871.290 | 打印完整 `gn gen` 命令并可原样执行 | 通过 | `--check` 输出 `Full gn gen : ... --args="target_cpu=\"x64\" cc_wrapper=\"sccache\" ..."`；原样执行得到 `Done. Made 31029 targets`，args.gn 引号正确 |
| 2026-11-13 | 150.0.7871.290 | 构建耗时日志（开始/结束/分段耗时） | 通过 | `Started : 17:58:49` → `gn gen finished at ... (0h 0m 26s)` → `Building targets (started ...)` → `Finished : 18:00:02`，`Elapsed : gn gen 0h 0m 26s, build 0h 0m 45s, total 0h 1m 13s`；与墙钟 73s 一致（`[int]` 舍入 bug 见 PIT-015） |
| 2026-11-16 | 150.0.7871.290 | 下载头部 PGO 两行（默认/`--pgo`/`--no-extra-deps`/`--deps False`） | 通过 | 默认：`PGO profiles: yes (...)` + `PGO build : not forced (...)`；`--pgo`：第二行变 `chrome_pgo_phase=2 (...)`；后两种显示 `PGO profiles: no (...)` |
| 2026-11-16 | 150.0.7871.290 | 下载完成摘要按 `*.pgo.txt` 校验 profile | 通过（模拟树） | 有匹配文件 → `...profdata present (1 MB) - build with --args "chrome_pgo_phase=2"`；仅旧 profile → `expected ... is MISSING (1 stale profile(s))`；空且未请求 → `profiles not downloaded (... chrome_pgo_phase=0)` |
| 2026-11-16 | 150.0.7871.290 | 构建侧按版本校验 PGO（PIT-013 补充） | 通过（模拟树） | 只有旧里程碑 profile 时输出 `Found 1 profile(s), but not the one this revision needs.` + `Expected profile: ...`，`chrome_pgo_phase` 落为 `0`；放入匹配文件后保持默认（不写 `chrome_pgo_phase`） |
| 2026-11-16 | 150.0.7871.290 | 浅仓库切分支后 `gclient sync` 不再全量 fetch（PIT-016） | **待实跑**（depot_tools 代码路径已核实） | 脚本已在分支/main 的 sync 加 `--revision <src名>@<40位sha>`；预期出现 `Up-to-date; skipping checkout.`、不再有 src 的 `fetch origin --no-tags`、`git -C src rev-parse --is-shallow-repository` 仍为 `true` |
| 2026-11-16 | 150.0.7871.290 | 切版本自动清理过期依赖（`gclient sync -D`） | **待实跑** | 分支与 main 的 sync 均带 `-D`；预期日志出现 `________ deleting 'third_party/safeint/src' in ...`，下次运行不再有 `'...' is no longer part of this client` 警告；有本地修改的依赖会保留并告警 |
| 2026-11-16 | 150.0.7871.290 | 依赖体检改为基于 `.gclient_entries` | 通过 | 真实树：`Dependency check: all 150 managed dependencies are present.`（原来的 55 条误报消失）；模拟树：`2 of 3 managed dependencies are empty/missing` + `EMPTY third_party\empty` / `MISSING third_party\gone`；无 `.gclient_entries` 时回退旧扫描 |
| 2026-11-17 | 150.0.7871.290 | 导出时 detached HEAD 的分支处理（PIT-017） | 通过（临时仓库） | detached → `checkout -B` 附着到 `b7871`；已在 `b7871` → `already checked out` 跳过；在其它分支 → `branch -M` 改名 |
| 2026-11-17 | 150.0.7871.290 | 导出前删除 `__pycache__` / `*.pyc` | 通过（模拟树） | 2 个 `__pycache__` 目录 + 3 个 `.pyc` 全部删除，剩余 0 |
| 2026-11-17 | 150.0.7871.290 | `init_tools\win` 附带 `.opencode`/`docs`/`AGENTS.md`/`win*.md` | 通过（复制测试） | 目标目录出现 `.opencode\`（6 文件）、`docs\`（6 文件）、`AGENTS.md`、`win*.md` |
| 2026-11-17 | 150.0.7871.290 | 导出中断后重跑复用已移动的 depot_tools | 通过（路径探测） | `<root>\depot_tools` 不存在时选中 `src\init_tools\150\depot_tools`（`gclient.bat` 存在），不会再 clone |
| 2026-11-17 | 150.0.7871.290 | 导出时把有内容的 submodule（gitlink）转成普通文件（PIT-018） | 通过（临时仓库） | 160000 gitlink → `100644 sub/a.txt`；提交树含文件；fresh clone 能拿到文件；**空** gitlink 保持 160000 不变 |
| 2026-11-17 | 150.0.7871.290 | 新导出策略 Phase 1：备份/全删/新建/提交 1（PIT-019） | 通过（临时树，含 8.3 短路径） | `src_git_bak\.git`、`src_git_bak\third_party\dep\.git` 按相对结构移动；`src_gitignore_bak\.gitignore` 等复制后源文件删除；pycache 清零；新分支 `b7871`；commit 1 只含源码 + 我们的根 `.gitignore` |
| 2026-11-17 | 150.0.7871.290 | 新导出策略 Phase 2：提交 init_tools + 清理备份（PIT-019） | 通过（临时树） | 生成第 2 个提交；`src_git_bak` / `src_gitignore_bak` 被删除；`git status` 为空；`init_tools` 已跟踪（当时清理是默认；现改为显式 `--cleanup`） |
| 2026-11-18 | 150.0.7871.290 | 保留模式（旧 `--keep-original`，现为默认） | 通过（复制语义测试；完整导出待实跑） | 源 `depot_tools\.git` 保留、复制到 `init_tools` 的树**不含** `.git`；根目录 `.gclient*`/`.gcs_entries` 与 `.cipd` 保留 |
| 2026-11-18 | 150.0.7871.290 | 导出保护 `win_toolchain` 原始字节（PIT-020） | 通过（属性/解压机制测试；完整导出待实跑） | 追加 `-text -diff` 后 `git check-attr text` 为 `unset`，`git add` 的 blob 大小 = 工作区字节（CRLF 保留）；从 zip 重解压幂等（marker 只加一次） |
| 2026-11-18 | 150.0.7871.290 | 构建前自动刷新工具链 timestamps（PIT-020 第二层） | 通过（chromium150 实测） | 日志 `Toolchain cache: refreshed fab72fa52c`；`gn gen finished ... (0h 0m 13s)`，无 `Calculating hash` / `Invalid token`；工具链保持 12,654 文件（`__nope__` 目标按预期失败） |
| 2026-11-18 | 150.0.7871.290 | 自动清理不可用的依赖仓库（PIT-021） | 通过（合成树） | 空 `.git` 与"记录 sha 缺失"的依赖被移到 `<root>\_bad_deps`；正常依赖保留；CIPD 条目跳过；`--help` 解析通过 |
| 2026-11-19 | 150.0.7871.290 | 下载脚本计时日志（开始/结束/失败） | 通过 | `Started : 09:01:54` → `Finished : 09:03:37` / `Elapsed : 0h 1m 44s`；失败时 `FAILED at ... (elapsed ...)` + `Error: ...` |
| 2026-11-19 | 150.0.7871.290 | 清理函数不再被 native stderr 中断（PIT-021 补充） | 通过 | `--retries 0 --skip-hooks` 单次运行：`Now at revision: refs/branch-heads/7871` + `Download complete`，无重试；`sync attempt ... error:` 行可显示真实异常 |
| 2026-11-19 | 150.0.7871.290 | 导出失败后自动恢复（PIT-022） | 通过（真实失败现场） | 恢复 151 个 `.git` 后 `origin` 正确、`git status`（忽略子模块）为 0；`--retries 0 --skip-hooks` 重跑成功；完成态（2 提交）不会被误恢复（合成测试） |
| 2026-11-19 | 150.0.7871.290 | 预置 sccache 跳过 GitHub 解析 | 通过 | `sccache v0.19.0` SHA-256 校验一致（`28be8c61…`），放置到 `init_tools\150\scache\sccache.exe`；`Get-SccacheExe` 检测到合法 PE 后不再联网 |
| 2026-11-19 | 150.0.7871.290 | sccache 提前下载 + 重试 + 缓存排除（PIT-023） | 通过（pathspec/代码路径） | sccache 在 phase 1 之前获取（失败不产生 commit 1）；`:(exclude)init_tools/150/scache/cache` 使 cache 不入库、仅 `sccache.exe` 入库；cache 默认保留，`--cleanup` 删除（旧语义相反，已改） |
| 2026-11-19 | 150.0.7871.290 | 自动停止阻塞的只读 git 进程（PIT-024） | 通过（代码路径/移动测试） | 移动 `.git` 失败后按 10 次重试；第 2/5 次停止运行 >60s 的只读 git（status/log/diff/.../fsmonitor），第 8 次不限时长；写操作（fetch/commit/gc/...）不杀；日志 `Stopped long-running read-only git process: pid ...`。**2026-11-20 按 ADR-015 收紧**：子命令按位置解析（路径/`-c` 值里的关键词不再误判）、只读允许名单、`-C`/`--git-dir` 指向无关仓库时跳过（见下两行） |
| 2026-11-19 | 150.0.7871.290 | 成功后清理恢复残留（PIT-025） | 通过（模拟目录） | `_bad_deps` 与 `_failed_export_git_*` 被删除，无关目录保留；导出成功与仅下载成功都会调用；不加 `--cleanup` 也会删除这两类残留 |
| 2026-11-19 | 150.0.7871.290 | 提交前清理 Python 缓存（PIT-009 补充） | 通过（临时仓库 + 存量仓库修复） | `Remove-PythonCaches` 在 toolchain 刷新后、commit 1 前与 commit 2 前各执行一次；`git add` 带 `:(exclude,glob)**/__pycache__/**`、`:(exclude,glob)**/*.pyc`，add 后 `git rm --cached` 兜底。存量仓库 `D:\chromium\src` 用 `filter-branch`（无 `--prune-empty`）重写后：`HEAD`/`HEAD~1` pycache 路径均为 0，`rev-list --count HEAD` 仍为 2，`git status --porcelain` 为空，`.gitignore` 含 `**/__pycache__/` 与 `**/*.pyc` |
| 2026-11-19 | 150.0.7871.290 | 完成标记跳过重跑（ADR-013） | 通过（真实仓库 + 合成仓库） | 标记 `<src>\init_tools\.offline_repo.state`（隐藏属性）随 commit 2/2 提交；重跑 `--version 7871 --win-toolchain-url file:///D:/win_toolchain_archive --make-offline-repo`：`Offline repository already complete`、`exit 0`、耗时 4 秒，无 bootstrap/网络；branch/ref/version/count=2+parent/工作区/custom_vars 指纹/zip 大小+mtime 任一不符时判为不匹配（合成测试）；amend commit 2 后标记仍有效 |
| 2026-11-19 | 150.0.7871.290 | 默认保留 / `--cleanup` 清理（ADR-013） | 通过（合成目录 + 端到端） | 默认：depot_tools 复制（原 `.git` 保留）、备份/`.gclient*`/`.cipd`/sccache 缓存保留；`--cleanup`：备份、5 个状态文件、`.cipd`、`<root>\depot_tools`、`init_tools\<MAJOR>\scache\cache` 删除，根目录不再残留标记（标记在 `src\init_tools` 内）；仓库与 `_bad_deps` 处理正确；失败时不清；`--keep-original`/`--no-cleanup` 只打印已废弃提示 |
| 2026-11-19 | 150.0.7871.290 | cmd.exe 下 `--args` 单引号被拆散（PIT-010 补充） | 通过（真实脚本 `--check`） | 单引号写法只保留 `target_os="win"` 且 `Config: debug`；新逻辑打印 `ERROR: these tokens look like GN assignments...` 并 `exit 3`（`Nothing was built.`）；`"--args=... target_cpu=\"x64\""` 与 `--args-file` 均得到 `Config: release` 和完整 GN args |
| 2026-11-20 | 150.0.7871.290 | PowerShell 下 `--args="...\"..."` 被拆散（PIT-010 补充） | 通过（真实脚本 `--check`） | 值变成 `target_os=\win\`/`target_cpu=\x64\`、构建目录 `out\\win\\x64\\r`；新检测打印 `GN arguments look mangled` 并 `exit 3`（`Nothing was built.`）；PowerShell 单引号与 `--args-file` 均得到 `Config: release`、`target_os="win"` |
| 2026-11-19 | 150.0.7871.290 | sccache 缓存目录自动切换（ADR-014 / PIT-021 补充） | 通过（真实 exe 三种状态） | 无服务：`--show-stats` 回显目标目录 → 不重启；服务用旧目录：检测到差异 → 自动 `--stop-server`；服务已是目标目录：不动。`--stop-server` 失败不再中断构建，`--check` 不探测/不建目录；`--sccache-dir D:\sccache_test` 同样正常 |
| 2026-11-20 | 150.0.7871.290 | env.bat 残留 + 源码缺失时重跑下载（PIT-026） | 通过（逻辑/环境同步测试；完整下载待实跑） | 指向 `<src>` 内部的 `DEPOT_TOOLS_PATH`/`GCLIENT_FILE` 被忽略，脚本变量**和子进程环境变量**都改为 `<root>` 路径（无 VERSION / 有 VERSION / `--dest-name` 改名 三种情况实测一致）；无 `chrome\VERSION` 的 `<src>` 被移到 `_stale_src_*`（内容保留）；`Invoke-Gclient` 自动创建缺失目录；`--help` 通过 |
| 2026-11-20 | 150.0.7871.290 | 已导出快照拒绝隐式更新（PIT-027 / ADR-013） | 通过（合成快照 4 场景） | 带/不带 `--make-offline-repo`、同版本均 `already complete`、exit 0；不带且 `--version 7872` → `refusing to update`、exit 3；删除标记后仍按 2 个提交识别并拒绝；全程无 fetch/checkout |
| 2026-11-20 | 150.0.7871.290 | 完成标记 `commit1` 写成 `HEAD~1`（PIT-028） | 通过（真实仓库修复 + 隔离检查） | 标记改为 `666e7f0e...`，与 `git rev-parse HEAD~1` 一致；隔离调用 `Test-OfflineRepoComplete` = True；脚本改为写 `HEAD` 并校验 40 位 sha |
| 2026-11-20 | 150.0.7871.290 | 停进程机制收紧：允许名单 + 位置解析 + 仓库归属（ADR-015） | 通过（冒烟测试） | 9 组子命令解析（引号路径、`-c` 值内嵌关键词、`--git-dir` 两种写法、写操作反例）全部正确；6 组仓库归属（含 `src`/`src2` 前缀边界、无路径 cwd 情形）全部正确；两个脚本在 ConstrainedLanguage 下 `--help` 退出码 0 |
| 2026-11-20 | 150.0.7871.290 | 清理 gclient 的 `_bad_scm`（PIT-025 补充） | 通过（合成目录 + 真实目录） | `Remove-TransientDirs` 删除 `_bad_scm`、`_bad_deps`、`_failed_export_git_*`，无关目录保留；真实的 `D:\chromium\_bad_scm`（gclient 坏 SCM 库，0 MB）已删除 |
| 2026-11-20 | 150.0.7871.290 | 导出同步 `args_default.gn` + sccache 参数识别 | 通过（真实仓库 `--check`） | `init_tools\win\args_default.gn` 已存在并被 git 跟踪；下载脚本拷贝列表包含它；`--check --args-file ...\args_default.gn` 得到 `Config: release`、`sccache cache: out\.cache150`、完整 GN args（`cc_wrapper` 不重复） |
| 2026-11-20 | 150.0.7871.290 | 仓库目录改名（chromium/webview/chromium150）自动识别 | 通过（合成目录） | build `--dir <parent>` 在只有一个 `chrome\VERSION` 子目录时输出 `Detected repository root: ...\chromium150`；两个候选时提示并失败。download 未给 `--dest-name` 时输出 `Using detected repository directory: ...\chromium150` 并 `already complete`；显式 `--dest-name chromium150` 不再提示 |
| 2026-11-20 | 150.0.7871.290 | `--dest-name` + 发现顺序 A（ADR-016） | 通过（合成目录） | `.gclient` 的 `name=chromium150` → 直接使用；仅完成标记 → `Using detected repository directory (completion marker)` 并跳过；显式 `--dest-name` → 不探测；两个 checkout / 两个标记 → exit 3；`--src-dir` → exit 3（提示已改名）；未知选项 → exit 3 |
| 2026-11-20 | 150.0.7871.290 | `--dest-name` 不自动重命名 `src`（ADR-016） | 通过（真实脚本 + 逻辑测试） | `src` 为有效 checkout + `--dest-name chromium150` → 打印 `Existing checkout found` 与手动 `Move-Item`，**exit 3**；`src` 未移动、`chromium150` 未创建、未 bootstrap；PATH 过滤逻辑删除 `<root>\*\init_tools*`、`<root>\*\scache*`，保留系统 git |
| 2026-11-20 | 150.0.7871.290 | 移除无意义的 `--skip-build` | 通过（真实脚本） | 下载脚本：`--skip-build` → `unknown option`、exit 3，帮助不再列出；构建脚本：`--skip-build is obsolete`、exit 2（不会继续构建） |
| 2026-11-20 | 150.0.7871.290 | 审查修复 ②③④：`Display` 键 / `--arch` 校验 / DEPS 边界匹配 | 通过（冒烟测试/代码路径） | `Resolve-RequestedVersion`/`Resolve-Milestone` 各分支均返回 `Display`（`--version 7871`→b7871、tag→b\<BUILD\> 与修复前一致）；`--arch foo` 告警并回退主机默认；DEPS 匹配 `/<rel>'` 边界（`foobar` 反例不匹配、`foo` 匹配、跨前缀 `chromium_src/` 亦匹配）；`--help` 解析通过 |
| 2026-11-20 | 150.0.7871.290 | RUNBOOK 逐条验证（/verify-runbook，干净目录） | 9/9 通过（步骤 1/2/5 与场景 B 未执行） | 验证目录 `%TEMP%\runbook-verify-20261120-1017`（合成导出树 + 假 gn/autoninja）：步骤 0 `git`/`opencode` 版本号 OK；步骤 3 `--check` 输出 `Mode : offline repo`、`Toolchain : stale -> will regenerate`、`Toolchain map: GYP_MSVS_HASH_e66617bc68=fab72fa52c`，完整构建路径 exit 0（`content_shell OK`、args.gn=`is_debug=false`），`--arch foo` 告警回退、`--arch x86 --release`→`out\winx86r`；步骤 4 robocopy 搬移后 `--check` `Source` 指向新位置、toolchain 仍 stale；步骤 1 入口预检 exit 0。真实下载/导出/构建与场景 B 因网络/时长/规则 1 跳过，RUNBOOK 状态仍为「未验证」 |

## 待验证（TODO）

| 项 | 阻塞 | 下一步 |
| --- | --- | --- |
| 真实 `ninja content_shell`（首次全量） | 未执行；预计耗时长 | DXC 已修复（PIT-011），在 `D:\chromium\src` 跑 `.\init_tools\win\chromium_build_win.bat --release --targets content_shell` |
| 真实 429 重试路径 | 需复现限流 | 用 `-j 1` + 长退避手工复现 |
| 全量 Runbook 时限 | — | 完整跑一次后回填耗时 |

## 记录模板

```
| <日期> | <Chromium 版本> | <场景> | 通过/失败 | <证据：命令输出关键行 / git status> |
```
