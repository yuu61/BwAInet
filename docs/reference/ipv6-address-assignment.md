# IPv6 アドレス割り当てフロー 完全解説

## はじめに

IPv6 のアドレス割り当てには複数のメカニズムが存在し、それぞれが独立して動作しつつ相互に補完する。IPv4 では DHCP が唯一のアドレス自動設定手段だったが、IPv6 では SLAAC (Stateless Address Autoconfiguration)、DHCPv6 Stateful、DHCPv6 Stateless の 3 つが共存する。どの方式が使われるかはルーターが送信する Router Advertisement (RA) のフラグによって決定される。

本ドキュメントでは、クライアントがネットワークに接続してからアドレスを取得するまでの全フローを、プロトコルレベルで解説する。

---

## 1. Router Advertisement (RA) のフラグ体系

RA は ICMPv6 Type 134 でルーターからリンク上の全ノードに送信される。RA のヘッダーとオプションに含まれるフラグが、クライアントのアドレス設定動作を制御する。

### 1.1 RA ヘッダーのフラグ

#### M flag (Managed Address Configuration)

- **位置**: RA ヘッダー (RFC 4861 Section 4.2)
- **意味**: 1 の場合、クライアントは DHCPv6 を使用してアドレス (IA_NA) を取得すべきであることを示す
- **注意**: M=1 であっても SLAAC が無効になるわけではない。M flag は「DHCPv6 からもアドレスが得られる」という追加情報であり、SLAAC の A flag とは独立して機能する

#### O flag (Other Configuration)

- **位置**: RA ヘッダー (RFC 4861 Section 4.2)
- **意味**: 1 の場合、クライアントは DHCPv6 を使用してアドレス以外の設定情報 (DNS サーバー、NTP サーバー、ドメイン検索リスト等) を取得すべきであることを示す
- **M=1 の場合**: O flag は暗黙的に 1 として扱われる (RFC 4861)。アドレスを DHCPv6 で取得するなら、当然他の設定情報も DHCPv6 で取得する

### 1.2 Prefix Information Option (PIO) のフラグ

RA に含まれる Prefix Information Option (Type 3) にはプレフィックスごとのフラグがある。

#### A flag (Autonomous Address-Configuration)

- **位置**: PIO 内 (RFC 4861 Section 4.6.2)
- **意味**: 1 の場合、クライアントはこのプレフィックスを使って SLAAC でアドレスを自律生成してよい
- **0 の場合**: このプレフィックスは SLAAC に使用しない。DHCPv6 でのみアドレスが配布されるか、on-link 判定のみに使う
- **重要**: A flag はプレフィックスごとに設定される。同一 RA 内に A=1 のプレフィックスと A=0 のプレフィックスが共存しうる

#### L flag (On-Link)

- **位置**: PIO 内 (RFC 4861 Section 4.6.2)
- **意味**: 1 の場合、このプレフィックスはリンク上に直接存在する (on-link) ことを示す。つまり、このプレフィックス宛のパケットはルーターを経由せずリンク上で直接到達可能
- **0 の場合**: on-link とは限らない。クライアントはこのプレフィックス宛の通信もデフォルトルーター経由で送信する
- **一般的な運用**: 通常は L=1, A=1 のセットで広告する

### 1.3 DHCPv6 Prefix Delegation 関連

#### P flag (RFC 9762)

- **位置**: RA の新しい Router Information Option (RFC 9762, 旧 draft-ietf-6man-pio-pflag)
- **意味**: ルーターが DHCPv6 Prefix Delegation (PD) をサポートしていることを示す
- **用途**: 下流ルーター (CE ルーター等) がこのフラグを見て、DHCPv6 PD でプレフィックスを要求すべきかどうかを判断する
- **エンドホストへの影響**: 通常のクライアント端末は P flag を無視する。ルーター機能を持つデバイスのみが参照する
- **背景**: 従来、下流ルーターは RA を見ても PD が利用可能かどうか判断できなかった。P flag によって、RA だけで PD の可否を判断できるようになった

---

## 2. SLAAC (Stateless Address Autoconfiguration)

RFC 4862 で定義される。ルーターやサーバーの状態管理なしに、クライアントが自律的にグローバルユニキャストアドレスを生成する。

### 2.1 全体フロー

```
1. インターフェースが up する
2. リンクローカルアドレスを生成 (fe80::/10)
3. リンクローカルアドレスに対して DAD を実行
4. DAD 成功後、Router Solicitation (RS) を送信
5. ルーターから Router Advertisement (RA) を受信
6. RA 内の PIO で A=1 のプレフィックスを取得
7. プレフィックス + インターフェース ID でグローバルアドレスを生成
8. グローバルアドレスに対して DAD を実行
9. DAD 成功後、アドレスを使用開始
```

### 2.2 リンクローカルアドレスの生成

IPv6 ノードがインターフェースを有効化すると、最初にリンクローカルアドレス (fe80::/10) を生成する。このアドレスはリンク外では使用できないが、NDP (Neighbor Discovery Protocol) や RS/RA 交換に必須。

生成方法:
- **EUI-64**: MAC アドレスから算出 (例: MAC `00:1a:2b:3c:4d:5e` → IID `021a:2bff:fe3c:4d5e` → `fe80::21a:2bff:fe3c:4d5e`)
- **RFC 7217 安定プライバシー**: ネットワークごとに安定だが MAC アドレスを漏洩しない (後述)
- **ランダム**: OS によってはランダム生成 (Windows 等)

### 2.3 Router Solicitation (RS) → Router Advertisement (RA)

クライアントはリンクローカルアドレスの DAD 完了後、ICMPv6 Type 133 (Router Solicitation) を全ルーター宛マルチキャスト (`ff02::2`) に送信する。ルーターは ICMPv6 Type 134 (Router Advertisement) で応答する。

- RS は最大 `MAX_RTR_SOLICITATIONS` 回 (デフォルト 3) 送信される
- ルーターは RS に対する即時応答に加え、定期的に unsolicited RA を全ノード宛 (`ff02::1`) に送信する (デフォルト 200〜600 秒間隔)

### 2.4 プレフィックスの取得

RA に含まれる Prefix Information Option (PIO) から以下の情報を取得する:

| フィールド | 用途 |
|-----------|------|
| Prefix | ネットワークプレフィックス (例: `2001:db8:1::/64`) |
| Prefix Length | プレフィックス長 (SLAAC では /64 が必須) |
| L flag | on-link 判定 |
| A flag | SLAAC 使用可否 |
| Valid Lifetime | アドレスの有効期限 (この時間を超えるとアドレスは無効) |
| Preferred Lifetime | アドレスの優先期限 (この時間を超えると deprecated 状態になり、新規接続には使用しない) |

### 2.5 インターフェース ID (IID) の生成方法

SLAAC アドレスの下位 64 ビット (インターフェース ID) の生成には複数の方式がある。

#### EUI-64 (RFC 4291)

MAC アドレス (48 bit) から 64 bit の IID を導出する。

```
MAC:  00:1a:2b:3c:4d:5e
       ↓
1. MAC を OUI (3B) + デバイス識別子 (3B) に分割
   OUI = 00:1a:2b   Device = 3c:4d:5e
2. 中間に ff:fe を挿入
   00:1a:2b:ff:fe:3c:4d:5e
3. 先頭バイトの bit 6 (Universal/Local bit) を反転
   00 (0000 0000) → 02 (0000 0010)
4. 結果
   IID = 021a:2bff:fe3c:4d5e
   アドレス = 2001:db8:1::21a:2bff:fe3c:4d5e
```

**問題点**: MAC アドレスがアドレスに埋め込まれるため、同一デバイスが異なるネットワーク間で追跡可能。プライバシー上の懸念から、現在は多くの OS でデフォルト無効。

#### RFC 7217 (Stable Privacy Addresses) — 安定プライバシーアドレス

```
IID = F(prefix, interface_name, network_id, DAD_counter, secret_key)
```

- ハッシュ関数 F (通常 SHA-256) を使用し、プレフィックスとインターフェース名等から IID を導出
- **同一ネットワーク・同一インターフェースでは常に同じアドレス** → サーバー設定、ACL、ログ分析に有利
- **異なるネットワークでは異なるアドレス** → ネットワーク間の追跡不可
- secret_key はデバイスに保存され、外部に漏洩しない
- DAD で衝突した場合は DAD_counter をインクリメントして再生成
- **現在の推奨方式** (RFC 8064)

#### RFC 4941 → RFC 8981 (Temporary / Privacy Addresses) — 一時アドレス

- ランダムな IID を定期的に再生成する
- 外向き通信 (outbound) のソースアドレスとして優先的に使用される
- Preferred Lifetime が切れると新しい一時アドレスが生成され、古いものは deprecated → 最終的に無効化
- **安定アドレス (RFC 7217) と併用される**: 安定アドレスは着信接続用、一時アドレスは発信接続用
- Web ブラウジング等での追跡防止が目的

#### 実際の OS の挙動

| OS | デフォルトの IID 生成 | 一時アドレス |
|----|---------------------|-------------|
| Windows 10/11 | ランダム安定 (RFC 7217 相当) | 有効 (デフォルト) |
| Linux (NetworkManager) | RFC 7217 (stable-privacy) | 有効 (カーネル設定依存) |
| macOS | ランダム安定 | 有効 (デフォルト) |
| iOS | ランダム安定 | 有効 (デフォルト) |
| Android | ランダム安定 (RFC 7217) | 有効 |

現代の OS では EUI-64 をデフォルトで使用するものはほぼない。

### 2.6 DAD (Duplicate Address Detection)

アドレスを使用する前に、リンク上に同じアドレスを使用するノードがいないかを確認するプロセス。

```
1. 生成したアドレスを tentative (仮) 状態にする
2. そのアドレスの solicited-node マルチキャストグループに参加
   (例: ff02::1:ff3c:4d5e — アドレス下位 24 bit から導出)
3. NS (Neighbor Solicitation) を solicited-node マルチキャスト宛に送信
   - Source: :: (unspecified、DAD 中は自アドレスを使えない)
   - Target: 確認対象のアドレス
4. DupAddrDetectTransmits 回 (デフォルト 1) 送信し、RetransTimer (デフォルト 1 秒) 待つ
5. NA (Neighbor Advertisement) が返ってこなければ DAD 成功 → アドレス使用開始
6. NA が返ってきたら重複あり → アドレスを破棄
```

**最適化**: RFC 7527 (Enhanced DAD) により、DAD 中のループ検出が可能。Optimistic DAD (RFC 4429) では、DAD 完了前にアドレスを限定的に使用開始できる。

---

## 3. DHCPv6 Stateful (IA_NA)

RFC 8415 で定義される。サーバーが個別のアドレスをクライアントに割り当て、リース状態を管理する。

### 3.1 いつ DHCPv6 が開始されるか

クライアントが RA を受信し、**M flag = 1** であった場合に DHCPv6 Stateful を開始する。ただし、OS によって挙動が大きく異なる (後述のセクション 8)。

### 3.2 4-message exchange (通常)

```
クライアント                        DHCPv6 サーバー
    |                                    |
    |--- SOLICIT (multicast) ----------->|  (1) ff02::1:2 宛、サーバー探索
    |                                    |
    |<-- ADVERTISE ----------------------|  (2) サーバーが自身を広告、提案アドレスを含む
    |                                    |
    |--- REQUEST (multicast) ----------->|  (3) 特定サーバーを選択し、アドレスを要求
    |                                    |
    |<-- REPLY --------------------------|  (4) アドレス割り当て確定、リース情報を含む
    |                                    |
```

- **SOLICIT**: クライアントが全 DHCPv6 サーバー宛マルチキャスト (`ff02::1:2`, UDP port 547) に送信。IA_NA (Identity Association for Non-temporary Addresses) オプションを含む
- **ADVERTISE**: サーバーが応答。Server ID、提案するアドレス (IA_NA 内の IA Address オプション)、T1/T2 タイマーを含む
- **REQUEST**: クライアントが特定のサーバー (複数サーバーから ADVERTISE を受信した場合は preference が最高のもの) を選択し、アドレスを要求
- **REPLY**: サーバーがアドレス割り当てを確定。Preferred Lifetime, Valid Lifetime を含む

### 3.3 2-message exchange (Rapid Commit)

```
クライアント                        DHCPv6 サーバー
    |                                    |
    |--- SOLICIT + Rapid Commit -------->|  (1) Rapid Commit オプション付き
    |                                    |
    |<-- REPLY + Rapid Commit -----------|  (2) 即座にアドレス割り当て
    |                                    |
```

- クライアントが SOLICIT に Rapid Commit オプションを付加
- サーバーが Rapid Commit をサポートしていれば、ADVERTISE/REQUEST をスキップして直接 REPLY を返す
- **ネットワーク上に DHCPv6 サーバーが 1 台のみの場合に推奨**。複数サーバーがある場合、全サーバーがアドレスを割り当ててしまう可能性があるため非推奨

### 3.4 IA_NA の仕組み

- **IA (Identity Association)**: クライアントとサーバー間のアドレス割り当ての論理的な関連付け
- **IAID**: IA の識別子。通常はインターフェースインデックスから導出される
- **IA_NA**: Non-temporary Address の IA。一般的なアドレス割り当てに使用
- 1 つの IA_NA に複数のアドレスを含めることが可能 (RFC 8415)

### 3.5 リース管理

| タイマー | 説明 | デフォルト (RFC 8415) |
|---------|------|---------------------|
| Preferred Lifetime | この時間内はアドレスを優先使用。超えると deprecated | サーバー設定依存 |
| Valid Lifetime | この時間を超えるとアドレスは無効 | サーバー設定依存 |
| T1 (Renew timer) | Preferred Lifetime の 50% (推奨)。T1 経過後に RENEW を送信 | 0.5 * Preferred Lifetime |
| T2 (Rebind timer) | Preferred Lifetime の 80% (推奨)。RENEW 失敗時に REBIND を送信 | 0.8 * Preferred Lifetime |

```
[--- Preferred Lifetime ------------------------------------]
[--- T1 (50%) ---][--- T2 (80%) ---][ Valid Lifetime 残り  ]
                   ↑ RENEW          ↑ REBIND               ↑ アドレス無効
```

- **RENEW** (ユニキャスト): T1 経過後、クライアントはリースを付与した元のサーバーに直接 RENEW を送信
- **REBIND** (マルチキャスト): RENEW に応答がない場合、T2 経過後にマルチキャスト (`ff02::1:2`) で REBIND を送信し、任意のサーバーからリースを更新
- **RELEASE**: クライアントがアドレスを明示的に解放する場合に送信

---

## 4. DHCPv6 Stateless (Information-Request)

### 4.1 いつ発生するか

RA で **O flag = 1 かつ M flag = 0** (正確には M=0 の場合で O=1) のとき、クライアントはアドレスは SLAAC で取得するが、DNS サーバー等の設定情報は DHCPv6 から取得する。

### 4.2 メッセージフロー

```
クライアント                        DHCPv6 サーバー
    |                                    |
    |--- INFORMATION-REQUEST ----------->|  (1) ff02::1:2 宛
    |                                    |
    |<-- REPLY --------------------------|  (2) DNS/NTP 等の設定情報
    |                                    |
```

- **アドレス割り当ては行われない** — IA_NA オプションを含まない
- サーバーはクライアントのアドレス状態を管理しない (stateless)

### 4.3 取得できる情報の例

| DHCPv6 オプション | 内容 |
|-------------------|------|
| DNS Recursive Name Server (23) | DNS サーバーアドレス |
| Domain Search List (24) | DNS 検索ドメイン |
| SNTP Servers (31) | SNTP サーバー |
| NTP Server (56) | NTP サーバー |
| Information Refresh Time (32) | 次回 Information-Request までの待ち時間 |

### 4.4 M=1 の場合の O flag

RFC 4861 Section 4.2 の記述:

> If the M flag is set, the O flag is redundant and can be ignored because DHCPv6 will return all available configuration information.

つまり M=1 の場合、クライアントは DHCPv6 Stateful (IA_NA) を行い、その過程でアドレスと設定情報の両方を取得する。別途 Information-Request を送る必要はない。

---

## 5. DHCPv6 Prefix Delegation (IA_PD)

### 5.1 概要

DHCPv6 PD は **ルーターがルーターに対して** プレフィックスを委任するための仕組み。エンドホストのアドレス取得ではなく、下流ルーターが自身の LAN に広告するプレフィックスを取得するために使用する。

### 5.2 メッセージフロー

DHCPv6 PD は通常の DHCPv6 と同じメッセージタイプを使用するが、IA_NA の代わりに IA_PD (Identity Association for Prefix Delegation) オプションを使用する。

```
要求ルーター (CPE)                   委任ルーター (ISP)
    |                                    |
    |--- SOLICIT (IA_PD) -------------->|  「/48 か /56 か /64 をください」
    |                                    |
    |<-- ADVERTISE (IA_PD) -------------|  「2001:db8:abcd::/48 を委任します」
    |                                    |
    |--- REQUEST (IA_PD) -------------->|  「その /48 でお願いします」
    |                                    |
    |<-- REPLY (IA_PD) -----------------|  「確定。Valid/Preferred Lifetime は以下」
    |                                    |
```

- **IA_PD オプション**: 要求するプレフィックス長のヒント (hint) を含めることができる
- **IA_Prefix サブオプション**: 委任されたプレフィックスとその長さを含む
- 委任されたプレフィックスを、要求ルーターが自身の下流インターフェースでさらに分割して RA 広告する

### 5.3 プレフィックス長の実例

| ISP | 委任プレフィックス長 | 備考 |
|-----|---------------------|------|
| OPTAGE (関西) | /64 | 分割不可。SLAAC の最小単位 |
| NTT フレッツ (v6プラス) | /56 | /64 x 256 に分割可能 |
| JPNE (v6プラス) | /56 | MAP-E 用 |
| 一般的な海外 ISP | /48 〜 /56 | RFC 6177 推奨は /48 |

### 5.4 RFC 9762 P flag

従来の問題:

- 下流ルーター (例: 家庭内の追加ルーター) は、上流ルーターが PD をサポートしているかどうかを RA から判断できなかった
- 結果として、下流ルーターは常に DHCPv6 PD を試みるか、手動設定が必要だった

RFC 9762 の解決策:

- RA ヘッダーに P flag を追加 (正確には PIO 内の新フラグ)
- **P=1**: 上流ルーターが DHCPv6 PD をサポートしており、下流ルーターは PD を要求すべき
- **P=0**: PD は利用不可。下流ルーターは PD を試みるべきではない
- エンドホストは P flag を無視する

---

## 6. RDNSS / DNSSL in RA (RFC 8106)

### 6.1 背景

従来、IPv6 で DNS サーバー情報を配布するには DHCPv6 (Stateful or Stateless) が必要だった。しかし、一部の OS (特に Android) が DHCPv6 を実装していないため、RA のみで DNS 情報を配布する仕組みが必要になった。

### 6.2 RDNSS (Recursive DNS Server) オプション

- **RA 内のオプション Type 25**
- DNS サーバーの IPv6 アドレスを直接含む
- Lifetime フィールドで有効期間を指定
- 複数の DNS サーバーアドレスを含めることが可能

### 6.3 DNSSL (DNS Search List) オプション

- **RA 内のオプション Type 31**
- DNS サフィックスサーチリスト (例: `example.com`, `corp.example.com`) を含む
- Lifetime フィールドで有効期間を指定

### 6.4 DHCPv6 の DNS オプションとの関係

| 方式 | 配布元 | Android 対応 | Windows 対応 | macOS 対応 |
|------|--------|-------------|-------------|-----------|
| RDNSS/DNSSL (RA) | ルーター | 対応 | 対応 (Win10 1709+) | 対応 |
| DHCPv6 DNS option (23/24) | DHCPv6 サーバー | 非対応 | 対応 | 対応 |

**運用上の推奨**: Android をサポートする必要がある場合、RDNSS は必須。DHCPv6 DNS と RDNSS を同時に設定し、両方の方式で DNS 情報を配布するのが最も広い互換性を持つ (本プロジェクトの architecture.md の設計もこの方針)。

---

## 7. クライアント視点の完全な意思決定フロー

### 7.1 フローチャート

```
[デバイスがネットワークに接続]
    |
    v
[リンクローカルアドレスを生成 (fe80::...)]
    |
    v
[リンクローカルアドレスに対して DAD 実行]
    |
    +--- DAD 失敗 → エラー (インターフェースを IPv6 無効化)
    |
    v (DAD 成功)
[Router Solicitation (RS) を ff02::2 に送信]
    |
    v
[Router Advertisement (RA) を受信]
    |
    +---> RA 内の RDNSS → DNS サーバーを設定
    |
    +---> RA 内の各 PIO を確認:
    |       |
    |       +--- A=1 → SLAAC アドレスを生成
    |       |     |
    |       |     +--- 安定アドレス (RFC 7217) を生成 → DAD → 使用開始
    |       |     +--- 一時アドレス (RFC 8981) を生成 → DAD → 使用開始
    |       |
    |       +--- L=1 → プレフィックスを on-link として経路表に登録
    |       |
    |       +--- A=0 → このプレフィックスでは SLAAC しない
    |
    +---> RA ヘッダーの M flag を確認:
    |       |
    |       +--- M=1 → DHCPv6 Stateful (IA_NA) を開始
    |       |     |
    |       |     +--- SOLICIT → ADVERTISE → REQUEST → REPLY
    |       |     +--- アドレスと DNS/NTP 等の設定情報を取得
    |       |
    |       +--- M=0 → DHCPv6 Stateful は開始しない
    |
    +---> RA ヘッダーの O flag を確認:
            |
            +--- O=1 かつ M=0 → DHCPv6 Stateless (Information-Request) を開始
            |     |
            |     +--- INFORMATION-REQUEST → REPLY
            |     +--- DNS/NTP 等の設定情報のみ取得
            |
            +--- O=0 → DHCPv6 Stateless は開始しない
```

### 7.2 複数メカニズムの共存

1 つのデバイスが**同時に複数の IPv6 アドレスを持つ**のは正常な状態:

| アドレスの種類 | ソース | 用途 |
|---------------|--------|------|
| `fe80::...` | リンクローカル (自動生成) | NDP、ルーター通信 |
| `2001:db8:1::a1b2:c3d4:e5f6:7890` | SLAAC 安定アドレス (RFC 7217) | サーバー公開、着信接続、ログ追跡 |
| `2001:db8:1::9876:5432:1fed:cba0` | SLAAC 一時アドレス (RFC 8981) | 外向き通信 (ブラウジング等) |
| `2001:db8:1::100` | DHCPv6 IA_NA | 管理者が明示的に割り当てたアドレス |

これらは全て同一インターフェースに同時にバインドされ、ソースアドレス選択アルゴリズム (RFC 6724) に従って使い分けられる。

### 7.3 典型的なフラグ組み合わせと結果

| A | M | O | RDNSS | 結果 |
|---|---|---|-------|------|
| 1 | 0 | 0 | あり | SLAAC のみ。DNS は RDNSS から。最小構成。Android フレンドリー |
| 1 | 0 | 1 | あり | SLAAC + DHCPv6 Stateless。DNS は DHCPv6 と RDNSS の両方 |
| 1 | 1 | 1 | あり | SLAAC + DHCPv6 Stateful。最大互換性。**本プロジェクトの設定** |
| 0 | 1 | 1 | なし | DHCPv6 のみ (SLAAC なし)。IPv4 DHCP に最も近い構成。Android 非対応 |
| 1 | 1 | 1 | なし | SLAAC + DHCPv6 Stateful。Android は SLAAC アドレスを取得するが DNS 解決不可 |

---

## 8. OS ごとの RA フラグ対応の違い

IPv6 アドレス割り当ての最大の運用課題は、OS ごとに RA フラグの解釈と DHCPv6 の実装が大きく異なることにある。

### 8.1 Windows (10 / 11)

- **SLAAC**: A=1 なら常に SLAAC アドレスを生成
- **M flag**: 正しく Honor する。M=1 で DHCPv6 IA_NA を開始し、DHCPv6 経由のアドレスを取得
- **O flag**: 正しく Honor する。O=1 で DHCPv6 Stateless (Information-Request) を開始
- **RDNSS**: Windows 10 1709 (Fall Creators Update) 以降で対応。それ以前は RDNSS を無視するため DHCPv6 での DNS 配布が必須だった
- **一時アドレス**: デフォルト有効。`netsh interface ipv6 set privacy state=disabled` で無効化可能
- **DHCPv6 PD**: クライアントとしては非対応 (ルーター機能ではないため)
- **特記事項**: M=0, O=0 でも DHCPv6 SOLICIT を送信する実装がある (Windows の「積極的」な挙動)。ただし、サーバーが応答しなければ SLAAC のみで動作する

### 8.2 Linux

- **SLAAC**: カーネルレベルで実装。A=1 なら SLAAC アドレスを生成
- **M flag / O flag**: カーネルの `accept_ra` sysctl と NetworkManager/systemd-networkd の設定の組み合わせで動作が決まる
  - `accept_ra = 1`: RA を受け入れるが、DHCPv6 を自動起動するかはユーザースペースデーモンの設定次第
  - NetworkManager: `ipv6.method=auto` で SLAAC + DHCPv6 (M/O flag に従う)
  - systemd-networkd: `[Network] DHCP=yes` または `DHCPv6=yes` で DHCPv6 有効化
- **RDNSS**: カーネルレベルでは対応しない。NetworkManager や systemd-resolved が処理
- **一時アドレス**: `use_tempaddr` sysctl で制御 (0=無効, 1=生成するが優先しない, 2=生成して優先)
- **DHCPv6 クライアント実装**: dhclient, dhcpcd, systemd-networkd (内蔵) のいずれかを使用
- **特記事項**: Linux は最も柔軟だが、ディストリビューション・設定の組み合わせにより挙動が大きく変わる。デフォルト設定では M flag を見て自動的に DHCPv6 を起動しないディストリビューションもある

### 8.3 macOS

- **SLAAC**: A=1 で常に SLAAC アドレスを生成
- **M flag**: 有線接続では Honor する。Wi-Fi では挙動が一貫しないという報告がある
  - macOS 10.15 以降では改善されているが、Wi-Fi での DHCPv6 IA_NA の挙動は環境依存
  - DHCPv6 IA_NA で取得したアドレスより SLAAC アドレスが優先される場合がある
- **O flag**: Honor する。DHCPv6 Stateless で DNS 等を取得
- **RDNSS**: 対応
- **一時アドレス**: デフォルト有効
- **特記事項**: macOS は SLAAC を強く優先する傾向がある。DHCPv6 でアドレスを取得しても、ソースアドレス選択で SLAAC アドレスが使われることが多い

### 8.4 iOS / iPadOS

- **SLAAC**: A=1 で SLAAC アドレスを生成。MAC アドレスランダム化と組み合わせて使用
- **M flag**: Honor しない (DHCPv6 IA_NA 非対応)。M=1 であっても DHCPv6 でアドレスを取得しない
- **O flag**: 部分的に対応。DHCPv6 Stateless で DNS 情報を取得する場合がある
- **RDNSS**: 対応。iOS の主要な DNS 設定方式
- **一時アドレス**: 有効。さらに MAC アドレスランダム化 (Private Wi-Fi Address) により、ネットワーク接続ごとに異なるリンクローカルアドレスが生成される
- **特記事項**: iOS は SLAAC + RDNSS の構成でのみ完全に動作する。DHCPv6 に依存する設計では iOS/iPadOS はアドレスを取得できない

### 8.5 Android

- **SLAAC**: A=1 で SLAAC アドレスを生成
- **M flag**: 完全に無視する。Android は DHCPv6 クライアントを実装していない。M=1 であっても DHCPv6 SOLICIT を送信しない
- **O flag**: 完全に無視する。DHCPv6 Stateless (Information-Request) も送信しない
- **RDNSS**: 対応。**Android で DNS 情報を配布する唯一の方法**
- **一時アドレス**: 有効。RFC 7217 ベースの安定アドレスと一時アドレスの両方を生成
- **MAC アドレスランダム化**: Android 10 以降でデフォルト有効 (ネットワークごとにランダム MAC)
- **特記事項**: Google は意図的に DHCPv6 を実装していない。理由として以下を挙げている:
  - SLAAC で十分にアドレスを取得できる
  - DHCPv6 はプライバシーリスクがある (DUID による追跡)
  - NAT64/DNS64 環境での IPv4-only アプリの互換性を SLAAC ベースで確保
  - **結果として、Android をサポートするネットワークでは SLAAC (A=1) + RDNSS が必須**

### 8.6 OS 対応まとめ

| 機能 | Windows | Linux | macOS | iOS | Android |
|------|---------|-------|-------|-----|---------|
| SLAAC (A=1) | 対応 | 対応 | 対応 | 対応 | 対応 |
| DHCPv6 IA_NA (M=1) | 対応 | 設定依存 | 有線:対応 / Wi-Fi:不安定 | 非対応 | 非対応 |
| DHCPv6 Stateless (O=1) | 対応 | 設定依存 | 対応 | 部分対応 | 非対応 |
| RDNSS (RFC 8106) | 対応 (1709+) | 対応 (NM/resolved) | 対応 | 対応 | 対応 |
| 一時アドレス (RFC 8981) | 有効 | 設定依存 | 有効 | 有効 | 有効 |
| RFC 7217 安定アドレス | 有効 | 設定依存 | 有効 | 有効 | 有効 |

---

## 9. 本プロジェクトへの適用 (BwAI ネットワーク)

architecture.md の設計で RA フラグを `A=1, M=1, O=1, RDNSS 設定` としている理由:

| 設定 | 目的 |
|------|------|
| A=1 | iOS/Android が SLAAC でアドレスを取得できるようにする |
| M=1 | Windows/macOS が DHCPv6 IA_NA でもアドレスを取得できるようにする。forensic log に DHCPv6 リース記録が残り、法執行機関対応に有利 |
| O=1 | M=1 のため暗黙的に有効。DHCPv6 経由で DNS 等の設定情報を配布 |
| RDNSS | Android が DNS サーバー情報を取得する唯一の方法。設定しないと Android は名前解決不可 |

この構成により:
- **Android**: SLAAC でアドレスを取得、RDNSS で DNS を取得 (DHCPv6 は完全に無視)
- **iOS**: SLAAC でアドレスを取得、RDNSS で DNS を取得
- **Windows**: SLAAC と DHCPv6 IA_NA の両方でアドレスを取得、DHCPv6 で DNS を取得
- **macOS**: SLAAC でアドレスを取得 (DHCPv6 アドレスも取得する可能性あり)、DHCPv6 + RDNSS で DNS を取得

全 OS がアドレスと DNS の両方を正常に取得できる、最大互換性の構成となっている。

---

## 参考 RFC 一覧

| RFC | タイトル | 内容 |
|-----|---------|------|
| RFC 4861 | Neighbor Discovery for IPv6 | NDP、RS/RA、NS/NA の基本仕様 |
| RFC 4862 | IPv6 Stateless Address Autoconfiguration | SLAAC の仕様 |
| RFC 4291 | IP Version 6 Addressing Architecture | IPv6 アドレス体系 (EUI-64 含む) |
| RFC 4941 | Privacy Extensions for SLAAC | 一時アドレス (旧版、RFC 8981 で更新) |
| RFC 7217 | A Method for Generating Semantically Opaque Interface Identifiers | 安定プライバシーアドレス |
| RFC 7527 | Enhanced Duplicate Address Detection | DAD の改良 |
| RFC 8064 | Recommendation on Stable Interface Identifiers | RFC 7217 の使用を推奨 |
| RFC 8106 | IPv6 Router Advertisement Options for DNS Configuration | RDNSS/DNSSL |
| RFC 8415 | Dynamic Host Configuration Protocol for IPv6 (DHCPv6) | DHCPv6 統合仕様 (RFC 3315/3633 等を統合) |
| RFC 8981 | Temporary Address Extensions for SLAAC | 一時アドレス (RFC 4941 の後継) |
| RFC 6724 | Default Address Selection for IPv6 | ソースアドレス選択アルゴリズム |
| RFC 6177 | IPv6 Address Assignment to End Sites | エンドサイトへのプレフィックス割り当て推奨 |
| RFC 9762 | Prefix Delegation and PIO Flags | RA での PD サポート通知 (P flag) |
