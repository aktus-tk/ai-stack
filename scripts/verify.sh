#!/usr/bin/env bash
# verify.sh — ai-stack (Docker Compose) 環境の健全性チェック
#
# 検証項目:
#   1. コンテナ稼働状態 (postgres/litellm/harness-memd/opencode-server/caddy)
#   2. LiteLLM への疎通 (compose 内 litellm:4000 → /v1/models)
#   3. harness-mem daemon への疎通 (compose 内 harness-memd:37888 → /health)
#   4. harness-mem DB の整合性 (integrity_check)
#   5. Caddy (Tailscale 経由の入口) の basic auth
#   6. security boundary: 公開ポートが意図したものだけであること
#
# 使い方:
#   ./scripts/verify.sh                # サーバー上で実行
#   ./scripts/verify.sh --quick        # コンテナ状態と疎通のみ
#
# 前提:
#   - ai-stack ディレクトリに .env が存在
#   - docker compose が利用可能

set -euo pipefail

AI_STACK="${AI_STACK_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
ENV_FILE="${AI_STACK}/.env"
QUICK="${1:-}"

fail=0

cd "$AI_STACK"

if [ ! -f "$ENV_FILE" ]; then
  echo "[error] ${ENV_FILE} がありません" >&2
  exit 1
fi

# .env から値を読み込む (source せずパース: bcrypt 等の $ 混在を避ける)
parse_env() {
  while IFS='=' read -r key value; do
    case "$key" in
      ''|\#*) continue ;;
      *) export "$key=${value%$'\r'}" ;;
    esac
  done < "$ENV_FILE"
}
parse_env

echo "== 1. コンテナ稼働状態 =="
services=(postgres litellm harness-memd opencode-server caddy)
for svc in "${services[@]}"; do
  state=$(docker compose ps --status running --format '{{.Name}} {{.State}}' "$svc" 2>/dev/null || true)
  if [ -n "$state" ]; then
    echo "[ok] ${svc} running"
  else
    echo "[ng] ${svc} not running"
    fail=1
  fi
done

if [ "$QUICK" = "--quick" ]; then
  if [ "$fail" -eq 0 ]; then echo "== 結果: すべて OK =="; else echo "== 結果: 問題あり =="; fi
  exit $fail
fi

echo "== 2. LiteLLM 疎通 =="
# LiteLLM は Tailscale IP (100.92.131.75:4000) に bind。
LITELLM_HOST="${LITELLM_VERIFY_URL:-http://100.92.131.75:4000}"
code=$(curl -s -o /dev/null -w "%{http_code}" -m 5 \
  "${LITELLM_HOST}/v1/models" -H "Authorization: Bearer ${LITELLM_API_KEY}" || echo 000)
if [ "$code" = "200" ]; then
  echo "[ok] LiteLLM reachable (http ${code})"
else
  echo "[ng] LiteLLM http=${code}"
  fail=1
fi

echo "== 3. harness-mem daemon 疎通 (harness-memd:37888) =="
# 移行期間中は 127.0.0.1:37888 には bind していないため、コンテナ内から確認
if docker compose exec -T harness-memd curl -s -m 5 http://127.0.0.1:37888/health 2>/dev/null | grep -q '"ok"[[:space:]]*:[[:space:]]*true'; then
  echo "[ok] harness-mem daemon healthy"
else
  echo "[ng] harness-mem daemon unreachable"
  fail=1
fi

echo "== 4. harness-mem DB integrity =="
if command -v sqlite3 >/dev/null 2>&1 && sqlite3 /home/tk/.harness-mem/harness-mem.db "PRAGMA integrity_check;" 2>/dev/null | grep -q '^ok$'; then
  obs=$(sqlite3 /home/tk/.harness-mem/harness-mem.db "SELECT count(*) FROM mem_observations;" 2>/dev/null)
  echo "[ok] DB integrity ok (observations=${obs})"
else
  echo "[warn] DB integrity チェック失敗 (sqlite3 なし or DB 読めず)"
fi

echo "== 5. Caddy basic auth (100.92.131.75:${CADDY_PORT:-8090}) =="
if curl -s -o /dev/null -w "%{http_code}" -m 5 "http://100.92.131.75:${CADDY_PORT:-8090}/" | grep -q "^401$"; then
  echo "[ok] Caddy requires auth (401 without credentials)"
else
  echo "[warn] Caddy 未認証応答が 401 でない (要確認)"
fi

echo "== 6. security boundary =="
# 公開 bind (0.0.0.0 / 公開IP) に 4000/37888/5432/4096 が無いこと
# 例外: litellm:4000 は Tailscale IP のみに bind (自宅 opencode 用) — ここでは 0.0.0.0 でなければ OK。
leaked=$(ss -tlnp 2>/dev/null | grep -E "0.0.0.0:(4000|37888|5432|4096)" || true)
if [ -z "$leaked" ]; then
  echo "[ok] 4000/37888/5432/4096 は public (0.0.0.0) に露出していない"
else
  echo "[ng] 公開ポート漏れ: ${leaked}"
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "== 結果: すべて OK =="
else
  echo "== 結果: 問題あり =="
  exit 1
fi
