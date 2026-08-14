# Skill: LiteLLM 運用

LLM ゲートウェイ (LiteLLM Proxy) を扱うための運用知識。

## 構成

- Docker Compose: `~/docker/litellm/` (サーバー `x162-43-21-240`)
- コンテナ: `litellm-litellm-1` (Proxy), `litellm-db-1` (Postgres)
- ポート: `4000`
- UI: `http://162.43.21.240:4000/ui`
- エンドポイント: `http://162.43.21.240:4000/v1`
- モデル登録は DB 永続化 (`STORE_MODEL_IN_DB=True`)

## 何を壊してはいけないか

1. **仮想キーとマスターキーを混同しない** — クライアントが使うのは仮想キー
   (`LITELLM_API_KEY`)。マスターキー (`LITELLM_MASTER_KEY`) は管理用。
2. **シークレットをコミットしない** — `.env` / `.envrc` はリポジトリ外。
3. **`latest` tag のまま長期運用しない** — リリースタグに固定推奨 (破壊的変更の回避)。

## よく使う操作

```bash
# 状態確認
ssh x 'cd ~/docker/litellm && docker compose ps'

# モデル一覧
curl -s -m 3 http://162.43.21.240:4000/v1/models \
  -H "Authorization: Bearer $LITELLM_API_KEY"

# ログ
ssh x 'cd ~/docker/litellm && docker compose logs --tail=50 litellm'

# 再起動
ssh x 'cd ~/docker/litellm && docker compose restart litellm'
```

## モデルの追加

`runbooks/add-llm-provider.md` を参照。
UI で登録 → クライアントの opencode.json にモデルを追加 → `/models` で切り替え。

## 関連

- プロバイダー追加 → `runbooks/add-llm-provider.md`
- ネットワーク → `architecture/network.md`
