# Skill: harness-mem 運用 (Granite embedding 統合)

harness-mem (remote memory service) の運用知識。**Granite embedding 統合後の
write path / read path** を中心に、何を壊さないか・どう拡張するかを示す。
既存 global skill (memory-commit / harness-recall) の reference として参照される。

## 構成

| Daemon | ポート | DB | 用途 | reindex scheduler |
|---|---|---|---|---|
| main (`harness-memd`) | `37888` | `/home/tk/.harness-mem/harness-mem.db` | 長期記憶 (canonical) | **有効** (converged 済み, tick は no-op) |
| working (`harness-memd-working`) | `37889` (内部 37888) | `/home/ai-working/.harness-mem/harness-mem.db` | 作業記憶 (working / 既定) | **無効** (OOM 防止, 手動 reindex 必須) |

- 接続先: 自宅 opencode から Tailscale IP `100.92.131.75:<port>` で HTTP 接続。
- 認証: 書き込み系 / admin 系は `Authorization: Bearer <token>` 必須。検索系は token 不要。
- vector engine: `js-fallback` (sqlite-vec 拡張なしの JS 実装。コサイン類似度総当たり。正しく動作、やや遅いのみ)。

## Granite embedding 統合

- **モデル:** `local:granite-embedding-311m-r2` (int8 ONNX, dim=384, Matryoshka 縮小)
- **プロバイダ設定:** `HARNESS_MEM_EMBEDDING_PROVIDER=auto` (compose.yaml で設定済み。
  未設定だと `getConfig()` が `fallback` (hash) になり granite が使われない)。
- **lazy init:** 初回検索時に worker 内でモデルロード (最大 ~60s)。
  `HARNESS_MEM_SEARCH_WORKER_TIMEOUT_MS=60000` / `STARTUP_TIMEOUT_MS=60000` で延長済み。
  再起動直後は health が `warming` になり得るが、初回検索で `ready` に遷移する (既知挙動)。

### Write path (観測保存 → granite vector)

```
/ v1/events/record で保存
        │
        ▼
observation 保存 (vector は fallback: local-hash-v3 が生成される)
        │
        ▼
POST /v1/admin/reindex-vectors  (手動実行, limit = 新規観測数 or 100)
        │
        ▼
granite vector (local:granite-embedding-311m-r2) 登録完了
  → vector_coverage: 1 / migration_complete: true
```

- **保存直後は必ず fallback vector**。`/v1/events/record` 応答の
  `meta.embedding_provider: "fallback"` で確認できる。
- working daemon は reindex scheduler が無効のため、新規観測は**手動 reindex が必須**。
- main daemon は scheduler 有効 (10 分間隔, batch 100, target 95%) だが converged 済み。
  新規観測も次回 tick で変換されるが、手動でも即時変換できる。
- reindex はモデルロードを含むため**数秒〜数十秒**かかる (実測: working 1 件 ≈ 9 秒)。
- reindex 後 `reindexed: 0` は「既に granite vector を持っている」= 正常。
- `mem_vectors` には変換済み観測の fallback 行が残る (PK = `observation_id+model`)。
  取得は current-model 優先なので retrieval には影響しない。

### Read path (検索 → granite embedding)

```
query
  │
  ▼
POST /v1/search {query, project, limit, debug:true}   ← project scope 必須
  │
  ▼
クエリを Granite embedding に自動変換 (手動生成不要)
  │
  ▼
lexical (FTS) + vector (semantic) hybrid ranking
  │
  ▼
meta: vector_search_enabled / vector_candidates / vector_coverage / vector_model
items[i].scores: lexical / vector / final
```

- **project scope 付きで実行しないと vector 重み付けが無効化される**:
  `internalLimit` が 15 に制限され `vector_coverage < 0.2` → `weights.vector = 0` になる
  (実測: `scores.vector: 0.000`)。project スコープ付きなら `vector_coverage: 1` (100%) で
  vector スコアが最終順位に反映される。
- `debug: true` を付けると `meta` に vector search の詳細
  (`vector_candidates` / `lexical_candidates` / `vector_coverage` / `vector_model` /
  `embedding_provider` / `vector_prefilter` / `weights` 等) が入る。
- クエリ embedding は自動生成のため、read path での手動 reindex は不要。

## API リファレンス

### POST /v1/events/record (admin token 必須)

```bash
curl -s -X POST \
  -H "Authorization: Bearer $HARNESS_MEM_WORKING_ADMIN_TOKEN" \
  -H 'content-type: application/json' \
  -d '{
    "event": {
      "platform": "opencode",
      "project": "<project>",
      "session_id": "<session_id>",
      "event_type": "decision|context|procedure|learned|open",
      "payload": { "title": "...", "content": "..." },
      "tags": ["memory_commit"]
    }
  }' \
  "http://100.92.131.75:37889/v1/events/record"
```

- 応答 `items[0].id` = observation id (例: `obs_xxxx`)。保存の証跡として必ず確認。
- 401 → token が無効/未指定。`HARNESS_MEM_ADMIN_TOKEN` (main) or
  `HARNESS_MEM_WORKING_ADMIN_TOKEN` (working) を確認。

### POST /v1/admin/reindex-vectors (admin token 必須)

```bash
curl -s -X POST \
  -H "Authorization: Bearer $HARNESS_MEM_WORKING_ADMIN_TOKEN" \
  -H 'content-type: application/json' \
  -d '{"limit": 100}' \
  "http://100.92.131.75:37889/v1/admin/reindex-vectors"
```

応答 `items[0]`:

| フィールド | 意味 | 正常時 |
|---|---|---|
| `reindexed` | 今回変換した件数 | 新規観測数 (0 = 変換済みで正常) |
| `vector_coverage` | granite vector カバレッジ | 1 (100%) |
| `current_model_vectors` | granite vector 保有数 | 全観測数 |
| `missing_vectors_remaining` | 未変換残 | 0 |
| `legacy_vectors_remaining` | 旧 vector 残 | 0 |
| `migration_complete` (meta) | 全変換完了 | true |

401 → admin token 未指定/誤り。検索系と違い **admin API は token 必須**。

### POST /v1/search (token 不要, project scope + debug:true)

```bash
curl -s -X POST -H 'content-type: application/json' \
  -d '{"query":"<query>","project":"<project>","limit":10,"debug":true}' \
  "http://100.92.131.75:37889/v1/search"
```

- 応答 `meta`: `vector_search_enabled` / `vector_candidates` / `lexical_candidates` /
  `vector_coverage` / `vector_model` / `embedding_provider` / `embedding_provider_status` /
  `ranking` (hybrid_v3)。
- 応答 `items[i].scores`: `lexical` (FTS) / `vector` (semantic) / `final` (hybrid 合成)。
- 401 は返らない (検索系は token 不要)。ただし project 未指定だと vector 無効化 (上記)。

## 何を壊してはいけないか

1. **`HARNESS_MEM_EMBEDDING_PROVIDER=auto` を外さない** — 外すと granite が使われず
   fallback (hash) に戻り、semantic 検索が機能しなくなる。
2. **working daemon の reindex scheduler を有効化しない** — main と同時刻に 299MB モデル
   ロードが走り 1.9GB RAM ホストで OOM になる (commit `c44c0cd` で無効化)。
   working の新規観測は手動 reindex (`/v1/admin/reindex-vectors`) で変換する。
3. **書き込み系に token を付け忘れない** — `/v1/events/record` と `/v1/admin/reindex-vectors`
   は admin token 必須。search 系と混同しない。
4. **シークレットをコミットしない** — token は `.env` (サーバー) / シェル env (クライアント) に保持。
   `.env.example` に雛形のみ。
5. **`docker compose build` をメモリ逼迫時に実行しない** — 1.9GB RAM 環境だとクラッシュしうる
   (AGENTS.md の鉄則)。キャッシュを活かすか不要コンテナを先に止める。
6. **模型/モデルの無断変更をしない** — granite-embedding-311m-r2 から 97M モデルへの切替は
   全ベクトルの次元再計算が必要。明示指示があるまで変更しない。

## 検証

```bash
# health (granite 稼働確認)
curl -s http://100.92.131.75:37888/v1/health | python3 -m json.tool   # main
curl -s http://100.92.131.75:37889/v1/health | python3 -m json.tool   # working
#   期待値: embedding_ready: true / embedding_readiness_state: ready /
#           embedding_provider: local / vector_model: local:granite-embedding-311m-r2

# vector 変換状況 (SQL, main)
sudo sqlite3 /home/tk/.harness-mem/harness-mem.db \
  "SELECT COUNT(*) AS total,
          COUNT(CASE WHEN model='local:granite-embedding-311m-r2' THEN 1 END) AS granite,
          COUNT(CASE WHEN model!='local:granite-embedding-311m-r2' THEN 1 END) AS fallback
   FROM mem_vectors;"
#   working は DB パスを /home/ai-working/.harness-mem/harness-mem.db に変えて実行

# 検索 meta 確認 (project scope + debug:true)
curl -s -X POST -H 'content-type: application/json' \
  -d '{"query":"<query>","project":"<project>","limit":5,"debug":true}' \
  "http://100.92.131.75:37889/v1/search" | python3 -m json.tool
#   期待値: vector_search_enabled: true / vector_coverage: 1 / scores.vector > 0
```

## 関連

- 移行・モニタリング手順 → `runbooks/harness-mem-granite-migration.md`
- 検証レポート → `docs/granite-embedding-verification.md`
- 保存フロー (global skill) → `~/.agents/skills/memory-commit/SKILL.md`
- 検索フロー (global skill) → `~/.agents/skills/harness-recall/SKILL.md`
- opencode 運用 → `skills/opencode/SKILL.md`