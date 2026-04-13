# 自宅 VyOS (r1) 設計書

## 概要

自宅ルーター r1 (VyOS)。家族用ネットワーク 192.168.10.0/24 と会場 VPN・GCP トランジットを担う。AS65002。

IX3315 からの移行記録は [`../investigation/ix3315-migration.md`](../investigation/ix3315-migration.md)、投入用コマンド集は [`../configs/r1-home.conf`](../configs/r1-home.conf) を参照。

## 物理構成

- **X710-DA4**: 4 ポート SFP+ (10GbE)。FS SFP-10GM-T-30 (10GBase-T SFP+ モジュール) を使用。NVM 9.56 にアップデート済み (7.00 ではベンダーロックあり)
- **オンボード NIC**: Intel I219-V 1GbE (ASRock B360M-ITX/ac)。AP 接続に使用

### インターフェースマッピング

| ethN | 物理 NIC | 論理名 | 役割 |
|------|----------|--------|------|
| eth0 | オンボード I219-V 1GbE | ETH-AP | LAN — AP (br0 メンバー) |
| eth1 | X710-DA4 (SFP+ + RJ45) | ETH-WAN | WAN (PPPoE) → pppoe0 |
| eth2 | X710-DA4 (SFP+ + RJ45) | ETH-PC | LAN — デスクトップ PC (br0) |
| eth3 | X710-DA4 (SFP+) | — | 検証用トランジット (r3 直結時) |
| eth4 | X710-DA4 (SFP+) | — | 未使用 |
| wg0 | — | — | 会場 VPN + BGP |
| wg1 | — | — | GCP (r2-gcp) |

### br0 (LAN ブリッジ)

br0 に 192.168.10.1/24 を付与し、eth0 (AP) + eth2 (PC) をメンバーに含める。IX3315 の BVI1 と同等。

## WAN (PPPoE)

OPTAGE 回線を PPPoE で終端。`ip adjust-mss clamp-mss-to-pmtu` で MSS クランプ、`dhcpv6-options pd 0 length 64` で DHCPv6-PD を取得。

## DHCP サーバー (192.168.10.0/24)

家族用 LAN の DHCPv4。レンジ .3–.199、リース 86400s。デスクトップ PC (.4) は固定マッピング (wstunnel サーバー/iperf3 用)。

## DNS フォワーディング

OPTAGE ISP の DNS を `name-server` で明示指定。`system` オプションは `system name-server 127.0.0.1` との組み合わせでループするため使わない。ルーター自身の DNS 解決のため `127.0.0.1` でもリッスンする。

## NTP

VyOS 自身が NTP サーバーを提供 (旧 .9 サーバーが VyOS に置き換わったため)。DHCP option 42 は 192.168.10.1 を案内。

### 起動順序の対策

chrony が vyos-router.service より先に起動すると DNS forwarding 未起動で NTP ホスト名解決に失敗する (`sources with unknown address`)。`/config/scripts/vyos-postconfig-bootup.script` で全サービス起動後に `systemctl restart chrony` を実行する。

## NAT

### SNAT (マスカレード)

| rule | source | outbound | 用途 |
|---|---|---|---|
| 100 | 192.168.10.0/24 | pppoe0 | 家族 LAN |
| 110-130 | 192.168.11/30/40 | pppoe0 | 会場サブネット |
| 150 | 10.255.0.0/24 | pppoe0 | WG トンネルアドレス (r3 自身の発トラフィック) |

### DNAT (DMZ: メインPC 192.168.10.4)

旧 .9 サーバーは VyOS に置き換わったため、wstunnel / iperf3 はメインPC (.4) で稼働。

| rule | port | 転送先 | 用途 |
|---|---|---|---|
| 30 | TCP 443 | 192.168.10.4 | wstunnel サーバー |
| 40 | TCP 5201 | 192.168.10.4 | iperf3 TCP |
| 50 | UDP 5201 | 192.168.10.4 | iperf3 UDP |

SSH と WireGuard は VyOS 自身が終端するため DNAT 不要。

### ヘアピン NAT

LAN 内から自宅グローバル IP 宛のアクセスも内部 DNAT 先に届くよう追加ルール (rule 110)。pppoe0 アドレスは動的のため、必要に応じて DNS split-horizon で代替も可。

## Conntrack イベントログ (NAPT 変換記録)

法執行対応として、masquerade の NAPT 変換マッピングを記録する。`conntrack -E` で NEW/DESTROY を syslog (facility local2, tag `conntrack-nat`) に出力。対象は会場サブネットのみ、家族 LAN は除外。

ログ設計の全体像は [`logging-compliance.md`](logging-compliance.md) §4 を参照。

## ファイアウォール

### WAN → LOCAL (pppoe0 inbound)

default-action drop。許可項目:
- established/related
- ICMP
- SSH (22) — ed25519 鍵認証のみ
- WireGuard (UDP 51820) — venue 向け

### WAN → LAN (forward)

default-action drop。established/related + メインPC (.4) の TCP 80/443/5201、UDP 5201 のみ許可。

### IPv6 WAN → LOCAL

established/related、ICMPv6、DHCPv6 replies (UDP 546 from 547)。

## IPv6 設計

自宅 LAN (br0) では IPv6 を使用しない。

**理由**: OPTAGE DHCPv6-PD は /64 のみ。/64 は SLAAC の最小単位で分割不可のため、自宅と会場で共有できない。イベント参加者への IPv6 提供を優先し、/64 は全量会場に割り当てる。家族用デバイスは IPv4 のみで運用 (現状問題なし)。

## WireGuard

### wg0 (会場 r3 向け, プライマリ)

10.255.0.1/30、listen 51820、MTU 1400。`allowed-ips` は venue (10.255.0.2/32 + 会場サブネット 192.168.11/30/40)。MSS clamp 有効。

### wg1 (GCP r2-gcp 向け)

10.255.1.1/30、listen 51821、MTU 1400。`allowed-ips` には r2-gcp P2P (10.255.1.2/32) + r3 P2P (10.255.2.0/30) + 会場サブネット + **goog.json v4 全 94 本**。goog.json 更新時に allowed-ips も連動更新が必要 ([`../operations/goog-prefix-update.md`](../operations/goog-prefix-update.md) 参照)。

r2-gcp peer に会場プレフィックスを許可するのは、r1↔r3 直結断時に r2-gcp 経由で会場トラフィックを迂回受信するため。

## BGP (AS65002)

### ピアリング

| ピア | AS | IF | 用途 |
|------|-----|-----|------|
| r3-venue (10.255.0.2) | 65001 | wg0 | 会場 |
| r2-gcp (10.255.1.2) | 64512 | wg1 | GCP トランジット |

### default-originate

r1-home は venue-r3 / r2-gcp 両方に `0.0.0.0/0` / `::/0` を BGP で広告する。r3 側はこれを AD=20 で受信し、DHCP 由来の default (AD=210) より優先される。これにより venue のユーザートラフィックが wg0 経由で r1 に到達し、pppoe0 から Internet へ抜ける。

### 経路優先度

WireGuard 直接リンク (r3) を優先し、r2-gcp 経由をフォールバック。
- r3 経由 (WG-IN): LP=250
- r2-gcp 経由 default: LP=50
- r2-gcp 経由 Google プレフィックス (goog.json): LP=250 (r2-gcp 直接優先)

### r2-gcp endpoint の escape route

goog.json BGP 広告により `34.64.0.0/10` 等が wg1 経由になるが、WG 外側パケット (`dst=34.97.197.104`) は pppoe0 から出す必要がある。`34.97.197.104/32 interface pppoe0` を静的経路として設定 ([`../operations/goog-prefix-update.md`](../operations/goog-prefix-update.md) 参照)。

### 静的経路のクリーンアップ

default-originate 投入と同時に、旧設計の残骸 (`route 192.168.11.0/24` 等の next-hop 10.255.1.2) は削除済み。残っていると BGP (AD=20) より static (AD=1) が優先され venue 戻りが wg1 に誤配送される。

## IPv6 プレフィックス委任 (会場向け)

OPTAGE から DHCPv6-PD /64 を取得し、**丸ごと会場 (r3) に転送**する。自宅 LAN には割り当てない。

### 方式: ダミー IF + 自動追従スクリプト

```
set interfaces dummy dum0
set interfaces pppoe pppoe0 dhcpv6-options pd 0 interface dum0 sla-id 0
```

### プレフィックス変更自動追従 (`pd-update-venue.sh`)

DHCPv6-PD のプレフィックスは PPPoE 再接続や ISP メンテナンスで変わる可能性がある。VyOS DHCPv6 クライアントはスクリプトにプレフィックス情報を渡さないため、dhclient hook 方式は使えない。**task-scheduler (cron) で 1 分間隔監視**する。

- スクリプト: [`../../scripts/pd-update-venue.sh`](../../scripts/pd-update-venue.sh)
- 配置: `/config/scripts/pd-update-venue.sh` (r1)

動作:
1. dum0 の IPv6 グローバルアドレスから現在の /64 を取得
2. 前回値と比較 (`/tmp/pd_current_prefix`)
3. 変更あり → r1 の IPv6 ルートを wg0 経由に更新、r3 VyOS API で v6 設定を全更新
4. 変更なし → wg0 ルートの存在を確認 (自己修復)

制約: プレフィックス変更から r3 反映まで最大 1 分のラグ。`/tmp/pd_current_prefix` は再起動で消えるため、起動後の初回はフル更新が走る。

会場側 r3 は受け取った /64 を VLAN 30/40 で RA 広告する。r1 側では RA を配信しない。

## HTTPS API

r1 の設定 API。管理 PC から `scripts/r1-config.py` (curl ベース) で設定投入する。

**`listen-address 192.168.10.1` の明示は必須**: デフォルトでは全 IF (pppoe0 WAN 含む) で 443 listen する。pppoe0:443 は DNAT ルール 30 でメインPC に転送されるため実害は薄いが、(1) LAN 内から自宅グローバル IP でアクセスした際に r1 nginx が応答してしまう、(2) API の WAN 露出でブルートフォース可能、の 2 点のリスクがあるため LAN 側 IP に限定する。

## SSH

WAN にも公開するため ed25519 鍵認証のみ (`disable-password-authentication`)。listen-address を指定せず全 IF で受け付ける (WAN-LOCAL ファイアウォールで WAN 側も許可済み)。

登録済み公開鍵の管理は [`../configs/r1-home.conf`](../configs/r1-home.conf) 参照 (authorized_keys 一覧あり)。

## wg-r1-tracker と r2-gcp endpoint 管理

r1 の動的 WAN IP 追従および r2-gcp endpoint の wg0 経由 double encapsulation 管理の責務は r3 側のスクリプトが持つ。r1 自身は安定したエンドポイントとして動作する。詳細は [`venue-vyos.md`](venue-vyos.md) §6 を参照。

## 関連ドキュメント

- [`../configs/r1-home.conf`](../configs/r1-home.conf) — 投入用 VyOS CLI コマンド集 (authorized_keys 含む)
- [`../operations/goog-prefix-update.md`](../operations/goog-prefix-update.md) — goog.json + allowed-ips 連動更新
- [`../operations/nic2-wan-switchover.md`](../operations/nic2-wan-switchover.md) — wstunnel server 運用
- [`../investigation/ix3315-migration.md`](../investigation/ix3315-migration.md) — 旧ルーターからの移行記録

## 注意事項

- PPPoE 認証情報は本番では secret 管理を検討
- WireGuard 鍵は生成後に差し替え
- OPTAGE DHCPv6-PD は /64 のみ → 自宅 LAN は IPv4 only、/64 は会場に全量転送
- VyOS は 2026.03 (Circinus, rolling release)
