#!/usr/bin/env bash
# backup-harness.sh — harness-mem DB の一貫スナップショットバックアップ
#
# SQLite は WAL モードのため、DB ファイル単体をコピーすると最新書き込みが失われる。
# VACUUM INTO で WAL 込みの一貫スナップショットを1ファイルに固めて保存する。
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

if [ "$MODE" = "--remote" ]; then
  TMP="/tmp/harness-mem-snapshot-${STAMP}.db"
  ssh x "sqlite3 ~/.harness-mem/harness-mem.db \"VACUUM INTO '${TMP}'\""
  scp "x:${TMP}" "${DEST_DIR}/harness-mem-${STAMP}.db"
  ssh x "rm -f ${TMP}"
else
  sqlite3 ~/.harness-mem/harness-mem.db "VACUUM INTO '${DEST_DIR}/harness-mem-${STAMP}.db'"
fi

# 整合性チェック
sqlite3 "${DEST_DIR}/harness-mem-${STAMP}.db" "PRAGMA integrity_check;" | grep -q '^ok$'
echo "[ok] backup saved: ${DEST_DIR}/harness-mem-${STAMP}.db"

# 古いバックアップの掃除 (10個残す)
ls -t "${DEST_DIR}"/harness-mem-*.db 2>/dev/null | tail -n +11 | xargs -r rm -f
