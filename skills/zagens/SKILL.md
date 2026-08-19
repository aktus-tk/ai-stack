# Skill: zagens 運用

Zagens (agent harness for DeepSeek V4, v0.9.0) を既存 OpenCode と並行利用するための運用知識。
LLM (OpenCode Go / DeepSeek V4) を共通化し、**Agent Harness ・ memory 接続方式が異なる**構成。

- **OpenCode**: global skill + HTTP API でメモリ接続 (MCP 不使用)
- **Zagens**: stdio MCP でメモリ接続 (OpenCode と独立)

セットアップ手順は `runbooks/setup-zagens.md` を参照。

## 実行方法

```bash
cd ~/zagen && direnv exec . ./bin/zagens exec '<prompt>' --json   # ヘッドレス CLI (one-shot)
cd ~/zagen && direnv exec . ./bin/zagens-tui                      # full-screen TUI (--fresh で新規)
cd ~/zagen && direnv exec . ./bin/zagens doctor                   # 診断 (config / API / MCP)
```

- OpenCode は従来どおり `cd ~/opencode && opencode`。こちらは一切変更しない。
- 3 種類の binary: `zagens` (CLI) / `zagens-tui` (TUI) / `zagens-runtime` (HTTP sidecar)。
- モデル切替は TUI 内 `/model`、CLI は `--model <id>`。

## 何を壊してはいけないか

1. **API key を config / mcp.json に書かない** — 認証は `~/zagen/.envrc` (direnv, chmod 600) 経由のみ。
   `DEEPSEEK_API_KEY` は既存 `~/opencode/.envrc` の `OPENCODE_API_KEY` と同値 (OpenCode Go 共用)。
2. **既存 OpenCode 設定を変更・削除しない** — `~/.config/opencode/opencode.json` /
   `~/opencode/.envrc` / harness-mem daemon・DB はそのまま。
   OpenCode は global skill ベースなので、Zagens の MCP 設定と共存可能。
3. **`harness-working` の wrapper を外さない** — Zagens v0.9.0 は stdio MCP の env 値に
   `{env:VAR}` 展開**非対応**。`bin/harness-working-wrapper.sh` が `HARNESS_MEM_WORKING_*` を
   `HARNESS_MEM_*` にリマップしてから harness-mcp-server を起動している。これを外すと
   harness-working が **main デーモン (37888) に接続**してしまい、memory-policy の
   long-term / working 分離が崩れる (両サーバとも main に繋がる)。
4. **`mcp.json` に HOST / PORT / ADMIN_TOKEN を直書きしない** — 秘密をファイルに残さず、
   親プロセス (direnv) からの継承 + wrapper のリマップで接続先を決める。
5. **`ZAGENS_CONFIG_PATH` を外さない** — 外すとデフォルト (api.deepseek.com / deepseek-v4-pro) に
   戻ってしまい、OpenCode Go に繋がらなくなる。
6. **`config.toml` の mode 設定を推測で足さない** — v0.9.0 のエンジンは task type が
   Code のみ (Auto は UI 概念、Office は削除済み)。現状の最小構成で正しく動く。

## 構成

```
~/zagen/
├── .envrc                     # 認証 (direnv, chmod 600, Git 対象外)
├── config.toml                # Zagens config (ZAGENS_CONFIG_PATH で指定)
├── mcp.json                   # MCP サーバ定義
├── .gitignore                 # .envrc
└── bin/
    ├── zagens                 # headless CLI (0.9.0)
    ├── zagens-tui             # full-screen TUI (0.9.0)
    ├── zagens-runtime         # HTTP sidecar (0.9.0)
    └── harness-working-wrapper.sh  # working デーモン接続用 wrapper
```

| 項目 | 値 |
|---|---|
| config | `~/zagen/config.toml` (env `ZAGENS_CONFIG_PATH`) |
| provider | `deepseek` (`base_url = "https://opencode.ai/zen/go/v1"`) |
| デフォルトモデル | `deepseek-v4-flash` (pro は `--model deepseek-v4-pro`) |
| セキュリティ | `allow_shell = false`, `sandbox_mode = "read-only"` |
| MCP 接続 | `harness` → main daemon (37888) / `harness-working` → working daemon (37889, wrapper 経由) |

## よく使う操作

```bash
cd ~/zagen

# 診断 (config 読込・API 到達性・MCP 状態を一括確認)
direnv exec . ./bin/zagens doctor

# LLM 疎通 (flash / pro)
direnv exec . ./bin/zagens exec 'Say hello in one short sentence.' --json
direnv exec . ./bin/zagens exec 'Say hello in one short sentence.' --model deepseek-v4-pro --json

# MCP サーバ確認 (list / tools)
direnv exec . ./bin/zagens mcp list
direnv exec . ./bin/zagens mcp tools harness-working   # 54 ツール (harness_mem_* 等)

# LLM 経由で MCP ツールを呼ぶ (agentic)
direnv exec . ./bin/zagens exec 'harness-working の検索ツールで検索して要約してください' --auto --json
```

## 検証のポイント

- **接続先の確認**: harness-working が本当に working デーモン (37889) に繋がっているかは
  `harness_mem_admin_metrics` / `harness_mem_stats` の observations 数で判別する
  (main ≈ 5600, working ≈ 60)。両方同じ数を返したら wrapper が壊れている。
- **秘密の確認**: `.envrc` の値がファイル・ログ・`git ls-files` に出ていないこと。
  特に Zagens が自動作成する `~/.zagens/snapshots/` (workspace の git snapshot) に
  `.envrc` が含まれないこと (gitignore 経由で除外)。

## 既知の制限 (v0.9.0)

- `zagens mcp connect` は未実装 (`not implemented yet`)。`mcp tools` で代替する。
- `zagens doctor` の `! config missing at ~/.zagens/config.toml` は cosmetic 警告
  (ZAGENS_CONFIG_PATH 経由で実際は読まれている)。
- Zagens 実行時に `~/.zagens/` (sessions.db, workspace snapshot) が自動作成される。
- `zagens mcp connect` 同様、stdio MCP env の変数展開がないため、接続先リマップは
  wrapper 方式に依存する (上流で対応されれば wrapper は不要になる)。

## 関連

- セットアップ手順 → `runbooks/setup-zagens.md`
- harness-mem 運用 → `skills/harness-mem/SKILL.md`
- OpenCode 運用 → `skills/opencode/SKILL.md`