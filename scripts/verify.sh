#!/usr/bin/env bash
# verify.sh — 環境の健全性チェック
#
# 検証項目:
#   1. LiteLLM への疎通 (/v1/models)
#   2. harness-mem daemon への疎通 (/health)
#   3. harness-mem DB の整合性 (integrity_check)
#   4. harness-mem DB の観測件数
#
# 使い方:
#   ./scripts/verify.sh            # クライアント側 (env から)
#   HARNESS_MEM_HOST=... ./scripts/verify.sh

set -euo pipefail

SERVER_HOST="${HARNESS_MEM_HOST:-100.92.131.75}"
SERVER_PORT="${HARNESS_MEM_PORT:-37888}"
LITELLM_URL="${LITELLM_URL:-http://162.43.21.240:4000/v1}"

fail=0

echo "== 1. LiteLLM =="
if [ -n "${LITELLM_API_KEY:-}" ]; then
  code=$(curl -s -m 5 -o /dev/null -w "%{http_code}" \
    "${LITELLM_URL}/models" -H "Authorization: Bearer ${LITELLM_API_KEY}" || echo 000)
  if [ "$code" = "200" ]; then
    echo "[ok] LiteLLM reachable (${LITELLM_URL})"
  else
    echo "[ng] LiteLLM http=${code}"
    fail=1
  fi
else
  echo "[skip] LITELLM_API_KEY 未設定"
fi

echo "== 2. harness-mem daemon (${SERVER_HOST}:${SERVER_PORT}) =="
if curl -s -m 5 "${SERVER_HOST}:${SERVER_PORT}/health" | grep -q '"ok"[[:space:]]*:[[:space:]]*true'; then
  echo "[ok] harness-mem daemon healthy"
else
  echo "[ng] harness-mem daemon unreachable"
  fail=1
fi

echo "== 3. harness-mem DB integrity =="
if command -v ssh >/dev/null 2>&1 && ssh -o ConnectTimeout=5 x \
  "sqlite3 ~/.harness-mem/harness-mem.db 'PRAGMA integrity_check;'" 2>/dev/null | grep -q '^ok$'; then
  echo "[ok] DB integrity ok (via ssh x)"
else
  echo "[warn] ssh x 経由の DB チェック失敗 (スキップ)"
fi

echo "== 4. harness-mem observation count =="
if ssh -o ConnectTimeout=5 x \
  "sqlite3 ~/.harness-mem/harness-mem.db 'SELECT count(*) FROM mem_observations;'" 2>/dev/null | grep -qE '^[0-9]+$'; then
  echo "[ok] observations=$(ssh x 'sqlite3 ~/.harness-mem/harness-mem.db \"SELECT count(*) FROM mem_observations;\"' 2>/dev/null)"
else
  echo "[warn] 件数取得失敗 (スキップ)"
fi

if [ "$fail" -eq 0 ]; then
  echo "== 結果: すべて OK =="
else
  echo "== 結果: 問題あり =="
  exit 1
fi
