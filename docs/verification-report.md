# 需求规格说明书 & 概要设计书 验证报告

**验证日期**: 2026-06-29  
**验证范围**: 需求规格说明书 v1.2 ↔ 概要设计书 v2.5  
**验证方法**: 自动化脚本 + 人工交叉审查

---

## 一、自动化验证结果摘要

| 检查项 | 结果 | 说明 |
|:---|:---|:---|
| FR 编号连续性 (01~30) | ✅ PASS | 30 条 FR 无跳号 |
| NFR 编号覆盖 | ✅ PASS | 28 条 NFR 全部存在 |
| 追溯矩阵 FR 覆盖 | ✅ PASS | FR 清单与追溯矩阵双向一致 |
| 用例编号连续性 (01~19) | ✅ PASS | 19 个用例无跳号 |
| 关键术语一致性 | ✅ PASS | identityHash, MediaSession, SAF, Doze 等在两文档中一致 |
| 设计章节完整性 (2.1~2.13) | ✅ PASS | 13 个子章节完整 |
| Entity 注册完整性 | ✅ PASS | 7 个 Entity 均在 MusicDatabase 中声明 |
| StateEvent 覆盖 | ✅ PASS | 4 种外部回调事件均已定义 |
| FinalizeReason 覆盖 | ✅ PASS | 8 个枚举值在设计文档中全部存在 |
| 质量标记值一致性 | ✅ PASS | GOOD/SUSPECT/ABNORMAL 两文档一致 |
| NFR → 设计追溯 | ✅ PASS | 5 条重点 NFR 均有对应设计 |
| 新增模块 → FR 反向追溯 | ✅ PASS | 8 个新增模块均可追溯到 FR |

**自动化检查通过率**: 12/12 (100%)

## 二、修复的问题

| # | 问题 | 严重度 | 修复方式 |
|:--|:---|:---|:---|
| 1 | **NFR-13c（日志分级保留）在设计文档中缺失** | 中 | 更新设计文档 5.5 节三层上报机制、4.4 节 error_logs 表说明、ErrorLogDao 接口，补充分级保留策略和 `pruneBySeverity()` 查询 |

## 三、人工交叉验证结果

### 3.1 FR → 设计模块 正向追溯（全部 30 条）

| 需求编号 | 设计章节 | 状态 |
|:---|:---|:---|
| FR-01（音频捕获） | 2.2 AudioCapture + 2.4.2 接口 | ✅ |
| FR-02（元数据同步） | 2.2 MetadataSessionListener + 2.4.3 接口 | ✅ |
| FR-03（状态联动） | 3.1 状态机 + 2.4.1 RecordingOrchestrator | ✅ |
| FR-04（MP3编码） | 2.2 LAME Encoder + 2.4.5 接口 | ✅ |
| FR-05（ID3标签） | 2.2 Id3TagWriter + 2.4.6 接口 | ✅ |
| FR-06（本地存储） | 3.2 存储布局 + 4.x 数据模型 | ✅ |
| FR-07（本地播放） | 2.6 本地播放器 + 2.1 UI层 | ✅ |
| FR-07a（后台播放） | 2.6 后台播放与通知栏 | ✅ |
| FR-08（后台保活） | 3.1 START_STICKY + 2.6 前台服务 | ✅ |
| FR-09（错误诊断） | 5.x 错误处理 + 5.5 三层上报 | ✅ |
| FR-10（质量标记） | 2.2 静音检测 + 2.3 异常片段机制 | ✅ |
| FR-11（白名单管理） | 2.3 白名单机制 + TargetAppManager | ✅ |
| FR-12（服务恢复） | 3.4 启动初始化 + 4.3 recording_sessions | ✅ |
| FR-13（权限引导） | 6.2 授权引导UX | ✅ |
| FR-14（曲库管理） | 5.4 级联清理 + TrackDao | ✅ |
| FR-15（质量审核） | 4.2 abnormal_silences + UI展示 | ✅ |
| FR-16（导出功能） | 2.5 文件导出模块 | ✅ |
| FR-17（元数据兜底） | 5.3 错误场景#5 + tagStatus=3 | ✅ |
| FR-18（搜索） | 2.8 搜索与筛选模块 + SearchService | ✅ |
| FR-19（筛选） | 2.8 搜索与筛选模块 | ✅ |
| FR-20（批量删除） | 2.9 批量管理模块 + BatchOperationsManager | ✅ |
| FR-21（批量导出） | 2.9 批量管理模块 | ✅ |
| FR-22（存储空间检查） | 2.7 存储空间监控 + StorageMonitor | ✅ |
| FR-23（冲突通知） | 2.6 录制冲突切换通知 | ✅ |
| FR-24（标签回写） | 2.4.6 Id3TagWriter + retryWriteTags | ✅ |
| FR-25（播放列表） | 2.10 播放列表模块 + PlaylistDao | ✅ |
| FR-26（录制统计） | 2.7 StorageOverview | ✅ |
| FR-27（诊断报告） | 2.12 诊断报告导出模块 | ✅ |
| FR-28（重复提醒） | 2.11 重复检测模块 + DuplicateDetector | ✅ |
| FR-29（隐私模式） | 2.6 通知隐私模式开关 | ✅ |
| FR-30（路由切换） | 2.13 音频路由监听 + FinalizeReason.AUDIO_ROUTING | ✅ |

**FR 正向追溯通过率**: 30/30 (100%)

### 3.2 设计模块 → FR 反向追溯

| 设计模块（章节） | 对应 FR | 状态 |
|:---|:---|:---|
| NotificationListenerService (2.2) | FR-02, FR-03 | ✅ |
| MetadataSessionListener (2.2) | FR-02, FR-03 | ✅ |
| SessionArbiter (2.2, 2.4.4) | FR-11, FR-23 | ✅ |
| TargetAppManager (2.3) | FR-11 | ✅ |
| AudioCapture (2.2, 2.4.2) | FR-01, FR-03 | ✅ |
| RecordingOrchestrator (2.4.1, 3.1) | FR-03, FR-08, FR-12 | ✅ |
| LAME Encoder (2.2, 2.4.5) | FR-04 | ✅ |
| ID3 Tag Writer (2.4.6) | FR-05, FR-24 | ✅ |
| ExportManager (2.5) | FR-16 | ✅ |
| LocalPlayerService (2.6) | FR-07, FR-07a | ✅ |
| RecordingNotificationManager (2.6) | FR-08, FR-23, FR-29 | ✅ |
| StorageMonitor (2.7) | FR-22, FR-26 | ✅ |
| SearchService (2.8) | FR-18, FR-19 | ✅ |
| BatchOperationsManager (2.9) | FR-20, FR-21 | ✅ |
| PlaylistManager (2.10) | FR-25 | ✅ |
| DuplicateDetector (2.11) | FR-28 | ✅ |
| DiagnosticReportExporter (2.12) | FR-27 | ✅ |
| AudioRoutingListener (2.13) | FR-30 | ✅ |

**设计反向追溯通过率**: 18/18 (100%)

### 3.3 FinalizeReason 语义对齐

| FinalizeReason 枚举（设计） | 需求 UC-03 中的触发条件 | 一致 |
|:---|:---|:---|
| PAUSED | "MediaSession 状态变为 PAUSED" | ✅ |
| SKIP_NEXT | "MediaSession 切歌事件" | ✅ |
| NEW_METADATA | "收到新 metadata 且 identityHash 与当前不同" | ✅ |
| SILENCE_THRESHOLD | "连续 5s 静音" + "全静音持续 30s" | ✅ |
| AUDIO_INTERRUPTED | "AudioCapture 被系统中断" | ✅ |
| SESSION_SWITCH | "SessionArbiter 切换到更高优先级 session" | ✅ |
| EMERGENCY | "不可恢复异常触发的紧急保存" | ✅ |
| AUDIO_ROUTING | "音频路由切换超过 2s" | ✅ |

**枚举语义对齐通过率**: 8/8 (100%)

## 四、文档质量评估

### 需求规格说明书
- **结构完整度**: ⭐⭐⭐⭐⭐ 覆盖引言、总体描述、功能需求、非功能需求、验收标准、追溯矩阵
- **用例覆盖**: ⭐⭐⭐⭐⭐ 19 个用例覆盖正常流、异常流、降级模式
- **FR 粒度**: ⭐⭐⭐⭐ 30 条 FR 粒度适中，部分 P2 需求与 P0/P1 区分明确
- **验收可测性**: ⭐⭐⭐⭐ 每条 FR 有对应验收标准和测试方法

### 概要设计书
- **模块完整性**: ⭐⭐⭐⭐⭐ 20 个模块均有接口定义和数据流描述
- **接口清晰度**: ⭐⭐⭐⭐⭐ Kotlin 伪代码风格，参数和返回值语义明确
- **线程安全**: ⭐⭐⭐⭐⭐ 明确标注回调线程、状态机单线程模型
- **错误处理**: ⭐⭐⭐⭐⭐ 21 个错误场景均有处理策略和用户感知描述

### 文档间一致性
- **需求→设计追溯**: ⭐⭐⭐⭐⭐ 30/30 FR 可追溯 (100%)
- **设计→需求追溯**: ⭐⭐⭐⭐⭐ 18/18 模块可追溯 (100%)
- **术语一致性**: ⭐⭐⭐⭐⭐ 关键术语两文档一致
- **数据模型对齐**: ⭐⭐⭐⭐⭐ 7 张表字段定义对齐

## 五、结论

- **发现并修复**: 1 个问题（NFR-13c 日志分级保留在设计文档中缺失，已修复）
- **验证通过**: 需求规格说明书 v1.2 与概要设计书 v2.5 内部一致、相互完整
- **建议**: 后续每次文档变更后运行 `bash docs/verify-docs.sh` 做自动化基线检查

## 六、后续维护建议

1. 将 `docs/verify-docs.sh` 加入 CI pipeline 或 pre-commit hook
2. 当新增 FR 时同步更新：① 3.3 FR 清单 ② 5.1 验收标准 ③ 6 追溯矩阵
3. 当新增设计模块时同步更新：① 2.2 模块职责表 ② 8 里程碑
4. 版本号变更时同步更新 CLUADE.md 中的版本引用
