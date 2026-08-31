---
name: chatgpt-import
description: ChatGPT 共有リンクの会話を原本として aktus-tk/chatgpt へ保存し、設計判断だけ harness-mem に記録するときに使う。
---

# Skill: ChatGPT Import (原本アーカイブ + 判断の要約記録)

ChatGPT 共有リンク (`https://chatgpt.com/share/<id>`) の会話を取得し、
**原本 (Markdown) は private repo `aktus-tk/chatgpt` に保存**、**判断・方針だけを
harness-mem main に要約記録** する手順。

## ルーティング (AGENTS.md)

`https://chatgpt.com/share/<share_id>` が提示されたら本 Skill を起動する (AGENTS.md「ChatGPT 共有リンク」)。

- 原本 → `aktus-tk/chatgpt` repo `conversations/` へ保存し commit/push
- 判断・方針のみ → harness-mem main へ要約記録 (Granite vector 登録まで)
- `share_url` は保存しない (`share_id` / `conversation_id` のみ frontmatter に残す)

## 知識の三層構成 (2026-08-27 決定)

| 層 | 置き場所 | 入れるもの |
|---|---|---|
| 原本 | `aktus-tk/chatgpt` (private repo) | 会話全文の Markdown (日付 + 題名) |
| 圧縮記憶 | harness-mem main (`37888`) | 長期的に再利用できる判断・方針・制約のみ。**全文は入れない** |
| 正式知識 | 各 project repo | 設計・Runbook・Incident など業務上の正式ドキュメント |

- `share_url` は公開トークンを含むため **Markdown にも harness-mem にも残さない**。
  `share_id` + `conversation_id` のみ frontmatter に残す。
- harness-mem は補助記憶であり正式知識の SSOT ではない。

## 前提・接続情報

- 原本リポジトリ: `/home/tk-rhems/github/aktus-tk/chatgpt` (gh CLI / tk-rhems で push)
- 書き込み先 daemon: `100.92.131.75:37888` (main)
- 書き込み系は admin token 必須: `$HARNESS_MEM_ADMIN_TOKEN` (main)
  - token は `~/.config/env` にあり、`source ~/.config/env` で読み込む
- 記録 API: `POST /v1/events/record` (Authorization: Bearer)
  - project は **フルパス** を使う (`/home/tk-rhems/github/aktus-tk/ai-stack` 等)。
    basename は project boundary check で落ちる既知バグのため必須
- reindex: `POST /v1/admin/reindex-vectors` (limit 100)

## 手順 1: 共有 JSON の取得

共有 URL の `/share/` を `/backend-api/share/` に置き換えるだけで、会話 JSON が返る。

```bash
share_url='https://chatgpt.com/share/<SHARE_ID>'
api_url="${share_url/\/share\//\/backend-api\/share\/}"

# JSON を一時ファイルへ (後の Markdown 整形・要約に使う)
curl -sS --compressed --max-time 30 "$api_url" -o /tmp/opencode/chatgpt_share.json

# 失敗したら HTTP コードを確認
curl -sS --compressed -i --max-time 30 "$api_url" | head -20
```

### 403 (Cloudflare challenge) 時のフォールバック — HTML flight 解析

**発生条件**: データセンター IP から叩くと Cloudflare の bot challenge
(`cf-mitigated: challenge`) で `HTTP 403` が返る。自宅 IP なら通ることが多い。
この場合、`/share/<id>` の HTML ページ自体は 200 で取得できるのでそこから抽出する。

```bash
# 1. 共有ページの HTML を取得 (UA 付き)
curl -sL --max-time 30 -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36" \
  "https://chatgpt.com/share/<SHARE_ID>" -o /tmp/opencode/chatgpt_share.html
```

```python
# 2. flight ペイロードを取り出す (streamController.enqueue の引数)
#    引数は JS 文字列リテラル → ast.literal_eval でデコード (json.loads では壊れる)
import re, json, ast

html = open('/tmp/opencode/chatgpt_share.html').read()
calls = re.findall(r'streamController\.enqueue\((.*?)\);\s*</script>', html, re.S)
payload = ast.literal_eval(calls[0])   # 最初の enqueue に会話データが入っている
data = json.loads(payload)             # flight 形式のフラット配列

def get(idx):
    return data[idx] if isinstance(idx, int) and 0 <= idx < len(data) else None

def extract_content(content_obj):
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

seen = set()
messages = []
for ts, role, ctype, text in sorted(turns):
    key = (ts, role, ctype, text)
    if key in seen:
        continue
    seen.add(key)
    if ctype == 'text' and text:
        messages.append({'role': role, 'text': text})

# messages を /tmp/opencode/chatgpt_conversation.json として保存
json.dump(messages, open('/tmp/opencode/chatgpt_conversation.json', 'w'), ensure_ascii=False, indent=2)
```

**flight 構造メモ** (2026-08-31 時点でさらに構造が変化したことを確認):
- 2026-08-29 の構造 (`_146`/`_147`/`_149`/`_250` 等) は現在の共有ページでは **動かない**。以下は 2026-08-31 に実測で動作した構造:
  - 全要素は data 配列 (フラット)。int 値は**データ配列内の index 参照** (1 hop で実値に解決する)
  - role 文字列は固定位置に存在: `assistant` / `user` / `system` / `tool` (data[380] / [534] / [486] / [452] 付近)
  - message node: `_151` (message_id: UUID str) / `_158` (→ dict) / `_162` (→ content dict) / `_54` (→ ts: epoch float)
  - role 解決: `_158` → dict の `_379` → role 文字列
  - content 解決: `_162` → dict の `_374` = type ('text'/'code'/'thoughts'/'reasoning_recap')、`_376` = parts (list of int → 文字列 index)
  - 共有メタデータは data[52] 付近の dict: `_53` → pageTitle、`_54` → create_time、`_97` → conversation_id、`_60` → sharedConversationId
    (title は HTML `<title>` タグ = `ChatGPT - <title>` からも取得可能)
  - **重複排除は message_id (`_151`) で行う**。並び順は ts (`_54` 解決値) でソート
  - 抽出時にやること: (1) `_151`/`_158`/`_162`/`_54` を持つ dict を収集 (2) `_54` は index 参照なので `data[idx]` で float に解決
    (3) role/type/text を解決 (4) `role in ('user','assistant')` かつ type=='text' のみ保存
  - 除外対象: role='system' (空 text・'Original custom instructions no longer available')、role='tool'、
    type='code' (検索呼び出し・結果)、'thoughts' / 'reasoning_recap' ('4s考えました' 等)
- 注意: flight 構造は ChatGPT 側で随時変わりうる。動かなくなったら data 配列内の構造を再調査する
  (手がかり: role 文字列 'user'/'assistant' と type 文字列 'text'/'code'、会話本文は長い日本語文字列として存在)。
  汎用的な手順: 文字列要素のうち「会話本文の長文」を探し、それを参照する dict を遡って message node を特定する。

## 手順 2: Markdown 整形 (原本)

以下の形式で生成し、`conversations/YYYY/MM/YYYY-MM-DD_HHMM_<slug>.md` に保存する。

```markdown
---
title: <会話タイトル>
date: <YYYY-MM-DDTHH:MM:SS+09:00>
source: chatgpt
share_id: <SHARE_ID>
conversation_id: <CONVERSATION_ID>
tags:
  - <tag>
---

# <会話タイトル>

## user
...

## assistant
...
```

```bash
# 例: JSON → Markdown へ変換 (jq)
jq -r '
  "---",
  "title: \(.title)",
  "date: <YYYY-MM-DDTHH:MM:SS+09:00>",
  "source: chatgpt",
  "share_id: <SHARE_ID>",
  "conversation_id: \(.conversation_id)",
  "tags:",
  "  - ai-stack",
  "---",
  "",
  "# \(.title)",
  "",
  (.messages[] | "## \(.role)\n\n" + .text + "\n")
' /tmp/opencode/chatgpt_record.json
```

- ファイル名: `conversations/YYYY/MM/YYYY-MM-DD_HHMM_<slug>.md`
  - slug はタイトルのローマ字/英語化 (例: `Open Notebook メモリ使用量` → `open-notebook-memory`)。日本語のままでも可
  - **同日重複防止に時刻 (HHMM) を含める**
  - date は UTC なら `+00:00` 表記、JST なら `+09:00`。会話 JSON に時刻が無い場合は仮置きしてよい
- **`share_url` は frontmatter に残さない** (公開トークンのため)。`share_id` + `conversation_id` のみ

## 手順 3: 機密情報ガード

投入前に以下を検知して commit/push を中断する簡易チェック。
検知時は対象行を報告し、exit 1 で停止する (手動確認の上で続行する場合のみ `--continue`)。

```bash
cat > /tmp/opencode/secret_guard.py <<'PYEOF'
import re, sys

PATTERNS = [
    ("aws_access_key", r'\b(?:AKIA|ASIA)[0-9A-Z]{16}\b'),
    ("private_key",    r'-----BEGIN (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----'),
    ("github_token",   r'\bgh[pousr]_[A-Za-z0-9]{20,}\b'),
    ("api_key",        r'\bsk-[A-Za-z0-9]{20,}\b'),
    ("password_assignment", r'(?i)(?:^|[^A-Za-z0-9])(password|passwd|secret|api[_-]?key|token)\s*[=:]\s*["\']?[^\s"\']{4,}'),
]

path = next((a for a in sys.argv[1:] if not a.startswith("--")), None)
if not path:
    print("usage: secret_guard.py <file> [--continue]")
    sys.exit(2)
hits = []
for ln, line in enumerate(open(path, encoding='utf-8'), 1):
    for name, pat in PATTERNS:
        if re.search(pat, line):
            hits.append((ln, name, line.rstrip()))

if not hits:
    print("OK: no secret patterns detected")
    sys.exit(0)

print(f"SECRET PATTERNS DETECTED in {path}:")
for ln, name, line in hits:
    print(f"  line {ln} [{name}]: {line}")
if "--continue" in sys.argv:
    print("--continue: proceeding (manual override)")
    sys.exit(0)
sys.exit(1)
PYEOF

python3 /tmp/opencode/secret_guard.py conversations/2026/08/2026-08-27_1430_slug.md
# 検知された場合:
#   1) 対象行を確認し、本当のシークレットなら redact / 中断
#   2) ローカル開発用デフォルト値 (例: SURREAL_PASSWORD=root) と判断できれば
#      手動確認の上 --continue で続行し、判断内容を報告に含める
```

- `password_assignment` は `password=...` / `secret: ...` 等の代入を広く拾う。
  拾った値がローカル開発用デフォルト (`root` 等) か実シークレットかは人が判断する。

## 手順 4: chatgpt repository へ保存

```bash
CHATGPT_REPO=/home/tk-rhems/github/aktus-tk/chatgpt
# 初回のみ: gh repo clone aktus-tk/chatgpt $CHATGPT_REPO
mkdir -p "$CHATGPT_REPO/conversations/2026/08"
cp conversations/2026/08/2026-08-27_1430_slug.md "$CHATGPT_REPO/conversations/2026/08/"
```

## 手順 5: git commit / push

```bash
cd "$CHATGPT_REPO"
git add conversations/
git commit -m "import: <会話タイトル> (share <SHARE_ID>)"
git push
```

## 手順 6: memory-commit (判断・方針のみ harness-mem main へ)

**全文ではなく**「長期的に再利用できる判断・方針」だけを抽出して要約し、
`POST /v1/events/record` で main に保存する。reindex まで実行する。

```bash
source ~/.config/env   # HARNESS_MEM_ADMIN_TOKEN を読み込む

cat > /tmp/opencode/mem_summary.json <<'JSONEOF'
{
  "event": {
    "platform": "opencode",
    "project": "/home/tk-rhems/github/aktus-tk/ai-stack",
    "session_id": "chatgpt-import-<SHARE_ID>",
    "event_type": "decision",
    "payload": {
      "title": "ChatGPT 会話要約: <要約タイトル>",
      "content": "<Markdown 形式の要約: decisions / principles / context を列挙>"
    },
    "tags": ["memory_commit", "chatgpt-import", "decision"]
  }
}
JSONEOF

# 1. 記録 (応答の items[0].id が observation id。必ず控える)
curl -s -X POST \
  -H "Authorization: Bearer $HARNESS_MEM_ADMIN_TOKEN" \
  -H 'content-type: application/json' \
  --data-binary @/tmp/opencode/mem_summary.json \
  "http://100.92.131.75:37888/v1/events/record" | jq '.items[0].id'

# 2. granite vector 変換 (記録直後は fallback vector なので必須)
curl -s -X POST \
  -H "Authorization: Bearer $HARNESS_MEM_ADMIN_TOKEN" \
  -H 'content-type: application/json' \
  -d '{"limit": 100}' \
  "http://100.92.131.75:37888/v1/admin/reindex-vectors" | jq '.items[0] | {reindexed, vector_coverage, missing_vectors_remaining}'

# 3. 検索で読み出し確認 (書き込み後は必ず再取得して反映を確認する)
curl -s -X POST -H 'content-type: application/json' \
  -d '{"query":"<確認クエリ>","project":"/home/tk-rhems/github/aktus-tk/ai-stack","limit":3,"debug":true}' \
  "http://100.92.131.75:37888/v1/search" | jq '.items[].id'
```

- 要約は `decisions:` / `principles:` / `context:` の Markdown リスト形式にする (後から検索・参照しやすい)
- 会話の結論がアーキテクチャ決定・ポリシーなら `event_type: decision` で main へ
- 一時的な調査・仮説は working (`37889`) へ。迷う場合は working

## 重要な注意事項

1. **全文は harness-mem に入れない** — 原本は `aktus-tk/chatgpt` に Markdown で保存。
   harness-mem には圧縮済みの判断・方針・制約のみ。
2. **API は公式ドキュメント化されていない** — `/backend-api/share/` は現状動くが将来変わる可能性がある。
   壊れたら HTML フォールバック (手順 1) へ。
3. **403 は Cloudflare challenge** — UA を変えても大抵通らない。`--compressed` を忘れない (br 圧縮)。
4. **`share_url` を残さない** — 公開トークン。`share_id` + `conversation_id` のみ frontmatter に残す。
5. **シークレットを保存しない** — 手順 3 のガードを必ず通す。検知時は redact するか、デフォルト開発値と
   判断できた場合のみ手動確認 (`--continue`) で続行し、判断内容を報告に含める。
6. **reindex は daemon を数十秒〜数分ブロックする** — main daemon は converged でも reindex は
   refresh pass (既存 observation の再 embedding) に落ちることがあり、その間 health/search が
   応答しなくなる。再試行せず、完了 (health 200) を待つ。reindex は同モデル再計算なので破壊的ではない。
7. **project はフルパスで渡す** — basename は project boundary check で落ちる既知バグ。
8. **保存先は main / working をポリシーで判断** — アーキテクチャ決定・ポリシーは main。迷う場合は working。

## トラブルシューティング

### API が 403 (Cloudflare challenge)
→ 手順 1 の HTML フォールバックを使う。HTML 自体は 200 で取得できる。

### flight ペイロードの json.loads が失敗する
→ `streamController.enqueue("...")` の引数は JS 文字列リテラル。`ast.literal_eval` でデコードする。
`json.loads('"' + raw + '"')` は末尾の HTML 混入やエスケープで壊れる。

### メッセージが 1 件しか出ない / user が出ない
→ ターンが 2 回出現する重複を `(ts, role, ctype, text)` で排除しているか確認。
`role` は turn ノードの `_150` → message dict の `_197` で引く (配列内の素の "role" 文字列は
1 ターン分しか現れない)。

### 書き込みが 401
→ token 未設定。`source ~/.config/env` して `HARNESS_MEM_ADMIN_TOKEN` (main) を確認。
port と token の組み合わせも確認。

### reindex 後に search / health が応答しない
→ reindex の refresh pass 実行中 (数十秒〜数分)。再試行せず、health が 200 を返すまで待つ。
正常な一時状態であり、プロセスが落ちたわけではない。

### git push が失敗する (chatgpt repo)
→ gh の credential helper が効いていない場合がある。`gh auth status` で https + repo scope を確認し、
`gh repo clone` で得た origin URL (https) のまま push する。SSH 鍵 (id_ed25519) は tk-rhems の
GitHub アカウントに登録済みの可能性があるため、必要なら origin を SSH URL に切り替える。

## 関連

- 記録フロー → `skills/harness-mem-commit/SKILL.md`
- harness-mem 運用 → `skills/harness-mem/SKILL.md`
- 接続情報 → `AGENTS.md`「接続の原則」「Memory Policy」