# 坑位库（PITFALLS）

> 每条 = 一个可复用的失败模式。格式固定：症状 / 触发 / 根因 / 修复 / 预防 / 验证。
> 相同根因只更新「再次出现」，不新开条目。命令必须可直接执行。

---

## PIT-001 安全策略按文件封杀 CIPD 客户端

- **症状**
  ```
  fork/exec ...\cipd.exe: Access to %1 has been restricted by your Administrator by policy rule %2
  ```
  或 `gclient.bat` 报 `failed to generate venv derivation ... exit status 1`
- **触发**：任何需要 CIPD 的步骤（`gclient sync` 装 gn/ninja/android_sdk；`vpython3` 建 venv；`cipd.bat`）
- **根因**：WDAC/EDR 对 `cipd` 客户端二进制做**按文件**封禁（换版本、改名、换目录都一样被拦；同机未签名的 `vpython3.exe` 复制后却能运行）。与网络无关。
- **修复**
  - 正解：由 IT 把该二进制加入允许列表；
  - 临时绕过：用 `python3.bat <depot_tools>\gclient.py ...` 直接驱动 gclient（不经过 vpython）；
  - 但 CIPD 包本身仍需要客户端，无法绕过 → 只能换机器/换策略。
- **预防**：新机器先做「可执行性」探测，而不是只看下载成功：
  ```powershell
  & "$env:LOCALAPPDATA\...\depot_tools\.cipd_client.exe" version   # 期望 exit 0
  ```
- **验证**：`cisd` 客户端能执行且 `gclient sync` 能装 `src\buildtools\win\gn.exe`。
- **首次发现**：2026-11-10（150.0.7871.290）
- **再次出现**：—

---

## PIT-002 googlesource 匿名短期限流（429）

- **症状**
  ```
  remote: RESOURCE_EXHAUSTED: Resource has been exhausted (e.g. check quota)
  remote: subject: "shared/shared_anonymous"
  remote: description: "Short term server-time rate limit exceeded"
  fatal: ... The requested URL returned error: 429
  ```
- **触发**：`gclient sync` 并行拉取大量子仓库；共享出口 IP（公司 NAT/代理）上多人同时拉
- **根因**：googlesource 对「匿名 + 出口 IP」的短期配额限流，**不是封禁**（封禁是 403/连接重置）
- **修复**
  - 等 10–30 分钟后重跑（`.gclient` 在就会续跑）；
  - 降低并发：`gclient sync --nohooks --no-history -j 1 --gclientfile .gclient`
  - 增加重试轮次：`--retries 10`（脚本默认已是 10 次；每次间隔 30 s、60 s … 300 s，累计约 27 分钟）
- **预防**：批量 sync 用低并发；重试要有长退避（2/5/10 分钟），不要 30s 连打
- **补充（2026-11-18）**：`--retries` 默认值已从 2 改为 **10**，适用于 fetch / `gclient sync` / `runhooks`。
  10 次仍失败说明限流窗口比 ~27 分钟的退避更长：**隔一段时间重跑**比继续加次数更有效。
- **验证**
  ```powershell
  git ls-remote --heads https://chromium.googlesource.com/chromium/src.git   # 期望 exit 0
  ```
- **首次发现**：2026-11-10

---

## PIT-003 `--gclientfile` 只能传文件名，不能传路径

- **症状**
  ```
  gclient.py: error: --gclientfile target must be a filename, not a path
  ```
- **触发**：`gclient ... --gclientfile D:\chromium\.gclient`
- **根因**：gclient 把该参数当「文件名」并相对当前目录解析
- **修复**：在 `.gclient` 所在目录执行，参数只给 `.gclient`
  ```powershell
  Push-Location D:\chromium
  D:\chromium\depot_tools\gclient.bat sync --nohooks --no-history --gclientfile .gclient
  Pop-Location
  ```
- **预防**：脚本里统一封装 `Invoke-Gclient`（切目录 + 传 leaf 名）
- **验证**：`gclient.bat root --gclientfile .gclient` 打印根目录
- **首次发现**：2026-11-10

---

## PIT-004 `fetch` 只能在空目录用，重试必须改 `gclient sync`

- **症状**
  ```
  Your current directory appears to already contain, or be part of, a checkout.
  "fetch" is used only to get new checkouts. Use "gclient sync" ...
  ```
- **触发**：`fetch.bat` 第一次失败后脚本原样重试
- **根因**：`fetch` 拒绝在已有 `.gclient`/`src` 的目录运行；第一次失败时已经创建了它们
- **修复**：重试分支检测到 `.gclient` 存在就改调 `gclient sync`（脚本已实现）
- **预防**：任何「幂等重试」都要先判断前置状态，而不是原命令重放
- **验证**：日志出现 `Partial checkout found; resuming with "gclient sync" instead of "fetch".`
- **首次发现**：2026-11-10

---

## PIT-005 PowerShell 数组字面量里逗号优先级高于 `+`

- **症状**：生成的 `env.bat` 里路径被拆成多行：
  ```
  set "DEPOT_TOOLS_PATH=%INIT%\
  150
  \depot_tools"
  ```
- **触发**：`@( 'a' + $x + 'b', 'c' + $y + 'd' )`
- **根因**：PowerShell 的逗号运算符优先级**高于** `+`，被解析成 `'a' + ($x, 'b', 'c') + $y + 'd'`（数组参与字符串拼接）
- **修复**：先把整行算成变量，再放进数组
  ```powershell
  $dtLine = 'set "X=%INIT%\' + $major + '\depot_tools"'
  $envBat = @('@echo off', $dtLine, ...)
  ```
  或给每个元素加括号：`@( (…) , (…) )`
- **预防**：数组元素里不要混用 `+` 和逗号；生成脚本后**读一遍产物**
- **验证**：`Get-Content env.bat` 每行完整、无断裂
- **首次发现**：2026-11-11

---

## PIT-006 ConstrainedLanguage 下的禁用清单（本机 WDAC 强制）

- **症状**：`无法调用方法...` / `无法将值转换为类型 ...InternalPSCustomObject` / `仅支持核心类型`
- **触发**：`[pscustomobject]`、`[IO.File]::*`、`[Convert]::*`、`[Math]::*`、`[Text.Encoding]`、`New-Object`（非核心类型）、`Add-Type`、`[Environment]::GetEnvironmentVariable`
- **根因**：WDAC 把 PowerShell 锁进 ConstrainedLanguage，脚本代码只能用核心类型与 cmdlet
- **修复（替代写法）**
  | 禁用 | 替代 |
  | --- | --- |
  | `[pscustomobject]@{}` | `[ordered]@{}`（属性访问同样可用） |
  | `[IO.File]::OpenRead` / `WriteAllText` | `Get-Content -Encoding Byte -TotalCount N` / `Set-Content -Encoding Byte` |
  | `SHA256::Create()` / `BitConverter` | `Get-FileHash -Algorithm SHA256` |
  | `[Convert]::FromBase64String` + `[Text.Encoding]::UTF8` | `certutil -decode` + `Get-Content -Raw -Encoding UTF8` |
  | `[Math]::Min/Max` | `if` 比较 |
  | `New-Object System.Collections.Generic.List[string]` | 临时文件 + `Add-Content`（分批） |
  | `Add-Type -AssemblyName ...` | 只用 cmdlet（如 `Expand-Archive`） |
- **预防**：新增代码前先问「这是 cmdlet 还是 .NET 调用」；写完在 CL 环境跑一次
- **验证**：`$ExecutionContext.SessionState.LanguageMode` = `ConstrainedLanguage` 且脚本 `--help` exit 0
- **首次发现**：2026-11-10

---

## PIT-007 `build\win_toolchain.json` 是绝对路径，搬移后必然失效

- **症状**：改名/换盘后 `gn gen` 报找不到编译器/SDK；或悄悄用了**旧位置**的 toolchain
- **触发**：复制/移动整个源码树；`ShouldUpdateToolchain()` 只比较 `version` 字段，路径不校验
- **根因**：文件内容形如
  ```json
  { "path": "D:\\old\\src\\third_party\\depot_tools\\win_toolchain\\vs_files\\fab72fa52c", ... }
  ```
- **修复**：删除该文件，让 `gn`（`get_toolchain_dir`）走 `Update(no_download=True)` 就地重建：
  ```powershell
  Remove-Item <src>\build\win_toolchain.json -Force
  ```
  构建脚本已自动做（判断 `path` 不在当前 `$Src` 下）。
- **预防**：该文件**不入库**（`.gitignore` + `git add` 排除）
- **验证**：`chromium_build_win.bat --check` 的 `Toolchain` 行显示 `absent (gn will create it)` 或 `ok (<新路径>)`，以及下面的补充。

- **补充（2026-11-12，搬移 + 自建工具链）**：用 `--win-toolchain-url` 时，本地目录名是**local hash**
  （如 `fab72fa52c`），而 `vs_toolchain.py` 重新生成 json 时按 **canonical hash**（如 `e66617bc68`）
  查找 —— 缺映射就会报"toolchain 不存在"。构建脚本现在会自动探测
  `<depot_tools>\win_toolchain\vs_files\<唯一目录>` 与 `build\vs_toolchain.py` 的 `TOOLCHAIN_HASH`，
  并设置 `GYP_MSVS_HASH_<canonical>=<local>`：
  ```powershell
  .\init_tools\win\chromium_build_win.bat --check
  # Toolchain map: GYP_MSVS_HASH_e66617bc68=fab72fa52c
  ```
- **首次发现**：2026-11-11

---

## PIT-008 想「保留依赖 .git」又「把内容装进一个仓库」是互斥的

- **症状**：`git add` 后子目录只剩一个 gitlink（submodule 引用），仓库里没有依赖文件
- **触发**：源码树里存在 `third_party/*/.git`、`v8/.git`、`init_tools/.../depot_tools/.git`
- **根因**：git 对含 `.git` 的子目录只记录 commit 引用，不记录内容
- **修复**：导出时删除所有嵌套 `.git`（保留源码仓库自己的 `.git`），依赖变成普通文件
- **后果（必须接受）**：导出后的仓库**不可再 `gclient sync`**，是只读快照；版本信息保存在
  `init_tools\<MAJOR>\config\.gclient*`
- **预防**：在文档里把「快照」写明，避免以后有人尝试 sync
- **验证**：`git -C <src> ls-files third_party/<dep> | Measure-Object` 有文件；`Test-Path <src>\third_party\<dep>\.git` 为 False
- **首次发现**：2026-11-11

---

## PIT-009 `git add -f src` 会把 `out\` 编进对象库

- **症状**：`git gc` 枚举出 1,011,567 个对象；仓库体积异常大、gc 很慢
- **触发**：先构建再导出，且用 `git add -A -f src`（`-f` 覆盖 `.gitignore`）
- **根因**：`-f` 强制加入被忽略的 `src\out`（几十万 `.obj/.pdb`），`git rm --cached` 只移出索引，对象仍在；`gc.pruneExpire` 默认 2 周内不回收
- **修复**：
  ```powershell
  git -C <src> add -A -f -- . ":(exclude)out" ":(exclude)build/win_toolchain.json"
  git -C <src> gc --prune=now        # 回收历史残留
  ```
- **预防**：导出时用 exclude pathspec；`.gitignore` 加 `/out/`
- **验证**：`git -C <src> ls-files out | Measure-Object` = 0；`git count-objects -v` 的 `size-pack` 合理
- **首次发现**：2026-11-11
- **补充（2026-11-17，同类根因：`-f` 绕过 `.gitignore`）**：`git add -A -f` 也会把
  `__pycache__/`、`*.pyc`、`*.log` 等被忽略的垃圾一起提交。导出前必须先物理删除：
  ```powershell
  Get-ChildItem <src> -Recurse -Force -Directory -Filter '__pycache__' | Remove-Item -Recurse -Force
  Get-ChildItem <src> -Recurse -Force -File -Filter '*.pyc'            | Remove-Item -Force
  ```
- **实测坑（2026-11-19，仅"导出前删一次"不够）**：
  - `Update-ToolchainTimestampCache` 会调用 python，**重新生成**
    `third_party/depot_tools/**/__pycache__`（commit 1 混进 3 个 `.pyc`）；
  - commit 2 前复制 `depot_tools` 到 `init_tools\<MAJOR>\depot_tools`，把它的
    `__pycache__`（含 `.cipd_bin` 里的 CPython 标准库缓存）一并带进去（789 个路径）。
  - 结论：清理必须放在**每次 commit 的紧前面**——toolchain 时间戳刷新之后、
    commit 1 `git add` 之前一次；init_tools 组装完成后、commit 2 `git add` 之前再一次。
  - 另外给两条 `git add` 都加 pathspec 兜底，并在 add 之后执行
    `git rm -r --cached --ignore-unmatch ':(glob)**/__pycache__/**' ':(glob)**/*.pyc'`，
    防止 add 与 commit 之间被 hook/工具重新生成。
  - 修复**已有**的两个提交（保留 2 个 commit，**不要** `--prune-empty`，否则会剪掉变成空的提交）：
    ```powershell
    git -C <src> filter-branch --force --index-filter "git rm -r --cached --ignore-unmatch ':(glob)**/__pycache__/**' ':(glob)**/*.pyc'" <branch>
    git -C <src> reset -q
    git -C <src> update-ref -d refs/original/refs/heads/<branch>
    git -C <src> reflog expire --expire=now --all
    git -C <src> prune --expire=now
    ```
  - 验证：
    ```powershell
    git -C <src> ls-tree -r --name-only HEAD   | Select-String '__pycache__|\.pyc$'   # 0
    git -C <src> ls-tree -r --name-only HEAD~1 | Select-String '__pycache__|\.pyc$'   # 0
    git -C <src> rev-list --count HEAD                                                # 2
    ```
- **预防**：`.gitignore` 保留 `**/__pycache__/` 与 `**/*.pyc`（导出脚本生成的
  `.gitignore` 已包含），但它只对**不加 `-f`** 的 add 生效。

---

## PIT-010 PowerShell 传给 `.bat` 的引号会被吞掉（`cc_wrapper="sccache"` → `cc_wrapper=sccache`）

- **症状**
  ```
  ERROR at the command-line "--args":1:27: Undefined identifier
  is_debug=false cc_wrapper=sccache
                            ^------
  ```
- **触发**：`chromium_build_win.bat --release ...`（脚本内 `gn.bat gen out\Default --args=is_debug=false cc_wrapper="sccache"`）
- **根因**：PowerShell 5.1 启动 `.bat` 时，参数里的**双引号在 cmd 解析层被吞掉**；`gn` 收到 `cc_wrapper=sccache`，把 `sccache` 当标识符
- **修复**：不要在命令行传 `--args`，改写 **`out\Default\args.gn`**（每行一个赋值），然后 `gn gen out\Default`：
  ```powershell
  New-Item -ItemType Directory -Force -Path out\Default | Out-Null
  Set-Content -LiteralPath out\Default\args.gn -Value @('is_debug=false', 'cc_wrapper="sccache"') -Encoding ASCII
  .\init_tools\150\depot_tools\gn.bat gen out\Default
  ```
  构建脚本已改为自动写 `args.gn`（`--gn-args` 支持用换行分隔多个参数）。
- **预防**：任何要传给 `.bat`/`.cmd` 的参数都**不要内嵌双引号**；能落到文件（args.gn、响应文件）就不要走命令行。
- **验证**
  ```powershell
  Get-Content D:\chromium\src\out\Default\args.gn       # 两行：is_debug=false / cc_wrapper="sccache"
  ```
  期望 `gn gen` 输出 `Done. Made <N> targets from <M> files`，退出码 0。
- **首次发现**：2026-11-11（150.0.7871.290）
- **再次出现**：—
- **补充（同日实测：各入口的转义规则）**

  | 调用方式 | 写法 | 脚本收到 | 可用 |
  | --- | --- | --- | --- |
  | 直接跑 `.ps1` | `--args 'target_os="win"'` | `target_os="win"` | ✅ |
  | 直接跑 `.ps1` | `--args "target_os=`"win`""` | `target_os="win"` | ✅ |
  | 走 `.bat` | `--args 'target_os="win"'` | `target_os=win` | ❌ |
  | 走 `.bat` | `--args 'target_os=""win""'` | `target_os=win`（双写**不是**转义） | ❌ |
  | **走 `.bat`** | **`--args 'target_os=\"win\"'`** | `target_os="win"` | ✅ |
  | 任意 | `--args-file <file>` | 原样 | ✅（无引号层） |

  **规则**：`.bat` 入口用 `\"`；直接 `.ps1` 用普通 `"`；长参数优先 `--args-file`。
  构建脚本会把 `\"` 归一化成 `"`，所以两种入口可以共用同一份文本。
  脚本还会打印**可直接复制的完整命令**（`--check` 里也能看到 `Full gn gen : ...`），
  其中的 `--args` 已按 `\"` 转义，实测可原样执行。
- **补充（2026-11-19，cmd.exe 里调用 `.bat`）**：上表"走 `.bat`"指**在 PowerShell 中**调用；
  **cmd.exe 不把单引号当引号**，`--args='a b c'` 会按空格拆成多个参数：
  ```bat
  rem 错误：只有 target_os="win" 进了 --args，其余被拆散
  chromium_build_win.bat --ide vs2022 -j16 --targets chrome ^
    --args='target_os=\"win\" target_cpu=\"x64\" is_debug=false'

  rem 正确：整段值用双引号包住，内部 GN 引号用 \"
  chromium_build_win.bat --ide vs2022 -j16 --targets chrome ^
    "--args=target_os=\"win\" target_cpu=\"x64\" is_debug=false"

  rem 最稳：没有引号层
  chromium_build_win.bat --ide vs2022 -j16 --targets chrome --args-file gn_args.txt
  ```
  旧版脚本对拆出来的 `key=value` 只打 `Unknown option` 警告并继续，结果会**静默变成
  debug 构建**（`is_debug=false` / `is_official_build=true` 全部丢失）。
  现在构建脚本会收集这些泄漏的 GN 赋值，打印明确错误并以 **exit 3** 退出
  （`Nothing was built.`），不再静默换配置。
  验证：`--check` 的 `Config` 应为 `release`，`GN args` 应包含 `is_debug=false`、
  `target_cpu="x64"` 等；完整命令可直接复制执行。
- **补充（2026-11-20，PowerShell 里用 `--args="...\"..."`）**：
  - **错误**（PowerShell）：
    ```powershell
    .\chromium_build_win.bat ... --args="target_os=\"win\" target_cpu=\"x64\" is_debug=false"
    ```
    PowerShell **不把 `\"` 当转义**，`"` 直接结束字符串；脚本收到
    `target_os=\win\`、`target_cpu=\x64\`。`gn` 报
    `Invalid token ... target_os=\win\`，构建目录还会变成 `out\\win\\x64\\r`。
  - **正确**（PowerShell，二选一）：
    ```powershell
    .\chromium_build_win.bat ... --args 'target_os="win" target_cpu="x64" is_debug=false'
    .\chromium_build_win.bat ... --args-file gn_args.txt      # 最稳
    ```
  - 同一行在 **cmd.exe** 里 `\"` 是转义，所以会出现"cmd 能跑、PowerShell 报错"。
  - 构建脚本现在会检测 `\value\` 形式（`^\\[A-Za-z0-9_.:/-]+\\$`）的 GN 值，
    打印错误并 **exit 3**（`Nothing was built.`），不再写出坏 args.gn。
  - 验证：`--check` 的 `GN args` 应为 `target_os="win"` 而不是 `target_os=\win\`。

---

## PIT-011 依赖目录为空（fetch 时 429 失败）→ ninja 报 missing and no known rule

- **症状**
  ```
  "../../third_party/dawn/third_party/directx-shader-compiler/src/include/llvm/Config/AsmParsers.def.in",
  needed by "gen/third_party/dawn/third_party/directx-shader-compiler/include/llvm/Config/AsmParsers.def",
  missing and no known rule to make it
  ```
- **触发**：导出前 `gclient sync` 曾因 429 失败；该依赖目录存在但 **0 个文件**
- **根因**：空目录被一起导出（git 不跟踪空目录，所以仓库里连空目录都没有），依赖内容从未落地；`gn gen` 不校验这些输入文件，ninja 才炸
- **诊断**
  ```powershell
  $dep = 'D:\chromium\src\third_party\dawn\third_party\directx-shader-compiler\src'
  (Get-ChildItem $dep -Recurse -File -Force | Measure-Object).Count    # 0 => 空
  ```
  再对照 `third_party\dawn\DEPS` 里的 pin（本项目为 `35c1b99e9e552267da5efaea07c003e322d65777`）
- **修复**（按 pin 浅取；`{chromium_git}` = `https://chromium.googlesource.com`）
  ```powershell
  $dep = 'D:\chromium\src\third_party\dawn\third_party\directx-shader-compiler\src'
  git -C $dep init
  git -C $dep remote add origin https://chromium.googlesource.com/external/github.com/microsoft/DirectXShaderCompiler
  git -C $dep fetch --depth 1 origin 35c1b99e9e552267da5efaea07c003e322d65777
  git -C $dep checkout --detach FETCH_HEAD
  ```
- **预防**：导出前做一次「依赖完整性检查」——`third_party/**/*/src` 里 0 文件的目录要列出来复核；
  或确认上次 `gclient sync` 没有报错（429 也要当成失败处理）
- **补充（2026-11-16）**：扫描 `third_party/**/src` 会大量误报（平台条件目录、submodule 占位目录）。
  现在改为以 `<root>\.gclient_entries`（gclient 本次实际管理的依赖清单）为准：
  正常输出 `Dependency check: all N managed dependencies are present.`；
  只有清单内的依赖为空/缺失才报 `EMPTY` / `MISSING`。对照 DEPS 的 pin 复核仍按上面的步骤。
- **验证**
  ```powershell
  Test-Path "$dep\include\llvm\Config\AsmParsers.def.in"    # True
  ```
  然后 `gn gen` 成功、ninja 不再报该文件
- **首次发现**：2026-11-11（150.0.7871.290）

---

## PIT-012 依赖源码版本与 Chromium 的 BUILD.gn 不匹配 → 链接 `undefined symbol`

- **症状**（本项目实例，链接 WebNN 服务 DLL）
  ```
  lld-link: error: undefined symbol: GetLiteRtRuntimeBuiltin
  >>> referenced by .../third_party/litert/src/litert/cc/internal/litert_runtime_proxy.h:172
  ```
- **触发**：离线仓库里某个依赖的源码是**另一个版本**（fetch 失败后残留），而 `BUILD.gn` 是当前 Chromium 版本的固定副本
- **根因**：`litert_runtime_proxy.h`（残留的新版源码）引用了 `GetLiteRtRuntimeBuiltin()`，该符号定义在 `litert/c/internal/litert_runtime_builtin.cc`；但 Chromium 的 `third_party/litert/BUILD.gn` 只把 `.h` 列进 sources，**从未编译那个 `.cc`**（pin 版本的 proxy 根本不引用它）
- **诊断**
  1. 在对应 `BUILD.gn` 里搜「定义该符号的 `.cc`」——搜不到 = 源码比 BUILD.gn 新/旧，版本不匹配；
  2. 对照根 `DEPS` 的 pin（本项目 `third_party/litert/src` = `09b4b05203fd7a9402ffcce9cc736d887ff7e3fc`）；
  3. 目录没有 `.git` → 无法直接看版本，只能按 pin 重取
- **修复**
  ```powershell
  $dep = 'D:\chromium\src\third_party\litert\src'
  Remove-Item $dep -Recurse -Force
  git -C $dep init
  git -C $dep remote add origin https://chromium.googlesource.com/external/github.com/google-ai-edge/LiteRT
  git -C $dep fetch --depth 1 origin 09b4b05203fd7a9402ffcce9cc736d887ff7e3fc
  git -C $dep checkout --detach FETCH_HEAD
  .\init_tools\150\depot_tools\gn.bat gen out\winx64d
  ```
- **预防**：导出前做「依赖版本体检」——对每个有 pin 的 `*/src`，确认存在 `.git` 且 `HEAD == pin`（没有 `.git` 的至少核对关键文件）；**把任何 fetch 失败（含 429）当作失败**，不要继续导出
- **验证**
  ```powershell
  Select-String ...\litert_runtime_proxy.h GetLiteRtRuntimeBuiltin   # 期望：无输出
  .\init_tools\150\depot_tools\autoninja.bat -C out\winx64d services_webnn_webnn_service.dll
  ```
  注意：直接调 autoninja 时要把 `init_tools\150\scache` 加进 PATH（否则报 `exec: "sccache": executable file not found in %PATH%`，与链接无关）
- **首次发现**：2026-11-12（150.0.7871.290）

---

## PIT-013 `is_official_build=true` 缺 PGO profile → `gn gen` 报 `requested profile ... doesn't exist`

- **症状**
  ```
  RuntimeError: requested profile "...\chrome\build\pgo_profiles\chrome-win64-7871-...profdata" doesn't exist
  ... you can also simply disable the PGO optimizations by setting |chrome_pgo_phase = 0|
  ERROR at //build/config/compiler/pgo/BUILD.gn:139:23: Script returned non-zero exit code.
  ```
- **触发**：`--args "is_official_build=true"`，且没下载 PGO profile（离线仓库常见：`--skip-hooks` / 未用 `--pgo`）
- **根因**：`is_official_build=true` 时 `chrome_pgo_phase` 默认为 2（使用 PGO），GN 会执行
  `tools/update_pgo_profiles.py` 去取 `chrome/build/pgo_profiles/*.profdata`；文件不存在即失败
- **修复（三选一）**
  1. 关闭 PGO：`--args "chrome_pgo_phase=0"`（构建脚本现在会**自动**加，并打印警告）；
  2. 下载 profile 后再开：下载阶段加 `--pgo`（或 `.gclient` 里 `checkout_pgo_profiles=True` + runhooks），然后 `chrome_pgo_phase=2`；
  3. 显式传 `--args "chrome_pgo_phase=2"`（前提：`.profdata` 已存在）
- **预防**：official 构建前先确认 `chrome/build/pgo_profiles` 是否非空；脚本已做存在性检查
- **验证**
  ```powershell
  Get-Content out\winx64r\args.gn | Select-String pgo      # chrome_pgo_phase=0
  .\init_tools\150\depot_tools\gn.bat gen out\winx64r      # Done. Made ... targets
  ```
- **首次发现**：2026-11-12（150.0.7871.290）

- **补充（2026-11-16，默认下载 profile + 按版本校验）**

  1. 下载脚本现在**默认**写 `custom_vars: { checkout_pgo_profiles=True, checkout_clang_coverage_tools=True }`，
     所以普通 `gclient runhooks` 就会拉 profile，不再需要显式 `--pgo`（`--no-extra-deps` /
     `--deps checkout_pgo_profiles=False` 可关闭）。之前头部的 `PGO : disabled` 只表示
     `--pgo` 没传，容易误解成"没下 profile"，现已拆成两行：
     ```text
      PGO profiles: yes (checkout_pgo_profiles=True; hooks fetch the .profdata)
      PGO build   : not forced (build auto-disables PGO when the profile is missing)
     ```
  2. 判断"有没有 profile"不能只看目录非空：`update_pgo_profiles.py` 从
     `chrome/build/<target>.pgo.txt`（如 `win64.pgo.txt`）读出**本里程碑需要的文件名**。
     旧里程碑的 `.profdata` 留在目录里并不能用。构建脚本现在按该文件精确校验，
     不匹配时打印 `Expected profile: ...` 并降级 `chrome_pgo_phase=0`。
  3. 下载结束的摘要会打印实际文件名与大小，例如：
     ```text
      PGO        : chrome-win64-150.0.7871.290-<hash>.profdata present (xxx MB) - build with --args "chrome_pgo_phase=2"
     ```
  4. 校验命令（下载完成后即可离线确认）：
     ```powershell
     Get-Content D:\chromium\.gclient | Select-String checkout_pgo_profiles
     Get-Content D:\chromium\src\chrome\build\win64.pgo.txt
     Get-ChildItem D:\chromium\src\chrome\build\pgo_profiles\*.profdata | Select-Object Name, Length
     ```

---

## PIT-014 链接 `chrome.dll` 报 `LLVM ERROR: IO failure on output stream: no space on device`

- **症状**
  ```
  [16055/16518] 2h48m22.47s E LINK(DLL) chrome.dll chrome.dll.lib chrome.dll.pdb
  LLVM ERROR: IO failure on output stream: no space on device
  Exception Code: 0xC0000005
  ```
- **触发**：`is_official_build=true`（ThinLTO）+ 磁盘剩余不足；本项目 D: 仅剩 18 GB，
  而 `out\winx64r` 已 49 GB（`thinlto-cache` 11 GB、`obj` 21 GB、PDB 约 10 GB）
- **根因**：`lld-link` 写 `chrome.dll`（~1.5 GB）+ `chrome.dll.pdb`（2+ GB）+ LTO 临时/缓存，
  需要数 GB 余量；写失败后 lld 崩溃（0xC0000005）是二次现象
- **修复（按收益排序，均不触发重编）**
  ```powershell
  cd D:\chromium\src
  # 1) ThinLTO 缓存（会自动重建）
  Remove-Item out\winx64r\thinlto-cache -Recurse -Force        # ~11 GB
  # 2) sccache 缓存（先停服务）
  & .\init_tools\150\scache\sccache.exe --stop-server 2>$null
  Remove-Item init_tools\150\scache\cache -Recurse -Force      # ~7 GB
  # 3) 仍不够时：删除不再需要的 PDB（链接会重建需要的那个）
  Get-ChildItem out\winx64r -Filter *.pdb | Remove-Item -Force # ~10 GB
  ```
- **预防**
  - 构建脚本已加**磁盘预检**：剩余 < 25 GB 时打印警告（`--check` 也会显示 `Disk free`）；
  - 长期：把仓库搬到更大磁盘（离线仓库可整体搬迁），或用 `symbol_level=1/0` 减小 PDB，
    或 `use_thin_lto=false`（省 LTO 缓存，但产物性能与链接行为会变）
- **验证**
  ```powershell
  .\init_tools\win\chromium_build_win.bat --check   # 看 Disk free 行
  ```
  腾出空间后重跑同一条构建命令即可（已完成的 16k 步不会重来）
- **首次发现**：2026-11-13（150.0.7871.290）

---

## PIT-015 耗时显示错乱：`[int]` 对 double 是四舍五入（`39s` 显示成 `0h 1m 39s`）

- **症状**：构建摘要里分段耗时和总耗时自相矛盾，甚至分段大于总耗时
  ```
  Elapsed  : gn gen 0h 0m 24s, build 0h 1m 39s, total 0h 1m 4s
  ```
  实际 `build` 只有约 39 秒。
- **触发**：`Format-Elapsed` 里写 `[int]($sec / 3600)`、`[int](($sec % 3600) / 60)`
- **根因**：PowerShell 的 `[int]` 转换对 `double` 做的是**四舍五入**（`[int]0.65 -eq 1`），
  所以 `39/60 = 0.65` 被进位成 1 分钟。ConstrainedLanguage 下 `[Math]::Floor` 不可用。
- **修复**：只在**整数**上做除法，余数先取模
  ```powershell
  function Format-Elapsed {
      param([int]$TotalSeconds)
      if ($TotalSeconds -lt 0) { $TotalSeconds = 0 }
      $rem = $TotalSeconds % 3600
      $h = [int](($TotalSeconds - $rem) / 3600)
      $m = [int](($rem - ($rem % 60)) / 60)
      $s = $rem % 60
      return ('{0}h {1}m {2}s' -f $h, $m, $s)
  }
  ```
- **验证**
  ```powershell
  cd D:\chromium\src
  .\init_tools\win\chromium_build_win.bat --build-dir out\TimeTest --targets __nope__
  # Elapsed : gn gen 0h 0m 26s, build 0h 0m 45s, total 0h 1m 13s
  ```
  `total` 应与 `Started`/`Finished` 的差值一致，且 `gn gen + build ≈ total`。
- **易踩点**：改了 `D:\git\x2\chromium_build_win.ps1` 后必须**同步**到
  `<src>\init_tools\win\chromium_build_win.ps1`，否则离线仓库跑的还是旧逻辑
  （本次就是这样先跑出一份旧的错误输出）。
- **首次发现**：2026-11-13（150.0.7871.290）

---

## PIT-016 切到分支后 `gclient sync` 悄悄拉了**完整 Chromium 历史**（浅仓库也会）

- **症状**：切到 `refs/branch-heads/7871` 之后，`gclient sync` 长时间静默，
  反复打印 `STALL DETECTED ... src (Running for 3:30:09)`；实际是 git 在跑
  ```
  git -c core.deltaBaseCacheLimit=2g fetch origin --no-tags
  git index-pack --stdin --fix-thin ... --pack_header=2,28413740
  ```
  `28413740` = 2,841 万个对象，已写入 `src\.git\objects\pack\tmp_pack_*` **33 GB**（约 10 GB/小时）。
  `--no-history` 完全没有生效。
- **触发**：三条同时成立
  1. `src` 是**浅仓库**（`fetch --no-history` 的 depth=1，`.git/shallow` 存在）；
  2. `gclient sync` 时 `src` **已经存在**（走 `_Update` 而不是 `_Clone`）；
  3. `.gclient` 里 `src` solution 是 **`managed: True`** —— 关键！
     脚本第 9 步 `Set-GclientCustomVars` 会跑
     `gclient config --name src --custom-var ... <url>`，而 `gclient config`
     **默认写 `managed=True`**，把 `fetch` 原本写的 `managed=False` 覆盖掉了。
     于是下一次 `gclient sync`（切完分支后那次）不再跳过 src，触发全量 fetch。
- **根因**（depot_tools 源码，可复核）
  - `gclient_scm.py:878`：
    ```python
    if not managed:
        self.Print('________ unmanaged solution; skipping %s' % self.relpath)
        return ...
    ```
    **managed=False 时 gclient 直接跳过 src，不会 fetch** —— 这就是 fetch 阶段
    和它的 resume sync 很安静的原因（那时 .gclient 还是 `managed=False`）。
  - `gclient_scm.py:1000`（managed=True 才走到这里）：
    ```python
    if not scm.GIT.IsValidRevision(self.checkout_path, revision, sha_only=True):
        self._Fetch(options, prune=options.force)     # 1002：不带 depth！
    ```
  - `scm.py:1180`：`sha_only` 的实现是 `return sha == rev.lower()` ——
    **revision 是引用名时永远为 False**，于是必然走 `_Fetch`；
  - `_Fetch`（`gclient_scm.py:1694`）只有在**显式传了 depth** 时才加 `--depth=N`；
    `--no-history` 只影响 `_Clone`（1413-1418）和 `_AutoFetchRef(..., depth=1)`，
    这条 `_Fetch` 路径拿不到 depth → 对浅仓库就是**全量历史**。
  - 首次同步时 `src` 还不存在，走 `_Clone` 的 depth=1 分支（所以前半段很安静）；
    切完分支再同步时 `src` 已存在且已变成 managed → 走 `_Update` → 全量 fetch。
- **为什么"上次是好的"**：上次同样触发了（就是之前见过的那次 18 GB `tmp_pack`），
  只是旧树的 `.git` 已经被撑大，后续 fetch 变成增量、几分钟结束；这次是干净浅仓库，
  同一条命令就变成从零下载 2841 万个对象。
- **修复（两层）**
  1. **让 src 保持 unmanaged**（主修复）：
     `gclient config --name src --unmanaged --custom-var ...`
     → `.gclient` 写 `managed: False` → `gclient sync` 直接跳过 src（878 行）。
     脚本 `Set-GclientCustomVars` 已加 `--unmanaged`，并且会**修正**已经写着
     `managed: True` 的旧文件（否则它会在第 9 步提前 return，不重写）。
     `--pinned` 分支的 `gclient config` 同样加了 `--unmanaged`。
  2. **给 sync 钉 40 位 sha**（兜底）：即使 `.gclient` 被手工改成 managed=True，
     `--revision src@<sha>` 也能让 `IsValidRevision(..., sha_only=True)` 命中
     （`sha == rev.lower()`），不 fetch；HEAD 已是该 sha，gclient 打印
     `Up-to-date; skipping checkout.`。
     **注意**：`src@refs/branch-heads/7871` / `src@refs/remotes/origin/main`
     这种**引用名仍然会全量 fetch**（永远过不了 sha_only）。
     脚本在 `Set-ChromiumRevision`、main 分支 sync、以及 fetch 失败后的 resume sync
     都加了 sha 钉住（resume 时 HEAD 无效则退回原命令）。
- **验证**（重新同步时应看到）
  ```powershell
  git -C D:\chromium\src rev-parse --is-shallow-repository   # true（保持浅仓库）
  Get-ChildItem D:\chromium\src\.git\objects\pack -Filter tmp_pack_*   # 无
  # gclient 输出里不应再出现 "fetch origin --no-tags"（针对 src）
  ```
- **已下载的半成品怎么清**
  ```powershell
  # 先停掉脚本进程树（父进程是 powershell -File chromium_download_win.ps1）
  taskkill /PID <script-pid> /T /F
  Remove-Item D:\chromium\src\.git\objects\pack\tmp_pack_* -Force
  ```
  然后重跑下载脚本即可（浅仓库和已完成的依赖都保留）。
- **首次发现**：2026-11-16（150.0.7871.290，分支 7871 切换后）

---

## PIT-017 导出离线仓库时报 `fatal: cannot rename the current branch while not on any`

- **症状**（`--make-offline-repo`，切版本之后）
  ```
  > git -C D:\chromium\src branch -M b7871
  fatal: cannot rename the current branch while not on any
  Command failed with exit code 128
  ```
  导出在最后提交前中断；`init_tools` 已生成、depot_tools 已被移走。
- **根因**：下载流程为了切到指定 revision，执行的是
  `git fetch --depth 1 <ref>` + `git checkout --detach <sha>`，HEAD 处于 **detached**
  状态（不在任何分支上）。`git branch -M <name>` 需要一个"当前分支"，detached 时必然失败。
- **修复**：按当前状态分三种处理（脚本已实现）
  ```powershell
  $current = (git -C <src> symbolic-ref --short -q HEAD)   # 空 = detached
  if ($current -eq $branchName) { <no-op> }
  elseif (-not $current)        { git -C <src> checkout -B $branchName }  # 附着到该提交
  else                          { git -C <src> branch -M $branchName }
  ```
- **验证**
  ```powershell
  git -C <src> symbolic-ref --short -q HEAD     # b7871
  git -C <src> log --oneline -1                 # offline repo: Chromium ...
  ```
- **补充**：导出中断后重跑是安全的 —— depot_tools 已在 `src\init_tools\<MAJOR>\depot_tools`，
  脚本会直接复用它（`Reusing exported depot_tools: ...`）而不是重新 clone；
  `.gclient` 缺失时会用 `gclient config --unmanaged` 重新生成。
- **首次发现**：2026-11-17（150.0.7871.290，导出 7871 离线仓库时）

---

## PIT-018 离线仓库"导出成功"，但 `git clone` 出来依赖/工具链是空目录（gitlink/submodule）

- **症状**：`--make-offline-repo` 正常提交、`git status` 干净，但仓库里查不到
  `win_toolchain`、`v8`、`angle`、`skia` 等依赖内容；从仓库 clone/checkout 后
  `third_party\depot_tools` 是空目录，构建直接失败。
- **触发**：Chromium 的索引里有 **265 个 mode `160000`（gitlink/submodule）** 路径，
  其中 **137 个有实际内容（本树约 20 GB）**，包括
  `third_party/depot_tools`（含 7.8 GB `win_toolchain`）、`v8`、`third_party/angle`、
  `third_party/skia`、`third_party/devtools-frontend/src`、`third_party/swiftshader` 等。
- **根因**：`git add -A -f` **不会进入 gitlink**，只把该路径的 commit 指针写进索引；
  即使导出前删掉了嵌套 `.git`，索引里的 160000 模式不变。于是提交树里只有：
  ```
  $ git ls-tree HEAD -- third_party/depot_tools
  160000 commit f4fadaf...  third_party/depot_tools
  ```
  一个文件都没有。注意这与 `.gitignore`/`-f` 无关，是 **gitlink 模式**导致。
- **诊断**
  ```powershell
  cd <src>
  git ls-files -s -- third_party/depot_tools        # 160000 ... => 只是指针
  git ls-files -s | Select-String '^160000' | Measure-Object -Line   # 265
  git ls-tree -r --name-only HEAD -- third_party/depot_tools | Measure-Object -Line  # 1（gitlink）
  ```
- **修复**：对每个**有内容**的 gitlink 转成普通文件（空目录保持原样）
  ```powershell
  git rm --cached -q -- <path>
  git add -f -- <path>
  ```
  转换后索引变成 `100644`/`100755`，提交树里就是真实文件；从 clone 出来的目录有内容。
  脚本已在导出流程中加入这一步（`Converting populated submodules (gitlinks) ...`，
  日志 `Converted N submodule path(s) to tracked content (X GB)`）。
- **验证**
  ```powershell
  git ls-files third_party/depot_tools | Measure-Object -Line      # 2 万+（原来是 1）
  git ls-tree -r --name-only HEAD -- third_party/depot_tools/win_toolchain | Measure-Object -Line  # 1 万+
  git clone --no-checkout <src> <tmp>; git -C <tmp> ls-tree -r --name-only HEAD -- third_party/depot_tools/win_toolchain | Measure-Object -Line
  ```
- **代价**：`.git` 增加约 6–10 GB（本树 20 GB 源文件），提交耗时较长；磁盘要预留空间。
- **首次发现**：2026-11-17（150.0.7871.290，导出 7871 离线仓库后核查工具链是否入库）
- **后续（2026-11-17）**：导出策略已改为**一律全删 `.git` 并重建**（ADR-012 / PIT-019），
  新仓库索引为空，从根上不存在 gitlink，因此不再需要 `git rm --cached` 转换；
  本条保留作为"为什么删嵌套 `.git` 还不够"的原理说明。

---

## PIT-019 离线导出新策略：备份 `.git` → 全删 → 重建 → 两次提交 → 清理备份

- **目的**：让离线仓库**只包含真实文件**（不再有 submodule 指针），且不再依赖
  "删嵌套 `.git` + 转换 gitlink" 这类容易出错的步骤。
- **流程**（`--make-offline-repo`）
  1. 把所有 `.git`（**包括 `src\.git`**）**移动**到 `<root>\src_git_bak\`，保留相对结构：
     - `src\.git` → `src_git_bak\.git`
     - `src\third_party\foo\.git` → `src_git_bak\third_party\foo\.git`
     （同卷移动，瞬时且不占双份空间）
  2. 把所有 `.gitignore` **复制**到 `<root>\src_gitignore_bak\`（保留相对结构），然后从源码树删除；
     导出的仓库只保留脚本生成的根 `.gitignore`（`/out/`、`*.log`、`__pycache__` 等）。
  3. 删除 `__pycache__` / `*.pyc`。
  4. `git init` 新仓库，分支 `b<BUILD>`（或 `main`）。
  5. **提交 1/2**：原始源码树（排除 `out\`、`build/win_toolchain.json`、`init_tools\`）。
  6. 组装 `init_tools\<MAJOR>\{config,depot_tools,scache}` 与 `init_tools\win`，**提交 2/2**。
  7. 完成标记 `<src>\init_tools\.offline_repo.state`（Windows 隐藏属性）**随 commit 2/2 提交**；
     只有显式 `--cleanup` 才清理下载现场（失败则全部保留）：
     - 删除 `src_git_bak` 与 `src_gitignore_bak`；
     - 删除根目录的 `.gclient` / `.gclient_entries` / `.gclient_previous_custom_vars` /
       `.gclient_previous_sync_commits` / `.gcs_entries`；
     - 删除 `<root>\.cipd`、`<root>\depot_tools` 与 sccache 构建缓存。
- **默认模式（不加 `--cleanup`）就是可复用现场**：用于"并库/导出失败后还要复用"
  - `depot_tools` **复制**进 `init_tools`（跳过 `.git`），原 `<root>\depot_tools` 及其 `.git` 保留；
  - `.gclient*` / `.gcs_entries` 只**复制**到 `init_tools\<MAJOR>\config`，根目录原件保留；
  - `src_git_bak` / `src_gitignore_bak`、`<root>\.cipd`、sccache 构建缓存都保留；
  - 加 `--cleanup` 时：移动 depot_tools，成功后删除备份、根目录 5 个状态文件、`.cipd` 与缓存。
- **失败时**：备份目录保留（日志会打印路径），工作区文件不受影响；可手工把
  `src_gitignore_bak\...` 复制回去、把 `src_git_bak\...\.git` 移回原位后重试。
  默认模式原始 depot_tools 一直在，直接重跑即可。
- **重复运行**：成功后标记存在且 branch/ref/version（及 deps 指纹）一致（给了
  `--win-toolchain-url` 时要求 URL + 本地 `<hash>.zip` 名称/大小/mtime 一致）
  → 直接跳过全部网络步骤；要强制重导就删除
  `<src>\init_tools\.offline_repo.state`（工作区变脏同样会走全流程）。
- **易踩点**
  - 顺序：必须先**移动所有 `.git`**，再 `git init`；否则 `git add` 会把子目录当
    "嵌入式仓库"（gitlink）。
  - `depot_tools` 是**备份阶段之后**才移进 `init_tools` 的，它自带的 `.git` 要单独删除
    （脚本会打印 `Removed depot_tools .git`）。
  - 相对路径不能用 `Substring($Src.Length + 1)` 直接算：`--dir` 可能是 **8.3 短路径**
    （如 `C:\Users\ZHANGF~1.ZFJ\...`），而 `Get-ChildItem` 返回长路径，长度不一致会算错。
    脚本先 `$srcFull = (Get-Item -LiteralPath $Src).FullName` 归一化。
- **验证**
  ```powershell
  Test-Path D:\chromium\src_git_bak            # 默认 True；--cleanup 成功后 False
  Test-Path D:\chromium\src_gitignore_bak      # 同上
  Test-Path D:\chromium\depot_tools\.git       # 默认 True（原始检出保留）；--cleanup 后 False
  Test-Path D:\chromium\src\init_tools\.offline_repo.state   # 成功导出后 True（且已在 git 中）
  Test-Path D:\chromium\.offline_repo.state                 # 旧位置：迁移后应为 False
  git -C D:\chromium\src log --oneline          # 恰好 2 条
  git -C D:\chromium\src status --porcelain     # 空
  (git -C D:\chromium\src ls-files third_party/depot_tools | Measure-Object -Line).Lines  # 2 万+
  ```
- **首次发现**：2026-11-17（150.0.7871.290）

---

## PIT-020 离线仓库里的 `win_toolchain` 被 git 行尾规范化改坏 → `unexpected value ... removing it`

- **症状**（`gn gen`，使用 `--win-toolchain-url` 的离线仓库）
  ```
  Calculating hash of toolchain in vs_files\fab72fa52c. Please wait...
  The hash of a version of the toolchain has an unexpected value
  (a3962485862404994327d53b382a23b5fbf8d62e instead of fab72fa52c), removing it.
  Removing old toolchain in 1s...
  ```
  之后 `vs_files` 变空，`get_toolchain_if_necessary.py --no-download` 失败，`gn gen` 报
  `Toolchain is out of date` / `Script returned non-zero exit code`。
- **根因**：Chromium 的 `.gitattributes` 有
  ```
  # Force LF checkout for all source files
  *.h text eol=lf
  *.idl text eol=lf
  ```
  这些规则对 `third_party/depot_tools/win_toolchain` 同样生效。导出时 `git add` 把工具链里的
  文本文件 CRLF→LF，**字节变了**；而 `get_toolchain_if_necessary.py:CalculateHash` 是
  `sha1(小写相对路径 + 文件字节)`，于是内容哈希从 `fab72fa52c` 变成 `a3962485...`，
  gclient 认为"损坏"就删掉了。
- **证据**（原始 zip vs git blob）
  | 文件 | 原始 zip | git blob |
  |---|---|---|
  | `DIA SDK/idl/dia2.idl` | 79,618 B | 77,257 B（少 2,361 B） |
  | `DIA SDK/include/cvconst.h` | 127,988 B | 123,717 B（少 4,271 B） |
- **修复（方案 A：保留原始字节）**
  1. 导出时**先从原始 `<hash>.zip` 重新解压** 到
     `<src>\third_party\depot_tools\win_toolchain\vs_files\<hash>`
     （之前 checkout 过的目录可能已经被 LF 化）；
  2. 在 `git add` **之前**往根 `.gitattributes` 追加：
     ```
     third_party/depot_tools/win_toolchain/** -text -diff
     ```
     后加的规则优先级更高，`-text` 让 git 不做 CRLF 转换（`git check-attr text` 显示 `unset`）。
  脚本已按此实现（`Re-extracting pristine win_toolchain ...` /
  `Added "-text -diff" rule ...`）。
- **临时恢复（不改仓库）**：直接从 zip 解压，不要再对该目录 `git checkout/reset`：
  ```powershell
  $dest = '<src>\third_party\depot_tools\win_toolchain\vs_files\<hash>'
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  tar -xf '<dir>\<hash>.zip' -C $dest
  ```
- **验证**
  ```powershell
  git -C <src> check-attr text -- 'third_party/depot_tools/win_toolchain/vs_files/<hash>/DIA SDK/include/cvconst.h'
  # 期望：... text: unset
  (Get-ChildItem '<src>\third_party\depot_tools\win_toolchain\vs_files' -Directory).Name  # <hash> 仍在
  ```
  构建时不再出现 `unexpected value ... removing it`。
- **注意**：已经用旧逻辑导出的仓库，其 blob 已经是 LF 版本 —— 必须**重新导出**（或从 zip 手工解压）
  才能根治；加规则本身不会修复旧 blob。
- **首次发现**：2026-11-18（150.0.7871.290，从离线仓库 checkout 后构建）

- **补充（2026-11-18，第二层失败：`Invalid token` + 工具链被删）**
  - **症状**：
    ```
    ERROR at dynamically parsed input ... :1:42: Invalid token.
    Calculating hash of toolchain in vs_files\fab72fa52c. Please wait...
                                             ^
    ```
    随后 7.8 GB 的工具链目录**又消失**了。
  - **根因**：
    1. `win_toolchain\<短hash>.timestamps` 缺失/过期（`git checkout`、robocopy、重新解压都会改 mtime）；
    2. `get_toolchain_if_necessary.py` 因此**重新计算哈希**，并把
       `Calculating hash ...` 打到 **stdout**；`gn` 把 `vs_toolchain.py` 的 stdout
       当作 GN 代码解析 → `Invalid token`；
    3. 重算后它用**40 位哈希**写 timestamps（`<full>.timestamps`），而
       `RemoveUnusedToolchains()` 只认**目录名对应的短 hash** 文件
       （`fab72fa52c.timestamps`）→ 判定"无主" → `RemoveToolchain()` 删除目录和 timestamps。
  - **修复**：
    * **构建脚本**：`gn gen` 之前调用 `Update-ToolchainTimestampCache`
      （depot_tools python 的 `SaveTimestampsAndHash('vs_files', '<短hash>')`），
      日志 `Toolchain cache: refreshed <hash>`；`--check` 不做（保持只读）。
    * **导出脚本**：重解压原始 zip 后也刷新一次短 timestamps
      （日志 `Refreshed toolchain timestamps: <hash>.timestamps`）。
    * **重要**：任何 `git checkout`/复制都会改 mtime，所以必须以**构建时刷新**为准；
      只加 `-text` 规则并不能解决"首次 gn 前没有 timestamps"的问题。
  - **验证**：真实构建日志出现 `Toolchain cache: refreshed fab72fa52c`，
    `gn gen` 不再打印 `Calculating hash`，工具链目录保持 12,654 个文件。

---

## PIT-021 `gclient sync -D` 清理"已移除依赖"时报 `fatal: bad object <sha>`

- **症状**（切分支/同步依赖时，重试多次都一样）
  ```
  Syncing projects: 100% (238/238), done.
  Error: Command 'git -c core.quotePath=false diff --name-status 7483ad8a...' returned non-zero exit status 128 in ...\third_party\ml_drift\src
  fatal: bad object 7483ad8a5181b220a19bcc20ec02dbe9c040c100
  ```
  `sync attempt N/11 failed` 会一直重复（不是 429，重试无效）。
- **触发条件**（三者同时成立）
  1. `.gclient_entries` 里记录了一个**当前 DEPS 已不存在**的依赖
     （典型：main 新增的 `ml_drift`，7871 分支没有）；
  2. 本地那个依赖仓库**不可用**：`.git` 是空的（`git init` 后 fetch 失败/中断，没有 HEAD），
     或者 HEAD 存在但**缺少记录里的那个 revision**；
  3. sync 带了 `-D`（脚本为了自动清理过期依赖而加）。
- **根因**：gclient 的"多余依赖"清理逻辑会先执行
  `git diff --name-status <记录里的 revision>` 判断有没有本地修改，再决定删除；
  它假设那个 revision 一定在本地仓库里。空仓库/浅仓库缺对象时直接 `fatal`，
  **让整次 sync 失败**（其它 238 个项目其实已经同步成功）。
  这是 gclient 的边界健壮性问题，但触发状态来自"fetch 失败残留 + 切分支 + `-D`"。
- **脚本修复**：`Remove-BrokenDependencyRepos`
  - 在每次 `gclient sync -D` 之前（分支 sync、main sync）执行；
  - 读取 `.gclient_entries`，对每个依赖检查：
    - 目录里有 `.git`，但 `git rev-parse --verify HEAD` 失败 → 不可用；
    - 或 HEAD 正常、但记录 URL 里的 40 位 sha 不存在（`git cat-file -e <sha>^{commit}` 失败）→ 不可用；
  - 把不可用的目录**移动**到 `<root>\_bad_deps\<相对路径>`，让 gclient 把它当"目录不存在"处理，
    不再做 diff；如果目标 DEPS 仍然需要它，gclient 会重新 clone；
  - 日志：`Moved unusable dependency repo: third_party\... -> ...\_bad_deps\...`。
- **手工应急**（不改脚本时）：
  ```powershell
  # 停掉脚本后，删/移走那个空依赖目录
  Move-Item D:\chromium\src\third_party\ml_drift D:\chromium\_bad_deps\ml_drift -Force
  # 或直接 Remove-Item（它没有有效提交内容）
  ```
  然后重跑；`-D` 会丢掉过期记录。
- **规避**：分支/标签目标在**全新目录**用 `--pinned`，完全不经过 main，
  也就不会记录 main 独有的依赖。
- **验证**
  ```powershell
  # 合成树测试：空 .git、缺记录 sha 的依赖被移动；正常依赖保留；CIPD 条目跳过
  # 真实日志：Moved unusable dependency repo: ... / Unusable dependency repo(s) moved: N
  git -C <dep> rev-parse --verify HEAD        # 被移走的那份本来就会失败
  ```
- **首次发现**：2026-11-18（150.0.7871.290，main 的 `ml_drift` 在 7871 不存在）

- **补充（2026-11-19：清理函数自己把 sync 弄失败了）**
  - **现象**：加了 `Remove-BrokenDependencyRepos` 之后，`gclient` 根本没启动，
    日志只有 `sync attempt N/11 failed`（没有任何 `>`/Error 行）。
  - **根因**：函数里的 `git rev-parse --verify HEAD` / `git cat-file -e` 在"对象缺失"
    这种**预期**情况下会往 stderr 写 `fatal: ...`；脚本全局是
    `$ErrorActionPreference = 'Stop'`，PowerShell 5.1 会把它升级成
    `NativeCommandError` 终止错误 → 被 sync 的 `catch` 当成"同步失败"重试。
    （同时 `cat-file -e <sha>^{commit}` 的 `^` 被吞掉，报成
    `Not a valid object name <sha>{commit}`，更难看。）
  - **修复**：
    * `Remove-BrokenDependencyRepos` 内部设 `$ErrorActionPreference = 'Continue'`
      （函数作用域，不影响调用方），关键 cmdlet 显式 `-ErrorAction Stop`；
    * 用 `git cat-file -e <sha>`（纯 sha，不需要 `^{commit}`）；
    * sync 重试日志现在带上异常：
      `sync attempt N/M error: <message>`，不再只有一句"失败"。
  - **验证**：`--retries 0 --skip-hooks` 单次运行 → `Now at revision: refs/heads...` +
    `Download complete`，elapsed 1m44s；`Remove-BrokenDependencyRepos` 单独调用不再抛错。
  - **同类（2026-11-19，构建脚本）**：`sccache --stop-server` 在**没有守护进程**时
    向 stderr 写 `couldn't connect to server` 并返回非 0；全局 `Stop` 把它变成终止错误，
    构建在打印 banner 之前就退出：
    ```
    sccache.exe : sccache: error: couldn't connect to server
    位置 ...chromium_build_win.ps1:605 ... & $sccacheExe --stop-server
    ```
    修复：先用 `sccache --show-stats` 读运行中守护进程的 `Cache location`，与目标
    目录比较；**不同才** `--stop-server`，相同/无服务不动。所有 sccache 调用都在
    `$ErrorActionPreference = 'Continue'` + `try/catch` 内（输出丢弃），无服务时
    `--stop-server` 的 `couldn't connect to server` 不会再中断构建。
    注意：无服务时 `--show-stats` 只回显客户端 `SCCACHE_DIR`（不会启动服务），
    所以"无服务"会被当作"目录已一致"，不会误停。
    验证：分别用无服务、旧目录服务、相同目录服务测试 → needRestart = False/True/False。

---

## PIT-022 `--make-offline-repo` 失败后重跑：`fatal: 'origin' does not appear to be a git repository`

- **症状**（导出在 commit 1 之后失败，例如 sccache 下载时网络中断）
  ```
    Commit 1/2: 84a699cd39
  ==> Resolving latest sccache release from GitHub
  FAILED at ...  Error: 基础连接已经关闭: 发送时发生错误。
  ```
  重新运行下载脚本时：
  ```
  ==> Shallow-fetching refs/branch-heads/7871 (depth 1)
    > git -C ...\src fetch --depth 1 origin refs/branch-heads/7871
  fatal: 'origin' does not appear to be a git repository
  ```
- **根因**：导出的 phase 1 会把**所有** `.git`（含 `src\.git`）移动到
  `<root>\src_git_bak`，然后 `git init` 一个**全新的快照仓库**。如果导出在
  commit 2 之前失败，`src\.git` 就是那个没有 `origin` 的快照仓库；
  下载脚本的 `git fetch ... origin ...` 自然失败。
  （旧行为下只能删掉整个目录重新下载。）
- **修复（自动恢复）**：`Restore-FailedExport`（下载脚本启动时、bootstrap 之后调用）
  - 条件：`src_git_bak\.git` 存在，且 `src\.git` **不存在**，或
    （没有 `origin` 且提交数 < 2）；
  - 动作：
    1. 把当前 `src\.git` 移到 `<root>\_failed_export_git_<时间戳>` 保留现场；
    2. 把 `src_git_bak` 里所有 `.git`（主库 + 所有依赖）按相对路径移回；
    3. 把 `src_gitignore_bak` 里的 `.gitignore` 复制回；
    4. `git checkout -- .gitattributes`（恢复被追加过 `-text -diff` 的版本）；
  - 之后脚本继续正常 fetch/sync/runhooks/export，**不需要重新下载源码**。
  - 日志：`Restoring the pre-export Chromium checkout ...` /
    `Restored N .git entr(ies); failed export repo kept at: ...`。
- **避免下一次失败**：
  - 导出成功后，脚本会给快照仓库补上 `origin` 远程；
    `Set-ChromiumRevision` 也会在 fetch 前检查并补 `origin`（兼容旧仓库）。
  - 依赖的完成度用"提交数"判断：**2 条提交 = 导出完成**（不会被误恢复）；
    只有 1 条（source）才视为失败。
- **sccache 网络失败的处理**
  - `Get-SccacheExe` 会**优先复用** `init_tools\<MAJOR>\scache\sccache.exe`
    （合法 PE 就跳过 GitHub API/下载）；
  - 预置方法（v0.19.0，SHA-256 `28be8c61f6b2c89b9eb2869f6af7f78e6f992e78a8abae0ce855fcc129cbeac1`）：
    ```powershell
    $tmp = Join-Path $env:TEMP 'sccache'
    Invoke-WebRequest -UseBasicParsing -OutFile "$tmp.zip" `
      -Uri 'https://github.com/mozilla/sccache/releases/download/v0.19.0/sccache-v0.19.0-x86_64-pc-windows-msvc.zip'
    Expand-Archive "$tmp.zip" $tmp -Force
    Copy-Item (Get-ChildItem $tmp -Recurse -Filter sccache.exe)[0].FullName `
      'D:\chromium\src\init_tools\150\scache\sccache.exe' -Force
    ```
- **手工恢复**（没有自动恢复时的等价步骤）
  ```powershell
  # 1) 移走失败的快照仓库
  Move-Item D:\chromium\src\.git D:\chromium\_failed_export_git
  # 2) 把所有 .git 按相对路径移回
  Get-ChildItem D:\chromium\src_git_bak -Recurse -Force -Directory -Filter .git | ForEach-Object {
      $rel = $_.FullName.Substring('D:\chromium\src_git_bak'.Length + 1)
      $dst = Join-Path 'D:\chromium\src' $rel
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
      Move-Item $_.FullName $dst -Force
  }
  # 3) 恢复 .gitignore 与 .gitattributes
  Copy-Item D:\chromium\src_gitignore_bak\* D:\chromium\src -Recurse -Force
  git -C D:\chromium\src checkout -- .gitattributes
  # 4) 校验
  git -C D:\chromium\src remote -v
  git -C D:\chromium\src status --porcelain --untracked-files=no --ignore-submodules
  ```
- **验证**：真实失败现场恢复 151 个 `.git` 后，`origin` 正确、`git status`（忽略子模块）为 0；
  随后 `--retries 0 --skip-hooks` 重跑：`Now at revision` + `Download complete`。
- **首次发现**：2026-11-19（150.0.7871.290，sccache 下载网络中断后重跑）
---

## PIT-023 sccache 下载放在 commit 1 之后：一次网络抖动就要重做整个源码提交

- **症状**（2026-11-19 实际发生）
  ```
    Commit 1/2: 84a699cd39
  ==> Resolving latest sccache release from GitHub
  FAILED ... Error: 基础连接已经关闭: 发送时发生错误。
  ```
  导出在 commit 1（整棵源码入 git，耗时很长）之后、commit 2 之前失败；
  重跑必须再做一遍 commit 1。
- **根因**：`init_tools` 属于 commit 2，但 sccache 的 GitHub API/下载放在
  phase 1（备份 + 清 `.git` + commit 1）之后才执行。网络抖动就让前一个小时的工作白做。
- **修复**
  1. **把 sccache 下载提前到 phase 1 之前**（仍然是 commit 2 的内容）：
     失败时还没备份、没提交，重跑代价很小；
  2. 下载带重试：沿用 `--retries`（默认 10 次），退避 10s、20s … 最多 120s；
     日志 `sccache attempt N/M failed: ...; retrying ...`；
  3. `init_tools` 里已存在合法 `sccache.exe` 时直接复用（不联网）；
  4. **sccache 的构建缓存**：
     - 位置：默认 `<src>\out\.cache<MAJOR>`（`out/` 已被 `.gitignore` 忽略；
       构建不会弄脏导出仓库，完成标记依赖干净工作区）；旧位置
       `init_tools/<MAJOR>/scache/cache` 仍会作为"legacy"被忽略/清理；
     - 构建脚本 `--sccache-dir DIR`（别名 `--sccache-cache-dir`）可覆盖；
     - 不进入 commit（pathspec `:(exclude)init_tools/<MAJOR>/scache/cache` 仍保留）；
     - `--cleanup` 会删除新旧两处缓存（构建时自动重建）；
     - 修改 `SCCACHE_DIR` 后需要重启 sccache 守护进程（构建脚本在目录变化时会自动
       `sccache --stop-server`，下一次编译用新目录）。
  5. 注意：**`sccache.exe` 本身必须保留**（它是离线仓库 commit 2 的一部分），
     "清理 sccache" 指的是构建缓存/临时下载，不是可执行文件。
- **验证**
  ```powershell
  # pathspec 测试：只有 exe 入库，cache 不入库
  git add -A -f -- . ':(exclude)init_tools/150/scache/cache'
  git ls-files -- init_tools/150/scache/cache      # 空
  git ls-files -- init_tools/150/scache/sccache.exe # 有
  ```
  真实环境已预置 `sccache v0.19.0`（SHA-256 `28be8c61…`），导出时日志显示
  `sccache already present`，不再访问 GitHub。
- **首次发现**：2026-11-19（150.0.7871.290，导出 commit 1 后 sccache 下载失败）
---

## PIT-024 `.git` 被外部 `git status` 锁住：导出 phase 1 报"访问被拒绝"

- **症状**（2026-11-19）
  ```
  ==> Backing up and removing all .git repositories
  FAILED ... Error: 对路径"D:\chromium\src\.git"的访问被拒绝。
  ```
  同时能看到一个长期运行的：
  ```
  C:\msys64\usr\bin\git.exe status     （pid 58984，启动 10:40，CPU 26 分钟）
  ```
- **根因**：`git status`（Git Bash / IDE / 旧终端）在超大仓库上跑了很久，
  持有 `src\.git` 内的句柄；Windows 不允许重命名被占用的目录。
  不是脚本逻辑错误，但脚本之前只会报 access denied。
- **修复（自动处理）**
  1. `Move-PathWithRetry`：所有 `.git` / depot_tools / toolchain / 迁移目录的移动
     改为 10 次重试（每次 2 秒）；
  2. 第 2、5 次失败时调用 `Stop-BlockingGitReaders`：
     **只停止运行超过 60 秒的只读 git 命令**
     （`status`/`log`/`diff`/`show`/`ls-files`/`rev-parse`/`cat-file`/`grep`/`blame`/`describe`/`name-rev`/`fsmonitor--daemon`）；
     第 8 次失败时不再限制运行时长；
  3. 绝不杀写操作：`fetch`/`clone`/`pull`/`push`/`commit`/`checkout`/`reset`/`gc`/`repack`/`index-pack`/`maintenance`；
     （2026-11-20 收紧，见 ADR-015：子命令按位置解析、只读允许名单、`-C`/`--git-dir` 归属过滤）
  4. 移动主 `.git` 前先 `git -C <src> fsmonitor--daemon stop`（escalation）。
  5. 日志：`Stopped long-running read-only git process: pid ...`。
- **残余限制（ADR-015）**：cwd 方式运行在**其他仓库**里的只读 git 进程仍可能被停
  （WMI 无法获取进程工作目录）；fsmonitor 守护进程被停后随下一次 git 命令自动重启。
- **仍然需要人工的情况**：占用者不是 git（IDE 的文件监听、资源管理器预览、
  杀毒扫描）。这时重试/杀 git 都无效，最终错误会列出正在运行的 git 进程并提示关闭对应窗口。
- **验证**
  ```powershell
  # 复现：在 Git Bash 里对仓库跑一个长时间 git status，然后执行导出
  # 期望：日志出现 Stopped long-running read-only git process: pid ...，移动成功
  ```
  机制级冒烟测试见 `VERIFY.md` 2026-11-20「停进程机制收紧（ADR-015）」行。
- **首次发现**：2026-11-19（150.0.7871.290，MSYS2 `git status` 锁住 src\.git）
---

## PIT-025 清理恢复残留：`_bad_deps` / `_bad_scm` / `_failed_export_git_*`

- **背景**：
  - `Remove-BrokenDependencyRepos` 会把不可用依赖移到 `<root>\_bad_deps`；
  - **gclient 自己**会把损坏的 SCM checkout 移到 `<root>\_bad_scm`
    （`depot_tools/gclient.py` 的 `bad_scm_dir_name`）；
  - `Restore-FailedExport` 会把失败的快照仓库移到 `<root>\_failed_export_git_<时间戳>`。
  这些目录**不是可复用的下载现场**，成功后应当自动回收。
- **行为**：`Remove-TransientDirs` 在**成功**结束时删除：
  - `<root>\_bad_deps`
  - `<root>\_bad_scm`
  - `<root>\_failed_export_git_*`
  调用点：导出成功（commit 2 之后）与仅下载成功（Download complete 之前）。
- **注意**：
  - **即使不加 `--cleanup` 也会删除**（`--cleanup` 控制的是 depot_tools/.gclient/备份，
    不是这些坏仓库/失败快照）；
  - 失败时**保留**，便于恢复/诊断；下一次成功运行再清理；
  - 若文件被占用，会打印 `Could not fully remove: ...`，不会阻塞流程。
- **验证**
  ```powershell
  Test-Path D:\chromium\_bad_deps                 # 成功后 False
  Test-Path D:\chromium\_bad_scm                  # 成功后 False
  Get-ChildItem D:\chromium -Directory -Filter '_failed_export_git_*'   # 空
  ```
- **首次发现**：2026-11-19（`_bad_scm` 于 2026-11-20 补充）

---

## PIT-026 在 env.bat 环境里重跑下载脚本：depot_tools 被克隆进 init_tools，gclient config 失败

- **症状**
  ```
  ==> Cloning depot_tools into D:\chromium\src\init_tools\150\depot_tools
  ==> Enabling .gclient custom_vars: ...
  FAILED ... Error: 找不到路径 "D:\chromium\src\init_tools\150\config"，因为该路径不存在。
  ```
- **触发**：先 `call init_tools\win\env.bat`（或终端里仍带着 `GCLIENT_FILE` /
  `DEPOT_TOOLS_PATH`），然后在同一个 cmd 里重跑 `chromium_download_win.bat`，
  且 `<src>` 里已经没有 `chrome\VERSION`（源码被删，或清理后只剩 `init_tools`）。
- **根因**
  1. `env.bat` 是为**构建**导出的：
     `DEPOT_TOOLS_PATH=<src>\init_tools\<MAJOR>\depot_tools`、
     `GCLIENT_FILE=<src>\init_tools\<MAJOR>\config\.gclient`；
  2. 下载脚本直接采信这两个变量，把 depot_tools 克隆到了**源码树内部**
     （克隆本身创建了 `<src>` 目录）；
  3. 脚本只改了自己的 `$GclientFile`，**没有同步环境变量**；`fetch.bat` /
     `gclient.py` 子进程仍按 `GCLIENT_FILE` 写配置 → 写到不存在的
     `init_tools\...\config\.gclient`；
  4. "源码是否存在"只判断 `Test-Path <src>`，没检查 `chrome\VERSION`，
     于是跳过 fetch，直接去 `init_tools\...\config` 执行 `gclient config`。
- **修复**
  1. 指向 `<src>` 内部（或 `<root>\*\init_tools\*`，覆盖改名后的 `--dest-name`）的
     `DEPOT_TOOLS_PATH` / `GCLIENT_FILE` **一律忽略**，改用 `<root>\depot_tools` /
     `<root>\.gclient`；
  2. **同步子进程环境变量**：`$env:DEPOT_TOOLS_PATH` / `$env:GCLIENT_FILE` 设为
     解析后的工作区路径（bootstrap 之后再设一次 depot_tools）；
  3. 预先创建 `$GclientFile` 的父目录（外部自定义路径也不怕）；
  4. 复用导出仓库里的 depot_tools 仅限**真实 checkout**（有 `chrome\VERSION`）；
  5. "源码存在"改为判断 `chrome\VERSION` 是否存在；
  6. 不是 checkout 的 `<src>` 自动移到 `<root>\_stale_src_<时间戳>`（**不删数据**），
     然后按全新下载流程 fetch；
  7. `Invoke-Gclient` 在配置目录缺失时自动创建，避免 `Push-Location` 的裸路径错误。
- **验证**
  ```powershell
  Test-Path D:\chromium\src\chrome\VERSION                        # True 才是有效源码
  Get-ChildItem D:\chromium -Directory -Filter '_stale_src_*'     # 被移走的残留（确认后可删）
  # env.bat 残留时（3 种情况：无 VERSION / 有 VERSION / --dest-name 改名）：
  # 脚本内部的 GCLIENT_FILE / DEPOT_TOOLS_PATH 都应是 <root>\.gclient / <root>\depot_tools
  ```
- **首次发现**：2026-11-19（150.0.7871.290；env.bat 残留 + 源码删除/配置目录缺失）

---

## PIT-027 对已导出快照重跑下载脚本（不带 `--make-offline-repo`）会 checkout 真实分支并删掉 init_tools

- **风险/症状**：导出成功后，在同一个 `<root>` 运行
  `chromium_download_win.bat --dir <root> --version <同版本>`（**没有**
  `--make-offline-repo`）。旧逻辑把快照当普通工作区：
  1. `gclient config` 重写 `.gclient`；
  2. `git fetch --depth 1 origin refs/branch-heads/...`；
  3. `git checkout --detach <真实 Chromium sha>`。
  结果：`init_tools`（commit 2 跟踪）和 `init_tools\.offline_repo.state` 被
  checkout 删除，工作区变成真实 Chromium，随后联网 `gclient sync`。
  `b7871` 分支上的 2 个快照提交还在，但“拷走即可离线构建”的仓库已被破坏。
- **根因**
  1. 完成标记的检查被 `if ($MakeOfflineRepo -and ...)` 门控，不带参数时根本不执行；
  2. “源码存在”只判断 `<src>\chrome\VERSION`，快照满足 → 跳过 fetch，
     直接进入“切换/更新版本”流程（`Set-ChromiumRevision` 的 fetch+checkout）。
- **修复**
  1. 快照检测（标记存在，或 **2 个提交 + 我们的提交信息**）在 bootstrap 之前执行，
     **不再依赖 `--make-offline-repo`**；
  2. 同 branch/ref/version/deps/工具链 → 直接跳过（零网络）；
  3. 快照存在但请求不一致（版本/依赖/工具链变了，或标记被删）：
     - 不带 `--make-offline-repo` 且不是 `--skip-fetch` → **拒绝执行（exit 3）**，
       打印原因与选项，不做任何 fetch/checkout；
     - 带 `--make-offline-repo` → 显式刷新/重导出。
- **验证**
  ```powershell
  # 合成快照（2 个提交 + 隐藏标记）：
  #   带/不带 --make-offline-repo、同版本        -> "already complete", exit 0
  #   不带 + --version 7872                      -> "refusing to update", exit 3
  #   删除标记后再跑（不带）                     -> 仍识别为快照并拒绝
  ```
- **首次发现**：2026-11-20（用户实际误跑；随后删除了源码树）

---

## PIT-028 完成标记的 `commit1` 被写成字面量 `HEAD~1`，导致跳过判定永远失败

- **症状**：快照明明完整，`--make-offline-repo` 同版本运行时却从不打印
  `already complete`；总是进入 `Shallow-fetching refs/branch-heads/...`，
  下载几十万对象后再 `git checkout` 真实分支（会删掉 `init_tools`）。
- **根因**：标记在 **commit 2 之前**写入，此时 HEAD 还是 commit 1；
  代码却执行 `git rev-parse 'HEAD~1'`。该 revision 尚不存在，git 把参数
  **原样打印**到 stdout，于是标记里出现：
  ```
  commit1=HEAD~1
  ```
  `Test-OfflineRepoComplete` 比较 `HEAD~1`（真实 40 位 sha）与字面量
  `HEAD~1` → 永远不相等 → 不跳过。
- **修复**
  1. 写标记时改用 `HEAD`（此时就是 commit 1），并校验 `^[0-9a-f]{40}$`，
     否则直接报错，不再写入坏值；
  2. 已有快照修复：把 `commit1` 改成 `git rev-parse HEAD~1` 的完整 sha，
     再 amend commit 2（commit 1 不变，标记仍有效）。
- **验证**
  ```powershell
  # 标记与仓库：
  Select-String D:\chromium\src\init_tools\.offline_repo.state -Pattern '^commit1='
  git -C D:\chromium\src rev-parse HEAD~1
  # 两者必须一致（40 位 sha）
  # 隔离调用 Test-OfflineRepoComplete -> True
  # 再跑 --make-offline-repo -> "already complete", ~5s, 无 fetch
  ```
- **首次发现**：2026-11-20（150.0.7871.290；12:17 导出的标记）
