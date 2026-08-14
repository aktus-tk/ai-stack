# Runbook: Google Drive の rclone マウント (mount-gdrive)

Windows + WSL 環境で Google Drive をローカルファイルシステムとして扱う手順。
opencode などの AI エージェントが `~/gdrive` 配下を自由に読み書きできるようにする。

## 背景

- Google Drive for Desktop は仮想ファイルシステム (VFS / Stream モード) のため、
  WSL の `/mnt/...` (DrvFS) からは参照できない (`I/O error`)。
- 実ファイルで見せるには Drive for Desktop の「Mirror モード」か、WSL 内で
  rclone をマウントするか、の 2 択。本 runbook は後者 (rclone mount) を採用する。
- rclone mount 方式は認証が rclone 側で完結し、エージェントに API キーを
  一切渡さないため、IAM/キー方式よりセキュアかつ簡単。

## 手順

### 1. rclone インストール

```bash
sudo apt-get update
sudo apt-get install -y rclone fuse3
```

### 2. OAuth 認証 (初回のみ)

```bash
rclone config create gdrive drive scope=drive
```

- 出力される `http://127.0.0.1:53682/auth?...` を Windows ブラウザで開く
  (WSL2 は localhost 転送があるためそのまま開ける)。
- Google アカウントで許可すると `~/.config/rclone/rclone.conf` に保存される。

### 3. マウント

```bash
mkdir -p ~/gdrive
rclone mount gdrive: ~/gdrive \
  --vfs-cache-mode full \
  --vfs-cache-max-size 1G \
  --daemon \
  --log-file /tmp/rclone_mount.log
```

- `--vfs-cache-mode full`: ファイルをローカルにキャッシュし、編集・書き込みを安定させる。
- `--daemon`: セッション終了後もプロセスが残るようデタッチする
  (バックグラウンド `&` 起動だと kill されるので注意)。
- `scripts/mount-gdrive.sh` としてスクリプト化済み。

### 4. 自動マウント (WSL 起動時)

`~/.bashrc` に追記:

```bash
~/bin/mount-gdrive.sh
```

またはリポジトリのスクリプトを直接参照:

```bash
~/github/aktus-tk/ai-stack/scripts/mount-gdrive.sh
```

### 5. opencode からアクセス許可

`~/.config/opencode/opencode.json` に `external_directory` を追加する
(workspace 外のパスはデフォルトで `ask` になるため):

```json
{
  "permission": {
    "external_directory": {
      "~/gdrive/**": "allow"
    }
  }
}
```

`edit` を制限したい場合は `permission.edit` に `"~/gdrive/**": "deny"` を追加する。

## 運用

- アンマウント: `rclone unmount ~/gdrive`
- ステータス確認: `mountpoint -q ~/gdrive && echo mounted`
- キャッシュ容量は環境変数 `RCLONE_CACHE_MAX` で変更可 (default: 1G)

## 注意

- rclone マウントは完全な POSIX ではない。rename の atomicity やファイルロックが弱い。
  テキストファイル編集には十分実用に耐えるが、DB や VCS のワークツリーとしては不向き。
- 書き込みは VFS キャッシュ経由で行われるため、他クライアントとの同時編集時は
  反映ラグに注意する。
