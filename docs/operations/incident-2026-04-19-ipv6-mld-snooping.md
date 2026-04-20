# インシデント記録: IPv6 通信不全 (MLD snooping / RA lifetime 起因) (2026-04-19)

## 概要

会場ネットワーク (VLAN 30/40) の IPv6 通信比率が想定 (Cloudflare Radar 比 30〜40%) に対して異常に低く、調査の結果、特定スイッチ配下のクライアントで GUA 取得不能、または GUA 取得後も実通信できない問題が判明した。

| 項目 | 内容 |
|---|---|
| 検知日時 | 2026-04-19 (NetFlow 集計時の比率乖離から発覚) |
| 影響範囲 | VLAN 30 / 40 のうち IOS 15 系および Allied Telesis スイッチ配下の有線クライアント、およびその下に接続された AP 配下の無線クライアント |
| 影響内容 | IPv6 GUA が付与されない / 付与されても外部と通信できない |
| 暫定対応 | r3 RA で全プレフィックスを `valid-lifetime 0 / preferred-lifetime 0` で広告し、クライアントの GUA を即時失効 |
| 状態 | 暫定対応中（恒久対応はスイッチ側 MLD snooping 無効化が必要） |

## 検知の流れ

1. r3 のインターフェースカウンタから「現在の総通信量」を集計 (eth1 で約 352 GB)。
2. v4/v6 比率を NetFlow (CT 200 nfcapd, 本日分) で集計したところ:
   - IPv4: 367.5 GB (92%)
   - IPv6: 32.0 GB (8%)
3. Cloudflare Radar 等の一般的な v6 比率 (30〜40%) と大きく乖離しているため異常を疑う。
4. NDP テーブル分析でクライアントの GUA 取得状況に偏り発見:
   - OPTAGE プレフィックス (2600:1900:41d1:92::/64) 保持: 24
   - GCP プレフィックス (2001:ce8:180:5a79::/64) 保持: 113
5. 有線 access VLAN30 ポートで GUA が付かないとの報告を踏まえ追加検証:
   - コアスイッチおよび IOS-XE 17.25 配下: GUA 付与 OK
   - IOS 15 / Allied Telesis 配下: GUA 付与 NG
   - NG スイッチを 3 段経由した AP 配下の Wi-Fi: GUA は付くが IPv6 通信できない

## 原因

### 一次原因: 古いスイッチの MLD snooping 実装

RFC 4541 §3 では link-local scope (`ff02::/16`) を MLD snooping の対象から除外することが推奨されているが、IOS 15 系や古い Allied Telesis スイッチではこれが守られていない。

| パケット | 宛先 multicast | 古いスイッチでの挙動 |
|---|---|---|
| RA (Router Advertisement) | `ff02::1` (all-nodes) | 実装により通る場合と drop する場合あり |
| NS (Neighbor Solicitation) | `ff02::1:ffXX:XXXX` (solicited-node) | snooping 学習対象外で drop されやすい |

これにより:
- access port で RA が drop されるパターン → クライアントが GUA を取得できない
- RA は通るが NS が drop されるパターン → GUA は付くが GW MAC を解決できず通信不能

### 二次原因 (副次的): r3 RA の preferred-lifetime 設定逆転

r3 の RA 設定では本来 OPTAGE 側を優先 (preferred=14400) にする方針だが、実機では逆転していた。

| Prefix | 期待値 (memory) | 実機初期値 |
|---|---|---|
| OPTAGE (2600:1900:41d1:92::/64) | preferred 14400s | preferred **1800s** |
| GCP (2001:ce8:180:5a79::/64) | preferred 1800s | デフォルト (14400s) |

OPTAGE GUA が早期に deprecated になり、クライアントは GCP 経由 (大阪迂回 → 高 RTT) を選択 → Happy Eyeballs で v4 にフォールバックされやすい状態だった。

## 対応経緯 (UTC)

| 時刻 | 出来事 |
|---|---|
| 08:25 | NetFlow 集計で v6 比率 8% を確認 |
| 08:35 | NDP 偏り (OPTAGE 24 / GCP 113) 確認 |
| 08:40 | r3 RA 設定で lifetime 逆転を発見 |
| 08:50 | OPTAGE 側 lifetime を delete してデフォルト化 |
| 09:10 | 有線 access ポートで GUA 付かない件を切り分け、MLD snooping 起因と推定 |
| 09:30 | 全プレフィックスに `preferred-lifetime 0 / valid-lifetime 0` を設定して RA 送出。tcpdump で `valid time 0s, pref. time 0s` を確認 |
| 09:33 | r3 設定をディスクに保存 (save) |

## 残課題

- **(必須・恒久対応)** IOS 15 系および Allied Telesis スイッチで `no ipv6 mld snooping` を投入し、不完全な snooping 実装による drop を解消する。対象スイッチの機種・管理 IP を確定し、コマンドを準備する。
- **(必須)** 暫定対応 (lifetime 0) を解除するタイミングと手順を決定。スイッチ側修正完了後に `delete service router-advert interface eth2.{30,40} prefix ... preferred-lifetime / valid-lifetime` で戻す。
- **(要確認)** `pd-update-venue.sh` (r1 task-scheduler 1分間隔) が r3 の RA 設定を再度書き換え、preferred-lifetime を 1800s に戻していないか。スクリプトの該当箇所を確認・修正する。
- **(再発防止)** v4/v6 比率を Grafana で常時可視化し、異常を NetFlow 解析を待たずに検知できるようにする。
- **(調査)** NetFlow が r3 上の eth2.30/40/wg0/wg1 4 IF からエクスポートされており同一パケットが複数回カウントされる問題。本件の比率分析には影響しないが、今後の流量集計のため exporter 設計を見直すべき。

## 学び

- 古いスイッチの IPv6 MLD snooping は RFC 4541 §3 を満たさない実装が多く、信用しない方が良い。会場で利用するスイッチは事前に IPv6 multicast 通過試験 (RA / NS) を行うべき。
- **事前構築検証は AP 経由だけで済ませず、各スイッチの access port にクライアントを直接接続して GUA が付与され外部 v6 通信が成立することを 1 ポートずつ確認するべきだった。** AP 経由は trunk + 無線ブリッジで multicast 挙動が変わるため、access port 固有の問題 (今回の MLD snooping 起因の RA/NS drop) を覆い隠してしまう。今回も AP 経由検証だけでは異常を発見できなかった。
- IPv6 比率を Cloudflare Radar 等の外部統計と比較するのは、ネットワーク健全性の良い指標になる。
- RA の preferred-lifetime / valid-lifetime はクライアント挙動に直接影響する。GUA を意図的に剥がしたい場合は両方 0 を送出すれば即時失効する。
