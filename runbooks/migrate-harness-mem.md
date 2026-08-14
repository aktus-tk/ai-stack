# Runbook: harness-mem の移行 (migrate-harness-mem)

ローカル (クライアント) で稼働していた harness-mem の SQLite DB を
中央サーバーの daemon に移行する手順。2026-08-14 に実行実績あり。

## 背景

- ローカル: `~/.harness-mem/harness-mem.db` (WAL モード)
- 移行先: サーバー `ssh x` の `~/.harness-mem/harness-mem.db`

## 重要な注意

- DB は **WAL モード**。`harness-mem.db` だけコピーすると WAL 内の未コミット書き込みが
  抜けて古い状態になる。**稼働中のファイルを直接コピーしない**こと。
- 両端の daemon を止めるか、`VACUUM INTO` で一貫スナップショットを作る。
- サーバーに既存データがある場合はバックアップを先に取る。

## 手順

### 1. ローカルで一貫スナップショット作成 (daemon 停止不要)

```bash
sqlite3 ~/.harness-mem/harness-mem.db "VACUUM INTO '/tmp/harness-mem-migrate.db';"
sqlite3 /tmp/harness-mem-migrate.db "PRAGMA integrity_check;"   # → ok
```

`VACUUM INTO` は WAL 込みの一貫スナップショットを1ファイルに固める。

### 2. リモート daemon 停止 → 既存DB退避

```bash
ssh x '~/.volta/bin/harness-memd stop'
ssh x 'cp ~/.harness-mem/harness-mem.db ~/.harness-mem/harness-mem.db.bak-$(date +%Y%m%d)'
ssh x 'rm -f ~/.harness-mem/harness-mem.db-wal ~/.harness-mem/harness-mem.db-shm'
```

### 3. 転送・置換

```bash
scp /tmp/harness-mem-migrate.db x:~/.harness-mem/harness-mem.db
```

### 4. 起動・検証

```bash
# PATH に bun / volta を通す (非ログインSSHでは通らないため)
ssh x 'export PATH="$HOME/.bun/bin:$HOME/.volta/bin:$PATH"; harness-memd start'

# 件数・整合性チェック
ssh x "sqlite3 -header -column ~/.harness-mem/harness-mem.db \
  'SELECT (SELECT count(*) FROM mem_observations) AS obs, \
          (SELECT count(*) FROM mem_sessions) AS sessions, \
          (SELECT count(*) FROM mem_facts) AS facts;'"
ssh x 'sqlite3 ~/.harness-mem/harness-mem.db "PRAGMA integrity_check;"'
```

移行前後の件数が一致することを確認。

## ローカル側の後始末

移行後、ローカル daemon を止めるか、残すかは用途による。
ローカルにも同じ DB があるので、記憶は二重に存在する。

## 関連

- 移行後に推奨される Granite embedding 切替 → `skills/harness-mem/SKILL.md`
