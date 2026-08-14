# AGENTS.md

このドキュメントは AI エージェント(Claude Code / opencode / Codex 等)が
この環境で作業を始める前に必ず読む「環境ガイド」です。

## この環境とは何か

個人用 AI インフラストラクチャ。中央サーバー1台 + 複数クライアントで構成される。

- **サーバー** (`x162-43-21-240` / 公開 IP `162.43.21.240` / Tailscale `100.92.131.75`)
  - LiteLLM Proxy (Docker, ポート 4000) — LLM ゲートウェイ
  - harness-mem daemon (systemd, ポート 37888) — 記憶/セッション DB
  - メールサーバー・Redmine・n8n など他サービス共存
- **クライアント** (例: `desk` / Tailscale `100.122.82.18`)
  - opencode / Claude Code などの AI エージェント CLI
  - harness-mem MCP クライアント (リモートの daemon に接続)

## 接続の原則

| 対象 | 接続先 | 認証 |
|---|---|---|
| LiteLLM | `http://162.43.21.240:4000/v1` | `LITELLM_API_KEY` (仮想キー) |
| harness-mem daemon | `http://100.92.131.75:37888` (Tailscale) | `HARNESS_MEM_ADMIN_TOKEN` |

- harness-mem daemon は **Tailscale IP にのみバインド** している。`127.0.0.1` にはバインドしない。
- リモートバインドのため、daemon への API アクセスにはトークンが必須(`HARNESS_MEM_ADMIN_TOKEN`)。
  ただしヘルスチェック系エンドポイントは認証なしで応答する。

## 作業時の鉄則

1. **既存設定を壊さない**。不足項目だけを追加する。
2. **設定変更前に現在状態を確認** する (`ss -tlnp`, `systemctl status`, 設定ファイルの読み取り)。
3. **シークレットをコミットしない**。`.env.example` に雛形を置き、実際の値は各ノードの
   `.envrc` / systemd unit / `~/.harness-mem/config.json` に置く。
4. 環境を構築・変更するときは **runbooks/** を、扱い方・拡張・留意点は **skills/** を参照する。

## リポジトリの読み方

- 構築手順 → `runbooks/` (人間・AI 共通の再現可能手順)
- 運用知識 → `skills/` (コンポーネントごとの「何を壊さないか」「どう拡張するか」)
- 実設定 → `config/` (systemd unit, opencode.json, compose)
- 検証 → `scripts/verify.sh`
- バックアップ → `scripts/backup-harness.sh`

## 主要な運用コマンド

```bash
# サーバーの harness-mem daemon
ssh x 'systemctl status harness-memd'
ssh x 'sudo systemctl restart harness-memd'

# サーバーの LiteLLM
ssh x 'cd ~/docker/litellm && docker compose ps'

# 検証
./scripts/verify.sh
```
