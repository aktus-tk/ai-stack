---
name: chatgpt-import
description: ChatGPT の会話要約 (/dl/YYYY-MM-DD_*.md) を原本として aktus-tk/chatgpt へ保存し、設計判断だけ harness-mem に記録するときに使う。
---

# Skill: ChatGPT Import (原本アーカイブ + 判断の要約記録)

ChatGPT の会話を **原本 (Markdown) は private repo `aktus-tk/chatgpt` に保存**、**判断・方針だけを
harness-mem main に要約記録** する手順。

## ルーティング (AGENTS.md)

ChatGPT 会話の記録依頼 (`/dl/YYYY-MM-DD_*.md` の提示、または「記録して」) で本 Skill を起動する
(AGENTS.md「ChatGPT 会話の記録」)。

- 原本 → `aktus-tk/chatgpt` repo `conversations/` へ保存し commit/push
- 判断・方針のみ → harness-mem main へ要約記録 (Granite vector 登録まで)

## 取得方法 (2026-09-03 決定: /dl/ から直接読み取り)

**共有リンクの自動解析 (curl / HTML flight 解析) も手動貼り付けも廃止した**。
flight 構造が頻繁に変わる・Cloudflare 403・コピペが途中で切れる、などの理由で維持コストが
高すぎたため。

現在のフロー: **ユーザーが ChatGPT に会話の要約を依頼し、ダウンロードしたファイル
(`/dl/YYYY-MM-DD_タイトル.md`) を AI が直接読み取る**。

ChatGPT への依頼文 (ユーザーが ChatGPT 側で使用する指示):

```text
この会話を、再利用可能な設計・思想・判断履歴として Markdown にまとめてください。
* 背景・課題・検討・判断・理由・設計原則が分かるように整理
* 会社名、個人名、顧客名、ドメイン、IP、ID等の固有情報は削除・一般化
* 他の環境やAI Agentでも再利用できる内容にする
* 重要な技術的判断と理由は残し、雑談や冗長な試行錯誤は省略
* 単体で読んでも背景と結論が分かる内容にする
ファイル名: `YYYY-MM-DD_タイトル.md`
```

## 知識の三層構成 (2026-08-27 決定)

| 層 | 置き場所 | 入れるもの |
|---|---|---|
| 原本 | `aktus-tk/chatgpt` (private repo) | 会話全文の Markdown (日付 + 題名) |
| 圧縮記憶 | harness-mem main (`37888`) | 長期的に再利用できる判断・方針・制約のみ。**全文は入れない** |
| 正式知識 | 各 project repo | 設計・Runbook・Incident など業務上の正式ドキュメント |

- `share_url` は公開トークンを含むため **Markdown にも harness-mem にも残さない**。
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

## 手順 1: /dl/ からファイルを読み取る

ユーザーが ChatGPT で要約しダウンロードしたファイルを読み取る。

- 対象: `/dl/YYYY-MM-DD_タイトル.md` (例: `/dl/2026-09-03_AI-Agentチケット管理と監査設計.md`)
- 日付 (YYYY-MM-DD) とタイトルは**ファイル名から取得**する
- ファイルが無い / 名前が分からない場合は `ls /dl/ | grep '^YYYY-MM-DD'` で探し、
  見つからなければユーザーに確認する
- 読み取った内容が ChatGPT の要約形式 (背景・判断・原則が整理されている) か確認する。
  生の会話ログや固有情報 (会社名・人名・ドメイン・IP・ID) が残っている場合はユーザーに確認する

## 手順 2: Markdown 整形 (原本)

以下の形式で /dl/ ファイルに frontmatter を付与し、`conversations/YYYY/MM/` へ保存する。

```markdown
---
title: <会話タイトル>
date: <YYYY-MM-DDTHH:MM:SS+09:00>
source: chatgpt
tags:
  - <tag>
---

# <会話タイトル>

<ダウンロードした要約本文をそのまま>
```

- ファイル名: `/dl/` のファイル名 (`YYYY-MM-DD_タイトル.md`) をそのまま使う
- frontmatter は /dl/ ファイルの先頭に付与する (title / date はファイル名から。date は JST `+09:00`)
- **`share_url` / `share_id` は frontmatter に残さない** (このフローでは共有リンクを使用しない)

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

python3 /tmp/opencode/secret_guard.py /tmp/opencode/2026-09-03_AI-Agentチケット管理と監査設計.md
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
# 保存先: conversations/YYYY/MM/ (ファイル名の日付から YYYY / MM を決める)
mkdir -p "$CHATGPT_REPO/conversations/2026/09"
cp /dl/2026-09-03_AI-Agentチケット管理と監査設計.md "$CHATGPT_REPO/conversations/2026/09/"
```

## 手順 5: git commit / push

```bash
cd "$CHATGPT_REPO"
git add conversations/
git commit -m "import: <会話タイトル> (chatgpt summary)"
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
    "session_id": "chatgpt-import-<YYYY-MM-DD-タイトル>",
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
2. **共有リンクの自動解析・手動貼り付けはしない** — `/dl/` の要約ファイルを直接読み取る (2026-09-03 決定)。
   flight 構造の変化・Cloudflare 403・コピペの途切れにより廃止。
3. **`share_url` / `share_id` を残さない** — このフローでは共有リンクを使用しないため frontmatter に載せない。
4. **シークレットを保存しない** — 手順 3 のガードを必ず通す。検知時は redact するか、デフォルト開発値と
   判断できた場合のみ手動確認 (`--continue`) で続行し、判断内容を報告に含める。
5. **reindex は daemon を数十秒〜数分ブロックする** — main daemon は converged でも reindex は
   refresh pass (既存 observation の再 embedding) に落ちることがあり、その間 health/search が
   応答しなくなる。再試行せず、完了 (health 200) を待つ。reindex は同モデル再計算なので破壊的ではない。
6. **project はフルパスで渡す** — basename は project boundary check で落ちる既知バグ。
7. **保存先は main / working をポリシーで判断** — アーキテクチャ決定・ポリシーは main。迷う場合は working。
8. **title / date はファイル名から取得する** — ファイル名が規約 (`YYYY-MM-DD_タイトル.md`) と
   異なる場合はユーザーに確認する。

## トラブルシューティング

### /dl/ に対象ファイルが無い
→ `ls /dl/ | grep '^YYYY-MM-DD'` で探す。無ければ「ChatGPT で要約して
`/dl/YYYY-MM-DD_タイトル.md` にダウンロードしてください」とユーザーに依頼する。

### 要約ファイルに固有情報が残っている
→ 会社名・個人名・ドメイン・IP・ID 等が残っている場合は、redact してから保存する。
判断できない場合はユーザーに確認する。

### 書き込みが 401
→ token 未設定。`source ~/.config/env` して `HARNESS_MEM_ADMIN_TOKEN` (main) を確認。
port と token の組み合わせも確認。

### reindex 後に search / health が応答しない
→ reindex の refresh pass 実行中 (数十秒〜数分)。再試行せず、health が 200 を返すまで待つ。
正常な一時状態であり、プロセスが落ちたわけではない。

### 記録後に検索でヒットしない / vector_search_enabled: false
→ 記録 (dedup で永続化確認可) は成功しているのに検索に出ない場合、daemon のインデックス
(FTS / vector) が壊れている可能性が高い。**reindex API では直らない** (vector 再計算のみで
FTS は再構築されない)。サーバーで `docker compose restart harness-memd` (main) を実行して
修復する。再起動後に `debug:true` 付き search で `vector_search_enabled: true` と
`vector_coverage: 1` になることを確認する (2026-09-03 実測: 再起動で復旧、検索も 60s → 2s に高速化)。

### git push が失敗する (chatgpt repo)
→ gh の credential helper が効いていない場合がある。`gh auth status` で https + repo scope を確認し、
`gh repo clone` で得た origin URL (https) のまま push する。SSH 鍵 (id_ed25519) は tk-rhems の
GitHub アカウントに登録済みの可能性があるため、必要なら origin を SSH URL に切り替える。

## 関連

- 記録フロー → `skills/harness-mem-commit/SKILL.md`
- harness-mem 運用 → `skills/harness-mem/SKILL.md`
- 接続情報 → `AGENTS.md`「接続の原則」「Memory Policy」