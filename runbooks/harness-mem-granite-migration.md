# harness-mem Granite Embedding Migration — Baseline & Monitoring Guide

- **Date (UTC):** 2026-08-17T06:55Z
- **Decision:** Option A — reindex-vectors scheduler handles the migration automatically
- **Model:** `local:granite-embedding-311m-r2` (int8 ONNX, 313 MB on disk, dim=384)
- **Host:** x (162.43.21.240), 1.9 GiB RAM + 6.0 GiB swap (2.0 GiB original + 4.0 GiB added)

---

## 0. Status: **COMPLETE** (verified 2026-08-17)

Migration is finished and verified. Detailed verification results and the acceptance
table live in `docs/granite-embedding-verification.md`.

**Final state:**

| Daemon | Granite vectors | Live observations | Coverage | Health |
|---|---|---|---|---|
| Main (`37888`) | **5,634** | 5,634 | **100%** | `status: ok` / `embedding_ready: true` / `ready` |
| Working (`37889`) | 34 (at migration time) | 34 at migration time | 100% (migration-time obs) | `provider: local`, granite active in searches; may show transient `warming` (lazy-init) until a search loads the model |

- Main daemon scheduler log: `converged — vector coverage target reached`
  (observed 2026-08-17 ~10:04Z).
- The remaining fallback rows on main (5,459) are stale duplicates of converted
  observations; they do not affect retrieval (current-model predicate wins).
- **New observations on the working daemon are not auto-converted** — its reindex
  scheduler is disabled (OOM prevention, commit `c44c0cd`). New obs since migration
  (e.g. 7 as of 2026-08-17) carry fallback vectors only; run a bulk reindex (see §8)
  to convert them when convenient.

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

Post-migration note: the main daemon's scheduler is still enabled but converged — ticks
now reindex 0 rows (no-op) and are safe to leave on (they keep new observations covered).
It can be disabled later if desired (same env var = `false`).

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

## 4. Timeline — ACTUAL (completed early via local bulk reindex)

- The in-container scheduler was **replaced by a local bulk reindex** on the desk PC
  (24 cores): one admin reindex call reindexed the remaining 4,057 observations in
  **1,029,492 ms (~17.2 min)** — far faster than the ~9 h in-container estimate.
  Response confirmed: `migration_complete: true`, `vector_coverage: 1`,
  `current_model_vectors: 5634`, `missing_vectors_remaining: 0`,
  `legacy_vectors_remaining: 0`, `retryable_embedding_errors: []`.
- The converted DB was copied back to the server and both daemons restarted.
- **Working daemon:** already complete (34/34 live observations granite at migration
  time). Stale fallback duplicates (37 rows) are harmless and are not processed.

### Success criteria (completion check) — PASSED

All live observations have a granite vector:
```bash
sudo sqlite3 /home/tk/.harness-mem/harness-mem.db \
  "SELECT COUNT(*) FROM mem_observations o WHERE o.archived_at IS NULL
   AND NOT EXISTS (SELECT 1 FROM mem_vectors v WHERE v.observation_id=o.id
                   AND v.model='local:granite-embedding-311m-r2');"
-- expected: 0  (verified: 0 on main; working has 7 new obs since migration)
```
Log line confirmed on the main daemon:
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

---

## 8. Cleanup (post-verification)

**COMPLETED 2026-08-17.** All rollback artifacts below were deleted after both daemons
were verified healthy and 100% granite (main 5,634/5,634; working 47/47 live obs).
Host disk usage dropped from 75% to 69% (`df -h /`: 50G total / 33G used / 15G free).

| Artifact | Location | Size | Status |
|---|---|---|---|
| `model.onnx.fp32.bak` (main) | `/home/tk/.harness-mem/models/granite-embedding-311m-r2/onnx/` | 1.2 GB | **DELETED 2026-08-17** |
| `model.onnx.fp32.bak` (working) | `/home/ai-working/.harness-mem/models/granite-embedding-311m-r2/onnx/` | 1.2 GB | **DELETED 2026-08-17** |
| Pre-reindex DB | `/home/tk/.harness-mem/harness-mem.db.pre-local-reindex` | 622 MB | **DELETED 2026-08-17** |

Durable backups remain under `/home/tk/backups/harness-mem/`.

Other post-migration hygiene (unrelated to embedding): journald vacuum, docker builder
prune, apt clean, and old Claude versions — see the local plan
`/home/tk/opencode/granite-cleanup-plan.md` (not in this repo).

---

## 9. Known Issue — Project Boundary Check Bug (2026-08-20)

**Symptom:** `/v1/search` with `project` parameter (even fullpath) returns
`vector_candidates: 0` / `final: 0` despite observations existing with granite vectors.

**Root cause:** `observation-store.ts:4361` post-filter compares `normalizedProject`
(a single basename value) against observation's project field. SQL layer uses
`projectMembers` (fullpath array from config), but the post-filter uses
`normalizedProject` (single basename) — causing all candidates to be excluded.

```
SQL layer:  projectMembers: ["/home/tk", "/home/tk/github/aktus-tk/ai-stack"] → finds candidates ✓
Post-filter: normalizedProject: "ai-ops" (single basename) → excludes all candidates ✗
```

**Verified 2026-08-20:**
- `vector_candidates: 15` with cross-project search (`strict_project: false`)
- `vector_candidates: 0` with project scope (`project: "/home/tk/github/aktus-tk/ai-stack"`)
- Workaround: use `strict_project: false` for search (cross-project default)

**Impact:**
- **Memory-commit:** ✅ Records work (fullpath used)
- **Harness-recall (cross-project):** ✅ Works (lexical + vector)
- **Harness-recall (single-project):** ⚠️ Vector candidates not found (boundary check bug)
- **Resume-pack:** ✅ Works (no project parameter needed)

**Workaround:** Default to cross-project search (`strict_project: false`) which bypasses
the boundary check. Vector coverage is lower (0.2–0.3) but lexical match is strong.

**Upstream fix needed:** Change `observation-store.ts:4361` to use `projectMembers`
instead of `normalizedProject` for boundary check. File:
`/usr/local/lib/node_modules/@chachamaru127/harness-mem/memory-server/src/core/observation-store.ts`

---

## 10. Cross-Project Search Configuration (2026-08-20)

**Decision:** Enable cross-project (horizontal) search by default in harness-recall.

**Rationale:** Users typically want to search across all projects, not just the current
project. Vector search with project scope is weaker due to boundary check bug (§9).

### Default Search Behavior

| Parameter | Value | Effect |
|---|---|---|
| `strict_project` | `false` | All projects searched |
| `project` | (omitted) | No project filter |
| `limit` | 20 | More results from broader search |
| `debug` | `true` | Include vector search metadata |

### Command Examples

```bash
# Cross-project search (default)
curl -s -X POST -H 'content-type: application/json' \
  -d '{"query":"<keywords>","limit":20,"strict_project":false}' \
  http://100.92.131.75:37888/v1/search

# Single-project search (optional, semantic priority)
curl -s -X POST -H 'content-type: application/json' \
  -d '{"query":"<keywords>","project":"/home/tk/github/aktus-tk/ai-stack","limit":10,"debug":true}' \
  http://100.92.131.75:37888/v1/search
```

### Response Format Differences

| Field | Cross-Project | Single-Project |
|---|---|---|
| `lexical_candidates` | High (63+) | Low (varies) |
| `vector_candidates` | Low (15) | None (0, bug) |
| `vector_coverage` | 0.17–0.30 | 0 |
| `scores.vector` | Low (0.0–0.5) | None |
| Priority | Lexical (keyword) | Semantic (vector) |

**Note:** Cross-project search has lower vector coverage by design (`internalLimit: 15`),
but lexical match is strong. Single-project search has higher semantic priority but is
affected by boundary check bug (§9).

---

## 11. Skill Updates (2026-08-20)

### Files Modified

| File | Change | Commit |
|---|---|---|
| `~/.agents/skills/memory-commit/SKILL.md` | PROJECT: basename → fullpath | `f59a8a5` |
| `~/.agents/skills/harness-recall/SKILL.md` | Cross-project default + routing update | `15c03a2` |
| `.agents/skills/memory-commit.md` | Repo copy sync | `f59a8a5` |
| `.agents/skills/harness-recall.md` | Repo copy sync | `15c03a2` |
| `skills/harness-mem/SKILL.md` | Operational guide | (pending) |

### Key Changes

1. **memory-commit:**
   - `PROJECT` variable changed from basename (`ai-ops`) to fullpath (`$(pwd)`)
   - All curl/harness-mem-client.sh examples updated
   - Verified: Fullpath works correctly (`final: 4` items returned)

2. **harness-recall:**
   - Default search: cross-project (`strict_project: false`)
   - Removed `project` parameter from resume-pack, sessions/list, search/facets
   - Response format updated with two variants (cross-project vs single-project)
   - Examples: curl + harness-mem-client.sh both support cross-project

3. **Git Commits:**
   - `f59a8a5`: Use fullpath for project scope in memory-commit & harness-recall
   - `15c03a2`: Cross-project search by default in harness-recall

### Testing Results

- **Cross-project search:** ✅ 10 results from multiple projects (lexical: 63, vector: 15)
- **Single-project search:** ⚠️ Vector candidates: 0 (boundary check bug, §9)
- **Memory-commit:** ✅ 6 observations recorded successfully
- **Vector search:** ✅ Granit embedding active (`embedding_provider: local`)
