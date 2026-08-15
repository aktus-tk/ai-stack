# Runbook: harness-mem の Docker Compose 移行

システム運用を systemd から ai-stack Compose へ移行する手順。
2026-08-15 に実行実績あり (systemd → Docker 移行完了)。

## 背景

- 旧: `harness-memd.service` (systemd) が `~/.harness-mem` の SQLite DB を管理
- 新: `compose.yaml` の `harness-memd` service が同一 DB を bind mount で管理

## 重要な注意

- **systemd と Docker の両方が同じ DB を開いてはいけない** (SQLite 破損の恐れ)。
  必ず片方だけ起動する。
- DB は **WAL モード**。バックアップは `VACUUM INTO` で一貫スナップショットを取る。

## 手順

### 1. バックアップ (VACUUM INTO)

```bash
mkdir -p /home/tk/backups/harness-mem
sqlite3 ~/.harness-mem/harness-mem.db \
  "VACUUM INTO '/home/tk/backups/harness-mem/pre-docker-migrate.db'"
sqlite3 /home/tk/backups/harness-mem/pre-docker-migrate.db "PRAGMA integrity_check;"
```

### 2. systemd harness-memd 停止

```bash
sudo systemctl stop harness-memd
sudo systemctl disable harness-memd
```

プロセスが残っていないこと:

```bash
ps aux | grep -E "harness-memd|memory-server" | grep -v grep
```

### 3. compose の harness-memd 起動

```bash
cd ~/github/aktus-tk/ai-stack
docker compose up -d harness-memd
```

### 4. 検証

```bash
# compose 内から health 確認
docker run --rm --network ai-stack_default \
  curlimages/curl -s http://harness-memd:37888/health

# DB 整合性・件数 (ホストから)
sqlite3 ~/.harness-mem/harness-mem.db "PRAGMA integrity_check;"
sqlite3 -header -column ~/.harness-mem/harness-mem.db \
  'SELECT (SELECT count(*) FROM mem_observations) AS obs,
          (SELECT count(*) FROM mem_sessions) AS sessions,
          (SELECT count(*) FROM mem_facts) AS facts;'
```

移行前後の件数が一致すること。

### 5. 全体検証

```bash
cd ~/github/aktus-tk/ai-stack && ./scripts/verify.sh
```

## Rollback

```bash
docker compose stop harness-memd
sudo systemctl start harness-memd
```

## 補足

- compose の `harness-memd` は `HARNESS_MEM_HOME=/home/tk/.harness-mem` で
  DB を bind mount する。
- memory daemon 起動は `bun run .../memory-server/src/index.ts` (npm global の実パス)。
  `/opt/harness-mem` (symlink) 経由だと bun が module 解決に失敗するため実パス指定。

## 関連

- 全体構成 → `compose.yaml`
- 検証 → `scripts/verify.sh`
- Granite embedding 切替 (推奨・未実施) → `skills/harness-mem/SKILL.md`
