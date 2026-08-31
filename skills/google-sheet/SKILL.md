---
name: google-sheet
description: Google Sheets の Apps Script Web App（doPost）へデータを書き込むときに使う。認証は $GOOGLE_SHEET_API_TOKEN、URL は $GOOGLE_SHEET_URL。
---

# Skill: Google Sheets POST

Google Sheets の Apps Script Web App（`doPost`）へデータを書き込む Skill。
指定したシートの指定セル（または範囲）へ、TSV 形式の値を書き込む。

## 環境変数

| 変数 | 内容 |
|---|---|
| `$GOOGLE_SHEET_URL` | Web App の URL（`https://script.google.com/macros/s/.../exec`） |
| `$GOOGLE_SHEET_API_TOKEN` | `doPost` 側が検証する API トークン |

## doPost 側の仕様（前提）

書き込み対象の Apps Script Web App は以下の仕様で動いている:

```js
// Content-Type: text/plain;charset=utf-8 で POST
// リクエスト body: JSON
// {
//   "token": "<API_TOKEN>",   // 検証に使用
//   "sheet": "<シート名>",    // 書き込み先シート名
//   "data":  "<TSV 文字列>",  // タブ区切り。複数行・複数列可
//   "cell":  "<セル位置>",    // 例 "A1"。書き込み開始セル
//   "format": {               // オプション。書き込み範囲全体に適用
//     "fontWeight": "bold",
//     "backgroundColor": "#ffff00"
//   }
// }
// 成功: "OK" / 認証失敗: "Unauthorized"
```

- `data` は **タブ区切り（TSV）** で、改行で行を区切る。
- `cell` が開始セルとなり、そこから行数×列数の範囲に `setValues` される。
- トークン不一致の場合は `Unauthorized` が返る。

### `format`（オプション）: 書式設定

`format` を指定すると、**書き込み範囲全体**（`cell` 開始セルから `data` の行数×列数の範囲）に
書式が適用される。`setValues` と同じ範囲に対して適用される。

値が存在する項目のみ適用される（未指定の項目は変更されない）。

| 項目 | 型 | 内容 | 例 |
|---|---|---|---|
| `fontSize` | 数値 | フォントサイズ | `12` |
| `fontColor` | 文字列（CSS 色） | 文字色 | `'#ff0000'` |
| `backgroundColor` | 文字列（CSS 色） | 背景色 | `'#ffff00'` |
| `fontWeight` | `'bold'` \| `'normal'` | 太字 | `'bold'` |
| `fontStyle` | `'italic'` \| `'normal'` | 斜体 | `'italic'` |
| `fontFamily` | 文字列 | フォント名 | `'Arial'` |
| `underline` | boolean | 下線 | `true` |
| `horizontalAlignment` | `'left'` \| `'center'` \| `'right'` | 横位置 | `'center'` |
| `verticalAlignment` | `'top'` \| `'middle'` \| `'bottom'` | 縦位置 | `'middle'` |
| `wrap` | boolean | 折り返し | `true` |
| `numberFormat` | 文字列 | 数値表示形式 | `'#,##0.00'` |

`underline` / `wrap` は `true` または文字列 `'true'` の場合に有効になる。

## 最重要: curl では動かない（redirect で body が失われる）

**⚠️ この API は `curl -L` では正しく動作しない。**

Apps Script Web App の `/exec` への POST は **302 リダイレクト** を返し、実際の処理は
リダイレクト先 `script.googleusercontent.com/macros/echo` で実行される。
`curl -L` は 302 時に **POST body を保持せず再送しない**ため、
`405` や空レスポンス、エラー HTML（「ページが見つかりません」）になる。

**必ず POST body を保持したままリダイレクトを追跡できる方法を使う。**

### 推奨: Python requests（`allow_redirects=True`）

```python
import requests, os, json

url  = os.environ["GOOGLE_SHEET_URL"]
body = json.dumps({
    "token": os.environ["GOOGLE_SHEET_API_TOKEN"],
    "sheet": "test",
    "data":  "hello\tworld\nline2",   # TSV
    "cell":  "A1",
})

r = requests.post(
    url,
    data=body,
    headers={"Content-Type": "text/plain;charset=utf-8"},
    allow_redirects=True,   # ← 必須。body を保持して追跡
    timeout=30,
)

print(r.status_code, r.text)   # 成功: 200 'OK'
```

#### format 使用例（ヘッダー行を太字・背景色付きにする）

`format` は書き込み範囲全体に適用されるため、ヘッダー行だけに書式を付ける場合は
ヘッダー行を単独のリクエストで書き込み、データ行を別リクエストで書き込む:

```python
import requests, os, json

url  = os.environ["GOOGLE_SHEET_URL"]

def post(body):
    return requests.post(
        url,
        data=json.dumps(body),
        headers={"Content-Type": "text/plain;charset=utf-8"},
        allow_redirects=True,   # ← 必須。body を保持して追跡
        timeout=30,
    )

# ヘッダー行: 太字 + 背景色 + 中央揃え
r = post({
    "token": os.environ["GOOGLE_SHEET_API_TOKEN"],
    "sheet": "test",
    "data":  "Name\tScore",
    "cell":  "A1",
    "format": {
        "fontWeight": "bold",
        "backgroundColor": "#ffff00",
        "horizontalAlignment": "center",
    },
})
print(r.status_code, r.text)   # 成功: 200 'OK'

# データ行: 書式なしで追記
r = post({
    "token": os.environ["GOOGLE_SHEET_API_TOKEN"],
    "sheet": "test",
    "data":  "Alice\t95\nBob\t88",
    "cell":  "A2",
})
print(r.status_code, r.text)   # 成功: 200 'OK'
```

- 成功レスポンス: `200` + body `OK`
- 認証失敗: body `Unauthorized`
- エラー時: `doPost` が `throw` すると HTML エラーページになる

### 代替: Node.js fetch（`redirect: "manual"` で手動追跡）

**⚠️ 素の `fetch` の `redirect: "follow"` では 302 で POST body が失われる（curl と同じ理由）。**
`redirect: "manual"` で `Location` へ手動再 POST する必要がある。
（Python `requests`（推奨）のほうが単純）

```js
const url  = process.env.GOOGLE_SHEET_URL;
const body = JSON.stringify({
  token: process.env.GOOGLE_SHEET_API_TOKEN,
  sheet: "test",
  data:  "hello\tworld",
  cell:  "A1",
});

async function postWithRedirect(u, payload) {
  const res = await fetch(u, {
    method: "POST",
    headers: { "Content-Type": "text/plain;charset=utf-8" },
    body: payload,
    redirect: "manual",   // 302 を自動追跡しない（follow だと POST body が失われる）
  });
  if (res.status === 302) {
    const location = res.headers.get("location");
    // 302 の Location 先へ同じ body で再 POST（body 保持）
    return postWithRedirect(location, payload);
  }
  return res;
}

const res = await postWithRedirect(url, body);
console.log(res.status, await res.text());
```

## 使い方（手順）

1. `$GOOGLE_SHEET_URL` と `$GOOGLE_SHEET_API_TOKEN` が設定されているか確認。
   ```bash
   echo "URL=${GOOGLE_SHEET_URL:?未設定}"
   test -n "$GOOGLE_SHEET_API_TOKEN" && echo "token: 設定済み"
   ```
2. 書き込む値（TSV）と開始セルを決める。
   - 単一セル: `data` に改行なし1行。
   - 複数セル: タブで列、改行で行を区切る。
3. 必要に応じて `format`（書式設定）を決める。`format` は書き込み範囲全体に適用される。
4. Python `requests`（または Node `fetch`）で POST。
5. レスポンス `OK` を確認。

## 注意事項

1. **curl 禁止**: `curl -L` では 302 時に body が失われ失敗する。必ず
   `requests` / `fetch` を使うこと。
2. **トークン**: `$GOOGLE_SHEET_API_TOKEN` は環境変数から取得。ファイルに直書きしない。
3. **Content-Type**: `text/plain;charset=utf-8` を指定（JSON 形式でも text/plain で送る。
   `application/json` にすると `e.postData.contents` の解釈が変わる可能性がある）。
4. **TSV**: `data` は TSV。カンマ区切りではない。タブ文字 `\t` を使う。
5. **書き込み範囲**: `cell` 開始セルから、`data` の行数×列数の分だけ上書きされる。
   既存データの上書きに注意。

## トラブルシューティング

| 症状 | 原因 | 対処 |
|---|---|---|
| `curl` で `405` / エラー HTML / 空 | 302 redirect で body 喪失 | Python `requests` か `fetch` を使う |
| body が `Unauthorized` | トークン不一致 | `$GOOGLE_SHEET_API_TOKEN` を確認 |
| `Sheet not found` エラー | シート名が誤り | `sheet` 名を正確に指定 |
| HTML エラーページ（throw） | `doPost` 内で例外発生 | シート名・セル位置・data 形式を確認 |
