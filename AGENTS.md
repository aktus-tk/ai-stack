# AGENTS.md

このドキュメントは AI エージェント(Claude Code / opencode / Codex 等)が
この環境で作業を始める前に必ず読む「環境ガイド」です。

## この環境とは何か

個人用 AI インフラストラクチャ。中央サーバー1台 + 複数クライアントで構成される。

- **サーバー** (`x162-43-21-240` / 公開 IP `162.43.21.240` / Tailscale `100.92.131.75`)
  - ai-stack (Docker Compose) で AI 基盤を一元管理
    - LiteLLM Proxy (compose 内, ポート 4000) — LLM ゲートウェイ
    - harness-mem daemon (compose 内, ポート 37888) — 記憶/セッション DB
    - opencode-server (compose 内, ポート 4096) — web/mobile 用 headless サーバー
    - Caddy (Tailscale IP `100.92.131.75:8090`) — 唯一の外部入口 (basic auth)
  - メールサーバー・Redmine・n8n など他サービス共存
- **クライアント** (例: `desk` / Tailscale `100.122.82.18`)
  - opencode CLI (Docker コンテナ経由で実行、`scripts/opencode` wrapper)
  - harness-mem MCP クライアント (compose 内の daemon に接続)

## 接続の原則

| 対象 | 接続先 | 認証 |
|---|---|---|
| LiteLLM (compose 内) | `http://litellm:4000/v1` | `LITELLM_API_KEY` (仮想キー) |
| harness-mem daemon (compose 内) | `http://harness-memd:37888` | `HARNESS_MEM_ADMIN_TOKEN` |
| opencode server (外部入口) | `http://100.92.131.75:8090` (Caddy) | basic auth |

- 5432 / 4096 は public へ **publish しない**。compose 内の service name で通信。
- 唯一の外部入口は **Caddy** (`100.92.131.75:8090`)、HTTP + Basic Auth で opencode-server へ proxy。
- 例外: LiteLLM `4000` / harness-mem `37888` のみ Tailscale IP (`100.92.131.75:4000`, `100.92.131.75:37888`)
  に bind。自宅の opencode から直接接続するためで、Tailscale 経由 + ログイン認証
  (LITELLM_API_KEY / HARNESS_MEM_ADMIN_TOKEN) があるため public へは露出しない。

## 作業時の鉄則

1. **既存設定を壊さない**。不足項目だけを追加する。
2. **設定変更前に現在状態を確認** する (`docker compose ps`, `ss -tlnp`, 設定ファイルの読み取り)。
3. **シークレットをコミットしない**。`.env.example` に雛形を置き、実際の値は各ノードの `.env` に置く。
4. 環境を構築・変更するときは **runbooks/** を、扱い方・拡張・留意点は **skills/** を参照する。
5. **systemd と Docker の harness-memd を同時起動しない** (同一 SQLite DB を共有するため)。
6. `docker compose build` はメモリ 1.9GB 環境だとクラッシュしうる。キャッシュを活かすか、
   ビルド前に不要なコンテナを止めること。

## リポジトリの読み方

- 構築手順 → `runbooks/` (人間・AI 共通の再現可能手順)
- 運用知識 → `skills/` (コンポーネントごとの「何を壊さないか」「どう拡張するか」)
- 実設定 → `compose.yaml` / `config/`
- 検証 → `scripts/verify.sh`
- バックアップ → `scripts/backup-harness.sh`
- opencode CLI wrapper → `scripts/opencode`

## 主要な運用コマンド

```bash
# ai-stack 全体の状態
cd ~/github/aktus-tk/ai-stack
docker compose ps

# 検証
./scripts/verify.sh

# harness-mem daemon 再起動
docker compose restart harness-memd

# opencode CLI (Docker 版)
opencode            # 任意のディレクトリで起動
```
