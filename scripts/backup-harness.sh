#!/usr/bin/env bash
# backup-harness.sh — harness-mem DB の一貫スナップショットバックアップ
#
# SQLite は WAL モードのため、DB ファイル単体をコピーすると最新書き込みが失われる。
# VACUUM INTO で WAL 込みの一貫スナップショットを1ファイルに固めて保存する。
#
# main (tk) と working (ai-working) の両方をバックアップする。
#
# 使い方:
#   ./scripts/backup-harness.sh                    # ローカルの DB をバックアップ
#   ./scripts/backup-harness.sh --remote           # サーバー (ssh x) の DB をバックアップ
#   BACKUP_DIR=/path ./scripts/backup-harness.sh   # 保存先指定

set -euo pipefail

DEST_DIR="${BACKUP_DIR:-/home/tk/backups/harness-mem}"
STAMP="$(date +%Y%m%d-%H%M%S)"
MODE="${1:-local}"

mkdir -p "$DEST_DIR"

# バックアップ対象 (DB パスと出力ファイル名)
#   main:    ~/.harness-mem/harness-mem.db       -> harness-mem-<stamp>.db
#   working: ~/.harness-mem/harness-mem.db       -> harness-mem-working-<stamp>.db (ai-working)
# working DB は ai-working の home (700) 配下のため sudo で読む。
backup_db() {
  local home_dir="$1"     # 対象ユーザーの home
  local out_name="$2"     # 出力ファイル名
  local use_sudo="$3"     # sudo を使うか (1/0)
  local tmp_db="/tmp/${out_name%.db}-snapshot-${STAMP}.db"
  local sdo=()
  if [ "$use_sudo" = "1" ]; then sdo=(sudo); fi

  if [ "$MODE" = "--remote" ]; then
    ssh x "${sdo[*]:-} sqlite3 ${home_dir}/.harness-mem/harness-mem.db \"VACUUM INTO '${tmp_db}'\""
    scp "x:${tmp_db}" "${DEST_DIR}/${out_name}"
    # tmp_db は sudo で作成されている場合があるため sudo で削除
    ssh x "${sdo[*]:-} rm -f ${tmp_db}"
  else
    "${sdo[@]}" sqlite3 "${home_dir}/.harness-mem/harness-mem.db" "VACUUM INTO '${DEST_DIR}/${out_name}'"
  fi

  # 整合性チェック
  "${sdo[@]}" sqlite3 "${DEST_DIR}/${out_name}" "PRAGMA integrity_check;" | grep -q '^ok$'
  echo "[ok] backup saved: ${DEST_DIR}/${out_name}"
}

backup_db "/home/tk" "harness-mem-${STAMP}.db" 0
backup_db "/home/ai-working" "harness-mem-working-${STAMP}.db" 1

# 古いバックアップの掃除 (main / working 各10個残す)
ls -t "${DEST_DIR}"/harness-mem-*.db 2>/dev/null | grep -v -- '-working-' | tail -n +11 | xargs -r rm -f
ls -t "${DEST_DIR}"/harness-mem-working-*.db 2>/dev/null | tail -n +11 | xargs -r rm -f
