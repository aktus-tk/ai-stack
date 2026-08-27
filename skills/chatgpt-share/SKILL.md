---
name: chatgpt-share
description: ChatGPT の共有リンク (chatgpt.com/share/...) の会話内容を取得して harness-mem に記録するときに使う。公開 JSON API が Cloudflare でブロックされる場合は HTML フォールバック解析を行う。
---

# Skill: ChatGPT Share → harness-mem 記録

ChatGPT 共有リンク (`https://chatgpt.com/share/<id>`) の会話を JSON として取得し、
harness-mem (main / working) に observation として記録する手順。

## 前提・接続情報

- 書き込み先 daemon: `100.92.131.75:37888` (main) / `37889` (working)
- 書き込み系は admin token 必須: `$HARNESS_MEM_ADMIN_TOKEN` (main) / `$HARNESS_MEM_WORKING_ADMIN_TOKEN` (working)
  - token は `~/.config/env` にあり、`source ~/.config/env` で読み込む
- 保存先の決定 (memory-commit ポリシー):
  - 既定 = working / durable な決定 (architecture / policy / decision) = **main**
  - 会話の結論がアーキテクチャ決定なら main を選ぶ

## 手順 1: 公開 JSON API で取得 (推奨)

共有 URL の `/share/` を `/backend-api/share/` に置き換えるだけで、会話 JSON がそのまま返る。

```bash
share_url='https://chatgpt.com/share/<SHARE_ID>'
api_url="${share_url/\/share\//\/backend-api\/share\/}"

curl -sS --compressed "$api_url" |
jq -r '
  "# " + .title,
  "",
  (
    .linear_conversation[]
    | .message?
    | select(
        .content.content_type == "text"
        and (.author.role == "user" or .author.role == "assistant")
        and (.metadata.is_thinking_preamble_message != true)
      )
    | "## \(.author.role)\n\n"
      + (.content.parts | map(select(type == "string")) | join("\n"))
      + "\n"
  )
'
```

- `linear_conversation[].message` に user / assistant の最終発言が時系列で入っている
- 途中のツール実行 (`code`) や「確認します」系の `commentary` は上記 select で除外される
- トークン不要・HTML 解析不要

### harness-mem に渡す JSON の組み立て

```bash
curl -sS --compressed "$api_url" |
jq '{
  source: "chatgpt-share",
  title,
  conversation_id,
  create_time,
  update_time,
  messages: [
    .linear_conversation[]
    | .message?
    | select(
        .content.content_type == "text"
        and (.author.role == "user" or .author.role == "assistant")
        and (.metadata.is_thinking_preamble_message != true)
      )
    | {
        id,
        role: .author.role,
        created_at: .create_time,
        text: (.content.parts | map(select(type == "string")) | join("\n"))
      }
  ]
}'
```

## 手順 2: フォールバック — HTML 解析 (API が 403 のとき)

**発生条件**: データセンター IP (ai-stack サーバー等) から叩くと Cloudflare の bot challenge
(`cf-mitigated: challenge`) で `HTTP 403` が返る。自宅 IP なら通ることが多い。

- 403 の判定: `curl -sS --compressed -i "$api_url" | head` で `HTTP/2 403` + `cf-mitigated: challenge` を確認
- この場合、`/share/<id>` の HTML ページ自体は 200 で取得できるので、そこから抽出する

### 抽出方法 (React Flight ペイロード)

```bash
# 1. 共有ページの HTML を取得 (UA 付き)
curl -sL --max-time 30 -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36" \
  "https://chatgpt.com/share/<SHARE_ID>" -o /tmp/opencode/chatgpt_share.html

# 2. flight ペイロードを取り出す (streamController.enqueue の引数)
#    <script>window.__reactRouterContext.streamController.enqueue("...")</script>
#    引数は JS 文字列リテラル → ast.literal_eval でデコード (json.loads では壊れる)
```

```python
import re, json, ast

html = open('/tmp/opencode/chatgpt_share.html').read()
calls = re.findall(r'streamController\.enqueue\((.*?)\);\s*</script>', html, re.S)
payload = ast.literal_eval(calls[0])   # 最初の enqueue に会話データが入っている
data = json.loads(payload)             # flight 形式のフラット配列
```

### flight 配列からの会話デコード

flight 配列 (`data`) は参照番号 (`{"_N": idx}`) で相互参照するフラット配列。
「turn ノード」= `_150` (message への参照) と `_154` (content への参照) と `_46` (timestamp) を持つ dict。

```python
def get(idx):
    return data[idx] if isinstance(idx, int) and 0 <= idx < len(data) else None

def extract_content(content_obj):
    """content オブジェクト (dict) から本文を取り出す"""
    ctype = get(content_obj.get('_192'))   # "text" / "code" / "thoughts" / "reasoning_recap"
    if ctype == 'text':
        parts_ref = content_obj.get('_194') or content_obj.get('_154')
        parts = get(parts_ref) if isinstance(parts_ref, int) else parts_ref
        texts = [get(p) for p in parts if isinstance(get(p), str)] if isinstance(parts, list) else []
        return 'text', '\n'.join(texts)
    if ctype == 'reasoning_recap':
        return 'recap', get(content_obj.get('_154'))
    if ctype == 'code':
        return 'code', get(content_obj.get('_193'))
    return ctype, None

# 全 turn ノードを収集 → (ts, role, ctype, text) で重複排除 → ts でソート
turns = []
for el in data:
    if isinstance(el, dict) and '_150' in el and '_154' in el:
        msg = get(el['_150'])
        role = get(msg.get('_197')) if isinstance(msg, dict) else None
        if role not in ('user', 'assistant'):
            continue
        ts = get(el.get('_46'))
        ctype, text = extract_content(get(el['_154']))
        turns.append((ts, role, ctype, text))
```

**重要な構造メモ**:
- 各ターンは **2 回出現する** (メイン + ストリーミング表示の重複) → `(ts, role, ctype, text)` で重複排除
- assistant ターンは `thoughts` → `reasoning_recap` → `code` → `text` の複数 content を持つ
  → 同一ターン内は `text` だけを連結し、`thoughts` (空) と `code` (ツール実行) は捨てる
- ユーザー本文・assistant 最終回答は `content_type == "text"` の `parts` に格納

## 手順 3: harness-mem への記録 (main の例)

```bash
source ~/.config/env   # HARNESS_MEM_ADMIN_TOKEN 等を読み込む

# 1. 記録 (project は cwd のフルパス。basename は project boundary check で落ちる既知バグあり)
curl -s -X POST \
  -H "Authorization: Bearer $HARNESS_MEM_ADMIN_TOKEN" \
  -H 'content-type: application/json' \
  -d '{
    "event": {
      "platform": "opencode",
      "project": "/home/tk-rhems/github/aktus-tk/ai-stack",
      "session_id": "chatgpt-share-<SHARE_ID>",
      "event_type": "decision",
      "payload": { "title": "<タイトル>", "content": "<会話 JSON 文字列>" },
      "tags": ["memory_commit", "chatgpt-share"]
    }
  }' \
  "http://100.92.131.75:37888/v1/events/record"

# 2. granite vector 変換 (記録直後は fallback vector なので必須)
curl -s -X POST \
  -H "Authorization: Bearer $HARNESS_MEM_ADMIN_TOKEN" \
  -H 'content-type: application/json' \
  -d '{"limit": 100}' \
  "http://100.92.131.75:37888/v1/admin/reindex-vectors"

# 3. 検索で読み出し確認 (書き込み後は必ず再取得して反映を確認する)
curl -s -X POST -H 'content-type: application/json' \
  -d '{"query":"<確認クエリ>","project":"/home/tk-rhems/github/aktus-tk/ai-stack","limit":3,"debug":true}' \
  "http://100.92.131.75:37888/v1/search"
```

- working に保存する場合は port `37889` + `$HARNESS_MEM_WORKING_ADMIN_TOKEN`
- reindex はモデルロードを含むため数秒〜数十秒かかる。curl のタイムアウトを切らない

## 重要な注意事項

1. **API は公式ドキュメント化されていない** — `/backend-api/share/` は現状動くが将来変わる可能性がある。
   壊れたら HTML フォールバック (手順 2) へ。
2. **403 は Cloudflare challenge** — UA を変えても大抵通らない。`--compressed` を忘れない (br 圧縮)。
3. **会話 JSON はそのまま content に入れる** — 抽出した JSON を加工せず丸ごと保存すると
   検索・再参照に強い (タイトル + role/text の messages 配列)。
4. **シークレットを保存しない** — 会話に API キー・パスワードが含まれる場合は保存前に `<REDACTED>` へ。
5. **保存先は main / working をポリシーで判断** — アーキテクチャ決定・ポリシーは main。
   迷う場合は working。

## トラブルシューティング

### API が 403 (Cloudflare challenge)
→ 手順 2 の HTML フォールバックを使う。HTML 自体は 200 で取得できる。

### flight ペイロードの json.loads が失敗する
→ `streamController.enqueue("...")` の引数は JS 文字列リテラル。`ast.literal_eval` でデコードする。
`json.loads('"' + raw + '"')` は末尾の HTML 混入やエスケープで壊れる。

### メッセージが 1 件しか出ない / user が出ない
→ ターンが 2 回出現する重複を `(ts, role, ctype, text)` で排除しているか確認。
`role` は turn ノードの `_150` → message dict の `_197` で引く (配列内の素の "role" 文字列は
1 ターン分しか現れない)。

### 書き込みが 401
→ token 未設定。`source ~/.config/env` して `HARNESS_MEM_ADMIN_TOKEN` (main) /
`HARNESS_MEM_WORKING_ADMIN_TOKEN` (working) を確認。port と token の組み合わせも確認。

## 関連

- 記録フロー → `skills/harness-mem-commit/SKILL.md`, `.agents/skills/memory-commit.md`
- harness-mem 運用 → `skills/harness-mem/SKILL.md`
- 接続情報 → `AGENTS.md`「接続の原則」「Memory Policy」