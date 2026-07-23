#!/usr/bin/env bash
# SessionStart フック: セッション開始時にプロジェクトの「現在地」を確定的に注入する。
#
# 設計意図(2026-07-12):
#   - docs/next-directions.md は「頭(現在地・着手順)」+「未完了タスク」の2部構成。
#     頭だけを注入する(全文注入は毎セッション高コストなアンチパターン。境界は session-head-end
#     マーカーで固定)。カタログは着手する節を agent がそのとき読むオンデマンド参照。
#   - 完了計画は docs/archive/ へ退避し、最新docからリンクする。未完了側は棚卸しするまで
#     `> 日付 更新:`積層で伸びるため、ここで機械的に計測し、閾値超過時だけ棚卸しを促す。
set -euo pipefail

# フックの cwd はプロジェクトルート。CLAUDE_PROJECT_DIR があればそれを優先(堅牢化)。
doc="${CLAUDE_PROJECT_DIR:-.}/docs/next-directions.md"
[ -f "$doc" ] || exit 0  # 正典が無ければ無言で終了(フックはセッションを止めない)

# 閾値: 第6版へ棚卸し直後(2026-07-24)はカタログ約93行 / 更新ブロック1個。
# ここを超えたら次版の棚卸し(積層を本文へ溶かし込み、頭を最新の現在地へ)を検討する合図。
# 数字はあくまで目安 — 棚卸ししたら現況に合わせて下げ直してよい(この値自体もメンテ対象)。
CATALOG_MAX_LINES=150
UPDATE_BLOCK_MAX=8

echo '=== docs/next-directions.md の頭(現在地・着手順)。詳細は未完了タスクとリンク先docを必要時だけ読む。更新は「> 日付 更新:」を積層・完了計画はarchiveへ移す ==='

# 1回のパスで: マーカーまでを注入 → 以降(カタログ)の行数と更新ブロック数を計測 → 閾値超過を警告。
awk -v maxlines="$CATALOG_MAX_LINES" -v maxblocks="$UPDATE_BLOCK_MAX" '
  # マーカー行に到達したらモードを頭→カタログへ切替(マーカー自身は出力しない)。
  !seen && /session-head-end:/ { seen = 1; next }
  # 頭: そのまま注入。
  !seen { print; next }
  # カタログ: 出力せず計測だけ。更新ブロックは「(先頭空白可)> **YYYY- ... 更新:」で数える。
  {
    catalog++
    if ($0 ~ /^[[:space:]]*> \*\*20[0-9][0-9]-.*更新[:：]/) updates++
  }
  END {
    if (catalog > maxlines || updates > maxblocks) {
      printf "\n⚠️ next-directions.md のカタログが肥大化しています(%d 行 / 更新ブロック %d 個、閾値 %d 行 / %d 個)。\n", catalog, updates, maxlines, maxblocks
      printf "   棚卸し(次版)を検討してください — 完了した節をdocs/archiveへ移し、最新docからリンクした上で、\n"
      printf "   頭(マーカーより上)を最新の現在地に更新し、このフックの現況コメントも調整する。\n"
    }
  }
' "$doc"
