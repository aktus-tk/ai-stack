# Runbook: デバイス追加 (add-device)

新しいノードを Tailscale メッシュに追加し、AI クライアントとして使えるようにする。

## 手順

1. **Tailscale 参加**
   ```bash
   sudo tailscale up
   ```
   `tailscale status` で新ノードが表示されることを確認。

2. **LiteLLM へのアクセス確認**
   ```bash
   curl -s http://162.43.21.240:4000/v1/models -H "Authorization: Bearer $LITELLM_API_KEY"
   ```

3. **harness-mem daemon への疎通確認**
   ```bash
   curl -s http://100.92.131.75:37888/health
   ```

4. **クライアントセットアップ** → `runbooks/bootstrap-client.md` を実行

## セキュリティ

- harness-mem daemon への到達は Tailscale メッシュに依存。
  Tailscale ACL (`tailscale` admin console) で、daemon へのアクセスを
  必要なノードに限定することを推奨 (特に厳密なトークン認証を未導入の場合)。
- デバイスを廃止する場合は `sudo tailscale down` と ACL から除去。
