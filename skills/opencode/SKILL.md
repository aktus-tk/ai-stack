# Skill: opencode 運用

opencode (対話型 AI エージェント CLI) の設定と運用知識。

## 設定ファイル

| ファイル | 役割 |
|---|---|
| `~/.config/opencode/opencode.json` | プロバイダー・モデル・MCP 設定 |
| `~/.config/opencode/tui.json` | TUI 表示・マウス・テーマ設定 |

## 何を壊してはいけないか

1. **`${env:XXX}` 参照を維持する** — シークレットは環境変数経由。実値を直書きしない。
2. **WSL + mouse 選択の問題** — opencode はマウスイベントを捕捉するため、ターミナルの
   マウス選択コピーが効かなくなる。`tui.json` の `"mouse": false` で無効化できる
   (キーボード操作は全て機能する)。設定変更は再起動で反映。
3. **MCP 環境変数は daemon の接続先と一致させる** — リモート daemon を使う場合は
   `HARNESS_MEM_HOST` を Tailscale IP に、`HARNESS_MEM_ADMIN_TOKEN` をサーバーと揃える。

## モデル切り替え

- TUI 内で `/models` → モデル選択
- 設定ファイルの `provider.litellm.models` に追加されたモデルが候補に現れる

## セッションについて

- 会話は opencode 自身のストレージ (`~/.local/share/opencode/storage/`) に保存。
  再起動後はセッション一覧から復元 (`opencode --continue` も可)。
- harness-mem が記憶レイヤーを担う。opencode の履歴は
  `HARNESS_MEM_OPENCODE_DB_PATH` (`~/.local/share/opencode/opencode.db`) から
  daemon が自動取り込みする (`opencode_history_ingest: true`)。

## TUI と tmux スクロール

- opencode は vim 同様 **オルトスクリーン (alt screen)** で描画するため、
  tmux のスクロールバックに記録されない。これは正常な動作。
- 履歴を見るには opencode 内でセッションを開き直すか、harness-mem を検索する。
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

## 関連

- クライアント構築 → `runbooks/bootstrap-client.md`
- 設定例 → `config/client/opencode.json.example`
