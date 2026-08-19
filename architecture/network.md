# ネットワーク設計

2026-08-15 以降、AI スタックは **Docker Compose (`ai-stack`)** で運用され、
内部サービスは**ホストへ publish しない**。唯一の外部入口は **Caddy**。

## ノード

| ノード | 公開 IP | Tailscale IP | 役割 |
|---|---|---|---|
| サーバー `x162-43-21-240` | `162.43.21.240` | `100.92.131.75` | ai-stack compose (harness-mem / opencode-server / Caddy) |
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
│        │                       │
│        ▼                       │
│  harness-memd :37888           │
│                                │
│    private Docker network      │
└────────────────────────────────┘
```

- コンテナ間通信は **compose の service name** (`harness-memd`, `harness-memd-working`) を使用。
- 公開 IP (`162.43.21.240`) や Tailscale IP (`100.92.131.75`) を内部通信に使わない。

## ポート・バインド一覧

| サービス | ポート | ホストへの publish | アクセス元 | 認証 |
|---|---|---|---|---|
| Caddy | 8090 | `100.92.131.75:8090` (Tailscaleのみ) | スマホ/クライアント (Tailscale) | Basic Auth (`luna`) |
| opencode-server | 4096 | なし (compose 内のみ) | Caddy (reverse proxy) | Caddy が担当 |
| harness-mem daemon (main) | 37888 | `100.92.131.75:37888`* (Tailscaleのみ) | 自宅 opencode / compose 内 (HTTP API) | `HARNESS_MEM_ADMIN_TOKEN` |
| harness-mem daemon (working) | 37889 | `100.92.131.75:37889`* (Tailscaleのみ) | 自宅 opencode / compose 内 (HTTP API) | `HARNESS_MEM_WORKING_ADMIN_TOKEN` |

\* 例外: 自宅の opencode から Tailscale 経由で直接接続するため、harness-mem `37888` / `37889`
   を Tailscale IP (`100.92.131.75:37888`, `100.92.131.75:37889`) に bind。
   Tailscale メッシュ + token 認証 (`HARNESS_MEM_ADMIN_TOKEN` / `HARNESS_MEM_WORKING_ADMIN_TOKEN`)
   があるため public へは露出しない。OpenCode から harness-mem への接続は HTTP API で行われ、MCP は使用しない。

## 経路の分離

```text
スマホ/クライアント ──(Tailscale VPN)→ Caddy :8090 ──(basic auth)→ opencode-server :4096
自宅 opencode ──(Tailscale HTTP API)→ harness-mem daemon :37888 / :37889 (curl経由、MCP不使用)
```

- **Caddy が主要な外部境界**。Tailscale IP にのみ bind し、Basic Auth を強制する。
- **harness-mem `37888` / `37889` は例外として Tailscale IP に bind**。自宅 opencode から
  直接接続するための専用入口で、token 認証により保護されている。
- **OpenCode → harness-mem の接続は HTTP API (curl 経由)** で行われ、MCP は使用しない。

## 変更時の確認コマンド

```bash
# 実際のバインド先 (public に 37888/37889/4096 が出ていないこと)
ss -tlnp | grep -E '37888|37889|4096|8090'

# コンテナ状態
cd ~/github/aktus-tk/ai-stack && docker compose ps

# Tailscale 上のノード一覧
tailscale status

# Tailscale ACL (ポート許可) — admin console で確認
# https://login.tailscale.com/admin/acls
# autogroup:member → 100.92.131.75: tcp:37888, tcp:37889, tcp:8090

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
