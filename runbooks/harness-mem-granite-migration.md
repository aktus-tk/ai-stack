# harness-mem Granite Embedding Migration — Baseline & Monitoring Guide

- **Date (UTC):** 2026-08-17T06:55Z
- **Decision:** Option A — reindex-vectors scheduler handles the migration automatically
- **Model:** `local:granite-embedding-311m-r2` (int8 ONNX, 313 MB on disk, dim=384)
- **Host:** x (162.43.21.240), 1.9 GiB RAM + 6.0 GiB swap (2.0 GiB original + 4.0 GiB added)

---

## 1. Baseline Numbers (captured 2026-08-17 ~06:05Z, before conversion started)

### Main daemon — `ai-stack-harness-memd-1` (port 37888, DB `/home/tk/.harness-mem/harness-mem.db`)

| Metric | Value |
|---|---|
| mem_vectors total | 5,485 |
| granite (`local:granite-embedding-311m-r2`) | 26 |
| fallback (`fallback:local-hash-v3`) | 5,459 |
| observations (live) | 5,634 |
| embedding_ready / status | true / ok |

### Working daemon — `ai-stack-harness-memd-working-1` (port 37889, DB `/home/ai-working/.harness-mem/harness-mem.db`)

| Metric | Value |
|---|---|
| mem_vectors total | 71 |
| granite | 34 (all 34 live observations already converted) |
| fallback | 37 (stale duplicates of converted obs + archived obs) |
| observations (live) | 34 |
| embedding_ready / status | true / ok (before restart; now lazy-init pending — see §4) |

### Progress as of 06:55Z (main): 176 granite / 5,635 total — conversion underway.

---

## 2. Scheduler Configuration (verified)

| Setting | Value | Env var |
|---|---|---|
| Interval | 10 min (600,000 ms) | `HARNESS_MEM_REINDEX_VECTORS_INTERVAL_MS` |
| Batch size | 100 vectors/tick | `HARNESS_MEM_REINDEX_VECTORS_BATCH_SIZE` |
| Target coverage | 95% | (config) |
| Concurrency | 4 (default) | `HARNESS_MEM_REINDEX_VECTORS_CONCURRENCY` |
| Main daemon | **enabled** (`HARNESS_MEM_REINDEX_VECTORS_ENABLED=true`) | |
| Working daemon | **disabled** (converged; prevents OOM) | |

Commits:
- `b599aea` Enable reindex-vectors scheduler for granite embedding migration
- `c44c0cd` Disable reindex scheduler on working daemon (converged; prevents OOM double model-load)

---

## 3. How to Check Progress

### 3a. Vector conversion progress (SQL)

Main:
```bash
sudo sqlite3 /home/tk/.harness-mem/harness-mem.db \
  "SELECT COUNT(*) AS total,
          COUNT(CASE WHEN model='local:granite-embedding-311m-r2' THEN 1 END) AS granite,
          COUNT(CASE WHEN model!='local:granite-embedding-311m-r2' THEN 1 END) AS fallback
   FROM mem_vectors;"
```

Working:
```bash
sudo sqlite3 /home/ai-working/.harness-mem/harness-mem.db \
  "SELECT COUNT(*) AS total,
          COUNT(CASE WHEN model='local:granite-embedding-311m-r2' THEN 1 END) AS granite,
          COUNT(CASE WHEN model!='local:granite-embedding-311m-r2' THEN 1 END) AS fallback
   FROM mem_vectors;"
```

Model distribution:
```bash
sudo sqlite3 /home/tk/.harness-mem/harness-mem.db "SELECT model, COUNT(*) FROM mem_vectors GROUP BY model;"
```

### 3b. Daemon health

```bash
curl -s http://100.92.131.75:37888/v1/health | python3 -m json.tool   # main
curl -s http://100.92.131.75:37889/v1/health | python3 -m json.tool   # working
```

Key fields: `status` (ok|degraded), `embedding_ready`, `embedding_readiness_state`
(ready|warming), `embedding_provider_details` (should show
`local ONNX: granite-embedding-311m-r2 (dim=384)`), `embedding_provider_status` (healthy).

### 3c. Scheduler activity (logs)

```bash
docker logs ai-stack-harness-memd-1 -t --since 30m | grep -E "reindex|tick|converged"
```

Healthy pattern every ~10 min: `tick: reindexed batch { reindexed: N, ... }`.

### 3d. Memory / swap

```bash
docker stats --no-stream | grep harness
free -h
cat /proc/swaps
```

---

## 4. Expected Timeline

- **Main daemon:** conversion began 2026-08-17 ~06:41Z. First two ticks backfilled 150
  vectorless observations (26 → 176 granite). The remaining **~5,459 fallback-only
  observations** convert at ~100 per 10-min tick → **~9 hours** (expected completion
  around **2026-08-17 ~15:45–16:00Z**). If a tick reindexes fewer than 100 (new
  observations, ingest load), completion may slip by a few hours.
- **Working daemon:** already complete (34/34 live observations granite). Stale fallback
  duplicates (37 rows) are harmless and are not processed.

### Success criteria (completion check)

All live observations have a granite vector:
```bash
sudo sqlite3 /home/tk/.harness-mem/harness-mem.db \
  "SELECT COUNT(*) FROM mem_observations o WHERE o.archived_at IS NULL
   AND NOT EXISTS (SELECT 1 FROM mem_vectors v WHERE v.observation_id=o.id
                   AND v.model='local:granite-embedding-311m-r2');"
-- expected: 0
```
Expected log line on the main daemon:
`converged — vector coverage target reached { coverage: ≥0.95, ... }`

Note: `fallback:local-hash-v3` rows for already-converted observations remain in
`mem_vectors` (PK is `observation_id+model`, so converted obs keep their old row). They
do not affect retrieval (current-model predicate wins) and are not re-processed.

---

## 5. Known Issue — Host OOM During Model Load (2026-08-17)

**Symptom:** `ai-stack-harness-memd-1` was OOM-killed (exit 137) 3 times (06:10, 06:21,
06:31Z) whenever the scheduler tick loaded the 311M ONNX model. Working daemon also OOMed
once. Host load spiked to 131; sshd became unresponsive during thrashing.

**Root cause:** host has only 1.9 GiB RAM. Running services (main ~300–430 MB, working
~285 MB, opencode-server ~460 MB, OS ~500 MB) leave <300 MB free; the model load needs
~500 MB–1 GB working set. With both daemons' ticks aligned (both restarted ~06:00Z,
both tick ~06:10Z) the double load guaranteed OOM.

**Mitigation applied:**
1. Disabled the reindex scheduler on the working daemon (commit `c44c0cd`) — it had
   already converged, so the scheduler only caused synchronized model loads.
2. Added a 4 GiB swapfile (`/swapfile2`, persisted in `/etc/fstab`) → 6 GiB total swap.
   Model load now spills to swap; conversion proceeds (verified: two consecutive ticks
   completed, 100 + 50 vectors, no OOM).

**Residual risk:** swap is heavily used (4.4/6.0 GiB). Embedding speed is CPU-bound and
unaffected; however the host is memory-tight. Recommended durable fix: **upgrade host RAM
to 4 GiB** (or move the working daemon to another host). Alternative: switch to the 97M
granite model (lower memory) — requires reindexing all vectors (dimension change) and a
coordinated model swap; do NOT do this mid-migration.

---

## 6. Troubleshooting

### 6a. OOM / container crash-loop (exit 137, `Restarting`)

1. Check: `docker inspect ai-stack-harness-memd-1 --format '{{.RestartCount}} {{.State.OOMKilled}}'`
2. Confirm swap exists: `cat /proc/swaps` (should show 6 GiB; `/swapfile2` 4 GiB).
3. If swap is missing, recreate it:
   ```bash
   sudo fallocate -l 4G /swapfile2 && sudo chmod 600 /swapfile2
   sudo mkswap /swapfile2 && sudo swapon /swapfile2
   ```
   (already in `/etc/fstab` — survives reboot)
4. Reduce concurrent load: `docker stop ai-stack-harness-memd-working-1` temporarily
   (it is converged; stopping it frees ~300 MB and removes one model-load path).
5. Docker auto-restarts the daemon (`restart: unless-stopped`). Conversion resumes at the
   next tick; progress is incremental and safe (batch of 100, DB writes are transactional).

### 6b. Scheduler stopped / no tick logs

```bash
docker logs ai-stack-harness-memd-1 --tail 50 | grep -i reindex
docker inspect ai-stack-harness-memd-1 --format '{{range .Config.Env}}{{println .}}{{end}}' | grep REINDEX
```
Should show `HARNESS_MEM_REINDEX_VECTORS_ENABLED=true`. If disabled, `docker compose up -d harness-memd`
(recreates from compose.yaml). Manual trigger (one-off): POST `/v1/admin/reindex-vectors`
with admin token.

### 6c. Embedding errors / `warming` stuck

- `warming` + `lazy initialization pending` is normal until a search/tick triggers the
  load (up to ~60 s with the raised worker timeout). First search on the working daemon
  will warm it.
- If `embedding_readiness_state` stays non-ready after a tick, check
  `docker logs ai-stack-harness-memd-1 --tail 100` for model load errors.

### 6d. How to cancel / roll back

- Disable the scheduler (stop conversion) by setting in compose.yaml:
  `HARNESS_MEM_REINDEX_VECTORS_ENABLED: "false"` (both services), then
  `docker compose up -d harness-memd harness-memd-working`. Already-converted vectors
  remain valid (granite is the current default model).
- To revert to fallback embeddings entirely, change
  `HARNESS_MEM_EMBEDDING_PROVIDER: auto` → (unset) in compose.yaml and restart. The DB
  `embedding_default_model` flag and `fallback:local-hash-v3` rows are still present, so
  fallback mode remains fully functional.

---

## 7. Monitoring Commands — One-Liner

```bash
# progress (main)
while true; do
  G=$(sudo sqlite3 /home/tk/.harness-mem/harness-mem.db \
      "SELECT COUNT(CASE WHEN model='local:granite-embedding-311m-r2' THEN 1 END) FROM mem_vectors;")
  echo "$(date -u +%H:%M:%SZ) granite=$G"
  sleep 300
done
```
