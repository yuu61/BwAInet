# 会場スイッチ共通設計 (マルチベンダー対応)

## 目的

会場に投入するスイッチは **sw01 (FS)**, **sw02 (Cisco ISR 1100)** に加え、現場調達や持ち込み機材としてマルチベンダー (Cisco / HPE Aruba / Juniper / MikroTik / 各社中古品) が参加する可能性がある。本ドキュメントはベンダー・機種に依存しない **共通 L2 設計ルール** を定義し、各機種の具体コンフィグは実装例ドキュメントに委譲する。

| 項目 | 参照先 |
|------|--------|
| 抽象的な共通設計 (本ドキュメント) | `venue-switch.md` |
| sw01 実装例 (FS, Cisco-like CLI) | [`venue-switch1.md`](./venue-switch1.md) |
| sw02 実装例 (Cisco ISR 1100 / C1111-8P) | [`venue-switch2.md`](./venue-switch2.md) |
| 管理 VLAN のアドレス一覧 | [`mgmt-vlan-address.md`](./mgmt-vlan-address.md) |

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

会場スイッチに接続されるすべてのポートは、以下 5 種類のいずれかに分類する。ベンダーが変わっても **この分類と設定意図は変わらず**、各ベンダーの構文にマッピングするだけで設定できる。

### Type T1: Uplink/Downlink Trunk (スイッチ・ルーター・コントローラ間相互接続)

**用途**: r3-vyos、Proxmox ミニ PC、**WLC (Cisco 3504)**、他スイッチ相互接続 (sw01 ↔ sw02, 追加スイッチのアップリンク/ダウンリンク)

**WLC を T1 に含める理由**: Cisco 3504 は管理 I/F + AP Manager I/F + Dynamic Interface (VLAN 30/40) を dot1q で 1 本に収容する前提。FlexConnect 運用でも Central DHCP / ウェブ認証 / ゲストアンカーなどで Dynamic Interface を使う可能性があり、access に絞ると拡張性を失う。WLC 側では管理 I/F の VLAN Identifier を 11 に設定して tagged VLAN 11 で自力参加させる (§6 の思想)。

| 項目 | 値 |
|------|-----|
| モード | trunk (802.1Q dot1q) |
| Allowed VLAN | 11, 30, 40 |
| Native VLAN | なし (全 VLAN tagged) |
| STP | BPDU 疎通、portfast trunk は使わない (または portfast trunk + BPDU guard 併用) |
| LLDP | 有効 |

**補足**: T1 では native VLAN を設定しない。対向機器 (r3-vyos `eth2.11`、Proxmox VLAN-aware ブリッジ、WLC tagged VLAN 11、他スイッチ SVI) が全て tagged VLAN 11 で参加しているため (§6)、native VLAN を設定すると VLAN 11 が untagged で送出され対向の tagged サブインタフェースに届かなくなる。Native VLAN が必要なのは T2 (AP) ポートのみ (AP が管理 IP を untagged で DHCP 取得するため)。

### Type T2: AP Trunk (SSID ローカルスイッチング)

**用途**: Aironet 3800 などの AP。AP 自身が管理 IP を VLAN 11 から DHCP 取得し、SSID ごとに VLAN 30/40 を付与してエッジに送出する (FlexConnect またはスタンドアロン運用)。

| 項目 | 値 |
|------|-----|
| モード | trunk (802.1Q dot1q) |
| Allowed VLAN | 11, 30, 40 |
| Native VLAN | 11 |
| PoE | PoE+ (IEEE 802.3at, 25.5W) 給電。本体給電能力を超える場合は外部 PoE+ インジェクター経由 |
| STP | portfast trunk + BPDU guard (AP は BPDU を送出しない前提) |

**管理 IP の取り方**:

- AP は起動時に untagged (native VLAN 11) または tagged VLAN 11 で DHCP Discover を送出
- r3-vyos の DHCP プール `192.168.11.100–.199` から管理 IP をリース
- クライアントトラフィックは AP が SSID 設定に従い VLAN 30 / 40 タグを付与してスイッチに送出

### Type T3: Endpoint Access (PC, スピーカー, 固定機器)

**用途**: 配信 PC、スピーカー、運営有線席、来場者向け有線 (稀)

| 項目 | 値 |
|------|-----|
| モード | access |
| VLAN | 30 (staff/配信 PC/スピーカー) または 40 (user) |
| STP | portfast 有効 + BPDU guard 併用 |
| Storm control | 推奨 (ブロードキャスト/マルチキャストを上限 1〜5%) |
| ポートセキュリティ | 任意 (MAC 数制限) |

### Type T4: Management Access (稀)

**用途**: NMS 機材、ベンダー持込の管理ワークステーションなど、VLAN 11 に直接ぶら下げるケース

| 項目 | 値 |
|------|-----|
| モード | access |
| VLAN | 11 |
| STP | portfast 有効 + BPDU guard 併用 |

原則として VLAN 40 (user) からは VLAN 11 へのアクセスは拒否 (ACL は r3-vyos 側)。本タイプは運営スタッフのみ使用。

### Type T5: Unused (shutdown)

**用途**: 未使用ポート。誤接続による L2 ループ、VLAN 侵害を防ぐため **必ず shutdown**。

| 項目 | 値 |
|------|-----|
| 状態 | shutdown |
| Access VLAN | (任意の未使用 VLAN、あるいは "black hole" VLAN 999) |

---

## 3. 管理 IP ルール (忘れずに)

**すべての会場スイッチは例外なく、以下を設定する。**

1. **VLAN 11 の SVI (Switch Virtual Interface) を作成**
2. **192.168.11.0/24 から静的 IP を 1 つ割り当てる** (割り当て表は [`mgmt-vlan-address.md`](./mgmt-vlan-address.md))
3. **デフォルトゲートウェイを 192.168.11.1 (r3-vyos) に設定**
4. **SSH 経由で疎通できることを確認**

| 機器 | 管理 IP | 備考 |
|------|---------|------|
| sw01 (FS) | 192.168.11.4 | 主系 L2 スイッチ |
| sw02 (Cisco ISR 1100) | 192.168.11.6 | 補助 L2 スイッチ |
| sw03+ | 192.168.11.7〜 | 追加スイッチ (現場で予約) |

**この手順を忘れると、スイッチに SSH で入れず現地で物理コンソールを探す羽目になる。必ず構築時に自宅環境で疎通確認してから搬入すること。**

---

## 4. STP (スパニングツリー) 方針

### モード選定

### MST リージョン設定

全スイッチで以下のパラメータを **完全一致** させること。1 台でも不一致があると別リージョン扱いになり、CIST boundary として動作し意図しない STP トポロジになる。

| パラメータ | 値 | 備考 |
|-----------|-----|------|
| リージョン名 | `BWAI` | 大文字小文字区別あり |
| リビジョン番号 | `1` | 変更時は全台同時更新 |
| VLAN マッピング | 全 VLAN → IST (instance 0) | デフォルトのまま |

VLAN が 3 つ (11/30/40) のみ、スイッチ台数も少ないため MST インスタンスを分割する意味はない。全 VLAN を IST (instance 0) に載せることで実質 RSTP (802.1w) 相当の単一ツリーで動作する。

### ルートブリッジ

- **プライマリルート**: sw01 (FS、集約スイッチ)
- **セカンダリルート**: sw02 (Cisco ISR 1100)
- priority は MST instance 0 に対して設定 (sw01=4096, sw02=8192, その他=32768 デフォルト)

### ポート別 STP 設定

| ポートタイプ | edge (portfast) | BPDU guard | 備考 |
|--------------|-----------------|-----------|------|
| T1 (upstream trunk) | no | no | BPDU 疎通を維持 |
| T2 (AP trunk) | edge trunk | yes | AP は BPDU 送出しない |
| T3 (endpoint access) | yes | yes | 端末は BPDU 送出しない |
| T4 (mgmt access) | yes | yes | 同上 |
| T5 (shutdown) | — | — | 無効化 |

---

## 5. マルチベンダー実装コマンド対比

共通設計を各ベンダーの CLI にマッピングする際の参考表。**厳密な構文はベンダー公式ドキュメントで確認すること** (バージョン依存あり)。

| 操作 | Cisco IOS / IOS-XE (ESM) / FS (Cisco-like) | HPE Aruba CX | Juniper Junos (ELS) | MikroTik RouterOS |
|------|--------------------------------------------|--------------|---------------------|-------------------|
| VLAN 作成 | `vlan 11` `name mgmt` | `vlan 11` `name mgmt` | `set vlans mgmt vlan-id 11` | `/interface bridge vlan add bridge=bridge1 vlan-ids=11` |
| Access ポート (T3/T4) | `switchport mode access` `switchport access vlan 30` | `interface 1/1/1` `no routing` `vlan access 30` | `set interfaces ge-0/0/0 unit 0 family ethernet-switching interface-mode access vlan members staff` | `/interface bridge port add bridge=bridge1 interface=ether3 pvid=30` |
| Trunk ポート T1 (native なし) | `switchport mode trunk` `switchport trunk allowed vlan 11,30,40` | `interface 1/1/1` `no routing` `vlan trunk allowed 11,30,40` `no vlan trunk native` | `set interfaces ge-0/0/0 unit 0 family ethernet-switching interface-mode trunk vlan members [mgmt staff user]` | `/interface bridge port add bridge=bridge1 interface=ether1 frame-types=admit-only-vlan-tagged` + `/interface bridge vlan add bridge=bridge1 tagged=ether1 vlan-ids=11,30,40` |
| Trunk ポート T2 (native 11) | `switchport mode trunk` `switchport trunk allowed vlan 11,30,40` `switchport trunk native vlan 11` | `interface 1/1/1` `no routing` `vlan trunk allowed 11,30,40` `vlan trunk native 11` | `set interfaces ge-0/0/0 unit 0 family ethernet-switching interface-mode trunk vlan members [mgmt staff user]` `set interfaces ge-0/0/0 native-vlan-id 11` | `/interface bridge port add bridge=bridge1 interface=ether1 pvid=11 frame-types=admit-all` + `/interface bridge vlan add bridge=bridge1 tagged=ether1 vlan-ids=11,30,40` |
| 管理 SVI (VLAN 11 IP) | `interface Vlan11` `ip address 192.168.11.x 255.255.255.0` | `interface vlan 11` `ip address 192.168.11.x/24` | `set interfaces irb unit 11 family inet address 192.168.11.x/24` `set vlans mgmt l3-interface irb.11` | `/interface vlan add interface=bridge1 name=vlan11 vlan-id=11` + `/ip address add address=192.168.11.x/24 interface=vlan11` |
| デフォルト GW | `ip default-gateway 192.168.11.1` | `ip route 0.0.0.0/0 192.168.11.1` | `set routing-options static route 0.0.0.0/0 next-hop 192.168.11.1` | `/ip route add dst-address=0.0.0.0/0 gateway=192.168.11.1` |
| LLDP 有効化 | `lldp run` | `lldp` | `set protocols lldp interface all` | `/interface bridge port set auto-isolate=no` + LLDP は別設定 |

**注意点**:

- **Native VLAN は T2 (AP) のみ**: T1 (幹線) では native VLAN を設定しない。対向が全て tagged VLAN 11 で参加しているため、native VLAN を設定すると VLAN 11 が untagged で送出され L2 不一致になる (§6 参照)
- **Native VLAN 表記の差異 (T2)**: Cisco は `native vlan 11`、Junos は `native-vlan-id 11`、MikroTik は `pvid 11`。意味は同じだが構文が異なる
- **Aruba CX の native VLAN (T2)**: デフォルトで `vlan trunk native 1`。明示的に `vlan trunk native 11` を設定しないと VLAN 1 untagged になる罠あり
- **Junos ELS の `interface-mode` vs 旧 `port-mode`**: ELS (EX2300/3400 以降) は `interface-mode`、旧機種は `port-mode`。設定前にバージョン確認
- **MikroTik は bridge VLAN filtering** を `/interface bridge set bridge1 vlan-filtering=yes` で有効化しないと VLAN が機能しない。忘れやすい

---

## 6. tagged VLAN 11 自力参加設計 (運用上の重要注記)

本プロジェクトでは **配下機器が全員 tagged VLAN 11 で自力参加する** 設計になっている:

- **VyOS r3**: `eth2.11 address 192.168.11.1/24` (tagged)
- **Proxmox ホスト**: `vmbr_trunk.11 address 192.168.11.3/24` (tagged、VLAN-aware ブリッジの子 IF)
- **local-srv CT**: `net0 bridge=vmbr_trunk,tag=11` (Proxmox が tagged で渡す)
- **WLC / AP**: trunk 経由で VLAN 11 tagged で管理 IP 取得
- **sw01 / sw02 / 追加スイッチ**: VLAN 11 SVI は tagged VLAN 11 で L3 参加

この設計により、スイッチ側の `switchport trunk native vlan 11` は「あれば動作が安定する」程度の **ベストエフォート** であり、**スイッチの設定ミス・初期化・代替機材への差し替えが発生しても L3 疎通に影響しない**。

### 運用上避けるべきこと

- **スイッチ側で VLAN 11 を untagged (access) に変換してしまう構成変更**: これを行うと tagged 参加している機器 (Proxmox、VyOS、WLC、他スイッチの VLAN 11 SVI) 側と L2 が分断される
- **Native VLAN の ID をスイッチごとに変える**: Native mismatch が発生するとベンダーによっては dot1q フレームを落とす
- **VLAN 1 を残すこと**: 未使用 VLAN 1 は shutdown / 別 VLAN に置換すること

### 逆に許容されること

- 共通設計の trunk 設定をそのまま投入して動かない場合でも、**機器側が tagged で自力参加するので先に進める**判断が可能
- ベンダー固有の構文エラーで trunk が組めない場合、一時的に access VLAN 11 で管理経路だけ確保し、後で trunk 化するワークフローも許容

---

## 7. IPv6 マルチキャスト対策 (全スイッチ共通)

### 背景

IPv6 では Neighbor Discovery (ND) が多数のマルチキャストグループを生成する。端末ごとに Solicited-Node マルチキャストアドレスが作られ、DAD (重複アドレス検出) でも個別のマルチキャストグループが使用される。端末 1 台あたり IPv6 アドレスを約 3 個保持するため、VLAN 40 (user, /22, 最大 1000 台) では **最大 3000 マルチキャストグループ** が生成される可能性がある。一般的なスイッチの L2MC テーブルは 1000〜4096 エントリであり、**テーブル枯渇により RA が端末に届かなくなる半死状態** が発生しうる (JANOG56 での実例あり)。

Wi-Fi 環境ではマルチキャストがブロードキャスト扱いとなり最低レートで全端末に送信されるため、パフォーマンス上も対策が必須。

### 7.1 MLD Snooping

IPv6 マルチキャストの L2 フラッディングを制限する。IPv4 の IGMP Snooping に相当。**全スイッチで有効化必須**。

| 項目 | 値 |
|------|-----|
| MLD Snooping | グローバル有効化 + VLAN 30, 40 で有効化 |
| MLD Querier | r3-vyos 側で設定不可のため、スイッチ側で Querier を有効化するか、VyOS が周期的に送出する RA/MLD Report で代替 |
| VLAN 11 (mgmt) | 端末数が少ないため MLD Snooping は任意 |

**効果**: DAD の Solicited-Node マルチキャストが全ポートにフラッディングされるのを防止し、L2MC テーブルの消費を該当ポートのみに限定する。

### 7.2 RA Guard

端末ポート (T2/T3) からの不正な Router Advertisement (ICMPv6 type 134) を遮断する。悪意のある端末や設定ミスの端末が RA を送出すると、セグメント内の全端末のデフォルトルータが書き換わり **大規模障害** となる。

| ポートタイプ | RA Guard 設定 |
|---|---|
| T1 (upstream trunk) | `device-role router` または未適用 (正規ルーターからの RA を許可) |
| T2 (AP trunk) | `device-role host` (AP および AP 配下の端末からの RA を遮断) |
| T3 (endpoint access) | `device-role host` (端末からの RA を遮断) |
| T4 (mgmt access) | `device-role host` |
| T5 (shutdown) | — (ポート無効化済み) |

**RA Guard が未対応の機種**: IPv6 ACL で ICMPv6 type 134 (RA) を access/AP ポートで drop するフィルタで代替する。

### 7.3 マルチキャスト→ユニキャスト変換 (Wi-Fi)

Wi-Fi ではマルチキャストフレームがブロードキャスト扱いとなり、最低データレート (1Mbps 等) で全端末に送信される。WLC 3504 または AP (FlexConnect) で **マルチキャスト→ユニキャスト変換 (Multicast-to-Unicast)** を有効化し、RA 等の重要なマルチキャストを各端末宛のユニキャストに変換する。

- **Cisco WLC 3504**: `Wireless > Multicast` で `Enable Global Multicast` + `Enable Multicast Direct` を有効化
- **FlexConnect ローカルスイッチング時**: AP 側で `multicast-to-unicast` を有効化 (WLC の FlexConnect Group 設定)

### 7.4 マルチベンダー実装コマンド対比 (IPv6 マルチキャスト)

| 操作 | Cisco IOS / IOS-XE (ESM) / FS (Cisco-like) | HPE Aruba CX | Juniper Junos (ELS) | MikroTik RouterOS |
|------|----------------------------------------------|--------------|---------------------|-------------------|
| MLD Snooping 有効化 (グローバル) | `ipv6 mld snooping` (Cisco) / `ipv6 mld-snooping enable` (FS) | デフォルト有効 (AOS-CX 10.16+) | `set protocols mld-snooping vlan <vlan>` | `/interface bridge set <bridge> igmp-snooping=yes` (IGMP/MLD 共通) |
| MLD Snooping 有効化 (VLAN) | `ipv6 mld snooping vlan <id>` (Cisco) / `ipv6 mld-snooping vlan <id>` (FS) | `vlan <id>` → `ipv6 mld snooping enable` | VLAN 名で指定 | bridge 単位で一括 |
| RA Guard ポリシー定義 | `ipv6 nd raguard policy <name>` → `device-role host` | `ipv6 nd-snooping ra-guard policy <name>` (ND snooping 前提) | `set forwarding-options access-security router-advertisement-guard` | bridge filter で ICMPv6 type 134 を drop |
| RA Guard 適用 | `ipv6 nd raguard attach-policy <name>` | `nd-snooping ra-guard` (IF 配下) | `interface <if> mark-interface block` | `/ipv6 firewall filter` |
| Storm Control (マルチキャスト) | `storm-control multicast level <pps>` (Cisco) / `storm-control multicast <threshold>` (FS) | `storm-control <if> multicast level <pps>` | `set interfaces <if> unit 0 family ethernet-switching storm-control` | `/interface bridge port set storm-rate` |

**注意点**:

- **FS (FSOS)**: MLD Snooping コマンドはハイフン区切り (`mld-snooping`) で Cisco のスペース区切り (`mld snooping`) と異なる。RA Guard は機種・バージョンにより未対応の可能性あり — その場合は IPv6 ACL で代替
- **Cisco ISR 1100 (ESM)**: ESM switchport での MLD Snooping 対応は文書上不明確 — **実機で `ipv6 mld snooping ?` を投入して確認すること**。WAN 側 EVC + bridge-domain では IP マルチキャストが非サポートと明記されており、MLD Snooping が正常動作しない可能性がある
- **MikroTik**: IGMP/MLD Snooping は共通設定。RA Guard はソフトウェア処理 (CPU) のため HW オフロード環境 (CRS) では制限あり
- **HPE Aruba CX**: RA Guard は ND Snooping のグローバル有効化が前提

### 7.5 L2MC テーブル監視

IPv6 環境では、L2 マルチキャストテーブルの使用率を監視することが重要。IPv4 での DHCP プール使用率や NAT テーブル使用率の監視に相当する。

- **確認コマンド例**: `show mac address-table multicast count` (Cisco/FS)、`show ipv6 mld snooping groups` (グループ数の把握)
- **SNMP 監視**: スイッチの L2MC テーブル使用率を SNMP Exporter 経由で Grafana に追加し、閾値アラートを設定
- **閾値目安**: テーブル容量の 70% で警告、90% で緊急 (機種ごとの最大エントリ数はデータシート参照)

## 8. 構築・投入チェックリスト (全スイッチ共通)

- [ ] VLAN 11 / 30 / 40 を作成し、名称を揃えた (`mgmt` / `staff` / `user`)
- [ ] VLAN 11 SVI に 192.168.11.x/24 を割り当てた (x は [`mgmt-vlan-address.md`](./mgmt-vlan-address.md) 参照)
- [ ] デフォルト GW = 192.168.11.1 を設定した
- [ ] 上位 trunk (T1) を allowed 11,30,40 で設定した (native VLAN なし、全 VLAN tagged)
- [ ] AP trunk (T2) を allowed 11,30,40 / native 11 / portfast trunk + BPDU guard で設定した
- [ ] 端末 access (T3) を VLAN 30 または 40 / portfast + BPDU guard で設定した
- [ ] 未使用ポート (T5) を shutdown した
- [ ] STP モードを rapid-pvst または mstp に設定した
- [ ] LLDP を有効化した (ベンダー横断トポロジ確認のため)
- [ ] MLD Snooping をグローバル + VLAN 30/40 で有効化した (§7.1)
- [ ] RA Guard を T2/T3/T4 ポートに適用した、または IPv6 ACL で RA (ICMPv6 type 134) を drop 設定した (§7.2)
- [ ] Storm control でマルチキャストを上限 1〜5% に設定した (T3 ポート)
- [ ] L2MC テーブルの現在使用数を確認し、容量に余裕があることを確認した (§7.5)
- [ ] 自宅環境で r3-vyos 経由で SSH ログインできることを確認した
- [ ] 自宅環境で AP / 配信 PC / 来場者端末エミュレーションで DHCP リースが取得できることを確認した
- [ ] 自宅環境で IPv6 RA が端末に正常に届くことを確認した (SLAAC アドレス取得)

## 9. 会場搬入時の差分作業

会場搬入後、VyOS (r3) が起動して BGP が上がったら、各スイッチは特に設定変更不要 (デフォルト GW `192.168.11.1` はそのまま)。

ただし **構築時に r1-home 経由で運用している場合** は、デフォルト GW が `192.168.11.254` (r1-home eth3.11) を指しているので、会場搬入時に `192.168.11.1` (r3-vyos) に戻すこと。この差し替え手順は各実装例ドキュメント ([`venue-switch1.md`](./venue-switch1.md), [`venue-switch2.md`](./venue-switch2.md)) を参照。
