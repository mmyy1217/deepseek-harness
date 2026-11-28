#!/usr/bin/env bash
#
# auto-sync-cron.sh — cron 包装脚本：每天 18:00 同步 fork 上游，
# 失败时自动调用 pi（无头模式）诊断并修复，然后重试一次。
#
# 由 crontab 调用：
#   0 18 * * * /home/zuomin/Projects/AI/deepseek-harness/scripts/auto-sync-cron.sh \
#     >> /home/zuomin/.dsh/auto-sync-cron.log 2>&1
#
# 日志: ~/.dsh/auto-sync.log（详细）、~/.dsh/auto-sync-last-error.log（最近一次失败片段）
#
# 可用环境变量覆盖: DSH_REPO（仓库路径）、DSH_LOG_DIR（日志目录），测试用
#
# 用法:
#   auto-sync-cron.sh             # 完整流程（失败时调 pi 自愈，最多两轮）
#   auto-sync-cron.sh --no-pi     # 失败时不调 pi，直接退出（调试用）
#   auto-sync-cron.sh --dry-run   # 同步到本地为止，不 build 不 push 不调 pi

set -uo pipefail

# cron 环境精简，补齐运行所需的环境与 PATH
export HOME="/home/zuomin"
export PATH="/home/zuomin/.local/bin:/usr/local/bin:/usr/bin:/bin"

REPO="${DSH_REPO:-/home/zuomin/Projects/AI/deepseek-harness}"
SYNC="$REPO/scripts/sync-from-upstream.sh"
LOG_DIR="${DSH_LOG_DIR:-$HOME/.dsh}"
LOG="$LOG_DIR/auto-sync.log"
ERROR_SNIPPET="$LOG_DIR/auto-sync-last-error.log"
LOCK="/tmp/dsh-auto-sync.lock"
PI_TIMEOUT_SECONDS=900

NO_PI=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --no-pi) NO_PI=1 ;;
    --dry-run) DRY_RUN=1 ;;
    *)
      echo "error: 未知参数: $arg" >&2
      exit 2
      ;;
  esac
done

mkdir -p "$LOG_DIR"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# flock 防重入：同步 + build 可能跑很久，前一轮未结束时直接跳过
exec 200>"$LOCK"
flock -n 200 || { log "已有实例在运行，本次跳过"; exit 0; }

cd "$REPO" || { log "无法进入 $REPO"; exit 1; }

SYNC_FLAGS=()
[[ "$DRY_RUN" -eq 1 ]] && SYNC_FLAGS+=(--dry-run)

run_sync() {
  "$SYNC" "${SYNC_FLAGS[@]}" >> "$LOG" 2>&1
}

# 生成给 pi 的修复指令（含最近失败日志片段）
build_pi_prompt() {
  local round="$1"
  cat <<EOF
你是 deepseek-harness 仓库的自动运维 agent。上游同步脚本运行失败，请诊断并修复。

仓库: $REPO
同步脚本: scripts/sync-from-upstream.sh
失败时间: $(date '+%Y-%m-%d %H:%M:%S')（第 ${round} 轮 pi 介入）
失败日志片段（$ERROR_SNIPPET，最近 $2 行）:
$(tail -n "$2" "$ERROR_SNIPPET")

任务：
1. 阅读失败日志，定位根因（git 冲突、pnpm 依赖、构建错误、网络/凭证等）。
2. 在仓库内修复问题。可以运行 git/pnpm 命令、改配置文件，但不要修改
   scripts/sync-from-upstream.sh 和 scripts/auto-sync-cron.sh 的逻辑。
3. 修复后自行验证：运行 scripts/sync-from-upstream.sh --skip-build，
   确认同步与提交步骤通过。
4. 完成后用一句话总结根因和修复动作。

如果问题无法在本次会话内解决，明确说明卡点和需要的人工操作。
EOF
}

log "=== 开始上游同步（$([ "$DRY_RUN" -eq 1 ] && echo dry-run || echo full)）==="

if run_sync; then
  log "同步成功"
  exit 0
fi
log "同步失败"

if [[ "$NO_PI" -eq 1 || "$DRY_RUN" -eq 1 ]]; then
  log "（--no-pi/--dry-run）跳过 pi 自愈，退出"
  exit 1
fi

# 准备失败上下文，调用 pi 自愈（最多两轮）
tail -n 150 "$LOG" > "$ERROR_SNIPPET"
log "失败详情已写入 $ERROR_SNIPPET，调用 pi 自愈（第 1 轮）"
pi_prompt="$(build_pi_prompt 1 150)"
if timeout "$PI_TIMEOUT_SECONDS" pi -p -a "$pi_prompt" >> "$LOG" 2>&1; then
  log "pi 第 1 轮完成，重试同步"
else
  log "pi 第 1 轮异常退出（$?），仍重试同步"
fi

if run_sync; then
  log "pi 修复后同步成功"
  exit 0
fi
log "第 1 轮修复后仍失败，调用 pi 自愈（第 2 轮）"

tail -n 150 "$LOG" > "$ERROR_SNIPPET"
pi_prompt="$(build_pi_prompt 2 150)"
timeout "$PI_TIMEOUT_SECONDS" pi -p -a "$pi_prompt" >> "$LOG" 2>&1
log "pi 第 2 轮退出码: $?"

if run_sync; then
  log "pi 第 2 轮修复后同步成功"
  exit 0
fi

log "两轮 pi 自愈均未解决，退出（需人工介入）"
exit 1
