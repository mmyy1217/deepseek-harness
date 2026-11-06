#!/usr/bin/env bash
#
# sync-from-upstream.sh — 一键同步 fork：origin master 紧跟 upstream master，
# 且二者永远只相差一个本地提交（FORK_FILES 清单中的 fork 独有脚本）。
#
# 工作方式：fork 独有脚本是 origin master 上唯一的本地提交（upstream 没有它们）。
# 每次运行都相当于把 upstream master rebase 到本地、重放该提交：
#   1. fetch upstream/origin 的最新 master
#   2. 本地 master 对齐 origin master
#   3. 备份 FORK_FILES，git reset --hard 到 upstream/master
#   4. 恢复并重新提交 FORK_FILES（base 变为最新 upstream）
#   5. pnpm install && pnpm run build（产物被 gitignore，不进提交）
#   6. git push --force-with-lease 到 origin master
#
# 用 reset + 重放而不是 git rebase，是为了保证无冲突、可预测：
# 上游即使改了同路径文件，也以本机 fork 独有脚本内容为准（脚本归 fork 所有）。
# push 需要 force-with-lease：每次脚本提交都是新 hash，历史被重写，
# 但 lease 保证只有 origin master 未被他人在本地 fetch 之后改动时才推送。
#
# 用法:
#   scripts/sync-from-upstream.sh            # 同步 + build + push
#   scripts/sync-from-upstream.sh --dry-run  # 只同步到本地，不 build 不 push
#   scripts/sync-from-upstream.sh --skip-build  # 同步 + push，跳过 build
#
# 可用环境变量覆盖: DSH_UPSTREAM / DSH_ORIGIN / DSH_BRANCH

set -euo pipefail

readonly UPSTREAM="${DSH_UPSTREAM:-upstream}"
readonly ORIGIN="${DSH_ORIGIN:-origin}"
readonly BRANCH="${DSH_BRANCH:-master}"

# fork 独有文件清单：upstream 没有、必须每次重放回 origin 的文件。
# reset 到 upstream 会删掉它们，因此先备份、reset 后恢复、再一并提交。
FORK_FILES=(
  "scripts/sync-from-upstream.sh"
  "scripts/auto-sync-cron.sh"
)

DRY_RUN=0
SKIP_BUILD=0

usage() {
  cat <<'EOF'
用法: scripts/sync-from-upstream.sh [--dry-run] [--skip-build]

  同步 origin master 到 upstream master，重放本脚本作为唯一本地提交，
  然后 build 并 push --force-with-lease 到 origin。

选项:
  --dry-run      只同步本地分支并提交，不 build、不 push
  --skip-build   同步并 push，跳过 pnpm install / build
  -h, --help     显示本帮助

环境变量:
  DSH_UPSTREAM   upstream remote 名（默认 upstream）
  DSH_ORIGIN     origin remote 名（默认 origin）
  DSH_BRANCH     要同步的分支（默认 master）
EOF
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "error: 未知参数: $arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# 切到仓库根目录，之后所有路径都相对根
cd "$(git rev-parse --show-toplevel)"

# 0. 前置检查：remote 必须存在，fork 独有文件必须存在于工作树
for f in "${FORK_FILES[@]}"; do
  [[ -f "$f" ]] || { echo "error: 找不到 $f（fork 独有文件必须存在于工作树）" >&2; exit 1; }
done
git remote get-url "$UPSTREAM" >/dev/null
git remote get-url "$ORIGIN" >/dev/null

echo "==> [1/6] fetch $UPSTREAM/$BRANCH 与 $ORIGIN/$BRANCH"
git fetch "$UPSTREAM" "$BRANCH"
git fetch "$ORIGIN" "$BRANCH"

# 先备份 fork 独有文件再动工作树：首次运行（脚本未提交）时，下面的 reset 会
# 先删掉工作树里的脚本文件，备份必须在任何 reset 之前完成。
backup_dir="$(mktemp -d)"
trap 'rm -rf "$backup_dir"' EXIT
for f in "${FORK_FILES[@]}"; do
  mkdir -p "$backup_dir/$(dirname "$f")"
  cp "$f" "$backup_dir/$f"
done

echo "==> [2/6] 本地 $BRANCH 对齐 $ORIGIN/$BRANCH（丢弃未提交更改）"
git checkout -f "$BRANCH"
git reset --hard "$ORIGIN/$BRANCH"

echo "==> [3/6] git reset --hard $UPSTREAM/$BRANCH"
git reset --hard "$UPSTREAM/$BRANCH"

echo "==> [4/6] 恢复并重新提交 fork 独有文件"
for f in "${FORK_FILES[@]}"; do
  cp "$backup_dir/$f" "$f"
done
chmod +x "${FORK_FILES[@]}"
git add "${FORK_FILES[@]}"
if git diff --cached --quiet; then
  echo "    fork 独有文件与 upstream 相同，无需提交（不应发生：upstream 不含这些文件）"
else
  git commit -m "chore: keep fork-only scripts as the only origin commit" >/dev/null
fi

# 校验：相对 upstream 必须恰好一个提交
local_count=$(git rev-list --count "$UPSTREAM/$BRANCH..HEAD")
if [[ "$local_count" -ne 1 ]]; then
  echo "error: HEAD 相对 $UPSTREAM/$BRANCH 有 $local_count 个提交（应为 1）" >&2
  exit 1
fi
echo "    ok: 唯一本地提交为 $(git rev-parse --short HEAD)"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "==> [dry-run] 跳过 build 与 push"
  echo "    待推送: git push --force-with-lease $ORIGIN $BRANCH"
  exit 0
fi

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  echo "==> [5/6] pnpm install && pnpm run build"
  pnpm install
  pnpm run build
else
  echo "==> [5/6] 跳过 build（--skip-build）"
fi

# build 不应留下任何未提交更改（lib/、dist/ 均被 gitignore）
dirty="$(git status --porcelain)"
if [[ -n "$dirty" ]]; then
  echo "warning: build 后存在未提交更改，未自动提交:" >&2
  echo "$dirty" >&2
fi

echo "==> [6/6] git push --force-with-lease $ORIGIN $BRANCH"
git push --force-with-lease "$ORIGIN" "$BRANCH"

echo "==> 完成: $ORIGIN/$BRANCH = $UPSTREAM/$BRANCH + 本脚本"
