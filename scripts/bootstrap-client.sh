#!/usr/bin/env bash
# bootstrap-client.sh — クライアントセットアップ (参照実装)
#
# runbooks/bootstrap-client.md のうち、自動化できる部分をまとめたもの。
# 既存設定は破壊せず、不足項目のみ追加する。
#
# 使い方:
#   ./scripts/bootstrap-client.sh
#
# 前提: Tailscale 参加済み・OPENCODE_API_KEY が環境に設定済み

set -euo pipefail

SERVER_MEM_HOST="${HARNESS_MEM_HOST:-100.92.131.75}"
SERVER_MEM_PORT="${HARNESS_MEM_PORT:-37888}"

# 1. Tailscale 疎通
echo "== 1. Tailscale 疎通 =="
ping -c1 -W2 100.92.131.75 >/dev/null 2>&1 || { echo "[ng] server unreachable via tailscale"; exit 1; }
echo "[ok] server reachable"

# 2. opencode インストール (未導入時のみ)
echo "== 2. opencode =="
if ! command -v opencode >/dev/null 2>&1; then
  echo "opencode 未導入。インストールします (curl -fsSL https://opencode.ai/install | bash)"
  curl -fsSL https://opencode.ai/install | bash
else
  echo "[ok] opencode already installed: $(opencode --version 2>/dev/null || echo unknown)"
fi

# 3. opencode.json (既存を壊さない)
echo "== 3. opencode.json =="
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
CONFIG="$CONFIG_DIR/opencode.json"
mkdir -p "$CONFIG_DIR"
if [ -f "$CONFIG" ]; then
  echo "[info] ${CONFIG} 既存あり。手動で確認してください"
else
  echo "[info] 雛形をコピー: このスクリプトは単純コピーのみ。config/client/opencode.json.example を参照"
  cp "$(dirname "$0")/../config/client/opencode.json.example" "$CONFIG"
  echo "[warn] ${CONFIG} の HARNESS_MEM_ADMIN_TOKEN と OPENCODE_API_KEY を実値に設定してください"
fi

# 4. 検証
echo "== 4. 検証 =="
"$(dirname "$0")/verify.sh" || exit 1
