# アーキテクチャ概要

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
