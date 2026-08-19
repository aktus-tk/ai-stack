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

### 5. opencode.json 生成

`config/client/opencode.json.example` を `~/.config/opencode/opencode.json` にコピー。
プロバイダー(OpenCode Go)の接続先を設定する。

```bash
mkdir -p ~/.config/opencode
cp config/client/opencode.json.example ~/.config/opencode/opencode.json
# ${env:OPENCODE_API_KEY} が読めるよう環境変数を設定済みであること
```

**注**: MCP セクションは不要。OpenCode は global skill ベースで harness-mem に HTTP API で接続する。

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
