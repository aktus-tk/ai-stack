# Skill: Tailscale 運用

Tailscale メッシュの運用知識。harness-mem daemon へのアクセスはこのネットワーク経由。

## ノード

| ノード | Tailscale IP |
|---|---|
| サーバー `x162-43-21-240` | `100.92.131.75` |
| クライアント `desk` | `100.122.82.18` |
| その他 (iphone 等) | 100.66.x / 100.108.x / 100.115.x |

## 何を壊してはいけないか

1. **サーバーの Tailscale を止めない** — remote memory service (harness-mem daemon) への唯一のアクセス経路。
   `tailscale down` するとクライアントからメモリにアクセスできなくなる。
2. **harness-mem daemon の bind を Tailscale IP に保つ** — 公開 IP にバインドを移すと
   認証なしの外部アクセス経路ができる。ACL か auth 設定が整うまで変更しない。
3. **ノードを削除する前に**、そのノードを利用するサービスがないか確認する。

## よく使う操作

```bash
# ノード一覧
tailscale status

# 自身の IP
tailscale ip -4

# 疎通確認
ping -c1 100.92.131.75

# 参加
sudo tailscale up
# 離脱
sudo tailscale down
```

## ACL

Tailscale admin console (https://login.tailscale.com/admin/acls) で
ノード間の到達性を制御できる。クライアント (`autogroup:member`) からサーバー
(`100.92.131.75`) へのアクセスは以下の ACL で許可している。

```json
{
  "src": ["autogroup:member"],
  "dst": ["100.92.131.75"],
  "ip":  ["tcp:37888", "tcp:37889", "tcp:8090"]
}
```

| ポート | 用途 |
|---|---|
| `tcp:37888` | harness-mem daemon (remote memory service, HTTP API) |
| `tcp:37889` | harness-mem working daemon (remote memory service, HTTP API) |
| `tcp:8090` | Caddy (opencode-server への入口) |

- 追加ポートが必要になったらこの ACL に追記し、このドキュメントも更新する。
- harness-mem daemon (`100.92.131.75:37888` / `37889`) へのアクセスは、
  global skill (memory-commit / harness-recall) 経由で行われ、必要なクライアントのみが HTTP API で接続。

## 関連

- デバイス追加 → `runbooks/add-device.md`
- ネットワーク → `architecture/network.md`
