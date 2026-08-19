---
name: harness-recall
description: ユーザーが「思い出して」「覚えてる」「覚えている」「前回」「続き」「resume」「recall」「直近」「最後に」「先ほど」「さっき」等の recall 意図を発話したときに invoke する Skill。harness-mem daemon の HTTP API を CLI/curl で呼び、source を明示した要約で回答する。
trigger_phrases:
  - 思い出して
  - 覚えてる
  - 覚えている
  - 前回
  - 続き
  - resume
  - recall
  - 直近
  - 最後に
  - 先ほど
  - さっき
---

# harness-recall

ユーザーの recall 意図を検知したときに、harness-mem daemon の HTTP API を CLI / curl で直接呼び出し、**source を明示した要約**で回答する。MCP は使用しない。

## 前提・接続情報

- daemon はリモート x (100.92.131.75) で稼働。
  - main: port `37888` (token = `HARNESS_MEM_ADMIN_TOKEN` — 検索系は token 不要)
  - working: port `37889` (token = `HARNESS_MEM_WORKING_ADMIN_TOKEN`)
- **検索系 API (search / recall / resume-pack / sessions-list / sessions/thread / search-facets) は admin token 不要**。直接 curl できる。
- **graph/neighbors のみ GET だが admin token 必須** なので混同しない。
- MCP は使用しない。Context Box (cb_recall / cb_search) は DROP する。

## intent 分類と routing

| intent | 呼び出し | 備考 |
|---|---|---|
| resume / 続き | POST `/v1/resume-pack` `{project, detail_level:L1}` | token 不要 |
| decisions / 方針 | `~/.claude/memory/decisions.md` | SSOT。存在しなければその旨を回答 |
| 既知問題 (harness-mem 内検索) | POST `/v1/search` `{query, project, limit, debug:true}` | token 不要。project scope 必須 (vector 有効化のため) |
| 直近 session | GET `/v1/sessions/list?project=...` | token 不要 |
| キーワード | POST `/v1/search` `{query, project, limit, debug:true}` | token 不要。project scope 必須 |
| facets 絞り込み | GET `/v1/search/facets?project=...&query=...` | token 不要 |
| session 内詳細 | GET `/v1/sessions/thread?session_id=...` | token 不要 |
| Context Box | ~~cb_recall / cb_search~~ | **DROP** (本環境では未設定) |

- **プロジェクト名は cwd の**フルパス** (`$(pwd)` 推奨)。basename ではなくフルパスを使用する**
  （harness-mem 内部の project boundary check で basename を使うと post-filter で全候補が除外される既知バグのため）。
- **`/v1/search` は必ず `project` スコープ付き + `debug: true` で実行する。**
  スコープなしの広域検索は `internalLimit` が 15 に制限され `vector_coverage < 0.2` となり
  **vector 重み付けが無効化**される (実測: `scores.vector: 0.000`)。project スコープ付きなら
  `vector_coverage: 1` (100%) で vector スコアが最終順位に反映される。

## コマンド例 (全て token 不要)

### resume-pack (続き)

```bash
curl -s -X POST -H 'content-type: application/json' \
  -d '{"project":"'"$(pwd)"'","detail_level":"L1"}' \
  http://100.92.131.75:37888/v1/resume-pack
```

### search (キーワード / 既知問題 / 意味検索 — Granite embedding 統合)

```bash
# project スコープ（フルパス使用）+ debug:true で vector search メタを取得
curl -s -X POST -H 'content-type: application/json' \
  -d '{"query":"<キーワード>","project":"'"$(pwd)"'","limit":10,"debug":true}' \
  http://100.92.131.75:37888/v1/search
```

レスポンスから抽出する項目:

| 場所 | フィールド | 意味 | 正常時の値 |
|---|---|---|---|
| `meta` | `vector_search_enabled` | vector search 有効フラグ | `true` |
| `meta` | `vector_candidates` | vector 検索で見つかった候補数 | > 0 |
| `meta` | `lexical_candidates` | FTS (キーワード) 候補数 | 任意 |
| `meta` | `vector_coverage` | project scope 内の vector カバレッジ | `1` (100%) |
| `meta` | `embedding_provider` | 埋め込みプロバイダ | `local` |
| `meta` | `vector_model` | 埋め込みモデル | `local:granite-embedding-311m-r2` |
| `meta` | `embedding_provider_status` | プロバイダ健康状態 | `healthy` |
| `items[i].scores.lexical` | FTS スコア (キーワード寄与) | 0.0–1.0 |
| `items[i].scores.vector` | vector スコア (semantic 寄与) | 0.0–1.0 |
| `items[i].scores.final` | 最終スコア (hybrid 合成) | 0.0–1.0 |

実測 (e2e, working `37889`): `vector_search_enabled: true` / `vector_candidates: 1` /
`vector_coverage: 1` / `vector_model: local:granite-embedding-311m-r2` /
`embedding_provider: local` / `scores.vector: 1.0`。

### sessions/list (直近 session)

```bash
curl -s 'http://100.92.131.75:37888/v1/sessions/list?project='"$(pwd)"
```

### search/facets (絞り込み)

```bash
curl -s 'http://100.92.131.75:37888/v1/search/facets?project='"$(pwd)"'&query=<キーワード>'
```

### sessions/thread (session 内詳細)

```bash
curl -s 'http://100.92.131.75:37888/v1/sessions/thread?session_id=<SESSION_ID>&project='"$(pwd)"
```

### decisions / 方針 (SSOT)

```bash
cat ~/.claude/memory/decisions.md 2>/dev/null || echo "decisions.md は未作成"
```

### harness-mem-client.sh (search / resume-pack — POST 系は動作確認済み)

```bash
# search (main) — debug:true 付きで vector search メタを取得（project はフルパス）
HARNESS_MEM_HOST=100.92.131.75 HARNESS_MEM_PORT=37888 \
  harness-mem-client.sh search '{"query":"<キーワード>","project":"'"$(pwd)"'","limit":10,"debug":true}'

# resume-pack
HARNESS_MEM_HOST=100.92.131.75 HARNESS_MEM_PORT=37888 \
  harness-mem-client.sh resume-pack '{"project":"'"$(pwd)"'","detail_level":"L1"}'
```

> 注: 本環境の `harness-mem-client.sh` は **GET 系コマンド (sessions-list / session-thread / search-facets) に既知バグ** があり、
> URL 末尾に余分な `}` が付いて失敗する。GET 系は上の **curl 直接記法** を使うこと (実測で HTTP 200 を確認済み)。

## 出力フォーマット

以下の形式で回答する (source を明示、vector search のメタ情報を含める):

```
source: daemon main `/v1/search` (Granite embedding + lexical hybrid)
vector_search: enabled / <vector_candidates> semantic candidates / coverage <vector_coverage*100>%
embedding_model: local:granite-embedding-311m-r2 (dim=384) / provider: local / status: healthy
summary: <要約>
results:
- obs_XXX: "<title>" (lexical:<lexical>, vector:<vector>, final:<final>)
- obs_YYY: "<title>" (lexical:<lexical>, vector:<vector>, final:<final>)
details:
- Vector search で <N> 件の semantic match を発見
- Session: <session_id> 内で <N> 件
- <observation id / session id などの追跡情報>
```

- source には「daemon main の `/v1/search` (Granite embedding + lexical hybrid)」「working の `/v1/resume-pack`」「`~/.claude/memory/decisions.md`」のように、情報源の API 名 or ファイルを明記する。
- **vector_search 行で「意味検索 (vector)」と「キーワード検索 (lexical/FTS)」の寄与度を明記**する。
  `scores.vector` が高い (= semantic 貢献) 項目と `scores.lexical` が高い (= キーワード一致) 項目を分けて示す。
- `meta.vector_candidates` が 0 の場合は「vector 候補なし (project scope 内に該当なし or 未変換観測のみ)」と明記する。
- 得られた observation の `id` や `session_id` を details に残すと、後続の検証や追跡に役立つ。

## 注意点

- 検索系は token 不要だが、`graph/neighbors` のみ admin token が必要。使用時は `x-harness-mem-token: $HARNESS_MEM_ADMIN_TOKEN` を付ける。
- Context Box (cb_recall / cb_search) は DROP。harness-mem 内の検索は `/v1/search` / `/v1/recall` で行う。
- 回答は source を明示し、推測と事実を分ける。観測された observation に無い情報は「メモリに見つからなかった」と明記する。
- decisions intent は `~/.claude/memory/decisions.md` を SSOT として参照し、存在しなければその旨を回答する。
- **`/v1/search` は必ず project スコープ付きで実行する**。スコープなしだと `vector_coverage < 0.2` となり
  vector 重み付けが無効化され、semantic 検索の効果が出ない (既知の設計挙動)。
- `scores.vector: 0` の項目は「未変換 (fallback vector) or スコープ外」の可能性がある。report ではその旨を注記する。
