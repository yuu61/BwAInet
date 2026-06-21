# MLD Snooping と RFC 4541 準拠: バージョン別コマンドと判断指針

会場スイッチの IPv6 マルチキャスト (RA / NS) が古いスイッチで drop される問題 ([incident-2026-04-19](./incident-2026-04-19-ipv6-mld-snooping.md)) を踏まえ、MLD snooping の **RFC 4541 §3 準拠の実態**、**バージョン別コマンド (確定)**、**どのスイッチで無効化すべきかの判断指針** をまとめる。

> **一行結論**: 正しく実装されたスイッチは MLD snooping を有効のまま `ff02::1` を素通しする (RFC 4541 §3)。`no ipv6 mld snooping` は **§3 を守らない壊れたスイッチに対する回避策** であって、RA を通すための一般的な必須操作ではない。

---

## 1. RFC 4541 §3 が実際に規定すること

**RFC 4541** "Considerations for Internet Group Management Protocol (IGMP) and Multicast Listener Discovery (MLD) Snooping Switches" (2006-05, Informational)。IGMP は §2.1.2、IPv6/MLD は **§3**。

原文で例外扱い (常時 flood) を **名指し** しているのは以下のみ:

| スコープ / アドレス | RFC 4541 の規定 | 原文 |
|---|---|---|
| IPv6 `ff02::1` (all-nodes) | snooping に関係なく **全ポートへ flood** | "The only exception is the address FF02::1 ... for which MLD messages are never sent. Packets with the all hosts link-scope address **should be forwarded on all ports**." (§3) |
| IPv6 `ff00::/15` (reserved + node-local) | リンク上に出現すべきでない | "These addresses should never appear in packets on the link." (§3) |
| IPv4 `224.0.0.0/24` (非 IGMP) | **全ポートへ転送** | "Packets with a destination IP (DIP) address in the 224.0.0.X range which are not IGMP must be forwarded on all ports." (§2.1.2 Rule 2) |

**重要な限界**: RFC 4541 §3 は **`ff02::1` のみ** を名指しで例外化しており、**solicited-node マルチキャスト (`ff02::1:ffXX:XXXX`) や `ff02::/16` スコープ全体を一括で pruning 対象外にするとは書いていない**。

> インシデント文書 (一次原因) の「link-local scope (`ff02::/16`) を MLD snooping の対象から除外することが推奨」という記述は §3 を一般化しすぎ。正確には「§3 が常時 flood を義務づけるのは `ff02::1` のみ。solicited-node は RFC 上の明示例外ではなく実装依存」。

### 2 つの故障モードへの対応

| 故障 | 宛先 | RFC 4541 §3 | 解釈 |
|---|---|---|---|
| RA drop (GUA 付かない) | `ff02::1` (all-nodes) | **明示的に「全ポートへ flood せよ」** | 古い OS がこれを守らず prune = 明確な §3 違反 |
| NS drop (GUA 付くが疎通不能) | solicited-node `ff02::1:ffXX:XXXX` | **明示的な例外規定なし** | RFC が守らない領域。MLD report 未観測の link-scope group の扱いがスイッチ実装依存 |

---

## 2. なぜ古い Catalyst だけ落とすのか (メカニズム)

Cisco の MLD snooping は次の挙動を持つ (15.x / IOS XE 16.12 / 17.x の config guide 共通記述):

> mrouter ポートが **発見される前は IPv6 マルチキャストを VLAN 全体に flood**。発見後は「unknown な」マルチキャストを **mrouter ポートにのみ** 転送する。
> ("unknown IPv6 multicast data is forwarded only to the discovered router ports; before that time, all IPv6 multicast data is flooded to the ingress VLAN")

- ホストは `ff02::1` に対して MLD report を出さない → スイッチから見て `ff02::1` は永遠に **「unknown」**。
- **準拠スイッチ** は `ff02::1` を特例として常時 flood し、この constraining を迂回する (RFC 4541 §3)。
- **非準拠スイッチ** は特例化せず、mrouter ポートが立った瞬間に `ff02::1` を mrouter 方向だけに絞る → ホストポートに RA が届かない。

### ⚠️ querier 有効化は非準拠機では逆効果

mrouter/querier が **無い間は全 flood** なので、snooping ON でも RA/NS は通る。mrouter/querier の存在が constraining を「点火」する。

→ **`venue-switch.md` §6.1 が予定する「スイッチ側で MLD querier を有効化」は、非準拠スイッチでは状況を悪化させる**。非準拠機では querier を載せない判断がありえる。準拠機 (snooping を有効運用する機) でのみ querier を検討する。

---

## 3. バージョン別コマンド (確定・裏取り済み)

**IOS 15.2 / IOS XE 16.12 / IOS XE 17.x で完全に同一**。Cisco config guide を相互照合し、コマンド・既定値・flood 挙動すべて一致を確認済み (バージョン差は無い)。

| 操作 | コマンド | モード |
|---|---|---|
| グローバル無効化 | `no ipv6 mld snooping` | `(config)#` |
| VLAN 単位で無効化 | `no ipv6 mld snooping vlan 30` / `no ipv6 mld snooping vlan 40` | **`(config)#` (グローバル) — `interface vlan` 配下ではない** |
| グローバル有効化 | `ipv6 mld snooping` | `(config)#` |
| VLAN 単位で有効化 | `ipv6 mld snooping vlan <id>` | `(config)#` |
| 確認 | `show ipv6 mld snooping` / `show ipv6 mld snooping vlan 30` | exec |
| 補助確認 | `show ipv6 mld snooping mrouter` / `... querier` / `... address [count]` | exec |

```
configure terminal
 no ipv6 mld snooping
end
show ipv6 mld snooping        ! Global MLD Snooping ... : Disabled を確認
```

注意点:
- **VLAN 単位の `no` もグローバルコンフィグから打つ**。Cisco ドキュメント本文の "...on a VLAN interface, use the `no ipv6 mld snooping vlan vlan-id` **global** configuration command" の "interface" は紛らわしいが、`interface Vlan30` 配下では入らない。
- **グローバルで `no ipv6 mld snooping` を打てば全 VLAN が自動的に無効** になる。VLAN 単位の `no` は冗長。VLAN 11 は v4 only (MLD は元々 30/40 にしか効かない) なので、**1 行のグローバル無効化で意図を満たせる**。

### 既定値 (なぜ「設定で有効化したスイッチ」だけ壊れたか)

| 項目 | 既定 |
|---|---|
| Global MLD snooping | **Disabled** |
| per-VLAN MLD snooping | Enabled (ただしグローバル有効時のみ実効) |

工場出荷状態のスイッチは MLD snooping **していない**。`venue-switch.md` §6.1 / 構築チェックリストの **明示的な `ipv6 mld snooping` (グローバル) 投入が ON にした張本人**で、`no ipv6 mld snooping` はそれを打ち消す操作。

### 無効化の副作用

`no ipv6 mld snooping` = **IPv6 マルチキャストの flood-all 復活** ("When MLD snooping is disabled, all MLD queries/reports are flooded in the ingress VLAN")。RA/NS は全ポートに届くが、`venue-switch.md` §6 が狙う **ND マルチキャストによる L2MC テーブル枯渇対策を巻き戻す**。特に VLAN 40 (/22, 最大 ~1000 台) では注意。

---

## 4. 判断指針 (どのスイッチで無効化するか)

「全機で snooping 停止」ではなく、**準拠機は ON のまま、非準拠機だけ OFF**:

| 区分 | 例 | 方針 |
|---|---|---|
| 準拠機 | IOS XE 17.15 (実測 OK)、FS sw01 (要確認) | snooping **ON のまま**。L2MC を守りつつ `ff02::1` も通す (両立する) |
| 非準拠機 | IOS 15.2、古い Allied Telesis | `no ipv6 mld snooping`、もしくはファーム更新 / 準拠機への入れ替え |
| 要検証 | IOS XE 16.12 | **実機テストで要否判定** (下記) してから決める |

### IOS XE 16.12 を盲目投入しない理由

Cisco ドキュメント上、MLD snooping 章は **16.12 / 17.3 / 17.12 / 17.16 が事実上同一記述で、どの train も RFC 4541 に言及しない**。「16.12 は 17.x 寄りだから安全」とはドキュメントから**断定できない**。「17.15 が素で通った」は**実測**であってベンダー保証の準拠差ではない。

### `no ipv6 mld snooping` 以外の打ち手

1. **トリガ (mrouter/querier) を作らない** — 非準拠機に querier を載せない (§2 参照)。
2. **static mrouter / static group** — `ff02::1` はピン留め可能だが、NS の solicited-node は**ホストごとに別グループで数千**になりスケールしない。実運用解にならない。
3. **ファーム更新 / 準拠機への入れ替え** — 本筋の恒久対応。古い IOS には「snooping を残したまま link-local だけ除外する」中間ノブは **無い**。
4. **`no ipv6 mld snooping vlan 30/40`** — blast radius を絞った当日回避策。

---

## 5. 投入前の検証手順 (スイッチ 1 台ごと)

1. `show ipv6 mld snooping` で **実際に有効化されているか** を読む (既定の Disabled を仮定しない)。
2. **access ポートにクライアントを直結** し、GUA 付与 + 外部 v6 疎通を確認 (AP 経由でなく access port で。理由は [incident の「学び」](./incident-2026-04-19-ipv6-mld-snooping.md))。
3. 通らなければ `no ipv6 mld snooping` (または `vlan 30/40`)。既定 (無効) のままで通るなら不要。
4. 無効化後、再度 access port で v6 疎通を確認。

---

## 6. 出典

- Cisco Catalyst 3750-X/3560-X Software Configuration Guide, IOS 15.0(2)SE / 15.2(4)E — "Configuring (IPv6) MLD Snooping"
- Cisco IP Multicast Routing Configuration Guide, IOS XE Gibraltar 16.12.x (Catalyst 9300 / 9500) — "Configuring MLD Snooping" (17.3 / 17.12 / 17.16 と同一記述を確認)
- RFC 4541 §2.1.2, §3 (rfc-editor.org)

## 7. 関連

- [incident-2026-04-19-ipv6-mld-snooping.md](./incident-2026-04-19-ipv6-mld-snooping.md) — 本件のインシデント記録
- [switch-cli-reference.md](./switch-cli-reference.md) — マルチベンダー CLI 対比
- [../design/venue-switch.md](../design/venue-switch.md) §6 — IPv6 マルチキャスト対策の設計
