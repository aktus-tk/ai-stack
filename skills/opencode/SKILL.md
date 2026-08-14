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

## 関連

- クライアント構築 → `runbooks/bootstrap-client.md`
- 設定例 → `config/client/opencode.json.example`
