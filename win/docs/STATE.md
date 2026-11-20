# 项目状态

> 记录「现在是怎样」，不记录历史决策（见 `DECISIONS.md`）。
> 最后更新：2026-11-20

## 1. 架构

| 阶段 | 脚本 | 职责 | 网络 |
| --- | --- | --- | --- |
| 下载/准备 | `chromium_download_win.ps1` / `.bat` | bootstrap git+depot_tools、`fetch`/`gclient sync --no-history`、`gclient runhooks`；（`--make-offline-repo`）导出自包含仓库 | 需要 |
| 构建 | `chromium_build_win.ps1` / `.bat` | 定位源码、修 `win_toolchain.json`、`gn gen` + `autoninja`、`--check` | 不需要 |
| 共享 | `bootstrap_depot_tools.ps1` | git/depot_tools/Python 引导；接受「无 `.git` 的物化快照」 | 需要（离线快照除外） |
| 工具链 | `prepare_win_toolchain.ps1` | 打包 VS/SDK 为 `<hash>.zip`，供 `--win-toolchain-url` | 需要 |

## 2. 目录布局

普通工作区：

```
<dir>\
  depot_tools\
  .gclient
  src\                 # Chromium 源码（浅拷贝）
  tools\git\           # 需要时自动下载的 PortableGit
```

导出后的离线仓库（`--make-offline-repo`，仓库根 = 源码目录）：

```
<dir>\<srcName>\        # 一个 git 仓库，.git 在这里
                       # 分支名：main / b<BUILD>（如 b7871）
  .gitignore            # 追加了 /out/、*.log、*.tmp、/build/win_toolchain.json 等
  <Chromium 源码...>
  init_tools\
    <MAJOR>\
      config\           # .gclient 等状态（版本↔配置对照）
      depot_tools\      # 普通文件，无 .git
      scache\           # sccache.exe
    win\                # 两套脚本 + README + env.bat/env.ps1
```

`<srcName>` 默认 `src`，可用 `--dest-name NAME` 改名；`env.bat/env.ps1` 用
`%~dp0` / `$PSScriptRoot` 推导，**整个仓库可改名/换盘/拷贝**。

## 3. 构建期关键文件（都在源码树内，随仓库搬运）

| 文件 | 作用 | 说明 |
| --- | --- | --- |
| `buildtools\win\gn.exe` | GN | CIPD 包，导出时作为普通文件提交 |
| `third_party\ninja\ninja.exe` | Ninja | 同上 |
| `third_party\llvm-build\Release+Asserts\bin\clang-cl.exe` | clang | GCS 包 |
| `build\config\gclient_args.gni` | GN 输入 | `gclient sync`/hooks 产物 |
| `build\util\LASTCHANGE` | 版本标记 | hooks 产物 |
| `build\win_toolchain.json` | 工具链绝对路径 | **不入库**，构建脚本会删除并让 gn 重建 |
| `third_party\depot_tools\win_toolchain\vs_files\<hash>` | MSVC+SDK | 在仓库内，构建时直接使用 |

## 4. 环境约束（本机，2026-11）

- Windows 10/11 x64；**PowerShell 5.1 处于 ConstrainedLanguage**（WDAC，`CodeIntegrityPolicyEnforcementStatus=2`）
- **未安装 Visual Studio**；工具链来自本地归档 `D:\win_toolchain_archive\<hash>.zip`
  （通过 `GYP_MSVS_HASH_<canonical>=<hash>` 映射）
- **CIPD 客户端被安全策略按文件封杀** → `gclient.bat`(vpython) 不可用；`python3.bat gclient.py` 可用（见 PIT-001）
- `chromium.googlesource.com` 存在**匿名短期限流**（见 PIT-002）
- 路径长度敏感：构建目录尽量短（如 `D:\cr2`）

## 5. 当前机器状态（2026-11-19，导出完成）

> **2026-11-20 状态变化**：`D:\chromium\src` 的 Chromium 源码与 `.git`、完成标记、
> `src_git_bak` 备份都已被删除（只剩 `init_tools\150\depot_tools`），`D:\chromium\chromium150`
> 也已删除；下面的"导出完成"描述是 2026-11-19 的历史状态。重新下载时见 **PIT-026**。

`D:\chromium`：

- `src` = 完整 Chromium 150.0.7871.290，**单一 git 快照仓库**（branch `b7871`，2 个提交）：
  - `offline repo: Chromium 150.0.7871.290 (init_tools + full deps)`
  - `offline repo: Chromium 150.0.7871.290 (original source)`
  - `git status --porcelain` 为空；`git ls-tree -r HEAD` / `HEAD~1` 中
    `__pycache__` / `*.pyc` 路径均为 **0**（按 PIT-009 补充修复）
- `src\init_tools\150\{config,depot_tools,scache}` 与 `src\init_tools\win` 齐全；
  `scache\sccache.exe` 已提交；sccache 构建缓存默认在 `src\out\.cache150`
  （`out/` 已忽略，不弄脏仓库；`--sccache-dir` 可覆盖）
- `src_git_bak` / `src_gitignore_bak` 仍在（默认保留模式；`--cleanup` 才会删）；
  根目录 `.gclient*` / `.gcs_entries` / `.cipd` / `depot_tools` 保留（可复用工作区）
- 完成标记 `src\init_tools\.offline_repo.state`（Windows 隐藏属性）**已随 commit 2/2 提交**（ADR-013）：
  branch `b7871`、ref `refs/branch-heads/7871`、commit 1、toolchain `fab72fa52c`
  （zip 大小/mtime、deps 指纹已记录；不记录 commit 2 自身）。
  下次以相同参数运行会打印 `Offline repository already complete` 并直接退出。
  强制重导：删除该标记文件（工作区变脏即不跳过）。
- `depot_tools` 等依赖的原 `.git` 已移入 `src_git_bak`，仓库内不再有嵌套仓库
  （`git -C third_party\depot_tools rev-parse` 现在返回外层 `b7871` 的提交）
- 工具链：`src\third_party\depot_tools\win_toolchain\vs_files\fab72fa52c`
- PGO：`src\chrome\build\pgo_profiles\chrome-win64-7871-…profdata`（约 447 MB），
  `chrome_pgo_phase=2` 可用
- GN 参数：支持 `--args` / `--args-file` 覆盖脚本默认值，最终写入 `out\<build-dir>\args.gn`（ADR-006）
- 构建前先 `--clean`/删除 `out`：导出时 `out` 不参与提交，当前 `src\out` 为空

## 6. 已知限制

- 导出仓库是**只读快照**：依赖的 `.git` 已删除，不能再 `gclient sync`；版本信息看 `init_tools\<MAJOR>\config\`
- 下载脚本重复运行：普通工作区可续跑；导出后需显式 `GCLIENT_FILE`/`DEPOT_TOOLS_PATH` + `--skip-fetch --skip-hooks`
- `--version stable` / `--milestone` 需要联网解析；纯数字/ref 可离线解析
- 导出遇锁会自动停用只读 git 进程（ADR-015：允许名单 + 按位置解析子命令 + `-C`/`--git-dir` 归属过滤）；残余限制：cwd 方式（命令行无仓库路径）运行在其他仓库的只读进程仍可能被停

## 7. 文档索引

- `docs/DECISIONS.md` — 架构决策（ADR）
- `docs/PITFALLS.md` — 坑位库（PIT-NNN）
- `docs/RUNBOOK.md` — 最小路径（可执行）
- `docs/VERIFY.md` — 验证记录
- `docs/技能蒸馏2026111101.md` — 项目记忆/知识蒸馏工作流的完整记录（含方案、步骤、用法、验证、可迁移模板）
