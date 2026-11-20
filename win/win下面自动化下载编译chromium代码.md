
# win下面自动化下载编译chromium代码

## 01 chromium代码中可以找到指定的depot_tools 版本

**可以根据代码根目录下的 `DEPS` 中的 `src/third_party/depot_tools` 确定 `chromium` 版本对应的 `depot_tools` 版本**

[https://source.chromium.org/chromium/chromium/src/+/main:DEPS](https://source.chromium.org/chromium/chromium/src/+/main:DEPS)
```
  'src/third_party/depot_tools':
    Var('chromium_git') + '/chromium/tools/depot_tools.git' + '@' + 'c4cdaeebba9b9ed92d041997317ffdbd042158ac',
```

## 02 

DEPOT_TOOLS_WIN_TOOLCHAIN=1      # 必需；不设也等于 1

依据：vs_toolchain.py:104 和 :529
bool(int(os.environ.get('DEPOT_TOOLS_WIN_TOOLCHAIN', '1')))
- 1 → 走 depot_tools 下载/配置工具链；
- 0 → 才回落到本机安装的 Visual Studio。


变量	作用	建议
DEPOT_TOOLS_WIN_TOOLCHAIN_BASE_URL	留空 → 用内部 gs://chrome-wintoolchain/；设为 https://… 或 file://… 才走自建镜像/本地 zip（get_toolchain_if_necessary.py:277-290）	留空，别设成 https/file，否则绕开内部 bucket
GYP_MSVS_HASH_<TOOLCHAIN_HASH>	把你自己的 zip hash 映射成规范 hash（vs_toolchain.py:493-499）	只有"自带 zip"才需要；你这个版本 TOOLCHAIN_HASH = e66617bc68（vs_toolchain.py:62），键名即 GYP_MSVS_HASH_e66617bc68
DEPOT_TOOLS_WIN_TOOLCHAIN_ROOT	工具链解压根目录，默认 depot_tools/win_toolchain（get_toolchain_if_necessary.py:38/516）	一般不用动
GYP_MSVS_OVERRIDE_PATH	已有解压好的工具链时直接指过去，跳过下载/检测（vs_toolchain.py:133）	想复用已下载的工具链时用
CHROME_HEADLESS=1	跳过"9 秒后删除旧工具链"的倒计时（:322），给 CI 用	无人值守时设



src/build/vs_toolchain.py + depot_tools/win_toolchain/get_toolchain_if_necessary.py


- 脚本默认就是 DEPOT_TOOLS_WIN_TOOLCHAIN=1，所以"内部直下"只需要：认证 + 不传 --win-toolchain-url；
- 一旦传了 --win-toolchain-url file://D:/win_toolchain_archive/，脚本会设 DEPOT_TOOLS_WIN_TOOLCHAIN_BASE_URL 并写 GYP_MSVS_HASH_<canonical>=<本地zip hash>（你那个 fab72fa52c.zip），走的就是"外部镜像"那条路，不会碰内部 bucket；


next time Git touches it
  > git -C D:\chromium rm -r --cached --ignore-unmatch src/out out
==> Committing offline repository
  > git -C D:\chromium -c user.name=offline-repo -c user.email=offline-repo@localhost commit -m init: Chromium 150.0.7871.290 offline repository
Auto packing the repository for optimum performance.
See "git help gc" for manual housekeeping.
Enumerating objects: 1011567, done.
Counting objects:  17% (172841/1011567)

.\chromium_build_win.bat --dir D:\chromium --version 7871 --make-offline-repo --release --targets content_shell --win-toolchain-url "file://D:/win_toolchain_archive/" 为啥没有编译 content_shell ?
init_tools 应该放入 src 目录下，.gitignore 也应该放入src 目录下，仓库的根目录是 src，不能修改原来chromium 主目录的代码，.git 也应该是在 src 下的；后续也可能修改src名字的



“有没有一种 agent 插件，可以把我的项目中的内容都记录下来，不停的完善和修正，到项目完成时，能给出一个最简路径实现的全过程文档或者流程的记录，这样，我下次重新改项目的流程会顺畅或者从零开始做类似项目的时候，可以大量借鉴已完成工作，少走弯路” 这段话，怎么用AI相关度比较高的，且相对专业方式描述出来

下面给你四种"专业度递进"的表述，任选或组合使用。
1. 一句话（评审/立项时用）
我希望引入一层项目级持久记忆与知识蒸馏能力（project-level persistent memory & knowledge distillation）：持续采集开发过程中的会话轨迹、架构决策与失败模式，将其收敛为结构化、可溯源、可验证的项目知识，并在里程碑自动合成一份可执行的最小路径运行手册（executable runbook），以降低后续变更的回归成本，并支持同类项目的跨项目复用。
英文版（AI 语境里更常用）：
I'm looking for an agentic workflow with persistent project memory: continuously capture session traces, design decisions, and failure modes; consolidate them into structured, provenance-linked, verifiable knowledge; and synthesize an executable minimal-path runbook at each milestone — to accelerate future changes and cross-project bootstrapping.
2. 结构化需求描述（PRD / issue 风格）
背景与能力缺口（capability gap）
当前 agent 具备单会话内的推理与执行能力，但缺少跨会话、跨项目的长期记忆与知识蒸馏层。过程信息随会话丢失，导致重复踩坑、重复调研、流程知识无法沉淀与迁移。
目标（Objective）
构建"采集 → 蒸馏 → 合成 → 验证 → 复用"的自改进闭环（self-improving loop），把一次性开发过程转化为可复用的程序性知识（procedural knowledge）。
能力要求
能力	说明	AI 术语
持续采集	自动/半自动记录会话、命令、报错、决策	episodic memory / session telemetry
知识蒸馏	去噪、去重、归纳、升级为通用规则	memory consolidation / distillation
产物合成	生成 ADR、坑位库、runbook、验收清单	artifact synthesis
可执行验证	每条路径都有可运行命令与验收标准	executable spec / acceptance test
检索与复用	按 context 召回，跨项目迁移	RAG grounding / skill reuse
溯源与保鲜	结论可回溯到 commit/会话；过期可标注	provenance / staleness
产出物（Artifacts）
STATE.md（架构与约束）、DECISIONS.md（ADR）、PITFALLS.md（失败模式库：症状→根因→修复→预防）、RUNBOOK.md（最小路径 SOP）、VERIFY.md（验收/回归脚本）、索引（供检索召回）。
质量属性（Non-functional）
低噪声（signal-to-noise）、可溯源、幂等更新、去重、防幻觉（结论必须经验证）、人机协同（human-in-the-loop）、可移植（不绑定单一会话/工具）。
验收标准（Acceptance Criteria）
1. 干净环境从零按 RUNBOOK 执行一次即可复现结果；
2. RUNBOOK 每一步都可执行、可校验，失败有分支说明；
3. 每条知识点都能溯源到具体 commit / 会话 / 文件行号；
4. 同类新项目可复用 ≥80% 的 runbook 与坑位库（只改环境变量与版本）。
3. 可直接作为 prompt 的需求描述
你是一个项目知识管家（project knowledge steward），具备长期记忆与知识蒸馏职责。
采集：在以下时机把信息结构化写入 docs/：做出非显然取舍（→ ADR）、遇到非显然失败（→ 失败模式条目，含症状/根因/修复/预防/验证命令）、发生结构变更（→ 状态文档）。
蒸馏：里程碑时读取 docs/ + git log，去重、归纳、标注过期项，把情景性记录升级为通用规则。
合成：输出可执行的 RUNBOOK（编号步骤 + 每步验证命令 + 失败分支），并生成/更新 VERIFY。
约束：结论必须可溯源（commit/文件:行/会话）；不确定的标注"未验证"；不写入密钥；不修改业务代码。
目标：让下一次变更可快速回归，让同类项目可从零复用。
4. 术语对照（你原话 → 专业表述）
你的说法	专业术语
把项目内容都记录下来	project-level persistent memory / episodic capture
不停完善和修正	memory consolidation / iterative refinement
最简路径实现的全过程文档	executable runbook / minimal-path SOP
下次改流程更顺畅	faster regression / change enablement
从零做类似项目可借鉴	cross-project transfer / skill & procedure reuse
少走弯路	reduce search cost / avoid repeated failure modes
（隐含）不瞎编	provenance-linked, verified knowledge / hallucination guard
如果你要把这段话直接写进仓库（比如 docs/VISION.md 或 issue 模板），我可以按第 2 节的格式生成一份正式文档。


结合上2次会话，给出一个相对完整的方案，并且给出实现方案的操作步骤，我不太懂上面的方案具体怎么做，能相对比较完善一些，另外实现了方案后，我要怎么用，才能让方案生效，生效后，我要怎么验证方案生效了

/pitfall /journal /distill /verify-runbook
zhangfengjiang.zfj@alibaba-inc.com

mkdir -p build && cd build

rem cmd.exe: 单引号不是引号。长参数优先 --args-file（每行一个 key = value）
.\init_tools\win\chromium_build_win.bat --dir D:\chromium --release --ide vs2022 -j16 --targets chrome --args-file gn_args.txt

rem 或者整段用双引号包住，内部 GN 引号写成 \"（--release 已包含 is_debug=false）
.\init_tools\win\chromium_build_win.bat --dir D:\chromium --release --ide vs2022 -j16 --targets chrome "--args=target_os=\"win\" target_cpu=\"x64\" is_official_build=true symbol_level=1"


dsh --profile headless 
dsh --profile tui
dsh web --no-open --port 8080



.\prepare_win_toolchain.bat --dir C:\wt --install-deps --chromium-version 7871



am start -n com.afree.demo/.MainActivity -e url 'https://www.bilibili.com/h5/vehicle-web/v2' -e ua 'Mozilla/5.0 (Linux; Android 6.0.99; AS22L Build/YunOSBuildID) AppleWebKit/537.36 (KHTML, like Gecko) Domono/3.0.0.0 Chrome/150.0.7871.255 Mobile Safari/537.36 Edg/150.0.0.0'


wget --no-check-certificate  -c --tries=0 --timeout=30 --waitretry=5 https://github.com/FFmpeg-Builds/FFmpeg-Builds/releases/download/latest/ffmpeg-n9.0-latest-linux64-lgpl-9.0.tar.xz

curl -k -L -C - --retry 999 --retry-delay 5 --retry-all-errors --connect-timeout 30 -o ffmpeg-n9.0-latest-linux64-lgpl-9.0.tar.xz https://github.com/FFmpeg-Builds/FFmpeg-Builds/releases/download/latest/ffmpeg-n9.0-latest-linux64-lgpl-9.0.tar.xz


scp -P 32890 supperapp.yunos.cn.ypp zhangfengjiang.zfj@11.167.225.81:/workspace/git/EC32_baseos_dev_ivi_Cyber_SOP_730_MY26/apps/

scp -P 33412 ffmpeg-n9.0-latest-linux64-lgpl-9.0.tar.xz zhangfengjiang.zfj@100.69.96.171:/workspace/usr/

scp -P 33412   zhangfengjiang.zfj@100.69.96.171:/tmp/obscura_bvid_download.sh ./


1 node 做一个独立的测试 bench_runner.js，可以指定url ，因为除了基准测试外，有些时候，可能也会找一些具体url看看效果
2 apk 增加一个 ObscuraBenchActivity 页，可以通过命令行指定 测试url和具体项目，如果传all的话，就是全部跑一遍，并且记录下来具体js的运行时间

