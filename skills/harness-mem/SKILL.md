# Skill: harness-mem 運用

harness-mem の記憶 DB・daemon を扱うための運用知識。

## 何を壊してはいけないか

1. **稼働中の DB を直接コピーしない** — SQLite は WAL モード。`db` だけコピーすると
   WAL 内の書き込みが消える。必ず `VACUUM INTO` で一貫スナップショットを取る。
2. **daemon を別の場所で二重起動しない** — ポート 37888 は単一 daemon が使用。
   systemd で管理されている。
3. **bind 先を勝手に `0.0.0.0` にしない** — 現状 Tailscale IP のみにバインド。
   公開バインドすると攻撃面が増える。必要な場合は必ず認証設定と合わせること。
4. **`--reset` 付きバックフィルは検索精度が一時低下する** — 全ベクトル再計算のため。
   影響範囲を理解してから実行する。

## 構成

- daemon: systemd ユニット `harness-memd.service` (サーバー)
- DB: `~/.harness-mem/harness-mem.db` (WAL)
- ログ: `~/.harness-mem/daemon.log`, `harness-mem-ui.log`
- バインド: `100.92.131.75:37888` (Tailscale) / UI `37901`
- 認証: `HARNESS_MEM_ADMIN_TOKEN` (Bearer)。ただし 401 強制は config.json の
  `auth` セクション設定時のみ (詳細は architecture/security.md)

## よく使う操作

```bash
# 状態確認
ssh x 'systemctl status harness-memd'
curl -s http://100.92.131.75:37888/health

# 再起動
ssh x 'sudo systemctl restart harness-memd'

# DB 件数確認
ssh x "sqlite3 ~/.harness-mem/harness-mem.db \
  'SELECT (SELECT count(*) FROM mem_observations) AS obs, \
          (SELECT count(*) FROM mem_sessions) AS sessions, \
          (SELECT count(*) FROM mem_facts) AS facts;'"
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
