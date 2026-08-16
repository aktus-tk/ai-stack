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

## 検索基盤の現状 (2026-08-17 実測)

- `config.json` は `embedding_provider: auto` / `embedding_model: multilingual-e5` を指定
  しているが、**embedding モデルが未インストール**のため daemon は
  `fallback:local-hash-v3` (hash 擬似ベクトル) で動作している。
- `embedding_provider: fallback` / `vector_engine: js-fallback` / `reranker_enabled: false`
  (metrics API で確認可)。
- hash 擬似ベクトルは意味的類似性を持たないため、実質の検索は
  **FTS (キーワード/BM25) + グラフ**のみ。セマンティック検索・あいまい検索は機能していない。
- したがって「導入で精度が上がる」のではなく「セマンティック検索が無い状態に
  初めて実装される」と理解する。

確認コマンド:

```bash
curl -s http://100.92.131.75:37888/v1/metrics -H "Authorization: Bearer $HARNESS_MEM_ADMIN_TOKEN"
```

## Embedding 導入 (推奨・未実施)

意味検索・あいまい検索を有効化するため、embedding モデルを導入し
`--reset` で全ベクトルを再計算するのが推奨。

- 効果:
  - 検索精度: 大幅向上 (現状はキーワード一致前提)。
  - あいまい検索: 同義語・言い換え・文脈による意味的類似検索が可能になる。
  - token 節約: 直接効果なし (embedding は LLM に送られない) が、検索精度↑ による
    不要観測の返却減と、dedupe/統合精度↑ による観測総数減の間接効果がある。
- モデル選択: データは日本語中心のため、多言語モデルが望ましい。
  - `granite-embedding-311m-r2` — **最上位 (推奨)**。harness-mem カタログ内の
    `granite-embedding-311m-r2` は IBM `granite-embedding-311m-multilingual-r2`
    (311M / dim=768、Matryoshka で 512/384/256/128 に縮小可) の ONNX 版を指す。
    多言語 200+ (52言語強化 + コード)。MTEB 多言語 Retrieval 65.2 / AVG 56.3
    (旧 278m 比 +13 / +14.5)。日本語クロスリンガル 0.54 → 0.96 / 複合スコア +0.20。
    `@384` は 768→384 への Matryoshka 縮小指定で、下記手順と整合。
  - `granite-embedding-97m-multilingual-r2` — 軽量代替 (97M / dim=384)。
    311M の約3分の1サイズ・約3倍速で品質は MTEB 60.3 (300M 級に匹敵)。
    精度優先なら 311M、速度/容量優先なら 97M。
  - `multilingual-e5` (多言語, dim=384) — MTEB 50.9。granite 311M R2 比 約14pt 劣る。
    現在 config が参照中のモデル (未インストール)。
  - `ruri-v3-30m` (日本語特化, dim=256) — 日本語のみなら有力候補。
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
