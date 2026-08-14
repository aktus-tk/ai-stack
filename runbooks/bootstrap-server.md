# Runbook: サーバーセットアップ (bootstrap-server)

中央サーバー (`x162-43-21-240` / 公開 IP `162.43.21.240`) を
LiteLLM + harness-mem daemon が動く AI サーバーとして構成する手順。

## 1. 前提

- Ubuntu/Debian 系のサーバー
- `tk` ユーザー (sudo 可)
- Tailscale インストール済み・ノード参加済み

## 2. harness-mem インストール

```bash
# Node 実行環境 (volta / bun)
curl -fsSL https://bun.sh/install | bash
curl -fsSL https://get.volta.sh | bash
volta install node

# harness-mem 本体 (npm パッケージ)
npm install -g @chachamaru127/harness-mem
# → ~/.volta/bin/harness-memd 等に配置される
```

## 3. systemd unit 配置

`config/server/systemd/harness-memd.service` をコピー:

```bash
sudo cp config/server/systemd/harness-memd.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now harness-memd
```

unit 内で `HARNESS_MEM_HOST` (Tailscale IP) と `HARNESS_MEM_ADMIN_TOKEN` を必ず実値に置き換えること。

## 4. LiteLLM 起動 (Docker Compose)

```bash
mkdir -p ~/docker/litellm && cd ~/docker/litellm
cp /path/to/config/server/litellm/docker-compose.yml .
# .env を作成 (LITELLM_MASTER_KEY / LITELLM_SALT_KEY / UI_PASSWORD を長いランダム値に)
docker compose up -d
```

LiteLLM UI: `http://162.43.21.240:4000/ui`

## 5. opencode web サーバー (mobile / web クライアント用)

iPhone の opencode mobile やブラウザからサーバー上の opencode に
接続するための headless サーバー。Tailscale IP にのみバインドする。

```bash
# opencode 本体 (リモートに未導入の場合)
curl -fsSL https://opencode.ai/install | bash

# systemd unit 配置 (config/server/systemd/opencode-web.service)
sudo cp config/server/systemd/opencode-web.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now opencode-web
```

unit 内で以下を実値に置き換えること:
- `LITELLM_API_KEY` — クライアントと同じ仮想キー
- `HARNESS_MEM_ADMIN_TOKEN` — harness-memd.service と同じトークン
- `OPENCODE_SERVER_PASSWORD` — 長いランダム値 (basic auth 用)

接続先: `http://100.92.131.75:4096` (ユーザー `opencode`)

## 6. 検証

```bash
ssh x 'systemctl status harness-memd'
ssh x 'systemctl status opencode-web'
ssh x 'cd ~/docker/litellm && docker compose ps'
curl -s http://100.92.131.75:37888/health
curl -s -u opencode:<PASSWORD> http://100.92.131.75:4096/global/health
```

## 補足: ハードニング

- harness-mem daemon は Tailscale IP にのみバインド (公開面を最小化)。
- 厳密な認証が必要な場合、`~/.harness-mem/config.json` に `auth` セクションを追加
  (architecture/security.md 参照)。
- opencode web サーバーも Tailscale IP にのみバインドし、basic auth
  (`OPENCODE_SERVER_PASSWORD`) を必ず設定する。Tailscale ACL で
  iPhone などのノードのみアクセス許可するのが望ましい。
- LiteLLM の image tag は `latest` でなくリリースタグに固定推奨。
