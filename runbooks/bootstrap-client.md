# Runbook: クライアントセットアップ (bootstrap-client)

新規マシンをこの AI 環境のクライアントとして構成する手順。
「既存設定は破壊せず、不足項目だけ設定する」方針。

前提: サーバー (`x162-43-21-240`) は稼働済みで、LiteLLM と harness-mem daemon が動いている。

## 手順

### 1. Tailscale 参加

```bash
# インストール(未導入の場合)
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

ノードが `tailscale status` に現れることを確認。クライアント例: `desk` = `100.122.82.18`。

### 2. サーバー疎通確認

```bash
# Tailscale 経由
ping -c1 100.92.131.75

# LiteLLM (公開 IP or Tailscale IP)
curl -s -m 3 http://162.43.21.240:4000/v1/models -H "Authorization: Bearer $LITELLM_API_KEY"
```

### 3. LiteLLM Virtual Key 取得

LiteLLM UI (`http://162.43.21.240:4000/ui`) から仮想キーを発行する。
発行したキーをクライアントの環境に保存:

```bash
# ~/.envrc (direnv 使用時) または ~/.bashrc
export LITELLM_API_KEY=sk-xxxxx
```

### 4. opencode インストール

```bash
curl -fsSL https://opencode.ai/install | bash
# または npm: npm install -g opencode-ai
```

### 5. opencode.json 生成

`config/client/opencode.json.example` を `~/.config/opencode/opencode.json` にコピーして編集。
プロバイダー(LiteLLM)と harness-mem MCP の接続先を設定する。

```bash
mkdir -p ~/.config/opencode
cp config/client/opencode.json.example ~/.config/opencode/opencode.json
# ${env:LITELLM_API_KEY} が読めるよう環境変数を設定済みであること
```

### 6. harness-mem リモート設定

MCP クライアントがリモート daemon に接続するよう設定する。

- `HARNESS_MEM_HOST`: `100.92.131.75` (サーバーの Tailscale IP)
- `HARNESS_MEM_PORT`: `37888`
- `HARNESS_MEM_ADMIN_TOKEN`: サーバー側の systemd unit と同じトークン

```json
"environment": {
  "HARNESS_MEM_HOST": "100.92.131.75",
  "HARNESS_MEM_PORT": "37888",
  "HARNESS_MEM_ADMIN_TOKEN": "REPLACE_WITH_SERVER_TOKEN",
  "HARNESS_MEM_MCP_PLATFORM": "opencode"
}
```

### 7. TUI 設定 (WSL でマウス選択したい場合)

WSL のターミナルで opencode のテキストをマウスでコピーできない場合、
TUI のマウスモードを無効化する (`tui.json`)。

```json
{
  "$schema": "https://opencode.ai/tui.json",
  "mouse": false
}
```

### 8. 検証

```bash
./scripts/verify.sh
```

- LiteLLM `/v1/models` が 200 で返る
- harness-mem daemon `/health` が `ok:true` を返す
- opencode 起動時に harness-mem MCP が認識される
