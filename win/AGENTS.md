# AGENTS.md

本仓库是「Chromium Windows 离线下载/构建」工具集。给 AI 助手的常驻约定，优先于默认行为。

## 项目概览

- **下载（联网）**：`chromium_download_win.ps1/.bat`
  bootstrap git/depot_tools → `fetch`/`gclient sync --no-history` → `gclient runhooks`
  →（`--make-offline-repo`）把 depot_tools/config/sccache/脚本收进 `<src>\init_tools` 并提交成自包含仓库。
- **构建（不联网）**：`chromium_build_win.ps1/.bat`
  定位源码（脚本相对位置 → 环境变量 → `--dir`）→ 修复 `build\win_toolchain.json` → `gn gen` + `autoninja`。
- **共享**：`bootstrap_depot_tools.ps1`（bootstrap）、`prepare_win_toolchain.ps1`（打工具链归档）。
- 文档：`docs/`（状态、ADR、坑位、runbook、验证记录）。

## 硬约束（必须遵守）

1. **PowerShell 5.1 + ConstrainedLanguage**（本机 WDAC 强制）：
   禁用 `[pscustomobject]`、`[IO.File]`、`[Convert]`、`[Math]::*`、`New-Object`（非核心类型）、`Add-Type`。
   替代：`[ordered]@{}`、`Get-FileHash`、`Get-Content -Encoding Byte`、`certutil -decode`、`Split-Path`。
2. **不要修改 Chromium 源码**；只在 `docs/`、`.opencode/`、脚本外围做改动。
3. **不要写密钥/令牌**到任何文件；日志里的凭据必须脱敏。
4. **不要删除用户数据**（`D:\chromium\src`、`D:\win_toolchain_archive`、未跟踪的笔记文件）。
5. 构建脚本必须保持「零网络、零 gclient」；联网逻辑只能出现在下载脚本里。

## 项目记忆约定（知识闭环）

- 遇到**非显然失败** → `/pitfall`（写 `docs/PITFALLS.md`，带 PIT 编号 / 根因 / 修复 / 验证命令）
- 做了**结构或流程取舍** → `/journal`（写 `docs/DECISIONS.md` ADR，并更新 `docs/STATE.md`）
- 每完成一版**可运行状态** → `/distill`（重写 `docs/RUNBOOK.md` + `docs/VERIFY.md`），随后 `/verify-runbook`
- 记录只写**可复用结论**（不写流水账）；命令必须**可直接执行**；相同根因不新开条目。
- 文档里的路径用仓库相对路径或明确的 `<dir>` 占位符。

## 回答风格

- 先给结论/根因，再给可执行步骤；给命令时注明预期输出与失败分支。
- 不确定的结论标注「未验证」。
