# セキュリティ設計

## 原則

1. **公開面を最小化**: 外部に出すのは Caddy のみ。harness-mem は Tailscale 内のみ。
2. **トークン認証を必須化**: 全 API アクセスはトークンで認証。
3. **シークレットはリポジトリ外**: リポジトリには `.env.example` のみ。実値は各ノードの
   非公開ファイル (`~/.envrc`, systemd unit, `~/.harness-mem/config.json`)。

## レイヤー別の対策

| レイヤー | 対策 |
|---|---|
| harness-mem | Tailscale バインド + `HARNESS_MEM_ADMIN_TOKEN` (Bearer) |
| Tailscale | メッシュ暗号化。ACL でノード間アクセスを制御可能 |
| ネットワーク | harness-mem daemon は公開 IP に一切バインドしない |

## 既知の注意点 (2026-08-14 時点)

- harness-mem daemon をリモートバインドで起動する際、起動時の FATAL チェックは
  `HARNESS_MEM_ADMIN_TOKEN` か config.json の `auth` セクションの存在のみを確認する。
- **ただし**、`resolveAccess` の 401 強制は config.json の `auth` セクション
  (auth_config) が設定された場合のみ有効。
- 現状 `auth` セクション未設定のため、**Tailscale ネットワーク内ではトークンなしで
  データ API にアクセス可能**。Tailscale ACL で到達可能ノードを制限しているか、
  厳密な認証が必要な場合は config.json に `auth` セクションを追加すること。

```json
{
  "auth": {
    "admin_token": "REPLACE_WITH_LONG_RANDOM_TOKEN",
    "tokens": {}
  }
}
```

## シークレット管理

| シークレット | 配置場所 | コミット禁止 |
|---|---|---|
| `OPENCODE_API_KEY` | `~/.envrc` 等 (クライアント) / `.env` (サーバー) | ✅ |
| `HARNESS_MEM_ADMIN_TOKEN` | systemd unit `Environment=` (サーバー) | ✅ |

## 監査・ログ

- harness-mem: `~/.harness-mem/daemon.log`, `~/.harness-mem/harness-mem-ui.log`
- systemd journal: `journalctl -u harness-memd`
