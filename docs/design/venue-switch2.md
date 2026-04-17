# 会場スイッチ sw02 (Cisco ISR 1100) 実装例

> **前提**: 本ドキュメントは [`venue-switch.md`](./venue-switch.md) で定義したマルチベンダー共通設計の **Cisco ISR 1100 (C1111-8PLTELAWQ) による実装例**である。共通設計を先に読むこと。

## 概要

構築に使えるスイッチが不足しているため、手元の **Cisco ISR 1100 (C1111-8PLTELAWQ)** を L2 スイッチとして流用する。LAN 側ポート (`GigabitEthernet0/1/0`〜`0/1/7`, `Wlan-GigabitEthernet0/1/8`) は Embedded Switch Module (ESM) のため標準の `switchport` 構文で動作する。WAN 側ポート (`GigabitEthernet0/0/0`, `0/0/1`) は `switchport` 非対応のため**使用しない (shutdown)**。

| 項目 | 値 |
|------|-----|
| ホスト名 | sw02 |
| 機種 | Cisco ISR 1100 (C1111-8PLTELAWQ) |
| OS | IOS XE 17.15 |
| 管理 VLAN | 11 |
| 管理 IP | 192.168.11.6/24 (Vlan11 SVI) |
| デフォルト GW | 192.168.11.1 (r3-vyos) |
| 位置付け | 現場判断で sw01 下位 / 並列どちらでも投入可能 |

### 設計方針: ESM ポートのみ使用

WAN ポート (Gi 0/0/0-1) を L2 化するには EVC (service instance) + bridge-domain 構文が必要だが、以下の理由から **ESM ポートのみで L2 構成** とする:

- sw01 と sw02 の接続順序・接続有無が現場まで確定しない
- EVC + bridge-domain の Vlan SVI 上 service instance は L3 (IP アドレス) と共存できず、管理 IP に BDI が必要になり複雑化
- bridge-domain 経由では MLD Snooping / IGMP Snooping が正常動作しない可能性

ESM ポート (Gi 0/1/0-7, Wlan-Gi 0/1/8) の 9 ポートで AP 収容・アップリンク・端末接続をすべてカバーする。

## 物理ポート構成 (C1111-8PLTELAWQ)

| ポート | 種別 | PoE | 速度 | 状態 | 備考 |
|--------|------|-----|------|------|------|
| Gi 0/0/0 | WAN (routed) | -- | 1G (SFP combo) | **shutdown** | switchport 非対応、未使用 |
| Gi 0/0/1 | WAN (routed) | -- | 1G | **shutdown** | switchport 非対応、未使用 |
| Gi 0/1/0 | LAN (ESM) | PoE+ | 1G | active | AP 直給電 |
| Gi 0/1/1 | LAN (ESM) | PoE+ | 1G | active | AP 直給電 |
| Gi 0/1/2 | LAN (ESM) | -- | 1G | active | PoE+ インジェクター経由 |
| Gi 0/1/3 | LAN (ESM) | -- | 1G | active | PoE+ インジェクター経由 |
| Gi 0/1/4 | LAN (ESM) | -- | 1G | active | PoE+ インジェクター経由 |
| Gi 0/1/5 | LAN (ESM) | -- | 1G | active | PoE+ インジェクター経由 |
| Gi 0/1/6 | LAN (ESM) | -- | 1G | **shutdown** | flex port (現場で有効化) |
| Gi 0/1/7 | LAN (ESM) | -- | 1G | **shutdown** | flex port (現場で有効化) |
| Wlan-Gi 0/1/8 | WLAN module | -- | 1G | active | 内蔵 WLAN モジュール |
| Cellular 0/2/0 | LTE | -- | -- | **shutdown** | ルーティング競合防止 |
| Cellular 0/2/1 | LTE | -- | -- | **shutdown** | 未使用 |

> **PoE 電源設計**: C1111-8PLTELAWQ の PoE 総バジェットは約 50W。Aironet 3800 は PoE+ (25.5W) のため、本体から直接給電できるのは `Gi 0/1/0-1` の 2 ポートのみ。それ以上の AP/PoE 機器は外部 PoE+ インジェクターを `Gi 0/1/2-5` に挿入。

## ポートアサイン (共通設計のポート種別にマッピング)

| ポート | 接続先 | Type | モード | VLAN | 備考 |
|--------|--------|------|--------|------|------|
| Gi 0/0/0 | -- | T5 | -- | -- | shutdown (未使用) |
| Gi 0/0/1 | -- | T5 | -- | -- | shutdown (未使用) |
| Gi 0/1/0–5 | AP (Aironet 3800) | T2 | trunk | 11,30,40 (native 11) | FlexConnect |
| Gi 0/1/6 | 現場決定 | T1/T3 | trunk | 11,30,40 | flex、デフォルト shutdown |
| Gi 0/1/7 | 現場決定 | T1/T3 | trunk | 11,30,40 | flex、デフォルト shutdown |
| Wlan-Gi 0/1/8 | 内蔵 WLAN モジュール | T2 | trunk | 11,30,40 (native 11) | AP 同等 |

## コンフィグ

投入用フルコンフィグは [`../configs/sw02.conf`](../configs/sw02.conf) を参照。flex ポート (Gi 0/1/6-7) の現場切替パターンも同ファイルに記載。

## IPv6 マルチキャスト対策

### RA Guard

**スイッチ側では RA Guard を設定しない**。不正 RA 対策は WLC および AP 側で実施する (SSID ごとの設定)。有線端末からの不正 RA は r3-vyos の IPv6 ファイアウォールで drop する。

### MLD Snooping

ISR 1100 ESM での MLD Snooping 対応は文書上不明確。実機で `ipv6 mld snooping ?` を投入して確認する。対応している場合は VLAN 30/40 で有効化を推奨。

## 設計メモ

### ESM ポートのみ使用する理由

WAN ポート (Gi 0/0/0-1) の L2 化には EVC + bridge-domain が必要だが、実機検証で以下の問題が判明:

1. Vlan SVI に service instance を設定すると L3 (IP) と共存不可 — 管理 IP に BDI 必要
2. EVC は `encapsulation dot1q <vlan-id>` で tagged のみマッチ。対向が native VLAN untagged 送出の場合、`vlan dot1q tag native` が対向側に必要
3. sw01 との接続が現場配置次第で確定しない

ESM 9 ポート (Gi 0/1/0-7 + Wlan-Gi 0/1/8) で AP 6 台 + flex 2 + WLAN モジュール 1 を収容でき実用十分。

### C1111-8PLTELAWQ 固有モジュール

| モジュール | インタフェース | 本設計での扱い |
|-----------|---------------|---------------|
| LTE | Cellular 0/2/0, 0/2/1 | **shutdown** (全トラフィックは WireGuard 経由) |
| WLAN | Wlan-GigabitEthernet 0/1/8 | AP 同等の trunk として使用 |

LTE をバックアップ回線に使う場合は別途設計を追加する。

### AP ポートを trunk (T2) にする意図

共通設計 ([`venue-switch.md`](./venue-switch.md) §2 Type T2) に従い、AP ポートを access VLAN 11 から **trunk (allowed 11,30,40, native 11)** に変更。AP 動作:

- 管理 IP は native VLAN 11 (untagged) で r3-vyos の DHCP プール (.100-.199) から取得
- クライアントトラフィックは AP 側 (FlexConnect / スタンドアロン) で SSID ごとに VLAN 30/40 タグ付け
- WLC 3504 は設定管理と認証のみ (トラフィックパスから外れる)

### 論理的な位置付け (現場柔軟)

sw02 は ESM flex ポート (Gi 0/1/6-7) 経由で sw01 下位、または r3-vyos 直結の並列スイッチとして投入できる。どちらでも設定は変わらない。

## 実機検証チェックリスト

- [ ] sw02 `Vlan11` (192.168.11.6) から `192.168.11.1` (r3-vyos) に ping が通る
- [ ] 自宅環境から sw02 へ SSH ログインできる
- [ ] AP (Aironet 3800) が native VLAN 11 経由で管理 IP を DHCP 取得できる
- [ ] AP の SSID ごとに VLAN 30/40 タグ付きトラフィックが送出され、上位経由で r3-vyos に到達する
- [ ] VLAN 30/40 の DHCP リースが端末で取得できる
- [ ] `ipv6 mld snooping ?` で ESM の MLD Snooping 対応可否を確認
- [ ] `show mac address-table` で AP / 上位スイッチの MAC が学習されている

## 関連ドキュメント

- [`venue-switch.md`](./venue-switch.md) — 会場スイッチ共通設計
- [`venue-switch1.md`](./venue-switch1.md) — sw01 (FS) 実装例
- [`mgmt-vlan-address.md`](./mgmt-vlan-address.md) — 管理 VLAN アドレス割当表
- [`../configs/sw02.conf`](../configs/sw02.conf) — 投入コンフィグ (flex ポート切替パターン含む)
- [`../operations/switch-cli-reference.md`](../operations/switch-cli-reference.md) — ベンダー別 CLI 対比

## 参考文献

- [Cisco 1000 Series SW Config Guide — Configuring Ethernet Switch Ports (XE 17)](https://www.cisco.com/c/en/us/td/docs/routers/access/isr1100/software/configuration/xe-17/isr1100-sw-config-xe-17/configuring_ethernet_switchports.html)
- [Cisco 1000 Series SW Config Guide — Configuring Bridge Domain Interfaces (XE 17)](https://www.cisco.com/c/en/us/td/docs/routers/access/isr1100/software/configuration/xe-17/isr1100-sw-config-xe-17/bdi_isr1k.html)
