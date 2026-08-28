---
name: redmine-textile
description: Redmine の journal note を Markdown から正しい Textile 形式へ整形するときに使う。
---

# Skill: Redmine Textile 整形

Redmine の journal note が Markdown で書かれていて崩れている場合に、
Textile 形式に整形する手順。

## 背景

Redmine 5.1.2 は Textile のみ対応。Markdown 記法はレンダリングされず、
そのまま表示されるため崩れて見える。

## 検出方法

- Redmine の issue を開いたとき、見出し（`##` など）や `**太字**`、backtick などが
  そのまま生テキストで表示されている場合、Markdown で書かれている。
- REST API の `GET /issues/<ID>.json?include=journals` で生の `notes` を確認する。

## 置換ルール

| Markdown | Textile |
|---|---|
| `# heading` / `## heading` / `### heading` | `h1.` / `h2.` / `h3.` |
| `**bold**` | `*bold*` |
| `_italic_` | `_italic_` |
| `` `code` `` | `@code@` |
| `` ``` ... ``` `` | `<pre>...</pre>` |
| `- item` / `* item` (unordered) | `* item` |
| `1. item` / `2. item` (ordered) | `# item` |
| `[text](url)` | `"text":url` |
| Markdown table | Textile `| a \| b \|` |

### 注意事項

- **既存の Textile 構文を壊さない。** `{{collapse(...)}}` ブロック内や
  既に `h1.` で書かれている見出しは変更しない。
- `<pre>...</pre>` 内の内容はそのまま保持する（JSON 等のコードブロック）。
- 変換後は `GET` で再取得し、レンダリングが正しいことを確認する。

## API 操作

### 1. 新しい journal note の追加（コメント投稿）

```
PUT /issues/<ISSUE_ID>.json
Content-Type: application/json

{
  "issue": {
    "notes": "... (Textile 形式)"
  }
}
```

**注意**: `status_id` を含めるとステータスも変更される。必要な場合のみ含める。

### 2. 既存 journal note の直接編集（上書き）

```
PUT /journals/<JOURNAL_ID>.json
Content-Type: application/json

{
  "journal": {
    "notes": "... (Textile 形式)"
  }
}
```

**成功時**: HTTP 204 (No Content) が返る。レスポンスボディは空。

### 3. journal note の削除

REST API では journal note の DELETE はサポートされていない（404 が返る）。
削除したい場合は内容を空文字列で上書きする:

```
PUT /journals/<JOURNAL_ID>.json
Content-Type: application/json

{"journal": {"notes": ""}}
```

### 対象特定の注意

URL の `#note-N` は「`notes` が空でない journal の N 番目」に対応する傾向がある。
journal ID を直接指定するため、必ず `GET` で全 journal を取得し、
内容照合してから `PUT` すること。

```
GET /issues/<ISSUE_ID>.json?include=journals
```

### 簡易確認コマンド

```bash
# journal 一覧を表示
curl -s -H "X-Redmine-API-Key: $REDMINE_API_KEY" \
  "https://redmine.rhems-japan.net/issues/<ISSUE_ID>.json?include=journals" \
  | python3 -c "
import json,sys
data = json.load(sys.stdin)
for j in data['issue']['journals']:
    print(f'#{j[\"id\"]}: notes={repr(j[\"notes\"][:80])}')
"

# 特定 journal の内容を取得（編集用）
curl -s -H "X-Redmine-API-Key: $REDMINE_API_KEY" \
  "https://redmine.rhems-japan.net/issues/<ISSUE_ID>.json?include=journals" \
  | python3 -c "
import json,sys
data = json.load(sys.stdin)
for j in data['issue']['journals']:
    if j['id'] == <JOURNAL_ID>:
        print(j['notes'])
"
```
