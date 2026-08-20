# Memory Policy

この環境の Memory Policy は **AGENTS.md** を SSOT (Single Source of Truth) とする。

詳細は以下を参照:
- `~/github/aktus-tk/ai-stack/AGENTS.md` の「Memory Policy」セクション
- `~/.agents/skills/memory-commit.md` (commit 操作)
- `~/.agents/skills/harness-recall.md` (recall 操作)

## 概要

- **MCP 無効化**: skill + HTTP API + curl で on-demand アクセス
- **明示 commit**: ユーザーが「記憶して」と言ったときのみ保存
- **store 使い分け**: working (既定/一時) / main (長期/canonical)
- **cross-project recall**: プロジェクト横断検索がデフォルト
