# Skill: Backlog API

RHEMS Backlog (`https://rhems-bl.backlog.com/`) の Issue 参照・検索・作成・更新・コメント操作を行う Skill。
認証はクエリパラメータ `?apiKey=` で `$BACKLOG_API_KEY` を渡す。
**注意**: `Authorization: Bearer` ヘッダー方式は使えない。クエリパラメータ方式のみ。

## 基本設定

```bash
SPACE="https://rhems-bl.backlog.com"
API_KEY="$BACKLOG_API_KEY"
API_BASE="${SPACE}/api/v2"
```

認証は全リクエストにクエリパラメータ `?apiKey=${API_KEY}` を付与する。
(`Authorization: Bearer` ヘッダーでは認証できない)

## エンドポイント一覧

### プロジェクト

| 操作 | メソッド | エンドポイント | 説明 |
|---|---|---|---|
| 一覧 | GET | `/projects` | 全プロジェクト取得 |
| 情報取得 | GET | `/projects/{projectId}` | プロジェクト詳細取得 |
| 情報取得 | GET | `/projects?archived=false` | アーカイブ以外 |

### 課題タイプ・優先度・ステータス

| 操作 | メソッド | エンドポイント |
|---|---|---|
| 課題タイプ一覧 | GET | `/projects/{projectId}/issueTypes` |
| 優先度一覧 | GET | `/priorities` |
| ステータス一覧 | GET | `/statuses` |

### 課題

| 操作 | メソッド | エンドポイント | 説明 |
|---|---|---|---|
| 検索 | GET | `/issues` | クエリ条件で検索 |
| 取得 | GET | `/issues/{issueKey}` | 課題情報取得（キーまたはID） |
| 作成 | POST | `/issues` | 新規課題作成 |
| 更新 | PATCH | `/issues/{issueKey}` | 課題更新 |
| 削除 | DELETE | `/issues/{issueKey}` | 課題削除 |

### コメント

| 操作 | メソッド | エンドポイント |
|---|---|---|
| 取得 | GET | `/issues/{issueKey}/comments` |
| 追加 | POST | `/issues/{issueKey}/comments` |
| 削除 | DELETE | `/issues/{issueKey}/comments/{commentId}` |

## API 呼び出し例

### 1. プロジェクト一覧取得

```bash
curl -X GET \
  "${API_BASE}/projects?apiKey=${API_KEY}"
```

レスポンス例:
```json
[
  {
    "id": 12345,
    "projectKey": "TEST",
    "name": "Test Project",
    "archived": false
  }
]
```

### 2. プロジェクト情報取得

```bash
PROJ_ID=12345
curl -X GET \
  "${API_BASE}/projects/${PROJ_ID}?apiKey=${API_KEY}"
```

### 3. 課題タイプ一覧（プロジェクトごと）

```bash
PROJ_ID=12345
curl -X GET \
  "${API_BASE}/projects/${PROJ_ID}/issueTypes?apiKey=${API_KEY}"
```

レスポンス例:
```json
[
  {
    "id": 11,
    "name": "バグ"
  },
  {
    "id": 12,
    "name": "実装"
  }
]
```

### 4. 優先度一覧

```bash
curl -X GET \
  "${API_BASE}/priorities?apiKey=${API_KEY}"
```

レスポンス例:
```json
[
  {"id": 2, "name": "低"},
  {"id": 3, "name": "中"},
  {"id": 4, "name": "高"}
]
```

### 5. ステータス一覧

```bash
curl -X GET \
  "${API_BASE}/statuses?apiKey=${API_KEY}"
```

レスポンス例:
```json
[
  {"id": 1, "name": "未対応"},
  {"id": 2, "name": "対応中"},
  {"id": 3, "name": "完了"}
]
```

### 6. 課題検索

```bash
# 条件付きで検索
curl -X GET \
  "${API_BASE}/issues?projectId=12345&offset=0&count=100&apiKey=${API_KEY}"

# JQL-like フィルター
curl -X GET \
  "${API_BASE}/issues?projectIds[]=12345&statusId[]=1&apiKey=${API_KEY}"
```

パラメータ:
- `projectIds[]`: プロジェクト ID（複数指定可）
- `statusId[]`: ステータス ID
- `typeId[]`: 課題タイプ ID
- `priorityId[]`: 優先度 ID
- `offset`, `count`: ページング

### 7. 課題取得

```bash
ISSUE_KEY="TEST-123"
curl -X GET \
  "${API_BASE}/issues/${ISSUE_KEY}?apiKey=${API_KEY}"
```

### 8. 課題作成

```bash
PROJ_ID=12345
ISSUE_TYPE_ID=11      # バグの ID を取得してから使用
PRIORITY_ID=3         # 優先度の ID を取得してから使用

curl -X POST \
  "${API_BASE}/issues?apiKey=${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "projectId": '${PROJ_ID}',
    "summary": "課題のタイトル",
    "issueTypeId": '${ISSUE_TYPE_ID}',
    "priorityId": '${PRIORITY_ID}',
    "description": "課題の説明"
  }'
```

### 9. 課題更新

```bash
ISSUE_KEY="TEST-123"

# ステータス更新
curl -X PATCH \
  "${API_BASE}/issues/${ISSUE_KEY}?apiKey=${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "statusId": 2,
    "comment": "対応を開始しました"
  }'
```

### 10. コメント取得

```bash
ISSUE_KEY="TEST-123"
curl -X GET \
  "${API_BASE}/issues/${ISSUE_KEY}/comments?apiKey=${API_KEY}"
```

### 11. コメント追加

```bash
ISSUE_KEY="TEST-123"
curl -X POST \
  "${API_BASE}/issues/${ISSUE_KEY}/comments?apiKey=${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "content": "コメントの内容"
  }'
```

## 重要な注意事項

1. **API キー管理**
   - `$BACKLOG_API_KEY` は環境変数から取得
   - ファイルに直接記載しない

2. **IDの取得**
   - `issueTypeId`, `priorityId`, `statusId` は作成・更新前に API から取得する
   - プロジェクトごとに異なる可能性あり

3. **ページング**
   - `offset` と `count` でページング
   - 大量データはループで処理

4. **エラーハンドリング**
   - Backlog API は 4xx / 5xx で エラーレスポンス返却
   - `content-type: application/json` を指定必須

5. **検索条件**
   - JQL ではなくクエリパラメータで指定
   - `statusId[]`, `typeId[]` など配列形式

## トラブルシューティング

### 認証エラー
```
401 Unauthorized
```
→ API キーが正しいか、`$BACKLOG_API_KEY` が設定されているか確認
→ **`Authorization: Bearer` ヘッダーではなく、クエリパラメータ `?apiKey=` で認証すること**

### リソースが見つからない
```
404 Not Found
```
→ プロジェクト ID や Issue Key が正しいか確認。Issue Key は `PROJECT-123` 形式。

### レート制限
Backlog API は同時接続数に制限あり。`curl` での呼び出しは通常範囲内。

