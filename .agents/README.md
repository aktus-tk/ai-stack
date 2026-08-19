# .agents — OpenCode Global Skills

このディレクトリには、OpenCode (Claude Code) のグローバルスキルが含まれます。

**これらのスキルは自宅の opencode クライアント (`~/.agents/skills/`) にコピーして使用します。**

## 含まれるスキル

### 1. memory-commit (`memory-commit.md`)

ユーザーが「ここまで記憶して」「記憶して」等の memory commit 意図を発話したときに、現在の context から「意味のある状態」を抽出・整理・圧縮し、harness-mem daemon へ HTTP 経由でバッチ保存する。

**特徴**:
- observation を `/v1/events/record` で保存
- 保存直後の fallback vector を `/v1/admin/reindex-vectors` で Granite embedding に変換
- vector 登録成功を確認してからユーザーに報告

**参照**: `skills/harness-mem/SKILL.md` (write path)

### 2. harness-recall (`harness-recall.md`)

ユーザーが「思い出して」「覚えてる」「前回」等の recall 意図を発話したときに、harness-mem daemon から semantic search で記憶内容を検索・取得する。

**特徴**:
- `/v1/search` で Granite embedding ベースの vector search を実行
- project scope + debug:true で vector 検索メタを取得
- lexical (FTS) + vector (semantic) の hybrid 結果を返す

**参照**: `skills/harness-mem/SKILL.md` (read path)

## セットアップ

### 自宅 opencode への導入

```bash
# スキルをコピー
cp memory-commit.md ~/.agents/skills/memory-commit/SKILL.md
cp harness-recall.md ~/.agents/skills/harness-recall/SKILL.md

# または
for f in *.md; do
  name="${f%.md}"
  mkdir -p ~/.agents/skills/$name
  cp "$f" ~/.agents/skills/$name/SKILL.md
done
```

### 環境変数の確認

スキルは以下の env を参照します（`.bashrc` や `.env` に設定）:

```bash
export HARNESS_MEM_HOST=100.92.131.75
export HARNESS_MEM_PORT=37888
export HARNESS_MEM_ADMIN_TOKEN=<token>
export HARNESS_MEM_WORKING_HOST=100.92.131.75
export HARNESS_MEM_WORKING_PORT=37889
export HARNESS_MEM_WORKING_ADMIN_TOKEN=<token>
```

## 関連ドキュメント

- `skills/harness-mem/SKILL.md` — harness-mem 本体の運用知識・API リファレンス
- `docs/granite-embedding-verification.md` — Granite embedding の検証結果
- `runbooks/harness-mem-granite-migration.md` — 移行手順・トラブルシューティング
- `README.md` — ai-stack 全体の概要
