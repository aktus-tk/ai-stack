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

journal note の編集は `PUT /journals/<JOURNAL_ID>.json` を使用する。

### 対象特定の注意

URL の `#note-N` は「`notes` が空でない journal の N 番目」に対応する傾向がある。
journal ID を直接指定するため、必ず `GET` で全 journal を取得し、
内容照合してから `PUT` すること。

詳細な手順・API 呼び出し例は `~/.codebuddy/skills/rhems-redmine/SKILL.md` を参照。