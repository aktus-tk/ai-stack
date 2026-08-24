# Skill: Harness Memory Commit (with Vector Embedding)

harness-mem main store への observation 記録時に、ベクトル埋め込みも自動実行する手順。

## 目的

長期記憶への記録と同時にベクトル化を完了させ、以降の検索・関連観測抽出が機能するようにする。

## 実装方針

### 記録フロー

```
1. harness-mem に observation 記録
   ↓
2. vector reindex 自動実行
   ↓
3. vector coverage 確認（ログ出力）
```

### Bash Script Example

```bash
#!/bin/bash

# 1. チェックポイント記録
curl -X POST http://harness-memd:37888/v1/checkpoint \
  -H "Authorization: Bearer ${HARNESS_MEM_ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "session_id": "'${SESSION_ID}'",
    "title": "Your title",
    "content": "Your content",
    "tags": ["tag1", "tag2"]
  }'

# 2. Vector reindex 実行（記録直後）
curl -X POST http://harness-memd:37888/v1/admin/reindex-vectors \
  -H "Authorization: Bearer ${HARNESS_MEM_ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "limit": 20,
    "reason": "post-checkpoint-record"
  }'

# 3. カバレッジ確認（オプション）
curl -s http://harness-memd:37888/v1/admin/metrics \
  -H "Authorization: Bearer ${HARNESS_MEM_ADMIN_TOKEN}" | jq '.items[0].coverage.vector_coverage'
```

## CLI による実行方法

### 方法1: curl + jq の組み合わせ

```bash
# 記録 + reindex を順序保証で実行
(
  curl -s -X POST http://harness-memd:37888/v1/checkpoint \
    -H "Authorization: Bearer ${HARNESS_MEM_ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{...}"
) && \
sleep 1 && \
curl -s -X POST http://harness-memd:37888/v1/admin/reindex-vectors \
  -H "Authorization: Bearer ${HARNESS_MEM_ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"limit": 20}'
```

### 方法2: Python + requests

```python
#!/usr/bin/env python3
import requests
import json
import os
import time

HARNESS_URL = "http://harness-memd:37888/v1"
TOKEN = os.environ.get("HARNESS_MEM_ADMIN_TOKEN")
HEADERS = {"Authorization": f"Bearer {TOKEN}"}

def commit_with_vector(session_id, title, content, tags):
    """Record checkpoint and reindex vectors"""

    # 1. Record
    checkpoint_data = {
        "session_id": session_id,
        "title": title,
        "content": content,
        "tags": tags
    }

    resp = requests.post(
        f"{HARNESS_URL}/checkpoint",
        json=checkpoint_data,
        headers=HEADERS
    )
    resp.raise_for_status()
    print(f"✓ Checkpoint recorded: {resp.status_code}")

    # 2. Wait (ensure DB write complete)
    time.sleep(1)

    # 3. Reindex vectors
    reindex_data = {"limit": 20}
    resp = requests.post(
        f"{HARNESS_URL}/admin/reindex-vectors",
        json=reindex_data,
        headers=HEADERS
    )
    resp.raise_for_status()
    result = resp.json()

    # 4. Report
    coverage = result.get("items", [{}])[0].get("vector_coverage", 0)
    print(f"✓ Vectors reindexed: coverage={coverage:.1%}")

    return result
```

## 重要な注意事項

### 1. 順序の保証
- 記録 → reindex の順序は必ず守る
- `&&` または `sleep` で依存関係を明示

### 2. Token 認証
- `$HARNESS_MEM_ADMIN_TOKEN` は環境変数から取得
- compose 内では `harness-memd:37888` で接続（localhost NG）

### 3. ベクトル化タイミング
- 記録直後は embedding_deferred の可能性
- reindex で確実に完了させる
- 検索精度向上（proximity search）に効果

### 4. Coverage 目標
- 目標: 95% 以上
- limit=20 で大半のケースをカバー
- 必要に応じて limit を増やす

## トラブルシューティング

### ベクトル化が遅い
```bash
# ステータス確認
curl -s http://harness-memd:37888/v1/admin/metrics \
  -H "Authorization: Bearer ${HARNESS_MEM_ADMIN_TOKEN}" | jq .
```
→ embedding_provider_status が "healthy" か確認

### Coverage が 95% に達しない
```bash
# 全体をリインデックス
curl -s -X POST http://harness-memd:37888/v1/admin/reindex-vectors \
  -H "Authorization: Bearer ${HARNESS_MEM_ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"limit": 50}'
```

### 403 Unauthorized
→ `$HARNESS_MEM_ADMIN_TOKEN` が正しいか確認

