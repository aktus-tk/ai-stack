# Runbook: サーバーセットアップ (bootstrap-server)

中央サーバー (`x162-43-21-240` / 公開 IP `162.43.21.240` / Tailscale `100.92.131.75`) で
AI 関連コンポーネントを **Docker Compose (`ai-stack`)** として構成する手順。

## 1. 前提

- Ubuntu/Debian 系のサーバー
- `tk` ユーザー (sudo 可)
- Tailscale インストール済み・ノード参加済み
- Docker / Docker Compose 導入済み

## 2. ai-stack リポジトリ配置

```bash
git clone git@github.com:aktus-tk/ai-stack.git ~/github/aktus-tk/ai-stack
cd ~/github/aktus-tk/ai-stack
cp .env.example .env
# .env に実値を設定する (シークレットは git に入れない)
```

`.env` に設定する値:

| 変数 | 説明 |
|---|---|
| `LITELLM_API_KEY` | opencode から litellm への接続キー (LiteLLM UI で発行) |
| `HARNESS_MEM_ADMIN_TOKEN` | harness-mem daemon の認証トークン |
| `POSTGRES_PASSWORD` | 既存 litellm DB のパスワード (移行時は `litellm`) |
| `LITELLM_MASTER_KEY` / `LITELLM_SALT_KEY` / `UI_PASSWORD` | LiteLLM 本体の鍵 |
| `CADDY_BIND_IP` / `CADDY_PORT` | 入口の Tailscale IP (既定 100.92.131.75:8090) |
| `CADDY_BASIC_AUTH_USER` / `CADDY_BASIC_AUTH_HASH` | basic auth (ハッシュは caddy hash-password で生成) |

## 3. 初回ビルド & 起動

```bash
cd ~/github/aktus-tk/ai-stack
docker compose build opencode harness-memd opencode-server
docker compose up -d
./scripts/verify.sh
```

## 4. サービス構成

| service | 役割 | ホストへの公開 |
|---|---|---|
| `postgres` | LiteLLM 用 PostgreSQL | なし (compose 内のみ) |
| `litellm` | LLM ゲートウェイ | 移行期間中のみ `127.0.0.1:4000` |
| `harness-memd` | harness-mem 記憶 daemon | なし |
| `opencode-server` | web/mobile 向け headless サーバー | なし (caddy 経由) |
| `caddy` | 唯一の入口 (basic auth + reverse proxy) | `100.92.131.75:8090` |

### アクセス経路

```text
Smartphone / desktop
        │  Tailscale
        ▼
  100.92.131.75:8090 (Caddy)
        │  HTTP + Basic Auth
        ▼
  opencode-server:4096 (opencode web)
```

## 5. CLI 利用 (Docker 版)

ホストに opencode を入れず、`scripts/opencode` wrapper を使う:

```bash
# PATH に追加 (例: ~/.bashrc)
export PATH="$HOME/github/aktus-tk/ai-stack/scripts:$PATH"

# どのディレクトリでも opencode で起動できる
cd ~/github/project
opencode
```

- 現在のディレクトリが `/workspace` として mount される
- セッションは `~/.local/share/opencode` (bind mount) に保存され引き継がれる
- モデル・MCP は `config/opencode/opencode.json` で compose 内 service name を参照

## 6. スマホ (OpenClient for OpenCode)

モバイルは **OpenClient for OpenCode** (App Store id6763641767) を使い、
サーバー設定に **`http://100.92.131.75:8090`** を指定する。
basic auth のユーザー/パスワード (`CADDY_BASIC_AUTH_USER` / パスワード) を入力する。

### 注意

- `opencode web` は plain HTTP。Caddy が `http://100.92.131.75:8090` で受け、
  basic auth を付けて reverse proxy する。
- HTTPS が必要なら Tailscale Serve で `https://<hostname>.ts.net` に proxy し、
  Caddy をその下に置く。

## 7. 検証

```bash
cd ~/github/aktus-tk/ai-stack
docker compose ps
./scripts/verify.sh
```

## 補足: ハードニング

- 4000 / 37888 / 5432 / 4096 はホストへ publish しない。唯一の入口は Caddy。
- Caddy は Tailscale IP にのみ bind し、basic auth を強制する。
  Tailscale ACL で iPhone などのノードのみ許可するのが望ましい。
- 移行完了後は litellm の `ports: 127.0.0.1:4000:4000` を削除する。
- LiteLLM の image tag は `latest` でなくリリースタグに固定推奨 (`LITELLM_IMAGE_TAG`)。

## 関連

- harness-mem の systemd → Docker 移行 → `runbooks/migrate-harness-mem.md`
- クライアント構築 → `runbooks/bootstrap-client.md`
- 検証 → `scripts/verify.sh`
