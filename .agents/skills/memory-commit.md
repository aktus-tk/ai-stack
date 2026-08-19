---
name: memory-commit
description: ユーザーが「ここまで記憶して」「この作業を記憶して」「記憶して」「覚えておいて」等の memory commit 意図を発話したときに invoke する Skill。現在の context から意味のある情報を抽出・整理・圧縮し、harness-mem daemon へ HTTP 経由でバッチ保存する。
trigger_phrases:
  - ここまで記憶して
  - この作業を記憶して
  - 記憶して
  - 覚えておいて
  - commit
---

# memory-commit

ユーザーの memory commit 意図を検知したときに、現在の context から「意味のある状態」(Git commit のイメージ) を抽出・整理・圧縮し、harness-mem daemon へ HTTP 経由でバッチ保存する。

## 前提・接続情報

- daemon はリモート x (100.92.131.75) で稼働。
  - main (長期 / canonical): port `37888`, token = `HARNESS_MEM_ADMIN_TOKEN`
  - working (作業記憶 / 既定): port `37889`, token = `HARNESS_MEM_WORKING_ADMIN_TOKEN`
- 両 token はシェル env に設定済み (本 skill は `$HARNESS_MEM_WORKING_ADMIN_TOKEN` / `$HARNESS_MEM_ADMIN_TOKEN` を参照する)。
- 認証ヘッダー: `x-harness-mem-token: <token>` または `Authorization: Bearer <token>`
- 書き込み API (`/v1/events/record` / `/v1/checkpoints/record`) は **admin token 必須**。token なしは 401 で拒否される。
- MCP は使用しない (CLI / curl で HTTP を直接叩く)。

## 処理フロー

1. **抽出** — 現在の context (会話・tool 実行結果) から以下を整理・圧縮:
   - 決定事項
   - 構成・アーキテクチャ
   - 実際に確認できた事実 (実行・検証済み)
   - 成功した作業手順 (再現可能な形)
   - 失敗した方法とその理由
   - 重要な判断理由
   - 注意点
   - 未解決事項
   - 次回継続するために必要な情報

2. **正規化** — 途中で否定・修正された古い情報は最終決定へ統合し、重複は排除。1 作業 = 意味のあるまとまったエントリ (Git commit の粒度) にする。単なる操作ログの羅列は保存しない。

3. **保存先の決定**:
   - 既定: **working** (`HARNESS_MEM_WORKING_HOST` / `HARNESS_MEM_WORKING_PORT` / `HARNESS_MEM_WORKING_ADMIN_TOKEN`)
   - 明示指示 or durable な決定 (architecture / policy / convention / security): **main** (`HARNESS_MEM_HOST` / `HARNESS_MEM_PORT` / `HARNESS_MEM_ADMIN_TOKEN`)
   - 判断に迷う場合は working を選択。

4. **プロジェクト名** — cwd のリポジトリ名 (`ai-ops` など)。session_id は現在セッションの ID を付与 (あれば)。

5. **保存** — カテゴリごとに `/v1/events/record` を POST (バッチ)。1 回の commit で全部を詰め込まず、意味単位で分割する。

6. **Granite vector 登録** — バッチ保存後に `/v1/admin/reindex-vectors` を **1 回だけ** 実行し、新規観測の vector を fallback (hash) から granite embedding に変換する (working daemon は reindex scheduler 無効のため手動実行必須。main は scheduler 有効だが converged 済みで新規分は手動でも可)。

7. **報告** — ユーザーへ「保存した observation ID と、Granite vector 登録の結果」を報告する。

## Granite vector 登録 (reindex-vectors)

### なぜ必要か

- `/v1/events/record` で保存した直後の vector は **fallback (hash)** のまま
  (`/v1/events/record` 応答の `meta.embedding_provider: "fallback"` で確認できる)。
- granite embedding への変換は `/v1/admin/reindex-vectors` で手動実行する。
  - working daemon: reindex scheduler が **無効** (OOM 防止, compose.yaml) のため手動必須。
  - main daemon: scheduler 有効だが converged 済みで新規観測は次回 tick まで未変換。手動でも変換できる。
- **search 側は自動で Granite embedding に変換される** (read path) ため、検索時にクエリ embedding の手動生成は不要。変換されていない観測は vector スコアが低くなる (fallback vector は意味的類似度を持たない)。

### コマンド例

```bash
# 直近の新規観測 (limit: 新規観測数 or 100) を granite 化
curl -s -X POST \
  -H "Authorization: Bearer $HARNESS_MEM_ADMIN_TOKEN" \
  -H 'content-type: application/json' \
  -d '{"limit": 100}' \
  "http://$HARNESS_MEM_HOST:$HARNESS_MEM_PORT/v1/admin/reindex-vectors"
```

- 成功例 (実測, working):
  ```json
  {
    "ok": true,
    "items": [{
      "reindexed": 1,
      "adopted_legacy_vectors": 0,
      "current_model_vectors": 80,
      "missing_vectors_remaining": 0,
      "legacy_vectors_remaining": 0,
      "vector_coverage": 1,
      "target_coverage": 0.95,
      "progress_pct": 100
    }],
    "meta": {
      "migration_complete": true,
      "embedding_provider": "local",
      "embedding_provider_model": "local:granite-embedding-311m-r2",
      "embedding_provider_status": "healthy"
    }
  }
  ```

### 完了確認の読み方

| フィールド | 意味 | 正常時の値 |
|---|---|---|
| `items[0].reindexed` | 今回変換した件数 | 新規観測数 (0 なら既に granite 化済み = 正常) |
| `items[0].vector_coverage` | 対象観測の granite vector カバレッジ | 1 (100%) |
| `items[0].current_model_vectors` | granite vector 保有数 | 全観測数 |
| `items[0].missing_vectors_remaining` | 未変換残 | 0 |
| `meta.migration_complete` | 全変換完了フラグ | true |
| `meta.embedding_provider` | 変換後の provider | `local` (fallback でなくなる) |

### エラーハンドリング

- `/v1/events/record` が 401 → 保存先の token (`HARNESS_MEM_WORKING_ADMIN_TOKEN` / `HARNESS_MEM_ADMIN_TOKEN`) と port が正しいか確認。
- `/v1/admin/reindex-vectors` が 401 → admin token 未指定 or 誤り。`Authorization: Bearer` ヘッダーを確認 (search 系と違い admin API は token 必須)。
- reindex 後 `reindexed: 0` → 対象観測は既に granite vector を持っている (正常。報告に「既に登録済み」と反映するだけ)。
- reindex はモデルロードを含むため **数秒〜数十秒** かかる (実測: working で 1 件 ≈ 9 秒, 初回はモデルロードで更に長い)。ユーザーに「数秒待機します」と事前通知し、curl のタイムアウトは切らない (既定は無制限)。

### limit の決め方

- 初版ルール: **新規 observation 数 or 100** (小さい方でなく、`limit` は「処理する上限」なので新規数が分かればそれ、分からなければ 100 で問題ない)。
- 複数 event を POST した場合は **最後に 1 回だけ** reindex を実行する (毎回実行はモデルロードで時間がかかるため)。

## 保存コマンド例

### curl (working へ, 既定)

```bash
HARNESS_MEM_HOST=100.92.131.75
HARNESS_MEM_PORT=37889          # working
HARNESS_MEM_ADMIN_TOKEN=$HARNESS_MEM_WORKING_ADMIN_TOKEN
PROJECT="ai-ops"
SESSION_ID="<現在のセッションID>"

# 各カテゴリを 1 event ずつ POST
RESP=$(curl -s -X POST \
  -H "x-harness-mem-token: $HARNESS_MEM_ADMIN_TOKEN" \
  -H 'content-type: application/json' \
  -d "{
    \"event\": {
      \"platform\": \"opencode\",
      \"project\": \"$PROJECT\",
      \"session_id\": \"$SESSION_ID\",
      \"event_type\": \"decision\",
      \"payload\": { \"title\": \"...\", \"content\": \"...\" },
      \"tags\": [\"memory_commit\", \"decision\"]
    }
  }" \
  "http://$HARNESS_MEM_HOST:$HARNESS_MEM_PORT/v1/events/record")

# 保存確認: items[0].id を抽出 (保存成功の証跡)
OBS_ID=$(echo "$RESP" | python3 -c "import json,sys; print(json.load(sys.stdin)['items'][0]['id'])")
echo "saved observation: $OBS_ID"
```

### 保存 → Granite vector 登録 (一気通貫の例)

```bash
HARNESS_MEM_HOST=100.92.131.75
HARNESS_MEM_PORT=37889          # working (既定)
HARNESS_MEM_ADMIN_TOKEN=$HARNESS_MEM_WORKING_ADMIN_TOKEN
PROJECT="ai-ops"
SESSION_ID="<現在のセッションID>"

# 1. 保存 (複数 event を POST する場合はここで batch 化)
RESP=$(curl -s -X POST \
  -H "x-harness-mem-token: $HARNESS_MEM_ADMIN_TOKEN" \
  -H 'content-type: application/json' \
  -d "{
    \"event\": {
      \"platform\": \"opencode\",
      \"project\": \"$PROJECT\",
      \"session_id\": \"$SESSION_ID\",
      \"event_type\": \"decision\",
      \"payload\": { \"title\": \"...\", \"content\": \"...\" },
      \"tags\": [\"memory_commit\", \"decision\"]
    }
  }" \
  "http://$HARNESS_MEM_HOST:$HARNESS_MEM_PORT/v1/events/record")
OBS_ID=$(echo "$RESP" | python3 -c "import json,sys; print(json.load(sys.stdin)['items'][0]['id'])")
echo "saved observation: $OBS_ID"   # 例: obs_xxxx

# 2. Granite vector 変換 (batch 保存後に 1 回だけ。数秒〜数十秒かかる)
echo "Granite vector 変換を実行します (数秒待機)..."
curl -s -X POST \
  -H "x-harness-mem-token: $HARNESS_MEM_ADMIN_TOKEN" \
  -H 'content-type: application/json' \
  -d '{"limit": 100}' \
  "http://$HARNESS_MEM_HOST:$HARNESS_MEM_PORT/v1/admin/reindex-vectors" \
  | python3 -c "
import json,sys
d = json.load(sys.stdin)
it = d['items'][0]
print(f\"reindexed: {it.get('reindexed')} / vector_coverage: {it.get('vector_coverage')} / current_model_vectors: {it.get('current_model_vectors')}\")
print(f\"migration_complete: {d['meta'].get('migration_complete')} / embedding_provider: {d['meta'].get('embedding_provider')}\")
"

# 3. 報告例
#    「obs_xxxx を保存し、Granite embedding (local:granite-embedding-311m-r2) で vector 登録しました (reindexed: 1, coverage 100%)」
```

### curl (main へ, 明示的に長期/昇格)

`HARNESS_MEM_PORT=37888` と `HARNESS_MEM_ADMIN_TOKEN=$HARNESS_MEM_ADMIN_TOKEN` に切り替えて同じ POST を行う。reindex-vectors も同じ token / port で実行する。

### harness-mem-client.sh (どちらの store にも)

```bash
# working へ
HARNESS_MEM_HOST=100.92.131.75 HARNESS_MEM_PORT=37889 \
HARNESS_MEM_ADMIN_TOKEN="$HARNESS_MEM_WORKING_ADMIN_TOKEN" \
  harness-mem-client.sh record-event \
  '{"event":{"platform":"opencode","project":"ai-ops","session_id":"<SESSION_ID>","event_type":"decision","payload":{"title":"...","content":"..."},"tags":["memory_commit","decision"]}}'

# main へ (長期/昇格)
HARNESS_MEM_HOST=100.92.131.75 HARNESS_MEM_PORT=37888 \
HARNESS_MEM_ADMIN_TOKEN="$HARNESS_MEM_ADMIN_TOKEN" \
  harness-mem-client.sh record-event \
  '{"event":{"platform":"opencode","project":"ai-ops","session_id":"<SESSION_ID>","event_type":"decision","payload":{"title":"...","content":"..."},"tags":["memory_commit","decision"]}}'
```

### event_type の使い分け (payload.title / payload.content を設定)

- `decision` — 決定事項・方針
- `context` — 構成・アーキテクチャ・確認済み事実
- `procedure` — 成功した作業手順
- `learned` — 失敗と理由・判断理由・注意点
- `open` — 未解決事項・次回継続情報

## 注意点

- **secret / token / 個人情報は保存前に REDACT** する。API キー・パスワード・資格情報は `<REDACTED>` に置換。
- 保存先 (working / main) が明示されない場合は既定の working を使い、明示された場合のみ main へ。
- 書き込みは admin token 必須。401 が返ったら token / port が正しいか確認。
- 保存後は応答の `items[0].id` (observation id) を確認し、記録できたことをユーザーに伝える。
- **保存直後の vector は fallback (hash)**。granite embedding への変換は `/v1/admin/reindex-vectors` の手動実行が必要
  (working daemon は reindex scheduler 無効のため。main も converged 済みで新規分は手動推奨)。
- reindex は **batch 保存後に 1 回だけ** 実行する。毎回の実行はモデルロードで数秒〜数十秒かかるため。
- reindex 実行前に「数秒待機します」とユーザーへ通知する (実測: working 1 件 ≈ 9 秒、初回はモデルロードで更に長い)。
- reindex 後 `reindexed: 0` は「既に granite vector を持っている」= 正常。報告に反映するだけ。
- ユーザーへの報告は「保存した observation ID + vector 登録結果 (reindexed 数 / coverage)」を含める。
