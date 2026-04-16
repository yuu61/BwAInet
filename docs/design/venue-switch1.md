# 会場スイッチ sw01 (FS) 実装例

> **前提**: 本ドキュメントは [`venue-switch.md`](./venue-switch.md) で定義したマルチベンダー共通設計 (VLAN モデル、ポート種別 T1〜T5、管理 IP ルール) の **FS 製スイッチ (Cisco-like CLI) による実装例** である。共通設計を先に読むこと。

## 概要

| 項目 | 値 |
|------|-----|
| ホスト名 | sw01 |
| 機種 | FS (Cisco ライク CLI) |
| 役割 | 会場の主系 L2 集約スイッチ |
| 管理 VLAN | 11 |
| 管理 IP | 192.168.11.4/24 |
| デフォルト GW | 192.168.11.1 (r3-vyos) |

## ポート一覧

| ポート | 速度 | タイプ |
|--------|------|--------|
| XSGigabitEthernet 0/1 | 10G | fiber (SFP+) |
| XSGigabitEthernet 0/2 | 10G | fiber (SFP+) |
| FiveGigabitEthernet 0/1 | 5G | copper |
| FiveGigabitEthernet 0/2 | 5G | copper |
| GigabitEthernet 0/3–10 | 1G | copper (×8) |

## ポートアサイン (共通設計のポート種別にマッピング)

| ポート | 接続先 | Type | モード | VLAN | 備考 |
|--------|--------|------|--------|------|------|
| XSGe 0/1 | 他スイッチ (sw02 等) | T1 | trunk | 11,30,40 | 10G fiber スイッチ間接続 |
| XSGe 0/2 | 他スイッチ (sw02 等) | T1 | trunk | 11,30,40 | 10G fiber スイッチ間接続 |
| 5Ge 0/1 | AP (Aironet 3800) | T2 | trunk | 11,30,40 (native 11) | mGig 対応 AP、PoE+ 給電 |
| 5Ge 0/2 | Proxmox (r1-home / r3-vyos) | T1 | trunk | 11,30,40 (native なし) | VM 基盤トランク (1GbE ネゴ)。Proxmox PVID=1 のため VLAN 11 は tagged で通す |
| Ge 0/3–7 | AP (Aironet 3800) | T2 | trunk | 11,30,40 (native 11) | SSID ローカルスイッチング、PoE+ 給電 |
| Ge 0/8 | WLC (Cisco 3504) | T1 | trunk | 11,30,40 | FlexConnect 制御プレーンのみ、PoE 不要 |
| Ge 0/9 | 配信 PC、スピーカー | T3 | access | 30 | 運営有線 |
| Ge 0/10 | 来場者有線 | T3 | access | 40 | ユーザー有線 |

**AP 収容数**: sw01 では 5Ge 0/1 + Ge 0/3–7 の計 6 台。5Ge 接続の AP は mGig (2.5G/5G) でリンクアップ可能。残り 14 台は sw02 および追加 PoE スイッチ経由で収容。

## コンフィグ

投入用フルコンフィグは [`../configs/sw01.conf`](../configs/sw01.conf) を参照。

## AP を trunk native VLAN 11 にする意図

共通設計 (Type T2) に従い、AP ポートを access VLAN 11 から **trunk (allowed 11,30,40, native 11)** に変更した。これに伴う運用モデルの違い:

| 項目 | 従前 (access VLAN 11 + CAPWAP 中央スイッチング) | 現行 (trunk + FlexConnect ローカルスイッチング) |
|------|-----------------------------------------------|-----------------------------------------------|
| AP 物理ポート | access VLAN 11 | trunk allowed 11,30,40 / native 11 |
| AP 管理 IP | VLAN 11 untagged で DHCP 取得 | VLAN 11 untagged (native) で DHCP 取得 |
| クライアントトラフィック | CAPWAP トンネルで WLC に集約 → WLC で VLAN 30/40 タグ付け | AP が直接 VLAN 30/40 タグ付けしてスイッチへ送出 |
| WLC 3504 の役割 | 全トラフィック経路・設定管理 | 設定管理のみ (トラフィックは AP ローカルで処理) |
| 利点 | WLC で集中 ACL・QoS 適用可 | WLC 経由の帯域消費を回避、WLC 故障時もクライアント疎通維持 |
| 必要な AP 設定 | CAPWAP discover のみ | FlexConnect モード有効化 + Native VLAN 設定 |

**重要**: AP 側 (Aironet 3800 + WLC 3504) で FlexConnect モードを有効化し、各 SSID に対し "FlexConnect local switching" を設定する必要がある。この設定は WLC 3504 の WebUI から行う。

## 構築時の変更点

r1-home / r3-vyos はいずれも Proxmox 内 VM のため、デフォルト GW は構築時・会場とも **192.168.11.1 (r3-vyos)** で統一。変更不要。

## 設計メモ

- **XSGe 0/1–0/2 をスイッチ間接続に使用**: 10G fiber (SFP+) で sw02 等の他スイッチとの ISL (Inter-Switch Link) に使用
- **5Ge 0/1 に mGig 対応 AP を収容**: Aironet 3800 は mGig 対応のため 5Ge で 2.5G/5G リンクが可能。帯域が集中する AP を 5Ge に接続し、制御プレーンのみの WLC は Ge 0/8 に配置
- **5Ge 0/2 に Proxmox を収容**: r1-home / r3-vyos は Proxmox 内の VM。1GbE ネゴで接続

## IPv6 マルチキャスト対策の実機確認事項

- [ ] `show ipv6 mld-snooping` で MLD Snooping が有効であることを確認
- [ ] `show ipv6 mld-snooping groups` で VLAN 30/40 のグループ数を確認 (L2MC テーブル容量との比較)
- [ ] 端末で `ipconfig /all` (Windows) または `ip -6 addr` (Linux) で SLAAC アドレスが正常に取得できることを確認

## 関連ドキュメント

- [`venue-switch.md`](./venue-switch.md) — 会場スイッチ共通設計 (マルチベンダー) — §6 に IPv6 マルチキャスト対策の共通ルール
- [`venue-switch2.md`](./venue-switch2.md) — sw02 (Cisco ISR 1100) 実装例
- [`mgmt-vlan-address.md`](./mgmt-vlan-address.md) — 管理 VLAN アドレス割当表
- [`venue-proxmox.md`](./venue-proxmox.md) — Proxmox 側の VLAN-aware ブリッジ設計
