# ai-stack

自宅/個人用 AI インフラ一式を「インテント(意図)としてのコード」で管理するリポジトリ。

AI エージェント(Claude Code / opencode / Codex など)が安全に動作するための基盤と、
その構築手順・運用知識をテキストとして一元化する。

## 構成要素

| コンポーネント | 役割 | 場所 |
|---|---|---|
| opencode | 対話型 AI エージェント CLI / web サーバー (モバイル: OpenClient for OpenCode) | サーバー (ai-stack compose) |
| harness-mem | remote memory service (HTTP API) — main (long-term) / working (working) の2系統 | サーバー (ai-stack compose) |
| Tailscale | サーバー⇔クライアント間の暗号化 VPN メッシュ | 全ノード |

## レポジトリ構成

```
ai-stack
├── README.md            # このファイル
├── AGENTS.md            # 「この環境とは何か」 — AI エージェント向け全体像
├── compose.yaml         # AI スタック全体の Docker Compose 定義
├── architecture/        # ネットワーク・セキュリティ・設計意図
├── runbooks/            # 「どう構築する」 — 人間・AI 共通の手順
├── skills/              # 「どう扱う」 — AI エージェント向け運用知識
├── config/              # 実際の設定ファイル (compose / opencode / caddy)
├── docker/              # Dockerfile (opencode image)
├── scripts/             # 構築・検証・バックアップスクリプト (opencode wrapper 含む)
└── .env.example         # 環境変数の雛形
```

## 三層構造の思想

```
              AGENTS.md
                  │
          「この環境とは何か」
                  │
       ┌──────────┴──────────┐
       ▼                     ▼
    runbooks                skills
「どう構築する」         「どう扱う」
       │                     │
       └──────────┬──────────┘
                  ▼
          config / scripts
             「実際の状態」
```

- **AGENTS.md** — 環境の全体像。AI がまず読む入り口。
- **runbooks/** — この環境を「どう作るか」。誰でも再現できる手順。
- **skills/** — この環境を「どう扱うか」。変更時に何を壊さないか、どう拡張するかの運用知識。
- **compose.yaml / config/ / docker/** — 実際の状態。コンテナ定義、ポート、bind 先、キー配置。
- **scripts/** — 起動 wrapper (`opencode`) と検証 (`verify.sh`)、バックアップ。

IaC(Terraform)にすべてを寄せず、「意図 + コード」として環境を宣言的に管理するのが目的。

## harness-mem Granite embedding フロー

harness-mem の観測 (observation) は **Granite embedding** (`local:granite-embedding-311m-r2`,
dim=384) でベクトル化され、lexical (FTS) + vector (semantic) の hybrid 検索に使われる。

```
【write path】観測保存 → granite vector
  /v1/events/record で保存
        │  (保存直後は fallback: local-hash-v3 vector が生成される)
        ▼
  POST /v1/admin/reindex-vectors   ← 手動実行 (limit: 新規観測数 or 100)
        │  (working daemon は scheduler 無効のため手動必須)
        ▼
  granite vector 登録完了 (vector_coverage: 1 / migration_complete: true)

【read path】検索 → semantic match
  query
        │  (クエリは自動的に Granite embedding へ変換 — 手動生成不要)
        ▼
  POST /v1/search {query, project, limit, debug:true}   ← project scope 必須
        │
        ▼
  lexical (FTS) + vector (semantic) hybrid ranking
        │
        ▼
  meta: vector_search_enabled / vector_candidates / vector_coverage / vector_model
  items[i].scores: lexical / vector / final
```

**重要な挙動**:

- **保存直後は fallback vector**。granite への変換は `/v1/admin/reindex-vectors` の手動実行が必要
  (working daemon は reindex scheduler 無効。main は有効だが converged 済み)。
- **検索は必ず project scope 付きで実行する**。スコープなしだと `vector_coverage < 0.2` となり
  vector 重み付けが無効化される (実測: `scores.vector: 0.000`)。
- **read path のクエリ embedding は自動生成**。検索時に手動の変換作業は不要。
- 詳細: `skills/harness-mem/SKILL.md` / `runbooks/harness-mem-granite-migration.md` /
  `docs/granite-embedding-verification.md`

## クイックスタート

サーバー (162.43.21.240) の構築は `runbooks/bootstrap-server.md` を参照。
クライアントのセットアップは `runbooks/bootstrap-client.md` を参照。

## opencode への接続方法

opencode は **ホスト直接起動** と **Docker コンテナ経由** の2通りで使える。

### 1. ホスト直接起動

サーバー上にインストールされた opencode をそのまま実行する。

```bash
cd ~/opencode
opencode -s ses_0003192c2ffeF50ENtS1FVeRVX   # 特定セッションを継続
opencode                                    # 新規/セッション選択
```

- モデル設定は `~/.config/opencode/opencode.json` を参照
  (OpenCode Go ゲートウェイ経由。`OPENCODE_API_KEY` で認証)
- セッションは `~/.local/share/opencode/opencode.db` に保存
- memory へのアクセスは global skill (memory-commit / harness-recall) 経由で HTTP API を使用

### 2. Docker コンテナ経由 (推奨)

```bash
/home/tk/github/aktus-tk/ai-stack/scripts/opencode   # 直接実行
# または PATH に追加して
export PATH="$HOME/github/aktus-tk/ai-stack/scripts:$PATH"
opencode                                        # どのディレクトリからでも起動
```

- 現在のディレクトリがそのままコンテナの workspace として mount される
  (ホストと同じ絶対パスで見せるため、セッション引継ぎが機能する)
- セッションは `~/.local/share/opencode/opencode.db` (bind mount) に保存され、
  ホスト直起動と**同じ DB を共有**する
- モデル設定は `config/opencode/opencode.json` を参照
  (OpenCode Go ゲートウェイ経由。`OPENCODE_API_KEY` で認証)
- memory へのアクセスは global skill 経由で HTTP API を使用 (MCP 不使用)
- 初回は image ビルドが必要: `docker compose build opencode`

### セッション引継ぎのポイント

- opencode はセッションを **作業ディレクトリ (directory) ベース**で区別する。
- wrapper は `-v "$PWD:$PWD" -w "$PWD"` でコンテナ内でもホストと同じ絶対パスを
  維持するため、ホスト直起動で作ったセッションをコンテナからも継続できる。
- 逆に `-w /workspace` のような相対マウントにすると別セッション扱いになり
  引継ぎが効かない (修正前のバグ)。
