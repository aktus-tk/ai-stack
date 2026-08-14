# ネットワーク設計

## ノード

| ノード | 公開 IP | Tailscale IP | 役割 |
|---|---|---|---|
| サーバー `x162-43-21-240` | `162.43.21.240` | `100.92.131.75` | LiteLLM / harness-mem daemon / その他サービス |
| クライアント `desk` | — | `100.122.82.18` | opencode / エージェント CLI |

## ポート・バインド一覧

| サービス | ポート | バインド先 | アクセス元 | 認証 |
|---|---|---|---|---|
| LiteLLM Proxy | 4000 | `0.0.0.0` | 全クライアント | `LITELLM_API_KEY` (仮想キー) |
| harness-mem daemon | 37888 | `100.92.131.75` (Tailscaleのみ) | クライアント (Tailscale) | `HARNESS_MEM_ADMIN_TOKEN` |
| harness-mem UI | 37901 | `100.92.131.75` (Tailscaleのみ) | クライアント (Tailscale) | — |
| harness-mem MCP | 標準入出力 | ローカル | 各エージェント | — |

## 経路の分離

```
クライアント ──(公開インターネット / HTTP)──→ LiteLLM      :4000
クライアント ──(Tailscale VPN / 暗号化)────→ harness-memd :37888
```

- **LiteLLM は「外から使う」ための入り口**。仮想キーがアクセス制御の役割。
- **harness-mem は「内側だけ」のサービス**。Tailscale メッシュ越しのみ到達可能。

## 変更時の確認コマンド

```bash
# 実際のバインド先
ss -tlnp | grep -E '37888|4000'

# Tailscale 上のノード一覧
tailscale status

# 疎通確認
curl -s -m 3 http://162.43.21.240:4000/v1/models -H "Authorization: Bearer $LITELLM_API_KEY"
curl -s -m 3 http://100.92.131.75:37888/health
```
