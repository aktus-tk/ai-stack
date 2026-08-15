# Skill: harness-mem 運用

harness-mem の記憶 DB・daemon を扱うための運用知識。

## 何を壊してはいけないか

1. **稼働中の DB を直接コピーしない** — SQLite は WAL モード。`db` だけコピーすると
   WAL 内の書き込みが消える。必ず `VACUUM INTO` で一貫スナップショットを取る。
2. **systemd と Docker の daemon を同時起動しない** — 同一 SQLite DB を共有するため。
   移行は `runbooks/migrate-harness-mem.md` の手順に従う。
3. **daemon の起動コマンドは npm global の実パスで指定** — `/opt/harness-mem` (symlink)
   経由だと bun が module 解決に失敗する。実パス
   `/usr/local/lib/node_modules/@chachamaru127/harness-mem/memory-server/src/index.ts` を使う。
4. **bind 先を勝手に `0.0.0.0` (ホスト公開) にしない** — compose 内では `0.0.0.0` だが
   ホストへ publish しない。公開バインドすると攻撃面が増える。
5. **`--reset` 付きバックフィルは検索精度が一時低下する** — 全ベクトル再計算のため。
   影響範囲を理解してから実行する。

## 構成

- daemon: compose `harness-memd` (ai-stack)
- DB: `~/.harness-mem/harness-mem.db` (WAL)
- ログ: `~/.harness-mem/daemon.log`, `harness-mem-ui.log`
- バインド: compose 内 `harness-memd:37888` (ホストへは publish しない)
- 認証: `HARNESS_MEM_ADMIN_TOKEN` (Bearer)。ただし 401 強制は config.json の
  `auth` セクション設定時のみ (詳細は architecture/security.md)

## よく使う操作

```bash
# 状態確認
cd ~/github/aktus-tk/ai-stack && docker compose ps
docker compose exec harness-memd curl -s http://127.0.0.1:37888/health

# 再起動
cd ~/github/aktus-tk/ai-stack && docker compose restart harness-memd

# DB 件数確認 (ホストから)
sqlite3 ~/.harness-mem/harness-mem.db \
  'SELECT (SELECT count(*) FROM mem_observations) AS obs, \
          (SELECT count(*) FROM mem_sessions) AS sessions, \
          (SELECT count(*) FROM mem_facts) AS facts;'
```

## バックアップ

```bash
./scripts/backup-harness.sh   # VACUUM INTO で一貫スナップショットを保存
```

## Granite embedding 移行 (推奨・未実施)

日本語クロスリンガル精度向上のため、embedding を Granite に切替えるのが推奨。

- 効果: 複合スコア +0.20 / 日本語クロスリンガル 0.54 → 0.96
- 注意: `--reset` で全ベクトル再計算。移行中は検索精度が一時低下。

```bash
export PATH="$HOME/.bun/bin:$HOME/.volta/bin:$PATH"
harness-mem model pull granite-embedding-311m-r2 --yes \
  && harness-mem admin-vector-backfill start --model granite-embedding-311m-r2 --dimension 384 --reset \
  && bun run scripts/s154-granite-flag-set.ts --execute --to granite-embedding-311m-r2@384 \
  && harness-mem model use-default \
  && scripts/harness-memd restart
```

## 関連

- 移行手順 → `runbooks/migrate-harness-mem.md`
- セキュリティ → `architecture/security.md`
- 障害復旧 → `runbooks/disaster-recovery.md`
