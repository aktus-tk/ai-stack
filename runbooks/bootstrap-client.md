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

### 5. opencode config symlink setup

Git repository を SSOT とした symlink 方式を使用。

```bash
./scripts/deploy-opencode-config.sh
# または bootstrap-client.sh が自動実行
```

最終的な構成:

```text
Git repository (SSOT)
  config/opencode/
  ├── opencode.json
  ├── instructions/
  │   └── memory-policy.md
  └── AGENTS.md

       ↓ symlink

~/.config/opencode/
  ├── opencode.json         → repository の config/opencode/opencode.json
  ├── instructions          → repository の config/opencode/instructions
  └── AGENTS.md             → repository の AGENTS.md
```

- **SSOT**: Git repository の `config/opencode/`
- **Runtime**: `~/.config/opencode/` (symlink via setup script)
- **Update method**: `git pull` 後、symlink は自動反映（deploy script 不要）

**注**: MCP は意図的に無効化。OpenCode は global skill ベースで harness-mem に HTTP API で接続する。

### 6. TUI 設定 (WSL でマウス選択したい場合)

WSL のターミナルで opencode のテキストをマウスでコピーできない場合、
TUI のマウスモードを無効化する (`tui.json`)。

```json
{
  "$schema": "https://opencode.ai/tui.json",
  "mouse": false
}
```

### 7. Google Drive マウント (任意)

opencode から Google Drive (`~/gdrive`) を読み書きしたい場合は
`runbooks/mount-gdrive.md` を参照。

```bash
# rclone を未導入なら
sudo apt-get install -y rclone fuse3

# OAuth 認証 (初回のみ、ブラウザでの許可が必要)
rclone config create gdrive drive scope=drive

# マウント
~/github/aktus-tk/ai-stack/scripts/mount-gdrive.sh
```

- `~/.bashrc` に `~/bin/mount-gdrive.sh` を追記すると WSL 起動時に自動マウントされる。
- `config/client/opencode.json.example` の `permission.external_directory` が
  `~/gdrive/**` へのアクセス許可を付与する。

### 8. 検証
```bash
./scripts/verify.sh
```

- opencode のモデル一覧に opencode-go (OpenCode Go) が表示される
- harness-mem daemon `/health` が `ok:true` を返す
- opencode が起動可能であること
