# アーキテクチャ概要

## エージェント構成

```text
User (Architect)
      │
      ▼
┌─────────────────────────────────────────────────────────┐
│  Director (primary agent, DeepSeek V4 Flash)            │
│                                                         │
│  責務:                                                   │
│  - ユーザー意図の理解・タスク分解                         │
│  - Engineer / QA への delegation                        │
│  - 結果統合・最終報告                                    │
│                                                         │
│  Escalation (自律判断しない):                            │
│  - architecture / security boundary / data-model        │
│  - major technology selection / significant trade-offs  │
│                                                         │
│  Memory: harness-mem main (長期記憶)                    │
└────────────────┬───────────────────┬────────────────────┘
                 │                   │
        ┌────────▼────────┐ ┌────────▼────────┐
        │    Engineer     │ │       QA        │
        │   (subagent)    │ │   (subagent)    │
        │                 │ │                 │
        │ implementation  │ │ adversarial     │
        │ investigation   │ │ review          │
        │ debugging       │ │ verification    │
        │ testing         │ │                 │
        │                 │ │ 問題発見→報告   │
        │ Memory: working │ │ Memory: working │
        └─────────────────┘ └─────────────────┘
```

### 責務境界

| エージェント | 自律実行 OK | Escalate |
|-------------|------------|----------|
| Director | タスク分解、delegation、結果統合 | architecture, security, data-model, major trade-offs |
| Engineer | implement, investigate, debug, test, verify | scope expansion, architecture change, destructive ops |
| QA | review, verify, 問題報告 | 大規模修正（報告のみ、自動修正しない） |

### Configuration SSOT Structure

```text
Git repository
├── AGENTS.md                        ← global agent policy
└── config/opencode/
    ├── opencode.json                ← agent definitions / config
    ├── instructions/
    │   └── memory-policy.md         ← instructions (AGENTS.md への参照)

         ↓ symlink

~/.config/opencode/
├── AGENTS.md                        → /path/to/repo/AGENTS.md
├── opencode.json                    → /path/to/repo/config/opencode/opencode.json
└── instructions                     → /path/to/repo/config/opencode/instructions
```

**更新フロー**:
1. `git pull` (repository 更新)
2. symlink 経由で runtime へ自動反映（追加の deploy/sync 不要）

**Setup**:
- 初期セットアップ: `scripts/setup-links.sh` (idempotent; 全エージェント + MCP)

## 全体像

```
                    ┌──────────────────────────────────────────────┐
                    │      サーバー (x162-43-21-240)                 │
                    │    公開IP 162.43.21.240                       │
                    │    Tailscale 100.92.131.75                    │
                    │                                              │
                    │  ┌────────────────────────────────────────┐  │
                    │  │ harness-mem daemon                     │  │
                    │  │ (remote memory service)                │  │
                    │  │ :37888 (main) :37889 (working)         │  │
                    │  │ HTTP API (no MCP)                      │  │
                    │  │ (docker compose)                       │  │
                    │  └────────────────────────────────────────┘  │
                    └───────────┬──────────────────────────────────┘
                                │
                       memory HTTP (Tailscale)
                       + トークン
                                │
                    ┌───────────┴──────────────────────────────┐
                    │     クライアント (desk 他)                 │
                    │   Tailscale 100.122.82.18               │
                    │                                        │
                    │ ┌────────────────────────────────────┐ │
                    │ │          OpenCode CLI              │ │
                    │ │  ├─ local session/history          │ │
                    │ │  │  (crash recovery)               │ │
                    │ │  │                                  │ │
                    │ │  ├─ global skill:                  │ │
                    │ │  │  memory-commit                  │ │
                    │ │  │    └─ curl → daemon:37889 HTTP │ │
                    │ │  │                                  │ │
                    │ │  └─ global skill:                  │ │
                    │ │     harness-recall                 │ │
                    │ │       └─ curl → daemon:37888 HTTP │ │
                    │ └────────────────────────────────────┘ │
                    └────────────────────────────────────────┘
```

## 責務の分離

| コンポーネント | 責務 | 特徴 |
|---|---|---|
| **OpenCode local session/history** | 短期作業 context + crash recovery | OpenCode が管理 (MCP 不使用) |
| **global skill: memory-commit** | ユーザー明示による harness-mem への永続保存 | curl で HTTP API 呼び出し |
| **global skill: harness-recall** | 過去記憶の検索・取得 | curl で HTTP API 呼び出し |
| **harness-mem daemon** | 記憶の remote storage (main / working) | OpenCode から独立 |

## データフロー

1. **通常作業** — OpenCode local session のみ (harness-mem アクセスなし)
2. **記憶を残したい** → ユーザーが「記憶して」発話 → memory-commit skill → curl HTTP POST
3. **過去を思い出したい** → ユーザーが「思い出して」発話 → harness-recall skill → curl HTTP GET
4. **crash 後の復旧** → OpenCode が local session を restore (harness-mem 不使用)

## 主要な決定事項

- **MCP は使用しない**: Memory 読み書きは global skill + curl + HTTP API ベース
- **明示 commit**: 自動記録ではなく、ユーザーが「記憶して」と言ったときのみ harness-mem へ保存
- **OpenCode は独立**: crash recovery は OpenCode の local history で完結。harness-mem は「長期的に残したいもの」のみ
- **harness-mem は remote service**: OpenCode の常時 context ではなく、必要時だけ呼び出す独立した service
