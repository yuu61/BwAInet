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
   - コアスイッチおよび IOS-XE 17.15 配下: GUA 付与 OK
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

## 申し送り (記録)

> 恒久対応の方針と残対応の状態の記録。完了・方針確定済みの項目を含む。

- **恒久対応 (方針確定済み)**: IOS 15 系・古い Allied Telesis スイッチは `no ipv6 mld snooping` で不完全な snooping 実装による drop を解消する。コマンド構文・既定値・判断指針は [`mld-snooping-rfc4541-compliance.md`](./mld-snooping-rfc4541-compliance.md) に確定済み (IOS 15.2 / IOS XE 16.12 / 17.x で同一構文を裏取り)。方針は「全機停止」ではなく **準拠機は ON のまま・非準拠機だけ OFF**。未確定なのは対象スイッチの機種・管理 IP のみ。IOS XE 16.12 は盲目投入せず `show ipv6 mld snooping` + access port v6 テストで要否を判定する想定 (Cisco ドキュメント上 16.12 は 17.x と同一記述で、17.15 の疎通は実測値であり準拠保証ではないため)。
- **暫定対応 (lifetime 0) は未解除**: 現在も全プレフィックスを valid/preferred-lifetime 0 で広告中 = 会場の IPv6 GUA は実質停止状態。解除はスイッチ側修正完了後に `delete service router-advert interface eth2.{30,40} prefix ... preferred-lifetime / valid-lifetime` で戻す想定。
- **既知の懸念**: `pd-update-venue.sh` (r1 task-scheduler 1分間隔) が r3 の RA 設定を上書きし preferred-lifetime を 1800s に戻し得る (未確認)。該当箇所は要精査。
- **(再発防止)** v4/v6 比率を Grafana で常時可視化し、NetFlow 解析を待たず異常検知できる状態が望ましい。
- **(調査)** NetFlow が r3 上の eth2.30/40/wg0/wg1 4 IF からエクスポートされ同一パケットが複数回カウントされる。本件の比率分析には影響しないが、流量集計の正確性のため exporter 設計の見直し余地がある。

## 学び

- 古いスイッチの IPv6 MLD snooping は RFC 4541 §3 を満たさない実装が多く、信用しない方が良い。会場で利用するスイッチは事前に IPv6 multicast 通過試験 (RA / NS) を行うべき。
- **事前構築検証は AP 経由だけで済ませず、各スイッチの access port にクライアントを直接接続して GUA が付与され外部 v6 通信が成立することを 1 ポートずつ確認するべきだった。** AP 経由は trunk + 無線ブリッジで multicast 挙動が変わるため、access port 固有の問題 (今回の MLD snooping 起因の RA/NS drop) を覆い隠してしまう。今回も AP 経由検証だけでは異常を発見できなかった。
- IPv6 比率を Cloudflare Radar 等の外部統計と比較するのは、ネットワーク健全性の良い指標になる。
- RA の preferred-lifetime / valid-lifetime はクライアント挙動に直接影響する。GUA を意図的に剥がしたい場合は両方 0 を送出すれば即時失効する。

## 後日検証 (2026-06-21 追記)

Cisco config guide と RFC 4541 原文を精査した結果。詳細・コマンド・判断指針は [`mld-snooping-rfc4541-compliance.md`](./mld-snooping-rfc4541-compliance.md) に集約。要点のみ:

- **一次原因の記述精緻化**: 本文 (一次原因) は「RFC 4541 §3 が link-local scope (`ff02::/16`) の除外を推奨」と書いたが、**§3 が常時 flood を名指しで義務づけるのは `ff02::1` (all-nodes) のみ**。solicited-node (`ff02::1:ffXX:XXXX`) や `ff02::/16` 全体は RFC 上の明示例外ではない。これは本インシデントの 2 故障モード (RA drop = `ff02::1` の §3 違反 / NS drop = RFC が守らない solicited-node 領域) に対応する。
- **メカニズム**: 古い Catalyst は mrouter ポート発見後に「unknown マルチキャスト」を mrouter 方向のみへ絞る。ホストは `ff02::1` の MLD report を出さないため `ff02::1` は常に unknown 扱いになり、準拠機の `ff02::1` 特例化が無い古い機ではホストポートに RA が届かない。**⚠️ 非準拠機で MLD querier を有効化すると constraining を点火し悪化する** (`venue-switch.md` §6.1 の「スイッチ側で querier 有効化」方針は非準拠機には適用しない)。
- **`no ipv6 mld snooping` は唯一解ではない**: 正しく実装されたスイッチは snooping ON のまま `ff02::1` を素通しする (17.15 が素で通ったのがその証拠)。無効化は **非準拠機に限った敗北処理**で、本筋はファーム更新 / 準拠機への統一。
- **「IOS-XE 17.25」表記を 17.15 に修正** (17.25 は実在しない train)。
