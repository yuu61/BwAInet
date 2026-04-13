# WireGuard 直接接続 ↔ wstunnel 経由の切替手順

会場上流のポート制限状況に応じて WireGuard のトンネル方式を切り替える。上位レイヤー (BGP, IPv6, firewall) は常に wg0 に統一されているため、下位トンネルの切替のみで対応する。設計は [`../design/architecture.md`](../design/architecture.md) および [`../design/venue-proxmox.md`](../design/venue-proxmox.md) を参照。

## トンネル動作概要

### 直接接続 (プロキシ解除時)

```
r3 VyOS (wg0) → eth1 (virtio) → vmbr_wan → nic3 → blackbox → Internet → 自宅 r1
```

- WireGuard endpoint: `<自宅グローバル IP>:51820`
- wstunnel コンテナは停止

### wstunnel 経由 (ポート制限環境時)

```
r3 VyOS (wg0 → 127.0.0.1:51821) → wstunnel (podman) → eth1 → WSS (TCP 443)
  → 自宅 wstunnel server (192.168.10.4:443, r1 DNAT 経由)
    → r1 wg0 (192.168.10.1:51820)
```

- WireGuard endpoint: `127.0.0.1:51821`
- wstunnel コンテナ起動必須
- デフォルトルート変更は不要 (wstunnel は VyOS 自身の eth1 から外に出る)

> **ポート分離**: r3 の wg0 自身が UDP 51820 で listen しているため、wstunnel client listen は 51821 にずらす。結果、wg1 (r2-gcp) は 51822 に割り当てる。

## 切替手順

### 直接 → wstunnel 経由

```bash
# 1. wstunnel コンテナを起動 (VyOS CLI で設定済みの場合)
restart container wstunnel

# 2. WireGuard endpoint を 127.0.0.1:51821 に変更
configure
set interfaces wireguard wg0 peer r1 endpoint '127.0.0.1:51821'
commit
save
```

### wstunnel 経由 → 直接

```bash
configure
set interfaces wireguard wg0 peer r1 endpoint '<自宅グローバルIP>:51820'
commit
save

# wstunnel コンテナを停止 (任意)
stop container wstunnel
```

## wstunnel コンテナ投入 (初回のみ)

`command` 文字列に `?` / `/` / `\` が含まれるため、**VyOS CLI から `set` で投入できない** (補完トリガー)。必ず REST API 経由で投入する。

```bash
curl -k -X POST https://<r3-mgmt-ip>/configure \
  -H "Content-Type: application/json" \
  -d '{"key":"<API_KEY>","commands":[
    {"op":"delete","path":["container","name","wstunnel","command"]},
    {"op":"set","path":["container","name","wstunnel","command",
      "/home/app/wstunnel client -L udp://127.0.0.1:51821:192.168.10.1:51820?timeout_sec=0 wss://<自宅FQDN>:443"]}
  ]}'

# 保存
curl -k -X POST https://<r3-mgmt-ip>/config-file \
  -H "Content-Type: application/json" \
  -d '{"key":"<API_KEY>","op":"save"}'
```

### 主要パラメータ

- `/home/app/wstunnel` の絶対パスは必須 (dumb-init が execve するため)
- `allow-host-networks`: localhost 経由で wg0 と UDP 通信するため必須
- `127.0.0.1:51821`: wg0 listen port 51820 との衝突回避
- `192.168.10.1:51820`: 自宅 r1 の WireGuard (wstunnel server から見た転送先)
- プロキシ併用時は `--http-proxy <proxy>:8080` を追加

## 自宅側 wstunnel サーバー

メインPC (192.168.10.4) で稼働させる。r1 の DNAT で pppoe0:443 → 192.168.10.4:443 に転送する (NAT rule 30)。

```bash
wstunnel server --restrict-to 192.168.10.1:51820 wss://[::]:443
```

## 関連

- [`../design/architecture.md`](../design/architecture.md) — VPN 方式選択
- [`../design/venue-proxmox.md`](../design/venue-proxmox.md) — wstunnel 配置
- [`../design/venue-vyos.md`](../design/venue-vyos.md) — r3 の WG 設定
- [`../design/home-vyos.md`](../design/home-vyos.md) — r1 DNAT
- [`../investigation/tailscale-derp-tcp443-fallback-investigation.md`](../investigation/tailscale-derp-tcp443-fallback-investigation.md) — 方式比較
