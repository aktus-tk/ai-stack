# Skill: opencode 運用

opencode (対話型 AI エージェント CLI) の設定と運用知識。
2026-08-15 以降、CLI / Server は **Docker Compose (`ai-stack`)** で運用する。

## 実行方法 (Docker 版)

```bash
# PATH に ai-stack の scripts を追加
export PATH="$HOME/github/aktus-tk/ai-stack/scripts:$PATH"

# どのディレクトリでも起動 (現在 dir が /workspace として mount)
cd ~/github/project
opencode
```

- ホストに opencode をインストールせず、image `ai-stack-opencode` を都度起動する。
- セッションは `~/.local/share/opencode` (bind mount) に保存され、CLI/Server 間で共有される。
- モデル・MCP 設定は `config/opencode/opencode.json` (compose 内 service name 参照)。

## 設定ファイル

| ファイル | 役割 |
|---|---|
| `config/opencode/opencode.json` | プロバイダー・モデル設定 (compose 内 mount) |
| `docker/opencode/Dockerfile` | opencode image ビルド定義 |
| `scripts/opencode` | CLI 起動 wrapper |

## 何を壊してはいけないか

1. **`${env:XXX}` 参照を維持する** — シークレットは環境変数経由。実値を直書きしない。
2. **Dockerfile に `ENTRYPOINT` を設定しない** — opencode (CLI/Server) と harness-memd の
   両方を同一 image から起動するため、compose の `command` で実行コマンドを指定する。
   `ENTRYPOINT ["opencode"]` があると harness-memd の `command` が上書きされ破壊する。
3. **コンテナの `HOME` は `/home/tk`** — opencode のデータ (`~/.local/share/opencode`) を
   bind mount と一致させるため。`HOME=/root` だとセッション引継ぎが効かなくなる。
4. **WSL + mouse 選択の問題** — opencode はマウスイベントを捕捉するため、ターミナルの
   マウス選択コピーが効かなくなる。`tui.json` の `"mouse": false` で無効化できる。

## モデル切り替え

- TUI 内で `/models` → モデル選択
- `config/opencode/opencode.json` の `provider.opencode-go.models` (OpenCode Go ゲートウェイのモデルが候補に現れる)

## セッションについて

- 会話は `~/.local/share/opencode/opencode.db` (bind mount) に保存。
  再起動後は `opencode --continue` かセッション一覧から復元。
- long-term memory が必要な場合は、ユーザーが「記憶して」と発話したときだけ
  harness-mem に保存される（memory-commit skill 経由）。
- crash からの復旧は OpenCode local session で完結。

## TUI と tmux スクロール

- opencode は vim 同様 **オルトスクリーン (alt screen)** で描画するため、
  tmux のスクロールバックに記録されない。これは正常な動作。
- セッション内のやり取りを後で確認するには opencode 内でセッションを開き直すか、
  必要に応じて「思い出して」と発話して harness-mem から取得する。
- tmux でスクロールさせたい場合は alt screen 無効化が可能だが描画に副作用あり:
  ```
  set -ga terminal-overrides ",*:smcup@:rmcup@"
  ```

## コンテキスト量の確認

コンテキストは opencode の SQLite ストレージに保存されている。現在のセッションの
コンテキスト量は以下の SQL で見積もれる (パーツのテキスト量から概算)。

```bash
sqlite3 ~/.local/share/opencode/opencode.db \
  "SELECT COUNT(*), SUM(length(data)) FROM part
   WHERE session_id='<session_id>';"
```

- `length(data)` 合計 / 3.5 ≈ トークン数 (日本語+英語+JSON 混在の概算)
- セッション累計使用量は `session.tokens_input` 列でも確認できる

## Context compaction 仕様

### トリガー条件

opencode は**毎ステップ (step-finish) の後**に累積トークンを判定し、閾値超過で
自動 compaction を実行する (`compaction.auto` が true のとき。デフォルト有効)。

```js
// 閾値 = モデルのコンテキスト上限 - reserved バッファ
reserved = config.compaction?.reserved ?? min(20000, maxOutputTokens)
// 発火条件
if (compaction.auto !== false
    && model.limit.context > 0
    && (tokens.total || input+output+cache.read+cache.write) >= 閾値)
  → 自動 compaction
```

- 対象: 累積 input + output + cache read/write トークン
- 例: コンテキスト 128K のモデルだと約 **120K トークン**で自動発火
  (128000 - reserved)
- **Context overflow エラー** (プロバイダが上限超過を拒否) 時も強制 compaction が走る
- 手動実行は `/compact` (keybind: `ctrl+x c`)。エイリアス `/summarize`

### 設定 (`opencode.json`)

```json
{
  "compaction": {
    "auto": true,      // コンテキスト満杯時に自動 compaction (default: true)
    "prune": false,    // 古いツール出力を削除してトークン節約 (default: false)
    "reserved": 10000  // compaction 用のトークン余白 (default: min(20000, maxOutputTokens))
  }
}
```

### 注意

- compaction は会話を要約に置き換えるため、詳細なやり取りは harness-mem 側に
  残る。必要なら harness-mem を検索して復元する。
- `prune` 有効時は古いツール出力が捨てられ、`skill` 系ツールは保護対象。

## モバイル / リモート接続 (opencode server)

ai-stack compose の `opencode-server` が headless サーバーを常駐させ、
Caddy が唯一の入口として受け付ける。

- **モバイルクライアント**: OpenClient for OpenCode
  (App Store: `https://apps.apple.com/jp/app/openclient-for-opencode/id6763641767`)
  - サーバー設定に **`http://100.92.131.75:8090`** を指定する
- **接続先**: `http://100.92.131.75:8090` (Caddy, Tailscale IP のみ bind)
- **認証**: basic auth (`CADDY_BASIC_AUTH_USER` / パスワード)
- **経路**: Smartphone → Tailscale → Caddy(8090, basic auth) → opencode-server(4096, compose 内)
- **状態確認**: `docker compose ps`, `docker logs ai-stack-opencode-server-1`

### 注意

- `opencode web` は plain HTTP サーバーのため、`https://` では接続できない。
  `http://` を指定すること。
- ブラウザ自動起動 (`xdg-open`) のエラーはヘッドレス環境では無害。
- Caddy の basic auth ハッシュは `caddy hash-password` で生成し `.env` の
  `CADDY_BASIC_AUTH_HASH` に設定する。

## 関連

- クライアント構築 → `runbooks/bootstrap-client.md`
- サーバー構築 → `runbooks/bootstrap-server.md`
- 設定例 → `config/opencode/opencode.json`
