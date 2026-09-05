---
name: install-cli-tools
description: クラウド CLI (tccli / tcclit / gcloud / gcloudt / awst / az 等) が command not found になった場合のインストール・PATH 確認手順。Use when コマンドが見つからない、CLI が無い、pipx / tccli / Azure CLI / cloud-cli ラッパーのインストール、~/.local/bin や ~/bin の PATH 設定確認が必要なとき。対象: plgl, iron, dmdb, choco, visualive, visualize。
---

# install-cli-tools

クラウド CLI コマンドが `command not found` になる場合のインストール手順と動作確認方法。

## 1. pipx

pipx はユーザー単位で Python CLI ツールをインストールするためのツール。

```bash
sudo apt-get install -y pipx
pipx --version   # 例: 1.7.1 (Debian 13 で確認)
```

- pipx でインストールしたアプリは `~/.local/bin` に配置される。
- `~/.local/bin` が PATH に含まれていること (`echo $PATH`) を確認する。含まれていなければシェル設定 (`~/.bashrc` 等) に `export PATH="$HOME/.local/bin:$PATH"` を追加する。

## 2. tccli (Tencent Cloud CLI)

```bash
pipx install tccli
which tccli    # ~/.local/bin/tccli になること
tccli --version   # 例: 3.1.160.1 (2026-09-03 時点)
```

## 3. tcclit / gcloudt / awst (cloud-cli ラッパー)

`tcclit` / `gcloudt` / `awst` は `~/github/aktus-tk/cloud-cli/` 配下のラッパーで、実体は以下の場所にある。

| コマンド | 実体 |
|---|---|
| tcclit | `~/github/aktus-tk/cloud-cli/tc-cli/bin/tcclit` |
| gcloudt | `~/github/aktus-tk/cloud-cli/g-cli/bin/gcloudt` |
| awst | `~/github/aktus-tk/cloud-cli/aws-cli/bin/awst` |

通常は `~/bin` へのシンボリックリンク経由で使用する:

```bash
ls -la ~/bin/tcclit   # -> ~/github/aktus-tk/cloud-cli/tc-cli/bin/tcclit
```

欠如時は:
- シンボリックリンクを再作成する: `ln -s ~/github/aktus-tk/cloud-cli/tc-cli/bin/tcclit ~/bin/tcclit` (gcloudt / awst も同様)。
- `~/bin` が PATH に含まれているか確認する (`echo $PATH`)。

## 4. tcclit の profile 注入メカニズム

- tcclit は `TENCENTCLOUD_PROFILE` 環境変数が設定されていれば `tccli --profile $TENCENTCLOUD_PROFILE` を自動注入する (`_shims/tccli` が実装)。
- `.envrc` 経由で使用する: `direnv exec projects/iron tcclit ...` のようにする。
- iron 用の `.envrc` は `projects/iron/.envrc` に存在し `TENCENTCLOUD_PROFILE=iron` を設定している (plgl は `~/github/visualize-takeshita/tc-plgl-tf/.envrc` 側にあり、ai-ops の `projects/plgl/` には .envrc は無い)。
- 前提として `tccli configure` に iron / plgl プロファイルが登録済みであること (確認済み)。

```bash
tccli configure list   # プロファイルの存在確認
tccli configure get secretId --profile=iron   # マスク表示される
```

## 5. gcloud

- 標準インストール先は `/opt/google-cloud-sdk/bin/gcloud`。
- 欠如時は Google Cloud SDK の公式手順 (https://cloud.google.com/sdk/docs/install) を参照してインストールする。

```bash
which gcloud   # /opt/google-cloud-sdk/bin/gcloud
gcloud version
```

## 6. Azure CLI (`az`)

- 標準インストール先は `/usr/bin/az` (Debian/Ubuntu パッケージ)。
- 欠如時は Microsoft 公式の Debian インストールスクリプトを使う:

```bash
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
which az       # /usr/bin/az
az version
```

## 7. インストール後の動作確認

```bash
tccli --version                  # 例: 3.1.160.1
tcclit cvm ls                    # profile 込み (direnv exec <dir> 経由)
direnv exec projects/iron tcclit cvm ls   # プロジェクト指定の例
gcloud version                   # 例: Google Cloud SDK 576.0.0
az version                       # Azure CLI
aws --version                    # AWS CLI (この環境では未インストールの場合あり。awst ラッパーの実体は cloud-cli/aws-cli 配下)
```

## 注意

- 認証情報 (secretId / secretKey の値) はファイルやログに記録しない。
- `tccli configure list` でプロファイル存在確認ができる。`tccli configure get secretId --profile=<名>` はマスク表示される。
- `.envrc` には `TENCENTCLOUD_SECRET_ID` / `TENCENTCLOUD_SECRET_KEY` が `tccli configure get` 経由で展開されるため、`.envrc` の内容をログやドキュメントへそのまま転記しない。