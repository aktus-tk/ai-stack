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

Memory は main (長期記憶) と working (作業記憶) の2つの daemon に分かれている。

- daemon (main): compose `harness-memd` (ai-stack)
  - DB: `~/.harness-mem/harness-mem.db` (WAL) — user `tk`
  - バインド: compose 内 `harness-memd:37888` (ホスト `100.92.131.75:37888`)
  - 認証: `HARNESS_MEM_ADMIN_TOKEN`
- daemon (working): compose `harness-memd-working` (ai-stack)
  - DB: `/home/ai-working/.harness-mem/harness-mem.db` (WAL) — user `ai-working`
  - バインド: compose 内 `harness-memd-working:37888` (ホスト `100.92.131.75:37889`)
  - 認証: `HARNESS_MEM_WORKING_ADMIN_TOKEN` (main とは別)
- ログ: `<home>/.harness-mem/daemon.log`, `harness-mem-ui.log`
- 認証: いずれも Bearer。ただし 401 強制は config.json の `auth` セクション設定時のみ
  (詳細は architecture/security.md)

## よく使う操作

```bash
# 状態確認
cd ~/github/aktus-tk/ai-stack && docker compose ps
docker compose exec harness-memd curl -s http://127.0.0.1:37888/health
docker compose exec harness-memd-working curl -s http://127.0.0.1:37888/health

# 再起動
cd ~/github/aktus-tk/ai-stack && docker compose restart harness-memd
cd ~/github/aktus-tk/ai-stack && docker compose restart harness-memd-working

# DB 件数確認 (ホストから)
sqlite3 ~/.harness-mem/harness-mem.db \
  'SELECT (SELECT count(*) FROM mem_observations) AS obs, \
          (SELECT count(*) FROM mem_sessions) AS sessions, \
          (SELECT count(*) FROM mem_facts) AS facts;'

sqlite3 /home/ai-working/.harness-mem/harness-mem.db \
  'SELECT (SELECT count(*) FROM mem_observations) AS obs, \
          (SELECT count(*) FROM mem_sessions) AS sessions, \
          (SELECT count(*) FROM mem_facts) AS facts;'
```

## バックアップ

```bash
./scripts/backup-harness.sh   # VACUUM INTO で一貫スナップショットを保存
```

## 検索基盤の現状 (2026-08-17 更新: granite embedding 導入完了・検証済み)

granite embedding は **導入完了・検証済み** (2026-08-17)。両 daemon とも
`embedding_provider: local` / `vector_model: local:granite-embedding-311m-r2` (dim=384)
で稼働しており、セマンティック検索・あいまい検索が有効になっている。

- **main daemon**: 全 5,634 観測の 100% が granite ベクトルへ変換済み
  (`mem_vectors` の granite 行 = 5,634 / live 観測 = 5,634)。
  ローカル PC (24 コア) での一括再インデックス (~17.2 分) で変換し、DB を
  サーバーへ戻して反映した。scheduler ログに
  `converged — vector coverage target reached` を確認済み。
- **working daemon**: 移行時点の 34 観測は 100% granite 変換済み。OOM 防止のため
  reindex scheduler は無効のまま (converged 済み)。移行後に新規追加された観測は
  fallback ベクトルのみのため、必要に応じて将来の再インデックス対象になる。
- health の主要フィールド (main): `status: ok` / `embedding_ready: true` /
  `embedding_readiness_state: ready` / `embedding_provider_status: healthy`。
- working daemon は再起動直後などに `status: degraded` / `embedding_ready: false` /
  `embedding_readiness_state: warming` (`lazy initialization pending`) を示すことがある。
  これは既知の挙動で、検索実行時に worker 側でモデルがロードされ granite ベクトルで
  検索される (検索 meta で `vector_model: local:granite-embedding-311m-r2` を確認できる)。
- 旧 `fallback:local-hash-v3` 行は変換済み観測分も `mem_vectors` に残る
  (PK が `observation_id+model` のため)。取得は current-model 優先なので影響なし。

確認コマンド:

```bash
# health (main / working)
curl -s http://100.92.131.75:37888/v1/health -H "Authorization: Bearer $HARNESS_MEM_ADMIN_TOKEN"
curl -s http://100.92.131.75:37889/v1/health -H "Authorization: Bearer $HARNESS_MEM_WORKING_ADMIN_TOKEN"

# ベクトル変換状況 (SQL)
sudo sqlite3 /home/tk/.harness-mem/harness-mem.db \
  "SELECT COUNT(*) AS total,
          COUNT(CASE WHEN model='local:granite-embedding-311m-r2' THEN 1 END) AS granite
   FROM mem_vectors;"
```

### 検索レスポンスの meta で確認する項目

- `embedding_provider: local` / `embedding_provider_status: healthy` — クエリ側も granite で埋め込み
- `vector_model: local:granite-embedding-311m-r2` — 使用モデル
- `vector_engine: js-fallback` — sqlite-vec 非導入 (下記 caveat)
- `vector_search_enabled: true` / `vector_coverage` — ベクトル候補のカバレッジ
- 各候補の `scores.vector` — ベクトル類似度。project スコープ検索では上位結果に影響する

### 既知の注意点 (caveats)

1. **project スコープなしの広域クエリはベクトルが効かない (設計上の挙動)**:
   `internalLimit` が 15 に制限され `vectorCoverage < 0.2` になるため
   `weights.vector` が 0 に設定される。ベクトル候補は見つかるが最終順位には影響しない。
   通常の MCP 利用は project スコープ付きなので実害はないが、挙動として理解しておく。
2. **`vector_engine` は `js-fallback`**: コンテナに sqlite-vec 拡張がないため、
   JS 実装の総当たりコサイン類似度で動作する。正しく動くがやや遅い。
3. **rollback ファイルが残っている** (動作確認が取れ次第削除してよい):
   - `model.onnx.fp32.bak` — 各 1.2GB (両 daemon のモデルディレクトリ)
   - `/home/tk/.harness-mem/harness-mem.db.pre-local-reindex` — 622MB
   - 削除判断の目安は `runbooks/harness-mem-granite-migration.md` の「Cleanup」節を参照

## Embedding 運用メモ

### 導入済みモデル

- `granite-embedding-311m-r2` — **導入済み (デフォルト)**。harness-mem カタログ内の
  `granite-embedding-311m-r2` は IBM `granite-embedding-311m-multilingual-r2`
  (311M / dim=768、Matryoshka で 512/384/256/128 に縮小可) の ONNX 版を指す。
  多言語 200+ (52言語強化 + コード)。MTEB 多言語 Retrieval 65.2 / AVG 56.3
  (旧 278m 比 +13 / +14.5)。日本語クロスリンガル 0.54 → 0.96 / 複合スコア +0.20。
  本環境では `@384` (768→384 への Matryoshka 縮小) で使用中。
- `granite-embedding-97m-multilingual-r2` — 軽量代替 (97M / dim=384)。
  311M の約3分の1サイズ・約3倍速で品質は MTEB 60.3 (300M 級に匹敵)。
  精度優先なら 311M、速度/容量優先なら 97M (RAM 1.9GB のホストでは有力な代替)。
- `ruri-v3-30m` (日本語特化, dim=256) — 日本語のみなら有力候補。

### 効果

- 検索精度: 大幅向上 (旧構成はキーワード一致前提の FTS + グラフのみ)。
- あいまい検索: 同義語・言い換え・文脈による意味的類似検索が可能になった。
  言い換えクエリで意味的に関連する観測が vector スコア 0.64–1.0 で上位に返る
  (project スコープ検索時)。
- token 節約: 直接効果なし (embedding は LLM に送られない) が、検索精度↑ による
  不要観測の返却減と、dedupe/統合精度↑ による観測総数減の間接効果がある。

### 将来、再インデックスが必要になったら (ローカル PC 方式)

サーバー (RAM 1.9GB) で全ベクトル再計算すると OOM の危険がある。性能の良い
ローカル PC (24 コアで約 17.2 分) で一括実行する方式が実績あり:

```bash
# 1. サーバーで DB の一貫スナップショットを取得 (WAL モードのため直接 cp 禁止)
sqlite3 ~/.harness-mem/harness-mem.db "VACUUM INTO '/tmp/harness-mem-reindex-copy.db'"

# 2. スナップショットをローカル PC へコピー (サーバー上で実行)
scp /tmp/harness-mem-reindex-copy.db desk-pc:/tmp/opencode/granite-local-run/harness-mem.db

# 3. ローカル PC に hermetic な実行環境を作る (実績: /tmp/opencode/granite-local-run)
#    npm install @chachamaru127/harness-mem@0.29.3  を pkgs/ に実施
#    models/ に granite-embedding-311m-r2 を配置 (サーバーからコピー)

# 4. ローカル daemon を起動 (capture/ingest 無効の hermetic 構成)
#    HARNESS_MEM_HOME / HARNESS_MEM_DB_PATH / HARNESS_MEM_LOCAL_MODELS_DIR /
#    HARNESS_MEM_CONFIG_PATH / HARNESS_MEM_EMBEDDING_PROVIDER=auto /
#    HARNESS_MEM_REINDEX_VECTORS_ENABLED=true /
#    HARNESS_MEM_REINDEX_VECTORS_CONCURRENCY=16 (コア数に合わせる) /
#    HARNESS_MEM_PORT=37999 / HARNESS_MEM_HOST=127.0.0.1
#    起動: bun run .../memory-server/src/index.ts  (npm global の実パス指定)

# 5. 一括再インデックスを admin API で実行 (limit 5000 相当)
#    POST /v1/admin/reindex-vectors  → 実績: 4,057 件を約 17.2 分 (1,029,492 ms)
#    完了応答: migration_complete: true / vector_coverage: 1 / missing_vectors_remaining: 0

# 6. 変換済み DB をサーバーへ戻し、daemon を再起動して反映
#    scp /tmp/opencode/granite-local-run/harness-mem.db x:/tmp/harness-mem.db.new
#    サーバー: daemon 停止 → 元 DB を .pre-local-reindex として退避 →
#    新しい DB を配置 → daemon 再起動 (rollback 用に退避を保持)
```

詳細・検証結果は `runbooks/harness-mem-granite-migration.md` と
`docs/granite-embedding-verification.md` を参照。

## 関連

- 移行手順 → `runbooks/migrate-harness-mem.md`
- セキュリティ → `architecture/security.md`
- 障害復旧 → `runbooks/disaster-recovery.md`
