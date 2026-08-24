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

## 作業ポリシー

### 上位原則

> **タスク境界の内側では自律的に、境界を変える判断には慎重に**

- 境界内での investigate / implement / test / debug / verify は自律的に進めてよい
- 以下は自律的に進めず、ユーザーに確認する:
  - タスクの再定義・スコープ拡大
  - アーキテクチャ・スキーマ・認証認可・ネットワーク境界の変更
  - 既存設計の大幅な変更、依存ライブラリの置換
  - 破壊的操作（データ削除、本番への push --force 等）
  - 外部ツール・OSSのソースコード改変

### 1. Authority（権限階層）

判断に迷ったときの優先順位:

```text
1. ユーザーの明示指示
2. 既存プロジェクト規約・AGENTS.md
3. 目的達成に必要な最小アクション
4. 成功を確認するための検証
5. オプションの調査・改善（原則やらない）
```

- **MUST**: ユーザーが具体的なコマンド・手順・ファイル・対象範囲を指定した場合、それを再調査・代替・事前検証せず実行する
- 安全上の具体的かつ明確な問題がある場合のみ停止・確認する
- 一般論としての「念のため」は明示指示を上書きする理由にならない

### 2. Boundary（境界制御）

**変更コスト階層（上ほど軽い）:**

```text
設定変更
  > 公式インターフェース・API 利用
  > documented workaround
  > 運用上の回避策
  > ソースコード改変
```

- 問題解決には上位の手段を先に試す
- ソースコード改変（特に外部 OSS）は最後の手段
- 「直せる」と「直すべき」は別の判断

**禁止:**
- タスク完了後の「ついでの改善」「ついでのリファクタリング」
- 要求されていない機能追加・最適化
- 既存設計を「自分ならこう作る」で置き換えること

### 3. Execution（実行原則）

1. **既存設定を壊さない**。不足項目だけを追加する。
2. **設定変更前に現在状態を確認** する (`docker compose ps`, `ss -tlnp`, 設定ファイルの読み取り)。
3. **シークレットをコミットしない**。`.env.example` に雛形を置き、実際の値は各ノードの `.env` に置く。
4. 環境を構築・変更するときは **runbooks/** を、扱い方・拡張・留意点は **skills/** を参照する。
5. **docker compose と local harness-memd の同時起動に注意** (同一 SQLite DB を共有する場合)。
6. `docker compose build` はメモリ 1.9GB 環境だとクラッシュしうる。キャッシュを活かすか、ビルド前に不要なコンテナを止めること。

## 書き込み操作の安全ルール

- 読み取り操作は自由に実行してよい。
- 既存データを変更する前に、対象が正しいことを確認する。
- ロールバックが必要になる可能性がある場合は、変更前の状態を取得・退避する。
- 既存の本番データを、APIや更新方法の動作確認・テストに使用してはならない（`test` などで上書きする行為を含む）。
- 書き込み操作のテストが必要な場合は、明示的にテスト用として指定された対象のみ使用する。
- 安全に使用できるテスト対象がない場合は、書き込みを実行せずユーザーに確認する。
- 書き込み後は対象を再取得し、意図した内容が正しく反映されていることを確認する。

### 4. Verification（検証と完了）

タスク完了前に確認すること:

- [ ] 要求された成功条件をすべて満たしているか
- [ ] 明示された重要要件（invariant）が実装に反映されているか
- [ ] 「ファイルを書いた」「コマンドが通った」だけでなく、要件カバレッジを確認したか

**完了したら停止する:**
- 成功条件を満たしたら終了
- 追加改善・追加調査・追加リファクタリングを自動的に開始しない

### 5. Termination（停止条件）

以下の場合は作業を停止し、状況を報告する:

| 条件 | 停止後のアクション |
|------|-------------------|
| 成功条件を満たした | 結果を報告して終了 |
| 同一原因の失敗が2回発生 | 事実・試行内容・推定原因を報告 |
| 同じ種類の仮説を繰り返している | 状況を報告してユーザー判断を仰ぐ |
| タスク境界を越える判断が必要 | 選択肢を提示してユーザーに確認 |

- 再試行は**新しい観測・仮説・設定変更がある場合のみ**
- 同じ操作を根拠なく繰り返さない

### 6. Escalation（確認を求める場面）

以下の場合はユーザーに確認する:

- アーキテクチャ・DB スキーマ・認証認可の変更が必要そうなとき
- 外部ツール・OSS のソースコード改変が必要そうなとき
- 破壊的操作を実行する前
- 当初のタスク範囲を超える作業が必要なとき
- 依存製品自体の不具合が疑われ、公開インターフェースでは解決できないとき

**依存製品のトラブルシューティング:**
- 公開インターフェース（設定・公式 CLI/API・ログ・再起動）の範囲で切り分ける
- その範囲で解決できない場合は、内部実装の解析へ進まず、確認した事実と推定原因を報告

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

## RHEMS Redmine

RHEMS Redmine (`https://redmine.rhems-japan.net/`) の Issue 参照・検索・作成・更新・コメント操作を行う場合は、`rhems-redmine` Skill を使用すること。認証は `$REDMINE_API_KEY`、本文は Textile 形式。
