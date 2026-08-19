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
| resume / 続き | POST `/v1/resume-pack` (project パラメータなし) | 全プロジェクト対象・token 不要 |
| decisions / 方針 | `~/.claude/memory/decisions.md` | SSOT。存在しなければその旨を回答 |
| 横断検索（デフォルト） | POST `/v1/search` `{query, limit, strict_project:false}` | **全プロジェクト対象** (横断検索重視、lexical 優先) |
| 特定プロジェクト検索 | POST `/v1/search` `{query, project, limit, debug:true}` | 単一プロジェクト限定（semantic 優先、vector スコア有効） |
| 直近 session | GET `/v1/sessions/list` (project パラメータなし) | 全プロジェクト・token 不要 |
| facets 絞り込み | GET `/v1/search/facets?query=...` (project パラメータなし) | 全プロジェクト対象 |
| Context Box | ~~cb_recall / cb_search~~ | **DROP** (本環境では未設定) |

**デフォルト: 横断検索** (`strict_project: false`)
- すべてのプロジェクトから該当する観測を検索
- lexical (FTS) が優先（keyword match が強い）
- vector スコアは計算されるが重み付けが低い（internalLimit 制限のため）
- 使用例: 「deepseek」「過去に何やった」「granite embedding」など、プロジェクト横断で思い出したい場合

**オプション: 単一プロジェクト検索** (`project: "$(pwd)"`, `debug: true`)
- 現在のプロジェクト内のみ検索
- vector スコアが有効（semantic matching が強い）
- 使用例: 「このプロジェクトで前にやった ai-stack 関連の作業」など、特定プロジェクト内で思い出したい場合

## コマンド例 (全て token 不要)

### resume-pack (続き、全プロジェクト対象)

```bash
curl -s -X POST -H 'content-type: application/json' \
  -d '{"detail_level":"L1"}' \
  http://100.92.131.75:37888/v1/resume-pack
```

### search (デフォルト: 横断検索、全プロジェクト対象)

```bash
# 全プロジェクトから横断検索（strict_project: false で全対象）
curl -s -X POST -H 'content-type: application/json' \
  -d '{"query":"<キーワード>","limit":20,"strict_project":false}' \
  http://100.92.131.75:37888/v1/search
```

### search (オプション: 特定プロジェクト限定、semantic 優先)

```bash
# 現在のプロジェクト内のみ検索（fullpath + debug:true で vector スコア有効化）
curl -s -X POST -H 'content-type: application/json' \
  -d '{"query":"<キーワード>","project":"'"$(pwd)"'","limit":10,"debug":true}' \
  http://100.92.131.75:37888/v1/search
```

レスポンスから抽出する項目:

| 場所 | フィールド | 意味 | 横断検索時 | 単一プロジェクト時 |
|---|---|---|---|---|
| `meta` | `vector_search_enabled` | vector search 有効フラグ | `true` | `true` |
| `meta` | `vector_candidates` | vector 検索で見つかった候補数 | ≥ 0 (制限あり) | > 0 |
| `meta` | `lexical_candidates` | FTS (キーワード) 候補数 | 通常多い | 少ない |
| `meta` | `vector_coverage` | vector カバレッジ | < 0.2（無視） | `1` (100%) |
| `meta` | `embedding_provider` | 埋め込みプロバイダ | `local` | `local` |
| `meta` | `vector_model` | 埋め込みモデル | `local:granite-embedding-311m-r2` | `local:granite-embedding-311m-r2` |
| `items[i].scores.lexical` | FTS スコア | キーワード寄与 | 高（重視される） | 低 |
| `items[i].scores.vector` | vector スコア | semantic 寄与 | 低（計算されるが重み低い） | 高 |
| `items[i].scores.final` | 最終スコア | hybrid 合成 | lexical ベース | vector ベース |

実測 (e2e, working `37889`): `vector_search_enabled: true` / `vector_candidates: 1` /
`vector_coverage: 1` / `vector_model: local:granite-embedding-311m-r2` /
`embedding_provider: local` / `scores.vector: 1.0`。

### sessions/list (直近 session、全プロジェクト対象)

```bash
curl -s 'http://100.92.131.75:37888/v1/sessions/list'
```

### search/facets (絞り込み、全プロジェクト対象)

```bash
curl -s 'http://100.92.131.75:37888/v1/search/facets?query=<キーワード>'
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
# search (横断検索 — 全プロジェクト対象)
HARNESS_MEM_HOST=100.92.131.75 HARNESS_MEM_PORT=37888 \
  harness-mem-client.sh search '{"query":"<キーワード>","limit":20,"strict_project":false}'

# resume-pack (全プロジェクト対象)
HARNESS_MEM_HOST=100.92.131.75 HARNESS_MEM_PORT=37888 \
  harness-mem-client.sh resume-pack '{"detail_level":"L1"}'
```

> 注: 本環境の `harness-mem-client.sh` は **GET 系コマンド (sessions-list / session-thread / search-facets) に既知バグ** があり、
> URL 末尾に余分な `}` が付いて失敗する。GET 系は上の **curl 直接記法** を使うこと (実測で HTTP 200 を確認済み)。

## 出力フォーマット

以下の形式で回答する (source を明示、search モードを明記):

### 横断検索時（デフォルト）

```
source: daemon main `/v1/search` (cross-project lexical + vector hybrid)
search_mode: cross-project / strict_project: false
query_scope: all projects
lexical_match: <N> candidates / vector_match: <M> candidates (制限あり)
embedding_model: local:granite-embedding-311m-r2 (dim=384)

summary: <要約>
results:
- obs_XXX: "<title>" [<project>] (lexical:<lexical>, vector:<vector>, final:<final>)
- obs_YYY: "<title>" [<project>] (lexical:<lexical>, vector:<vector>, final:<final>)

details:
- Keyword match で <N> 件検出
- Vector (semantic) 補助で ranking 調整
- プロジェクト横断的に検索
```

### 単一プロジェクト検索時（オプション）

```
source: daemon main `/v1/search` (single-project semantic + lexical hybrid)
search_mode: single-project / project: <fullpath>
query_scope: current project only
vector_search: enabled / <vector_candidates> semantic candidates / coverage 100%
embedding_model: local:granite-embedding-311m-r2 (dim=384)

summary: <要約>
results:
- obs_XXX: "<title>" (lexical:<lexical>, vector:<vector>, final:<final>)
- obs_YYY: "<title>" (lexical:<lexical>, vector:<vector>, final:<final>)

details:
- Semantic match で <M> 件検出（vector score 有効）
- 当該プロジェクト内のみ検索
```

## 注意点

- **デフォルト: 横断検索** (`strict_project: false`)。すべてのプロジェクトから検索。
- **オプション: 単一プロジェクト検索**。`project: "$(pwd)"` + `debug: true` を指定して、特定プロジェクト内で semantic 優先検索。
- 検索系は token 不要だが、`graph/neighbors` のみ admin token が必要。使用時は `x-harness-mem-token: $HARNESS_MEM_ADMIN_TOKEN` を付ける。
- Context Box (cb_recall / cb_search) は DROP。harness-mem 内の検索は `/v1/search` / `/v1/recall` で行う。
- 回答は source を明示し、推測と事実を分ける。観測された observation に無い情報は「メモリに見つからなかった」と明記する。
- decisions intent は `~/.claude/memory/decisions.md` を SSOT として参照し、存在しなければその旨を回答する。
- 横断検索時：lexical (keyword) が優先され、vector スコアは計算されるが重み付けが低い（internalLimit 制限）。semantic match が必要な場合は単一プロジェクト検索を使う。
- `scores.vector: 0` の項目は「未変換 (fallback vector) or スコープ外」の可能性がある。report ではその旨を注記する。
