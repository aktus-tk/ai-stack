# Runbook: Zagens セットアップ (setup-zagens)

Zagens (agent harness for DeepSeek V4) を既存の OpenCode と並行利用するためのセットアップ手順。
LLM (OpenCode Go / DeepSeek V4) と memory (harness-mem MCP) を共通化し、Agent Harness のみを比較する構成。

## 1. 概要

- OpenCode を従来どおり使い続けながら、Zagens を同じ LLM / memory に接続して並行評価する。
- LLM は OpenCode Go (`opencode.ai/zen/go/v1`) の DeepSeek V4 (flash / pro) を共用。
- memory は harness-mem の MCP サーバ (main / working の 2 daemon) を共用。
- 構成の違いは Agent Harness (OpenCode vs Zagens) のみ。既存の OpenCode 設定は変更しない。

## 2. Zagens とは

- バージョン: **v0.9.0** (pre-built binary)。
- 3 つの実行形態:
  - `zagens` — ヘッドレス CLI (one-shot exec / doctor / mcp 等)
  - `zagens-tui` — full-screen TUI (対話・セッション管理)
  - `zagens-runtime` — HTTP sidecar
- 設定は TOML (`config.toml`)、MCP は `mcp.json`。

## 3. ディレクトリ構成

```
~/zagen/
├── .envrc                     # 認証 (direnv, chmod 600, Git 対象外)
├── config.toml                # Zagens config (ZAGENS_CONFIG_PATH で指定)
├── mcp.json                   # MCP サーバ定義
├── .gitignore                 # .envrc
└── bin/
    ├── zagens                 # headless CLI (0.9.0)
    ├── zagens-runtime         # HTTP sidecar (0.9.0)
    ├── zagens-tui             # full-screen TUI (0.9.0)
    └── harness-working-wrapper.sh  # working デーモン接続用 wrapper
```

## 4. インストール

- GitHub Releases から pre-built binary をダウンロード (`cargo install` 不要)。
- `chmod +x` を付与し、`~/zagen/bin/` に配置。
- ダウンロードした binary の sha256 を、公式 `.sha256` ファイル (および提供ハッシュ) と照合して検証する。

```bash
curl -fSL -o /tmp/zagens-tui \
  https://github.com/didclawapp-ai/zagens/releases/download/zagens-v0.9.0/zagens-tui-x86_64-unknown-linux-gnu
curl -fSL -o /tmp/zagens-tui.sha256 \
  https://github.com/didclawapp-ai/zagens/releases/download/zagens-v0.9.0/zagens-tui-x86_64-unknown-linux-gnu.sha256
# 照合例
sha256sum /tmp/zagens-tui
awk '{print $1}' /tmp/zagens-tui.sha256
```

## 5. 認証 (.envrc / direnv)

`~/zagen/.envrc` に環境変数を定義 (chmod 600, `direnv allow` 済み)。値は config に書かず、direnv 環境からのみ供給する。

| 変数 | 用途 |
|---|---|
| `DEEPSEEK_API_KEY` | API キー。既存 `~/opencode/.envrc` の `OPENCODE_API_KEY` と同値 (OpenCode Go 共用) |
| `ZAGENS_CONFIG_PATH` | `$HOME/zagen/config.toml` を指す |
| `HARNESS_MEM_HOST` / `HARNESS_MEM_PORT` / `HARNESS_MEM_ADMIN_TOKEN` | main / 長期記憶 daemon (port 37888) |
| `HARNESS_MEM_WORKING_HOST` / `HARNESS_MEM_WORKING_PORT` / `HARNESS_MEM_WORKING_ADMIN_TOKEN` | working daemon (port 37889) |

- `.envrc` は chmod 600。`.gitignore` に `.envrc` を記載し、Git 対象外にする。

## 6. config.toml

```toml
provider = "deepseek"
base_url = "https://opencode.ai/zen/go/v1"
default_text_model = "deepseek-v4-flash"
allow_shell = false
approval_policy = "on-request"
sandbox_mode = "read-only"
mcp_config_path = "~/zagen/mcp.json"
instructions = ["~/.config/opencode/instructions/memory-policy.md"]
```

- API キーは **書かない** (env から供給)。
- 補足: Zagens は env から `DEEPSEEK_API_KEY` / `DEEPSEEK_BASE_URL` / `DEEPSEEK_MODEL` を読む (config.example.toml の Env overrides 仕様)。
- base_url 正規化により `https://opencode.ai/zen/go/v1` がそのまま `/chat/completions` に使われる。

## 7. MCP (mcp.json)

- `harness`: harness-mcp-server を直接起動 (`env: HARNESS_MEM_MCP_PLATFORM=zagens`)。HOST/PORT/TOKEN は direnv 環境から継承 (main 37888 へ接続)。
- `harness-working`: **wrapper 経由** (`bin/harness-working-wrapper.sh`)。Zagens v0.9.0 は stdio MCP env の `{env:VAR}` 展開非対応のため、wrapper が `HARNESS_MEM_WORKING_*` → `HARNESS_MEM_*` をリマップしてから harness-mcp-server を exec する。これにより working daemon (37889) に接続。
  - 注意: リマップなしだと両サーバとも main (37888) に接続してしまう (memory-policy の分離が崩れる)。metrics プローブ (observations 数) で接続先を検証すること。

## 8. 疎通確認手順

```bash
# doctor (diagnostics)
direnv exec . ~/zagen/bin/zagens doctor

# LLM 疎通 (flash)
direnv exec . ~/zagen/bin/zagens exec 'Say hello in one short sentence.' --json

# LLM 疎通 (pro)
direnv exec . ~/zagen/bin/zagens exec 'Say hello in one short sentence.' --model deepseek-v4-pro --json

# MCP サーバ一覧
direnv exec . ~/zagen/bin/zagens mcp list

# working のツール一覧 (54 ツール)
direnv exec . ~/zagen/bin/zagens mcp tools harness-working

# LLM 経由で MCP (harness_mem_search) を呼ぶ
direnv exec . ~/zagen/bin/zagens exec '...検索...' --auto --json
```

## 9. 既知の制限 (v0.9.0)

- `zagens mcp connect` は未実装 (`not implemented yet`)。`mcp tools` で代替する。
- `zagens doctor` の `! config missing at ~/.zagens/config.toml` は cosmetic 警告 (ZAGENS_CONFIG_PATH 経由で実際は読まれている)。
- Zagens 実行時に `~/.zagens/` (sessions.db, workspace snapshot) が自動作成される。snapshot は .envrc を除外 (gitignore 経由)。

## 10. 起動方法

| クライアント | 起動コマンド |
|---|---|
| OpenCode | `cd ~/opencode && opencode` (従来どおり) |
| Zagens headless | `cd ~/zagen && direnv exec . ./bin/zagens exec '<prompt>' --json` |
| Zagens TUI | `cd ~/zagen && direnv exec . ./bin/zagens-tui` (`--fresh` で新規セッション) |

- TUI は full-screen interactive UI のため、ヘッドレス環境では起動確認しない (`--version` / `--help` のみ)。

## 11. 検証結果 (2026-08-19 時点)

- doctor OK
- flash OK (`deepseek-v4-flash`)
- pro OK (`deepseek-v4-pro`)
- MCP: 2 サーバ (`harness`, `harness-working`)、working は 54 ツール
- LLM 経由 `harness_mem_search` OK
- 既存 OpenCode (`opencode.json`, `~/opencode/.envrc`) は未変更

## シークレット注意

プロバイダーの API キー (`DEEPSEEK_API_KEY` 等) をリポジトリにコミットしないこと。
`.envrc` は chmod 600 かつ `.gitignore` 対象とし、`.env.example` には変数名だけを置く。
HARNESS_MEM の ADMIN_TOKEN も同様にコミットしないこと。
