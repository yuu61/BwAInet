# 会場スイッチ共通設計 (マルチベンダー対応)

## 目的

会場に投入するスイッチは **sw01 (FS)**, **sw02 (Cisco ISR 1100)** に加え、現場調達や持ち込み機材としてマルチベンダー (Cisco / HPE Aruba / Juniper / MikroTik / 各社中古品) が参加する可能性がある。本ドキュメントはベンダー・機種に依存しない **共通 L2 設計ルール** を定義し、各機種の具体コンフィグは実装例ドキュメントに委譲する。

| 項目 | 参照先 |
|------|--------|
| 抽象的な共通設計 (本ドキュメント) | `venue-switch.md` |
| sw01 実装例 (FS, Cisco-like CLI) | [`venue-switch1.md`](./venue-switch1.md) |
| sw02 実装例 (Cisco ISR 1100 / C1111-8P) | [`venue-switch2.md`](./venue-switch2.md) |
| 管理 VLAN のアドレス一覧 | [`mgmt-vlan-address.md`](./mgmt-vlan-address.md) |
| ベンダー別 CLI 実装対比 | [`../operations/switch-cli-reference.md`](../operations/switch-cli-reference.md) |

---

## 1. VLAN 定義 (全スイッチ共通)

| VLAN ID | 名称 | 用途 | IPv4 | IPv6 |
|---------|------|------|------|------|
| 11 | mgmt | NW 機器管理、AP 管理 IP | 192.168.11.0/24 | なし (v4 only) |
| 30 | staff | 運営スタッフ、配信 PC、スピーカー | 192.168.30.0/24 | DHCPv6-PD /64 |
| 40 | user | 来場者 | 192.168.40.0/22 | DHCPv6-PD /64 |

全スイッチで上記 3 VLAN を一貫して定義する。VLAN ID・名称・用途の揃えはベンダー横断でのトランク接続成立に必須。

---

## 2. ポート種別の抽象モデル

会場スイッチに接続されるすべてのポートは、以下 5 種類のいずれかに分類する。ベンダーが変わってもこの分類と設定意図は変わらず、各ベンダーの構文にマッピングするだけで設定できる。

### Type T1: Uplink/Downlink Trunk

**用途**: r3-vyos、Proxmox ミニ PC、WLC (Cisco 3504)、他スイッチ相互接続

**WLC を T1 に含める理由**: Cisco 3504 は管理 I/F + AP Manager I/F + Dynamic Interface (VLAN 30/40) を dot1q で 1 本に収容する前提。FlexConnect でも Central DHCP / ウェブ認証 / ゲストアンカー等で Dynamic Interface を使う可能性があり、access に絞ると拡張性を失う。WLC 側は管理 I/F の VLAN Identifier を 11 に設定し tagged VLAN 11 で自力参加させる (§6)。

| 項目 | 値 |
|------|-----|
| モード | trunk (802.1Q dot1q) |
| Allowed VLAN | 11, 30, 40 |
| Native VLAN | なし (全 VLAN tagged) |
| STP | BPDU 疎通、portfast trunk は使わない (または portfast trunk + BPDU guard) |
| LLDP | 有効 |

**T1 では native VLAN を設定しない**。対向機器 (r3-vyos `eth2.11`、Proxmox VLAN-aware ブリッジ、WLC tagged VLAN 11、他スイッチ SVI) が全て tagged VLAN 11 で参加しているため、native を設定すると VLAN 11 が untagged で送出され対向の tagged サブインタフェースに届かない。Native VLAN が必要なのは T2 (AP) のみ。

### Type T2: AP Trunk (SSID ローカルスイッチング)

**用途**: Aironet 3800 等の AP。AP 自身が管理 IP を VLAN 11 から DHCP 取得し、SSID ごとに VLAN 30/40 を付与してエッジに送出する (FlexConnect またはスタンドアロン運用)。

| 項目 | 値 |
|------|-----|
| モード | trunk (802.1Q dot1q) |
| Allowed VLAN | 11, 30, 40 |
| Native VLAN | 11 |
| PoE | PoE+ (IEEE 802.3at, 25.5W) 給電。本体給電能力を超える場合は外部インジェクター |
| STP | portfast trunk + BPDU guard |

### Type T3: Endpoint Access

**用途**: 配信 PC、スピーカー、運営有線席、来場者向け有線 (稀)

| 項目 | 値 |
|------|-----|
| モード | access |
| VLAN | 30 または 40 |
| STP | portfast 有効 + BPDU guard |
| Storm control | 推奨 (ブロードキャスト/マルチキャストを上限 1〜5%) |

### Type T4: Management Access (稀)

**用途**: NMS 機材、ベンダー持込の管理ワークステーション等

| 項目 | 値 |
|------|-----|
| モード | access |
| VLAN | 11 |
| STP | portfast 有効 + BPDU guard |

VLAN 40 からは VLAN 11 へのアクセスは拒否 (ACL は r3-vyos 側)。本タイプは運営スタッフのみ使用。

### Type T5: Unused (shutdown)

**用途**: 未使用ポート。誤接続による L2 ループ、VLAN 侵害を防ぐため **必ず shutdown**。

---

## 3. 管理 IP ルール

**すべての会場スイッチは例外なく、以下を設定する。**

1. VLAN 11 の SVI を作成
2. 192.168.11.0/24 から静的 IP を 1 つ割り当てる ([`mgmt-vlan-address.md`](./mgmt-vlan-address.md))
3. デフォルトゲートウェイを 192.168.11.1 (r3-vyos) に設定
4. SSH 経由で疎通できることを確認

| 機器 | 管理 IP | 備考 |
|------|---------|------|
| sw01 (FS) | 192.168.11.4 | 主系 L2 スイッチ |
| sw02 (Cisco ISR 1100) | 192.168.11.6 | 補助 L2 スイッチ |
| sw03+ | 192.168.11.7〜 | 追加スイッチ (現場で予約) |

この手順を忘れるとスイッチに SSH で入れず、現地で物理コンソールを探す羽目になる。必ず構築時に自宅環境で疎通確認してから搬入する。

---

## 4. STP (スパニングツリー) 方針

### MST リージョン設定

全スイッチで以下を**完全一致**させる。1 台でも不一致があると別リージョン扱いになり CIST boundary として動作する。

| パラメータ | 値 |
|-----------|-----|
| リージョン名 | `BWAI` (大文字小文字区別あり) |
| リビジョン番号 | `1` (変更時は全台同時更新) |
| VLAN マッピング | 全 VLAN → IST (instance 0) |

VLAN が 3 つ (11/30/40) のみ、スイッチ台数も少ないため MST インスタンス分割は不要。全 VLAN を IST に載せることで実質 RSTP 相当の単一ツリーで動作する。

### ルートブリッジ

- **プライマリルート**: sw01 (FS、集約スイッチ) — priority 4096
- **セカンダリルート**: sw02 (Cisco ISR 1100) — priority 8192
- その他はデフォルト (32768)

### ポート別 STP 設定

| ポートタイプ | edge (portfast) | BPDU guard | 備考 |
|--------------|-----------------|-----------|------|
| T1 (upstream trunk) | no | no | BPDU 疎通を維持 |
| T2 (AP trunk) | edge trunk | yes | AP は BPDU 送出しない |
| T3 (endpoint access) | yes | yes | 端末は BPDU 送出しない |
| T4 (mgmt access) | yes | yes | 同上 |
| T5 (shutdown) | — | — | 無効化 |

---

## 5. マルチベンダー実装

各ベンダー (Cisco IOS / IOS-XE、FS、HPE Aruba CX、Juniper Junos ELS、MikroTik RouterOS) の CLI 対比表は [`../operations/switch-cli-reference.md`](../operations/switch-cli-reference.md) を参照。

要点:
- Native VLAN は T2 (AP) のみ。T1 には設定しない
- 構文差異: Cisco `native vlan 11` / Junos `native-vlan-id 11` / MikroTik `pvid 11`
- Aruba CX デフォルト `vlan trunk native 1` の罠あり (明示 11 必要)
- MikroTik は `vlan-filtering=yes` を忘れると VLAN 機能しない

---

## 6. tagged VLAN 11 自力参加設計 (運用上の重要注記)

本プロジェクトでは **配下機器が全員 tagged VLAN 11 で自力参加する** 設計になっている:

- **VyOS r3**: `eth2.11 address 192.168.11.1/24` (tagged)
- **Proxmox ホスト**: `vmbr_trunk.11 address 192.168.11.3/24` (tagged、VLAN-aware ブリッジの子 IF)
- **local-srv CT**: `net0 bridge=vmbr_trunk,tag=11` (Proxmox が tagged で渡す)
- **WLC / AP**: trunk 経由で VLAN 11 tagged で管理 IP 取得
- **sw01 / sw02 / 追加スイッチ**: VLAN 11 SVI は tagged VLAN 11 で L3 参加

この設計により、スイッチ側の `switchport trunk native vlan 11` は「あれば動作が安定する」程度の **ベストエフォート**であり、スイッチの設定ミス・初期化・代替機材への差し替えが発生しても **L3 疎通に影響しない**。

### 運用上避けるべきこと

- スイッチ側で VLAN 11 を untagged (access) に変換 → tagged 参加機器と L2 分断
- Native VLAN の ID をスイッチごとに変える → native mismatch でベンダーによっては dot1q drop
- VLAN 1 を残す → 未使用 VLAN 1 は shutdown / 別 VLAN に置換

### 許容されること

- 共通 trunk 設定がベンダー固有エラーで組めない場合、一時的に access VLAN 11 で管理経路だけ確保し、後で trunk 化するワークフロー

---

## 7. IPv6 マルチキャスト対策 (全スイッチ共通)

### 背景

IPv6 ND は多数のマルチキャストグループを生成する。DAD (重複アドレス検出) でも個別グループが使われ、端末 1 台あたり IPv6 アドレスを約 3 個保持するため、VLAN 40 (/22, 最大 1000 台) では最大 3000 グループが生成されうる。一般的なスイッチの L2MC テーブルは 1000〜4096 エントリであり、**テーブル枯渇により RA が端末に届かない半死状態**が発生しうる (JANOG56 実例)。

Wi-Fi 環境ではマルチキャストがブロードキャスト扱いで最低レートで全端末に送信されるため、パフォーマンス上も対策が必須。

### 7.1 MLD Snooping

IPv6 マルチキャストの L2 フラッディングを制限する。IGMP Snooping の IPv6 版。**全スイッチで有効化必須**。

- グローバル有効化 + VLAN 30, 40 で有効化
- MLD Querier は r3-vyos 側で設定不可のため、スイッチ側で有効化するか、VyOS の周期 RA/MLD Report で代替
- VLAN 11 は端末数が少ないため任意

**効果**: DAD の Solicited-Node マルチキャストが全ポートにフラッディングされるのを防止。

### 7.2 RA Guard

端末ポート (T2/T3) からの不正 RA (ICMPv6 type 134) を遮断する。悪意または設定ミスの端末が RA を送出するとセグメント全体のデフォルトルーターが書き換わり**大規模障害**になる。

| ポートタイプ | RA Guard 設定 |
|---|---|
| T1 (upstream trunk) | `device-role router` または未適用 (正規 RA 許可) |
| T2 (AP trunk) | `device-role host` (AP および配下端末からの RA 遮断) |
| T3 (endpoint access) | `device-role host` |
| T4 (mgmt access) | `device-role host` |

RA Guard が未対応の機種では IPv6 ACL で ICMPv6 type 134 を access/AP ポートで drop して代替する。

### 7.3 マルチキャスト→ユニキャスト変換 (Wi-Fi)

WLC 3504 または AP (FlexConnect) で Multicast-to-Unicast を有効化し、RA 等の重要なマルチキャストを各端末宛のユニキャストに変換する。

- **Cisco WLC 3504**: `Wireless > Multicast` で `Enable Global Multicast` + `Enable Multicast Direct`
- **FlexConnect ローカルスイッチング時**: AP 側で `multicast-to-unicast`

### 7.4 各ベンダー CLI 対比

MLD Snooping、RA Guard、Storm Control のベンダー別 CLI 対比は [`../operations/switch-cli-reference.md`](../operations/switch-cli-reference.md) を参照。

### 7.5 L2MC テーブル監視

IPv6 環境では L2 マルチキャストテーブル使用率の監視が重要。

- **確認コマンド例**: `show mac address-table multicast count` (Cisco/FS)、`show ipv6 mld snooping groups`
- **SNMP 監視**: L2MC テーブル使用率を SNMP Exporter 経由で Grafana に追加し閾値アラート
- **閾値目安**: 容量 70% で警告、90% で緊急

## 8. 構築・投入チェックリスト

- [ ] VLAN 11 / 30 / 40 を作成し、名称を揃えた (`mgmt` / `staff` / `user`)
- [ ] VLAN 11 SVI に 192.168.11.x/24 を割り当てた
- [ ] デフォルト GW = 192.168.11.1 を設定した
- [ ] 上位 trunk (T1) を allowed 11,30,40 で設定 (native なし、全 VLAN tagged)
- [ ] AP trunk (T2) を allowed 11,30,40 / native 11 / portfast trunk + BPDU guard
- [ ] 端末 access (T3) を VLAN 30 または 40 / portfast + BPDU guard
- [ ] 未使用ポート (T5) を shutdown
- [ ] STP モードを rapid-pvst または mstp
- [ ] LLDP 有効化
- [ ] MLD Snooping をグローバル + VLAN 30/40 で有効化 (§7.1)
- [ ] RA Guard を T2/T3/T4 に適用、または IPv6 ACL で RA drop (§7.2)
- [ ] Storm control でマルチキャストを 1〜5% (T3)
- [ ] L2MC テーブル容量に余裕があることを確認 (§7.5)
- [ ] 自宅環境で r3-vyos 経由で SSH ログイン確認
- [ ] 自宅環境で AP/端末エミュレーションで DHCP リース取得確認
- [ ] 自宅環境で IPv6 RA が端末に届き SLAAC アドレス取得確認

## 9. 会場搬入時の差分作業

会場搬入後、VyOS (r3) が起動して BGP が上がれば各スイッチは設定変更不要 (デフォルト GW `192.168.11.1` のまま)。

ただし **構築時に r1-home 経由で運用していた場合** は、デフォルト GW が `192.168.11.254` (r1-home eth3.11) を指しているため、会場搬入時に `192.168.11.1` (r3-vyos) に戻すこと。手順は各実装例 ([`venue-switch1.md`](./venue-switch1.md), [`venue-switch2.md`](./venue-switch2.md)) を参照。
