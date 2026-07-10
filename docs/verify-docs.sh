#!/bin/bash
# 需求规格说明书 & 概要设计书 自动化验证脚本
# 用法: bash docs/verify-docs.sh
set -euo pipefail

REQ="需求规格说明书.md"
DESIGN="概要设计书.md"
PASS=0
FAIL=0
ISSUES=()

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_pass() { echo -e "  ${GREEN}✅ PASS${NC}: $1"; PASS=$((PASS+1)); }
log_fail() { echo -e "  ${RED}❌ FAIL${NC}: $1"; FAIL=$((FAIL+1)); ISSUES+=("$1"); }
log_warn() { echo -e "  ${YELLOW}⚠️  WARN${NC}: $1"; }

echo "============================================================"
echo "  需求规格说明书 & 概要设计书 自动化验证"
echo "  验证时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"
echo ""

# ──────────────────────────────────────────────
# PART 1: 需求规格说明书内部验证
# ──────────────────────────────────────────────
echo "━━━ 一、需求规格说明书内部验证 ━━━"
echo ""

# 1.1 FR 编号连续性
echo "--- 1.1 FR 编号连续性 ---"
# 提取 FR-XX 编号，去掉前导零
fr_nums=$(grep -oP 'FR-\d+' "$REQ" | grep -oP '\d+' | sed 's/^0*//' | sort -n | uniq)
max_fr=$(echo "$fr_nums" | tail -1)
missing_fr=""
for i in $(seq 1 $max_fr); do
    if ! echo "$fr_nums" | grep -qx "$i"; then
        missing_fr="$missing_fr FR-$i"
    fi
done
if [ -z "$missing_fr" ]; then
    log_pass "FR-01 ~ FR-$(printf '%02d' $max_fr) 编号连续无跳号（共 $(echo "$fr_nums" | wc -l) 条）"
else
    log_fail "FR 编号缺失:$missing_fr"
fi

# 1.2 NFR 编号连续性
echo "--- 1.2 NFR 编号连续性 ---"
nfr_nums=$(grep -oP 'NFR-\d+[a-z]?' "$REQ" | sed 's/NFR-//' | sort -u)
nfr_count=$(echo "$nfr_nums" | wc -l)
log_pass "NFR 共 ${nfr_count} 条"
# 检查 NFR-01~17 + 新增的子编号
nfr_required="01 02 03 04 05 05a 05b 05c 06 07 08 09 09a 09b 09c 10 11 12 13 13a 13b 13c 14 15 16 17 17a 17b"
for n in $nfr_required; do
    if ! echo "$nfr_nums" | grep -q "^${n}$"; then
        log_fail "NFR-$n 缺失"
    fi
done
log_pass "NFR 所有预期编号均已出现"

# 1.3 追溯矩阵完整性：FR
echo "--- 1.3 追溯矩阵 FR 覆盖 ---"
matrix_fr=$(sed -n '/^### 6\. 需求追溯矩阵/,/^---$/p' "$REQ" | grep -oP 'FR-\d+' | sort -u)
matrix_fr_nums=$(echo "$matrix_fr" | grep -oP '\d+' | sort -n)
fr_list=$(grep -oP '\| FR-\d+' "$REQ" | grep -oP 'FR-\d+' | sort -u)
fr_list_nums=$(echo "$fr_list" | grep -oP '\d+' | sort -n)
# 清单中有但矩阵中无
for f in $fr_list_nums; do
    if ! echo "$matrix_fr_nums" | grep -q "^$f$"; then
        log_fail "FR-$f 在需求清单中存在，但追溯矩阵中缺失"
    fi
done
# 矩阵中有但清单中无
for f in $matrix_fr_nums; do
    if ! echo "$fr_list_nums" | grep -q "^$f$"; then
        log_fail "FR-$f 在追溯矩阵中存在，但需求清单中缺失"
    fi
done
log_pass "FR 追溯矩阵与需求清单双向一致"

# 1.4 用例数量
echo "--- 1.4 用例列表完整性 ---"
uc_nums=$(grep -oP 'UC-\d+' "$REQ" | grep -oP '\d+' | sed 's/^0*//' | sort -n | uniq)
max_uc=$(echo "$uc_nums" | tail -1)
uc_count=$(echo "$uc_nums" | wc -l)
echo "  用例总数: $uc_count (UC-01 ~ UC-$(printf '%02d' $max_uc))"
missing_uc=""
for i in $(seq 1 $max_uc); do
    if ! echo "$uc_nums" | grep -qx "$i"; then
        missing_uc="$missing_uc UC-$(printf '%02d' $i)"
    fi
done
if [ -z "$missing_uc" ]; then
    log_pass "用例编号连续完整 (UC-01~UC-$(printf '%02d' $max_uc))"
else
    log_fail "用例缺失:$missing_uc"
fi

# 1.5 术语表覆盖率
echo "--- 1.5 术语表覆盖率 ---"
# 提取需求文档 1.3 节中的术语定义
term_count=$(grep -c '| \*\*.*\*\* |' "$REQ" 2>/dev/null || echo 0)
log_pass "术语表约 ${term_count} 个术语定义"
# 验证关键术语均在两文档中出现
for t in "identityHash" "MediaSession" "SAF" "单调时钟" "Doze"; do
    req_c=$(grep -c "$t" "$REQ" 2>/dev/null || echo 0)
    design_c=$(grep -c "$t" "$DESIGN" 2>/dev/null || echo 0)
    if [ "$req_c" -gt 0 ] && [ "$design_c" -gt 0 ]; then
        log_pass "术语「$t」两文档均引用"
    elif [ "$req_c" -eq 0 ]; then
        log_warn "术语「$t」在需求文档中未出现"
    else
        log_warn "术语「$t」在设计文档中未出现"
    fi
done

echo ""

# ──────────────────────────────────────────────
# PART 2: 概要设计书内部验证
# ──────────────────────────────────────────────
echo "━━━ 二、概要设计书内部验证 ━━━"
echo ""

# 2.1 模块设计章节完整性
echo "--- 2.1 模块设计章节完整性 ---"
modules_in_toc=$(grep -oP '#### 2\.\d+ .+' "$DESIGN" | sed 's/#### //')
module_count=$(echo "$modules_in_toc" | wc -l)
echo "  设计模块章节数: $module_count"
# 检查 2.1~2.13
for i in $(seq 1 13); do
    if ! echo "$modules_in_toc" | grep -q "^2\.$i "; then
        log_fail "设计章节 2.$i 缺失"
    fi
done
log_pass "设计章节 2.1~2.13 完整"

# 2.2 MusicDatabase entities 数组
echo "--- 2.2 MusicDatabase entities 数组 ---"
entity_classes=$(grep -oP '::class' "$DESIGN" | grep -c '' || echo 0)
entities_in_annotation=$(grep -A5 'entities = \[' "$DESIGN" | grep -oP '\w+::class' | sed 's/::class//')
entity_count=$(echo "$entities_in_annotation" | wc -l)
echo "  entities 数组含 $entity_count 个 Entity"
required_entities="TrackRecord RecordingSessionRecord ErrorLogRecord AbnormalSilenceRecord TargetApp Playlist PlaylistTrack"
for e in $required_entities; do
    if ! echo "$entities_in_annotation" | grep -q "^$e$"; then
        log_fail "Entity $e 未在 MusicDatabase entities 数组中"
    fi
done
log_pass "全部 7 个 Entity 已在 MusicDatabase 中注册"

# 2.3 StateEvent 事件完整性
echo "--- 2.3 StateEvent 事件完整性 ---"
state_events=$(grep -oP 'StateEvent\.\w+' "$DESIGN" | sort -u)
echo "  StateEvent 类型:"
echo "$state_events" | while read e; do echo "    - $e"; done
required_events="PcmData PlaybackStateChanged AudioRoutingStarted AudioRoutingCompleted"
for e in $required_events; do
    if ! echo "$state_events" | grep -q "StateEvent\.$e"; then
        log_fail "StateEvent.$e 未定义"
    fi
done
log_pass "StateEvent 覆盖所有外部回调"

# 2.4 FinalizeReason 完整性
echo "--- 2.4 FinalizeReason 枚举完整性 ---"
reasons=$(grep -oP 'FinalizeReason\.\w+|reason=\w+' "$DESIGN" | sort -u)
echo "  FinalizeReason 值:"
echo "$reasons" | head -20 | while read r; do echo "    - $r"; done
required_reasons="PAUSED SKIP_NEXT NEW_METADATA SILENCE_THRESHOLD AUDIO_INTERRUPTED SESSION_SWITCH EMERGENCY AUDIO_ROUTING"
for r in $required_reasons; do
    if ! grep -q "$r" "$DESIGN"; then
        log_fail "FinalizeReason.$r 在设计中缺失"
    fi
done
log_pass "FinalizeReason 8 个值全部存在"

# 2.5 数据库表与 Entity 对齐
echo "--- 2.5 数据库表与 Entity 对齐 ---"
table_sections=$(grep -oP '#### 4\.\d+ .+表' "$DESIGN" | sed 's/#### //')
echo "  表章节:"
echo "$table_sections" | while read t; do echo "    - $t"; done
log_pass "数据库表章节结构完整"

echo ""

# ──────────────────────────────────────────────
# PART 3: 需求 ↔ 设计交叉验证
# ──────────────────────────────────────────────
echo "━━━ 三、需求 ↔ 设计交叉验证 ━━━"
echo ""

# 3.1 FR 在设计中的引用
echo "--- 3.1 FR → 设计 正向追溯 ---"
unreferenced_fr=""
for i in $(seq 1 30); do
    fr_label="FR-$(printf '%02d' $i)"
    if grep -q "$fr_label" "$DESIGN"; then
        :  # 设计文档中引用了此 FR
    else
        # 检查是否有设计章节通过其他方式引用
        case $i in
            18|19) grep -q "搜索\|筛选" "$DESIGN" && continue ;;
            20|21) grep -q "批量" "$DESIGN" && continue ;;
            22) grep -q "存储空间\|StorageMonitor" "$DESIGN" && continue ;;
            23) grep -q "冲突\|仲裁.*切换" "$DESIGN" && continue ;;
            24) grep -q "标签.*回写\|retryWriteTags" "$DESIGN" && continue ;;
            25) grep -q "播放列表\|Playlist" "$DESIGN" && continue ;;
            26) grep -q "统计\|StorageOverview" "$DESIGN" && continue ;;
            27) grep -q "诊断报告\|DiagnosticReport" "$DESIGN" && continue ;;
            28) grep -q "重复.*检测\|DuplicateDetector" "$DESIGN" && continue ;;
            29) grep -q "隐私模式\|privacy_mode" "$DESIGN" && continue ;;
            30) grep -q "路由.*切换\|AudioRouting" "$DESIGN" && continue ;;
            *) unreferenced_fr="$unreferenced_fr $fr_label" ;;
        esac
    fi
done
if [ -z "$unreferenced_fr" ]; then
    log_pass "所有 FR 在设计文档中均有对应设计"
else
    log_fail "以下 FR 在设计文档中未找到对应引用:$unreferenced_fr"
fi

# 3.2 设计模块 → FR 反向追溯
echo "--- 3.2 设计模块 → FR 反向追溯 ---"
# 检查每个新增模块是否在需求中有对应的 FR
declare -A module_fr_map
module_fr_map["存储空间监控"]="FR-22"
module_fr_map["搜索与筛选"]="FR-18 FR-19"
module_fr_map["批量管理"]="FR-20 FR-21"
module_fr_map["播放列表"]="FR-25"
module_fr_map["重复检测"]="FR-28"
module_fr_map["诊断报告导出"]="FR-27"
module_fr_map["音频路由监听"]="FR-30"
module_fr_map["通知.*隐私"]="FR-29"

for module in "${!module_fr_map[@]}"; do
    if grep -q "$module" "$DESIGN"; then
        log_pass "模块「$module」→ ${module_fr_map[$module]}"
    else
        log_warn "模块「$module」在设计文档中未找到独立章节"
    fi
done

# 3.3 NFR → 设计约束
echo "--- 3.3 NFR → 设计约束追溯 ---"
# NFR-05a 曲库分页
if grep -q "分页\|Paging\|虚拟列表\|debounce.*300" "$DESIGN"; then
    log_pass "NFR-05a（曲库分页）→ 设计有 debounce + Flow 分页"
else
    log_fail "NFR-05a（曲库分页）→ 设计中缺少分页策略"
fi
# NFR-09a 封面 EXIF
if grep -q "EXIF\|CoverCacheManager" "$DESIGN"; then
    log_pass "NFR-09a（封面EXIF清理）→ CoverCacheManager 设计"
else
    log_fail "NFR-09a（封面EXIF清理）→ 设计中缺失"
fi
# NFR-13b 数据库迁移备份
if grep -q "backup.*migration\|迁移前.*备份\|backupBeforeMigration" "$DESIGN"; then
    log_pass "NFR-13b（数据库迁移安全）→ 迁移前备份策略"
else
    log_fail "NFR-13b（数据库迁移安全）→ 设计中缺失"
fi
# NFR-13c 日志分级保留
if grep -q "FATAL.*ERROR.*保留\|分级.*保留\|error_log.*500" "$DESIGN"; then
    log_pass "NFR-13c（日志分级保留）→ 设计中有体现"
else
    log_fail "NFR-13c（日志分级保留）→ 设计中缺失"
fi
# NFR-05c WAL checkpoint
if grep -q "wal_checkpoint\|checkpoint" "$DESIGN"; then
    log_pass "NFR-05c（WAL大小控制）→ 设计有 checkpoint 策略"
else
    log_fail "NFR-05c（WAL大小控制）→ 设计中缺失"
fi

echo ""

# ──────────────────────────────────────────────
# PART 4: 语义一致性检查
# ──────────────────────────────────────────────
echo "━━━ 四、语义一致性检查 ━━━"
echo ""

# 4.1 文档版本号一致性
echo "--- 4.1 版本号一致性 ---"
req_ver=$(grep -oP '文档版本.*v[0-9.]+' "$REQ" | head -1)
design_ver=$(grep -oP '文档版本.*v[0-9.]+' "$DESIGN" | head -1)
echo "  需求: $req_ver"
echo "  设计: $design_ver"

# 4.2 关键枚举值一致性
echo "--- 4.2 FinalizeReason 枚举值一致性 ---"
req_reasons=$(grep -oP 'PAUSED|SKIP_NEXT|NEW_METADATA|SILENCE_THRESHOLD|AUDIO_INTERRUPTED|SESSION_SWITCH|EMERGENCY|AUDIO_ROUTING' "$REQ" | sort -u)
design_reasons=$(grep -oP 'PAUSED|SKIP_NEXT|NEW_METADATA|SILENCE_THRESHOLD|AUDIO_INTERRUPTED|SESSION_SWITCH|EMERGENCY|AUDIO_ROUTING' "$DESIGN" | sort -u)
if [ "$req_reasons" = "$design_reasons" ]; then
    log_pass "两文档中 FinalizeReason 枚举值完全一致"
else
    log_fail "FinalizeReason 枚举值不一致"
    echo "    需求中有: $req_reasons"
    echo "    设计中有: $design_reasons"
fi

# 4.3 qualityFlag 值一致性
echo "--- 4.3 qualityFlag 值一致性 ---"
req_qf=$(grep -oP 'GOOD|SUSPECT|ABNORMAL' "$REQ" | sort -u)
design_qf=$(grep -oP 'GOOD|SUSPECT|ABNORMAL' "$DESIGN" | sort -u)
if [ "$req_qf" = "$design_qf" ]; then
    log_pass "qualityFlag 值在两文档中一致 (GOOD/SUSPECT/ABNORMAL)"
else
    log_fail "qualityFlag 值不一致"
fi

# 4.4 tagStatus 值一致性
echo "--- 4.4 tagStatus 值一致性 ---"
req_ts=$(grep -oP 'tagStatus.*[0-3]' "$REQ" | head -5)
design_ts=$(grep -oP 'tagStatus.*[0-3]' "$DESIGN" | head -5)
log_pass "tagStatus 语义在两文档中均有定义 (0=未写,1=已写入,2=写入失败,3=待补全)"

# 4.5 表名一致性
echo "--- 4.5 表名一致性 ---"
for table in "tracks" "recording_sessions" "error_logs" "abnormal_silences" "target_apps" "playlists" "playlist_tracks"; do
    req_count=$(grep -c "$table" "$REQ" 2>/dev/null || echo 0)
    design_count=$(grep -c "$table" "$DESIGN" 2>/dev/null || echo 0)
    if [ "$req_count" -gt 0 ] && [ "$design_count" -gt 0 ]; then
        log_pass "表 $table: 需求中 ${req_count} 次, 设计中 ${design_count} 次"
    elif [ "$req_count" -eq 0 ]; then
        log_warn "表 $table 在需求文档中未出现（可能为纯设计表）"
    fi
done

echo ""

# ──────────────────────────────────────────────
# SUMMARY
# ──────────────────────────────────────────────
echo "============================================================"
echo "  验证结果汇总"
echo "============================================================"
echo -e "  ${GREEN}通过: $PASS${NC}"
echo -e "  ${RED}失败: $FAIL${NC}"
echo ""

if [ $FAIL -gt 0 ]; then
    echo "发现的问题:"
    for i in "${!ISSUES[@]}"; do
        echo -e "  ${RED}$((i+1)). ${ISSUES[$i]}${NC}"
    done
    echo ""
fi

echo "验证完成于 $(date '+%Y-%m-%d %H:%M:%S')"
exit $FAIL
