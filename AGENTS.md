# AGENTS.md

このドキュメントは AI エージェント(Claude Code / opencode / Codex 等)が
この環境で作業を始める前に必ず読む「環境ガイド」です。

## この環境とは何か

個人用 AI インフラストラクチャ。中央サーバー1台 + 複数クライアントで構成される。

- **サーバー** (`x162-43-21-240` / 公開 IP `162.43.21.240` / Tailscale `100.92.131.75`)
  - ai-stack (Docker Compose) で AI 基盤を一元管理
    - harness-mem daemon (compose 内, ポート 37888) — long-term memory store (main)
    - harness-mem daemon (compose 内, ポート 37889) — working memory store (working)
    - opencode-server (compose 内, ポート 4096) — web/mobile 用 headless サーバー
    - Caddy (Tailscale IP `100.92.131.75:8090`) — 唯一の外部入口 (basic auth)
  - メールサーバー・Redmine・n8n など他サービス共存
- **クライアント** (例: `desk` / Tailscale `100.122.82.18`)
  - opencode CLI (Docker コンテナ経由で実行、`scripts/opencode` wrapper)
  - global skills で harness-mem に HTTP API で接続

## 接続の原則

| 対象 | 接続先 | 認証 | 用途 |
|---|---|---|---|
| OpenCode Go (外部) | `https://opencode.ai/zen/go/v1` | `OPENCODE_API_KEY` | LLM API |
| harness-mem main (compose 内) | `http://harness-memd:37888/v1` | `HARNESS_MEM_ADMIN_TOKEN` | long-term memory (HTTP) |
| harness-mem working (compose 内) | `http://harness-memd-working:37889/v1` | `HARNESS_MEM_WORKING_ADMIN_TOKEN` | working memory (HTTP) |
| opencode server (外部入口) | `http://100.92.131.75:8090` (Caddy) | basic auth | web / mobile UI |

**注**: 
- クライアントの OpenCode は harness-mem に対して MCP ではなく HTTP API で直接接続
- HTTP API 呼び出しは global skill (memory-commit / harness-recall) で行われ、CLI/curl を使用
- 4096 は public へ**publish しない**。compose 内の service name で通信。
- 唯一の外部入口は **Caddy** (`100.92.131.75:8090`)。
- harness-mem `37888` / `37889` のみ Tailscale IP (`100.92.131.75`) に bind。
  自宅の opencode から直接接続するためで、Tailscale 経由 + token 認証があるため public へは露出しない。

## Memory Policy

OpenCode の記憶は2つのレイヤーに分かれている：

1. **OpenCode local session/history** — 短期作業 context + crash recovery
   - OpenCode が管理 (MCP・harness-mem に依存しない)
   - セッション切断 / crash 後は復旧可能

2. **harness-mem (main / working stores)** — 長期的に記憶を残す必要がある場合のみ
   - ユーザーが「ここまで記憶して」と**明示**したときだけ保存
   - 自動記録はしない
   - main store: 建築的決定・ポリシー・再利用可能な知識
   - working store: 一時的な調査結果・仮説・作業記憶

```text
Memory policy (明示 commit 方式):

- OpenCode local session が基本的な context 管理を担当

- 長期的に残したい情報は、ユーザーが
  「ここまで記憶して」「記憶しておいて」と発話したときだけ
  harness-mem に保存される（memory-commit skill 経由）

- 過去の記憶が必要な場合は、ユーザーが
  「思い出して」「前回は何を」と発話したとき
  harness-mem から取得される（harness-recall skill 経由）

- crash 復旧は OpenCode local session で完結
```

参照: `~/.agents/skills/memory-commit/SKILL.md`, `~/.agents/skills/harness-recall/SKILL.md`

## 作業時の鉄則

1. **既存設定を壊さない**。不足項目だけを追加する。
2. **設定変更前に現在状態を確認** する (`docker compose ps`, `ss -tlnp`, 設定ファイルの読み取り)。
3. **シークレットをコミットしない**。`.env.example` に雛形を置き、実際の値は各ノードの `.env` に置く。
4. 環境を構築・変更するときは **runbooks/** を、扱い方・拡張・留意点は **skills/** を参照する。
5. **docker compose と local harness-memd の同時起動に注意** (同一 SQLite DB を共有する場合)。
6. `docker compose build` はメモリ 1.9GB 環境だとクラッシュしうる。キャッシュを活かすか、
   ビルド前に不要なコンテナを止めること。
7. **依存製品・外部ライブラリの内部デバッグは、ユーザーから明示的な指示がない限り行わない。**
   通常の設定確認、公式 CLI/API、ログ確認、再起動など公開されたインターフェースの範囲で切り分ける。
   その範囲で解決できず、依存製品自体の不具合が疑われる場合は、内部実装の解析へ進まず、
   確認した事実と推定原因を報告してユーザーの判断を仰ぐ。

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

# harness-mem working daemon 再起動
docker compose restart harness-memd-working

# opencode CLI (Docker 版)
opencode            # 任意のディレクトリで起動
```
