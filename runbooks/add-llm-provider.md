# Runbook: LLM プロバイダー追加 (add-llm-provider)

LiteLLM に新しいモデル/プロバイダーを追加する手順。

## 1. LiteLLM 側

- LiteLLM UI (`http://162.43.21.240:4000/ui`) でモデルを追加
  - モデル名・プロバイダー (例: `deepseek`, `openai`, `anthropic`) を指定
  - API キーは環境変数 or UI から設定
- `STORE_MODEL_IN_DB=True` なので、UI での登録が DB に永続化される
  (docker-compose 再起動でも維持)

### 既存モデル例

| モデル ID | 実体 |
|---|---|
| `deepseek-v4-flash` | DeepSeek V4 Flash |

## 2. クライアント側 (opencode)

`~/.config/opencode/opencode.json` の `provider.litellm.models` に追加:

```json
"models": {
  "deepseek-v4-flash": { "name": "DeepSeek V4 Flash" },
  "new-model-id": { "name": "表示名" }
}
```

opencode 内で `/models` から切り替え可能になる。

## 3. 検証

```bash
curl -s -m 3 http://162.43.21.240:4000/v1/models -H "Authorization: Bearer $LITELLM_API_KEY"
# 新しいモデルが data[] に含まれること
```

## シークレット注意

プロバイダーの API キーをリポジトリにコミットしないこと。
`.env.example` には変数名だけを置く。
