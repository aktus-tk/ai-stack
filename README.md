# ai-stack

自宅/個人用 AI インフラ一式を「インテント(意図)としてのコード」で管理するリポジトリ。

AI エージェント(Claude Code / opencode / Codex など)が安全に動作するための基盤と、
その構築手順・運用知識をテキストとして一元化する。

## 構成要素

| コンポーネント | 役割 | 場所 |
|---|---|---|
| LiteLLM Proxy | LLM ゲートウェイ・仮想キー管理 | サーバー (Docker) |
| opencode | 対話型 AI エージェント CLI / web サーバー (モバイル: OpenClient for OpenCode) | クライアント + サーバー (systemd) |
| harness-mem | セッション/記憶の永続化 (MCP サーバー + daemon) | サーバー (systemd) |
| Tailscale | サーバー⇔クライアント間の暗号化 VPN メッシュ | 全ノード |

## レポジトリ構成

```
ai-stack
├── README.md            # このファイル
├── AGENTS.md            # 「この環境とは何か」 — AI エージェント向け全体像
├── architecture/        # ネットワーク・セキュリティ・設計意図
├── runbooks/            # 「どう構築する」 — 人間・AI 共通の手順
├── skills/              # 「どう扱う」 — AI エージェント向け運用知識
├── config/              # 実際の設定ファイル (systemd / opencode / compose)
├── scripts/             # 構築・検証・バックアップスクリプト
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
- **config/ + scripts/** — 実際の状態。エンドポイント、ポート、バインド先、キー配置。

IaC(Terraform)にすべてを寄せず、「意図 + コード」として環境を宣言的に管理するのが目的。

## クイックスタート

クライアントを新規セットアップする場合は `runbooks/bootstrap-client.md` を参照。
サーバー(162.43.21.240)構築は `runbooks/bootstrap-server.md` を参照。
