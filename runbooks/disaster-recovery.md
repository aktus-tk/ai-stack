# Runbook: 障害復旧 (disaster-recovery)

## 事前準備 (平常時)

- `scripts/backup-harness.sh` で DB を定期的にバックアップ (cron 推奨)。
- バックアップは DB 本体 + WAL を一貫スナップショットにまとめる (`VACUUM INTO`)。
- シークレット (LiteLLM キー, harness-mem トークン) は各ノードの設定から再現可能にしておく。

## 復旧シナリオ

### A. harness-mem daemon が落ちた

```bash
ssh x 'systemctl status harness-memd'
ssh x 'sudo systemctl restart harness-memd'
# 起動後: curl -s http://100.92.131.75:37888/health
```

再起動しても DB はそのまま。`systemctl enable` 済みなので OS 再起動でも自動起動する。

### B. DB が破損した

1. バックアップから復元
   ```bash
   ssh x '~/.volta/bin/harness-memd stop'
   ssh x 'cp ~/.harness-mem/harness-mem.db ~/.harness-mem/harness-mem.db.corrupt'
   # バックアップを転送・配置
   scp backup/harness-mem-XXXX.db x:~/.harness-mem/harness-mem.db
   ssh x 'systemctl start harness-memd'
   ```

2. 整合性チェック
   ```bash
   ssh x 'sqlite3 ~/.harness-mem/harness-mem.db "PRAGMA integrity_check;"'   # → ok
   ```

### C. サーバーごと消失 (OS 再インストール)

1. `runbooks/bootstrap-server.md` でサーバー再構築
2. バックアップから DB を復元
3. Tailscale に再参加 → クライアントの接続先 IP は変わらない (Tailscale IP 固定)

### D. クライアント消失

新規クライアントを `runbooks/bootstrap-client.md` で再構築。
記憶はサーバー側にあるため、クライアント交換で失われない。

## 検証

復旧後は必ず `./scripts/verify.sh` を実行して、LiteLLM と harness-mem の
両方が疎通することを確認する。
