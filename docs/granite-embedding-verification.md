# Granite Embedding Migration — Verification Report

- **Date:** 2026-08-17 (UTC)
- **Status:** 完了・検証済み (COMPLETE & VERIFIED)
- **対象:** main daemon (`100.92.131.75:37888`) / working daemon (`100.92.131.75:37889`)
- **モデル:** `local:granite-embedding-311m-r2` (dim=384, Matryoshka 縮小)
- **経緯・移行手順:** `runbooks/harness-mem-granite-migration.md`
- **運用メモ:** `skills/harness-mem/SKILL.md`

---

## 1. 完了時の最終状態

| Daemon | live 観測数 | granite ベクトル数 | カバレッジ | health |
|---|---|---|---|---|
| main | 5,634 | 5,634 | **100%** | `status: ok` / `embedding_ready: true` / `embedding_readiness_state: ready` |
| working | 34 (移行時点) | 34 | 100% (移行時点観測) | provider `local` / granite で検索稼働。再起動直後は `warming` (lazy-init) になり得る (既知挙動) |

- main の scheduler ログ: `converged — vector coverage target reached` (2026-08-17 ~10:04Z)。
- main の変換はローカル PC (24 コア) での一括再インデックスで実施:
  4,057 件を **1,029,492 ms (~17.2 分)** で変換、
  `migration_complete: true` / `vector_coverage: 1` / `missing_vectors_remaining: 0` /
  `legacy_vectors_remaining: 0` / `retryable_embedding_errors: []` を確認。
- 変換済み DB をサーバーへ戻し両 daemon を再起動して反映。
- `mem_vectors` には変換済み観測分の `fallback:local-hash-v3` 行が残る
  (PK が `observation_id+model` のため)。取得は current-model 優先なので影響なし。

---

## 2. 検証クライアリア (6項目) — 合格表

| # | クライアリア | 検証方法 | 結果 |
|---|---|---|---|
| 1 | `embedding_ready` が検索中も true を維持 | 検索前後の health 比較 | ✅ main は検索中も `embedding_ready: true` 維持 (working は lazy-init のため初回検索で worker がモデルロード) |
| 2 | クエリ側も granite で埋め込み | 検索レスポンス `meta` を確認 | ✅ `embedding_provider: local` / `embedding_provider_status: healthy` / `vector_model: local:granite-embedding-311m-r2` / `vector_search_enabled: true` |
| 3 | 言い換えクエリで意味的に関連する観測が上位に | project スコープの言い換え検索で上位候補の `scores.vector` を確認 | ✅ 関連観測が上位に出現、vector スコア 0.64–1.0 |
| 4 | 同義語・FTS 困難クエリの改善 | 同義語/言い換えクエリで FTS では拾えない観測のヒット | ✅ ベクトル検索により改善 (vector 候補が上位に寄与) |
| 5 | メモリ安定 (クエリ連打で RSS フラット) | 検索連打時の `docker stats` RSS 推移 | ✅ ±1MB 程度で安定 |
| 6 | 警告・fallback なし | daemon ログの warning/fallback/error を確認 | ✅ 検索経路に警告・fallback なし (ベクトルはすべて granite で生成) |

補足: 検証で使った初期クエリ (Q1–Q5) は **project スコープなし**だったため、
下記 §3-1 の設計挙動により `vector_coverage` が 0.13–0.21 となり vector スコアが
最終順位に反映されなかった。その後の **project スコープ検索**で vector スコア
0.64–1.0 の効果を確認している。

---

## 3. 既知の注意点 (caveats)

### 3-1. project スコープなしの広域クエリはベクトルが効かない (設計上の挙動)

`internalLimit` が 15 に制限されるため `vectorCoverage < 0.2` となり、
`weights.vector` が 0 に設定される。ベクトル候補は見つかる (検索メタの
`vector_candidates` に計上) が、最終順位には影響しない。

- 実測: スコープなし検索で `vector_coverage: 0.128` (< 0.2) → 全候補 `scores.vector: 0.000`。
- 通常の MCP 利用は project スコープ付き (`project` パラメータ指定) なので実害なし。
  ヘルスチェックや手動 curl で「ベクトルが効かない」ように見えるのはこのため。

### 3-2. `vector_engine` は `js-fallback`

コンテナに sqlite-vec 拡張がないため、JS 実装の総当たりコサイン類似度で動作する。
正しく動作し、結果は同一。ネイティブ版よりやや遅いだけ。検索 worker の
`worker_latency_ms` で実測確認可能 (数百 ms オーダー)。

### 3-3. working daemon の新規観測は自動変換されない

working の reindex scheduler は OOM 防止のため無効 (commit `c44c0cd`、converged 済み)。
移行後に新規追加された観測 (2026-08-17 時点で 7 件) は fallback ベクトルのみ。
必要になったら §4 の手順で一括再インデックスする。

### 3-4. working daemon の health が `warming` になることがある

再起動直後は `status: degraded` / `embedding_ready: false` /
`embedding_readiness_state: warming` (`lazy initialization pending`) を示すことがある。
これは既知の挙動で、検索実行時に worker がモデルをロードし granite で検索される
(検索 meta で `vector_model: local:granite-embedding-311m-r2` を確認できる)。
モデルロードエラー等は daemon ログで確認する。

---

## 4. 検証コマンド (再現手順)

```bash
# 1. health (main / working)
curl -s http://100.92.131.75:37888/v1/health -H "Authorization: Bearer $HARNESS_MEM_ADMIN_TOKEN" | python3 -m json.tool
curl -s http://100.92.131.75:37889/v1/health -H "Authorization: Bearer $HARNESS_MEM_WORKING_ADMIN_TOKEN" | python3 -m json.tool
#   期待値: status: ok / embedding_ready: true / embedding_readiness_state: ready /
#           embedding_provider_status: healthy / embedding_provider_details: local ONNX: granite-embedding-311m-r2 (dim=384)

# 2. ベクトル変換状況 (main)
sudo sqlite3 /home/tk/.harness-mem/harness-mem.db \
  "SELECT COUNT(*) AS total,
          COUNT(CASE WHEN model='local:granite-embedding-311m-r2' THEN 1 END) AS granite,
          COUNT(CASE WHEN model!='local:granite-embedding-311m-r2' THEN 1 END) AS fallback
   FROM mem_vectors;"
#   期待値: granite = live 観測数 (main では 5,634 = 100%)

# 3. 未変換の live 観測がないこと
sudo sqlite3 /home/tk/.harness-mem/harness-mem.db \
  "SELECT COUNT(*) FROM mem_observations o WHERE o.archived_at IS NULL
   AND NOT EXISTS (SELECT 1 FROM mem_vectors v WHERE v.observation_id=o.id
                   AND v.model='local:granite-embedding-311m-r2');"
#   期待値: 0

# 4. 検索 meta の確認 (project スコープ付きで検索)
#   → embedding_provider: local / vector_model: local:granite-embedding-311m-r2 /
#     vector_search_enabled: true / vector_engine: js-fallback

# 5. scheduler 収束ログ (main)
docker logs ai-stack-harness-memd-1 -t | grep -E "converged" | tail -3
#   期待値: converged — vector coverage target reached
```

---

## 5. ローカル PC 一括再インデックス手順 (将来の再実行用)

サーバー (RAM 1.9GB) では全量再計算は OOM リスクがある。性能の良い PC で実施する。

実績 (2026-08-17、デスク PC / 24 コア):

```bash
# 1. サーバーで一貫スナップショットを取得 (WAL のため直接 cp 禁止)
sqlite3 ~/.harness-mem/harness-mem.db "VACUUM INTO '/tmp/harness-mem-reindex-copy.db'"
scp /tmp/harness-mem-reindex-copy.db desk-pc:/tmp/opencode/granite-local-run/harness-mem.db

# 2. ローカルに hermetic 実行環境を用意 (/tmp/opencode/granite-local-run)
#    npm install @chachamaru127/harness-mem@0.29.3  を pkgs/ に実施
#    models/ に granite-embedding-311m-r2 を配置 (サーバーからコピー)

# 3. ローカル daemon 起動 (capture/ingest 無効・ポート 37999)
#    HARNESS_MEM_HOME / DB_PATH / LOCAL_MODELS_DIR / CONFIG_PATH /
#    HARNESS_MEM_EMBEDDING_PROVIDER=auto /
#    HARNESS_MEM_REINDEX_VECTORS_ENABLED=true /
#    HARNESS_MEM_REINDEX_VECTORS_CONCURRENCY=16 (コア数に応じて) /
#    HARNESS_MEM_PORT=37999 / HARNESS_MEM_HOST=127.0.0.1
#    起動: bun run .../memory-server/src/index.ts

# 4. 一括再インデックスを admin API で実行
#    POST /v1/admin/reindex-vectors
#    実績: 4,057 件 / 1,029,492 ms (~17.2 分) / migration_complete: true / coverage: 1

# 5. 変換済み DB をサーバーへ戻し、元 DB を .pre-local-reindex として退避してから
#    daemon を再起動して反映
#    scp /tmp/opencode/granite-local-run/harness-mem.db x:/tmp/harness-mem.db.new
```

---

## 6. 残タスク / リマインダー

- [x] rollback ファイル削除済み (2026-08-17):
  `model.onnx.fp32.bak` ×2 (各 1.2GB) と
  `/home/tk/.harness-mem/harness-mem.db.pre-local-reindex` (622MB)。
  詳細は `runbooks/harness-mem-granite-migration.md` §8。
- [x] working daemon の新規 fallback 観測を granite へ変換済み (2026-08-17,
  admin API `POST /v1/admin/reindex-vectors`, live 47 観測すべて granite、
  archived テスト観測 3 件は対象外)。
- [ ] (任意) main の reindex scheduler は converged 済みで tick は no-op。不要なら
  compose.yaml で `HARNESS_MEM_REINDEX_VECTORS_ENABLED=false` にしてよい
  (working と同様)。
- [ ] ホスト RAM 1.9GB の恒久対策 (4GB 増設、または 97M モデルへの切替) は
  任意。切替時は全ベクトルの次元再計算が必要。