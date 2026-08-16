# ネットワーク設計

2026-08-15 以降、AI スタックは **Docker Compose (`ai-stack`)** で運用され、
内部サービスは**ホストへ publish しない**。唯一の外部入口は **Caddy**。

## ノード

| ノード | 公開 IP | Tailscale IP | 役割 |
|---|---|---|---|
| サーバー `x162-43-21-240` | `162.43.21.240` | `100.92.131.75` | ai-stack compose (LiteLLM / harness-mem / opencode-server / Caddy) |
| クライアント `desk` | — | `100.122.82.18` | opencode (Docker wrapper) / エージェント CLI |
| スマホ iPhone | — | `100.66.98.118` | OpenClient for OpenCode |

## アーキテクチャ

```text
        Smartphone / desktop
                │
            Tailscale
                │
                ▼
    x / 100.92.131.75
                │
         Caddy :8090        ← 唯一の外部入口 (HTTP + Basic Auth)
                │
                ▼
┌──────── Docker Compose ────────┐
│                                │
│  opencode-server :4096         │
│        │            │          │
│        ▼            ▼          │
│  litellm :4000  harness-memd:37888 │
│        │                        │
│        ▼                        │
│  postgres :5432                 │
│                                │
│    private Docker network      │
└────────────────────────────────┘
```

- コンテナ間通信は **compose の service name** (`litellm`, `harness-memd`, `postgres`) を使用。
- 公開 IP (`162.43.21.240`) や Tailscale IP (`100.92.131.75`) を内部通信に使わない。

## ポート・バインド一覧

| サービス | ポート | ホストへの publish | アクセス元 | 認証 |
|---|---|---|---|---|
| Caddy | 8090 | `100.92.131.75:8090` (Tailscaleのみ) | スマホ/クライアント (Tailscale) | Basic Auth (`luna`) |
| opencode-server | 4096 | なし (compose 内のみ) | Caddy (reverse proxy) | Caddy が担当 |
| LiteLLM Proxy | 4000 | `100.92.131.75:4000`* (Tailscaleのみ) | 自宅 opencode / compose 内 | `LITELLM_API_KEY` (仮想キー) |
| harness-mem daemon | 37888 | `100.92.131.75:37888`* (Tailscaleのみ) | 自宅 opencode / compose 内 | `HARNESS_MEM_ADMIN_TOKEN` |
| harness-mem MCP | 標準入出力 | ローカル (コンテナ内) | opencode | — |
| PostgreSQL | 5432 | なし (compose 内のみ) | litellm (compose 内) | `POSTGRES_PASSWORD` |

\* 例外: 自宅の opencode から Tailscale 経由で直接接続するため、LiteLLM `4000` / harness-mem `37888`
  を Tailscale IP (`100.92.131.75:4000`, `100.92.131.75:37888`) に bind。Tailscale メッシュ +
  ログイン認証 (`LITELLM_API_KEY` / `HARNESS_MEM_ADMIN_TOKEN`) があるため public へは露出しない。

## 経路の分離

```text
スマホ/クライアント ──(Tailscale VPN)→ Caddy :8090 ──(basic auth)→ opencode-server :4096
opencode-server ──(compose network)→ litellm :4000
opencode-server ──(compose network)→ harness-memd :37888
litellm ──(compose network)→ postgres :5432
```

- **PostgreSQL はホストからは直接到達不可**。コンテナ内で完結。
- **Caddy が主要な外部境界**。Tailscale IP にのみ bind し、Basic Auth を強制する。
- **LiteLLM `4000` / harness-mem `37888` は例外として Tailscale IP に bind**。自宅 opencode から
  直接接続するための専用入口で、`LITELLM_API_KEY` / `HARNESS_MEM_ADMIN_TOKEN` 認証により保護されている。

## 変更時の確認コマンド

```bash
# 実際のバインド先 (public に 4000/37888/5432/4096 が出ていないこと)
ss -tlnp | grep -E '4000|37888|5432|4096|8090'

# コンテナ状態
cd ~/github/aktus-tk/ai-stack && docker compose ps

# Tailscale 上のノード一覧
tailscale status

# Tailscale ACL (ポート許可) — admin console で確認
# https://login.tailscale.com/admin/acls
# autogroup:member → 100.92.131.75: tcp:37888, tcp:4000, tcp:8090

# 入口 (Caddy) の疎通
curl -s -m 3 -u 'luna:<password>' http://100.92.131.75:8090/global/health

# 内部疎通 (compose 内から)
docker compose exec harness-memd curl -s http://127.0.0.1:37888/health
```

## 関連

- 全体構成 → `compose.yaml`
- 構築手順 → `runbooks/bootstrap-server.md`
- 検証 → `scripts/verify.sh`
- セキュリティ → `architecture/security.md`
