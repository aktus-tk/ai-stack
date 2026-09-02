# Runbook: クライアントセットアップ (bootstrap-client)

新規マシンをこの AI 環境のクライアントとして構成する手順。
「既存設定は破壊せず、不足項目だけ設定する」方針。

前提: サーバー (`x162-43-21-240`) は稼働済みで、harness-mem daemon が動いている。

## 手順

### 1. Tailscale 参加

```bash
# インストール(未導入の場合)
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

ノードが `tailscale status` に現れることを確認。クライアント例: `desk` = `100.122.82.18`。

### 2. サーバー疎通確認

```bash
# Tailscale 経由
ping -c1 100.92.131.75
```

### 3. OPENCODE_API_KEY 設定

OpenCode Go ゲートウェイの API キーを取得し、クライアントの環境に保存:

```bash
# ~/.envrc (direnv 使用時) または ~/.bashrc
export OPENCODE_API_KEY=sk-xxxxx
```

### 4. opencode インストール

```bash
curl -fsSL https://opencode.ai/install | bash
# または npm: npm install -g opencode-ai
```

### 5. エージェント設定 symlink + MCP セットアップ

Git repository を SSOT とした symlink 方式を使用。
全 AI ツール (opencode / codebuddy / codex / cursor / claude / agy) へ
`AGENTS.md` と `skills/` を共通設定としてリンクする。

```bash
./scripts/setup-links.sh          # 確認プロンプト付き
./scripts/setup-links.sh --force  # 確認なしで実行
./scripts/setup-links.sh --verify # 検証のみ
```

最終的な構成:

```text
Git repository (SSOT)
  AGENTS.md
  skills/
  config/opencode/
  ├── opencode.json
  └── instructions/
      └── memory-policy.md

       ↓ symlink

~/.config/opencode/   (opencode)
~/.codex/             (codex)
~/.cursor/            (cursor)
~/.claude/            (claude)
~/.codebuddy/         (codebuddy)
~/.gemini/config/     (agy)
  ├── AGENTS.md       → repository の AGENTS.md
  ├── skills          → repository の skills/
  └── (opencode のみ) opencode.json, instructions
```

- **SSOT**: Git repository (`AGENTS.md`, `skills/`, `config/opencode/`)
- **Runtime**: 各ツールの設定ディレクトリ (symlink via `setup-links.sh`)
- **Update method**: `git pull` 後、symlink は自動反映（再実行不要）
- **MCP**: `setup-links.sh` が Agent360 Browser MCP も各ツールへマージする
  (`--links-only` で MCP をスキップ可能)

### 6. TUI 設定 (WSL でマウス選択したい場合)

WSL のターミナルで opencode のテキストをマウスでコピーできない場合、
TUI のマウスモードを無効化する (`tui.json`)。

```json
{
  "$schema": "https://opencode.ai/tui.json",
  "mouse": false
}
```

### 7. 検証
```bash
./scripts/verify.sh
```

- opencode のモデル一覧に opencode-go (OpenCode Go) が表示される
- harness-mem daemon `/health` が `ok:true` を返す
- opencode が起動可能であること
