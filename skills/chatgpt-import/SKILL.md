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

## 取得方針 (2026-09-02 決定)

ChatGPT share URL の取得では、共有 API / curl 等の直接取得が
Cloudflare により 403 になることを想定する。

1. 通常の取得方法を**1回だけ**試す
2. 403 / Cloudflare challenge の場合、**再試行・原因調査を行わず**、
   直ちに share ページ HTML 取得へフォールバックする
3. HTML 内の flight data から会話データを抽出する
4. flight data の構造が既知パターンと異なる場合は、
   **固定キーに依存せず role / content / message relationship を基準に構造を解析する**
5. **Browser MCP は HTML 取得も失敗した場合のみ**最終フォールバックとして使用する

## 手順 1: 共有 JSON の取得

共有 URL の `/share/` を `/backend-api/share/` に置き換えるだけで、会話 JSON が返る。
**方針 1 に従い、この試行は 1 回だけ** (HTTP コードの追加確認も含めて) 行う。

```bash
share_url='https://chatgpt.com/share/<SHARE_ID>'
api_url="${share_url/\/share\//\/backend-api\/share\/}"

# JSON を一時ファイルへ (後の Markdown 整形・要約に使う)
curl -sS --compressed --max-time 30 -o /tmp/opencode/chatgpt_share.json -w "http_code=%{http_code}\n" "$api_url"
```

HTTP 200 で JSON が取れたら以降のステップへ。**403 (Cloudflare challenge) なら
再試行せず、直ちに下記の HTML flight 解析へ進む**。

### 403 (Cloudflare challenge) 時のフォールバック — HTML flight 解析

**発生条件**: データセンター IP から叩くと Cloudflare の bot challenge
(`cf-mitigated: challenge`) で `HTTP 403` が返る。自宅 IP なら通ることが多い。
この場合、`/share/<id>` の HTML ページ自体は 200 で取得できるのでそこから抽出する。
**方針 2 に従い、UA 変更等の再試行はしない**。

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
```

# 3. 以降は下記「汎用 flight 解析手順」に従う
#    (固定キーに依存しない。2026-09-02 時点の実測構造は flight 構造メモ参照)

**flight 構造メモ** (2026-09-02 時点の実測で最新。構造は随時変わりうる):
- 過去の構造メモ: 2026-08-29 版 (`_146`/`_147`/`_149`/`_250`)・2026-08-31 版 (`_151`/`_158`/`_162`/`_54`)
  は現在の共有ページでは **動かない**。固定キーを前提にしないこと (方針 4)。
- **2026-09-02 実測の構造** (info削除提案 share で確認):
  - 全要素は data 配列 (フラット)。int 値は**データ配列内の index 参照** (1 hop で実値に解決)
  - message node: `_149` (message_id: UUID str) / `_156` (→ role マーカー dict) / `_160` (→ content dict) / `_54` (→ ts: epoch float)
  - role 解決: `_156` → dict の `_236` → role 文字列 ('user'/'assistant'/'system'/'tool')
  - content 解決: `_160` → dict の `_231` = type ('text'/'code'/'thoughts'/'reasoning_recap'/'model_editable_context')、`_233` = parts (list of str を直接持つ場合も、int index の場合もある)
  - 共有メタデータ: `_53` → pageTitle、`_54` → create_time、`_60` → conversation_id (title は HTML `<title>` タグ = `ChatGPT - <title>` からも取得可能)
  - **重複排除は message_id (`_149`) で行う**
  - 除外対象: role='system' (空 text・'Original custom instructions no longer available')、role='tool'、
    type='code' (検索呼び出し・結果)、'thoughts' / 'reasoning_recap' ('4s考えました' 等)、'model_editable_context'
- **順序の注意 (2026-09-02 実測)**: user メッセージの ts は編集により assistant 応答より 1〜2 秒
  「後」にずれることがある。ts 単純ソートでは assistant が直前の user より先に並ぶ。
  対処: ts を 1 分単位に丸めたバケット + ロール順 (user 先) でソートし、strict alternation
  (user/assistant 交互・先頭 user) を検証する。
- **注意: flight 構造は ChatGPT 側で随時変わりうる**。固定キー (`_149` 等) が見つからない場合は
  下記の汎用手順で構造を再調査する (手がかり: role 文字列 'user'/'assistant' と type 文字列 'text'/'code'、
  会話本文は長い日本語文字列として存在)。

### 汎用 flight 解析手順 (固定キー非依存・方針 4)

固定キーに依存せず **role / content / message relationship** を基準に解析する。

1. **長文テキスト探索**: data 配列内の長い日本語文字列 (会話本文候補) を列挙する
2. **role 文字列探索**: `'user'` / `'assistant'` / `'system'` / `'tool'` の文字列要素位置を列挙する
3. **role 参照の逆引き**: role 文字列を参照する dict (role マーカー) を特定し、その親を辿って
   message node を特定する (message node は message_id・ts・content 参照を持つ dict)
4. **content 解決**: content dict から type ('text' 等) と parts (本文文字列) を解決する
5. **メタデータ**: title (`_53` または HTML `<title>`)、conversation_id (`_60` 等)、create_time を取得する
6. **重複排除と順序**: message_id で重複排除し、上記「順序の注意」の方法で並べる

実装例 (2026-09-02 実測で動作):

```python
def get(idx):
    return data[idx] if isinstance(idx, int) and 0 <= idx < len(data) else idx

def resolve(x, depth=0, maxd=8):
    """int index を data 配列の実値へ再帰解決する"""
    if depth > maxd: return '<maxdepth>'
    if isinstance(x, int) and 0 <= x < len(data): return resolve(data[x], depth+1, maxd)
    if isinstance(x, dict): return {k: resolve(v, depth+1, maxd) for k, v in x.items()}
    if isinstance(x, list): return [resolve(v, depth+1, maxd) for v in x]
    return x

# 1) message node 候補: role マーカー (_236 を持つ dict) を参照する親 dict を探す
#    汎用的には「message_id っぽい UUID 文字列・ts float・content dict への参照を持つ dict」
rev = {}
for i, el in enumerate(data):
    if isinstance(el, dict):
        for v in el.values():
            if isinstance(v, int): rev.setdefault(v, []).append(i)

# 2) role 文字列の位置から role マーカー dict → message node を特定
#    (2026-09-02 例: role マーカー = {_236: role} で、その親 message node は
#     _149=id / _156=role マーカー / _160=content / _54=ts を持つ)

# 3) 抽出: mid で重複排除、role in (user, assistant) & type=='text' のみ保存
# 4) 順序: ts を 1 分バケット + user 先でソートし、交互性を検証
```

### Browser MCP フォールバック (最終手段・方針 5)

HTML 取得 (curl) も失敗した場合のみ、Browser MCP で共有ページを開いて
表示された会話テキストを抽出する。この手段は最終フォールバックであり、
通常の取得フローでは使わない。

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
- **project は「会話の対象リポジトリのローカルフルパス」を使う** (例: 会話が
  visualize-takeshita の構成なら `/home/tk/github/visualize-takeshita/ai-ops`、
  ai-stack 関連なら `/home/tk-rhems/github/aktus-tk/ai-stack`)。会話内容から
  対象リポジトリを判断し、単にテンプレートの ai-stack を流用しない。

## 重要な注意事項

1. **全文は harness-mem に入れない** — 原本は `aktus-tk/chatgpt` に Markdown で保存。
   harness-mem には圧縮済みの判断・方針・制約のみ。
2. **API は公式ドキュメント化されていない** — `/backend-api/share/` は現状動くが将来変わる可能性がある。
   壊れたら HTML フォールバック (手順 1) へ。
3. **403 は Cloudflare challenge** — 再試行・UA 変更はしない (取得方針 2)。`--compressed` を忘れない (br 圧縮)。
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
→ 取得方針 2 に従い、再試行せず直ちに手順 1 の HTML フォールバックを使う。HTML 自体は 200 で取得できる。

### HTML 取得も失敗する (curl)
→ 取得方針 5 に従い、最終フォールバックとして Browser MCP で共有ページを開き、
表示された会話テキストを抽出する。

### flight ペイロードの json.loads が失敗する
→ `streamController.enqueue("...")` の引数は JS 文字列リテラル。`ast.literal_eval` でデコードする。
`json.loads('"' + raw + '"')` は末尾の HTML 混入やエスケープで壊れる。

### 既知の固定キー (flight 構造メモ) が data 配列に見つからない
→ 構造が再度変わっている。取得方針 4 に従い、固定キーに依存せず
「汎用 flight 解析手順」(role / content / message relationship 基準) で再調査する。
メッセージが 1 件しか出ない / user が出ない場合も同様。

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