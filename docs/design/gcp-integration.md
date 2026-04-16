# GCP 連携強化設計

## 背景

現状の GCP 活用は以下の 2 点に留まっている:

| 機能 | 内容 |
|------|------|
| r2-gcp (トランジット) | WireGuard mesh + BGP でフォールバック経路 |
| GCS ログ保存 | local-server (CT 200) から GCS に直送 (curl raw REST API + `ifGenerationMatch=0`)、180 日保持、SA は `objectCreator` のみ |

経路冗長化とログアーカイブのみで、GCP の活用としては薄い。Google グローバルの DevRel Central からカメラクルー・GDE 等の大物ゲストが来場する規模のイベントとして、GCP との機能連携を強化し、ネットワーク運用の質とデモ価値を高めたい。

ハンズオンセッション等で GCP 向けトラフィックが多いことが予想されるため、r2-gcp を活用した **GCP トラフィック最適化を最優先**で設計する。

---

## 1. GCP トラフィック最適化

GCP 向けトラフィックを r2-gcp (GCE 大阪) 経由で Google 内部ネットワークに直接流し、自宅回線 (OPTAGE) の負荷を軽減する。

- **IPv4**: r2-gcp が Google IP レンジ (`goog.json`) を BGP で広告、宛先ベースで最適化、r2-gcp で SNAT
- **IPv6**: OPTAGE /64 に加え GCP /64 を会場で RA 広告、r3 の source-based PBR で振り分け、r2-gcp で NAT66

```
[IPv6]
会場デバイス (SLAAC: OPTAGE GUA + GCP GUA)
  │
  ▼
r3 (PBR: src prefix で振り分け)
  ├── src = OPTAGE /64 → wg0 → r1 → OPTAGE → Internet
  └── src = GCP /64    → wg1 → r2-gcp → NAT66 → Google backbone → GCP / Internet

[IPv4]
r3 (BGP: dst で振り分け)
  ├── dst = Google IP (goog.json) → wg1 → r2-gcp → SNAT → Google backbone
  └── dst = その他                → wg0 → r1 → OPTAGE → Internet
```

## 2. GCP IPv6 制約と NAT66 採用

GCP データプレーンはサブネット /64 内で VM の /96 に割り当てられていないアドレス宛パケットを drop する。会場デバイスの SLAAC アドレスは r2-gcp の /96 外のため戻りパケットが drop される。

### 回避策は全て不適合

Alias IP, NCC, Hybrid Subnet, HA VPN 等を検討したがいずれも IPv4 限定または drop 制約を回避できない。詳細は [`../investigation/gcp-v6-prefix-constraint.md`](../investigation/gcp-v6-prefix-constraint.md) を参照。

### NAT66 による解決

r2-gcp で `snat prefix to /96` を行い、会場デバイスの src アドレスを r2-gcp の /96 アドレス範囲に変換する。IID 下位 32bit を保持するため、外部から見てもデバイスごとにほぼ一意のアドレスとなる。戻りパケットは r2-gcp の /96 宛で届き GCP が正しくルーティングする。

## 3. 期待されるメリット

| 項目 | 現状 (全て r1 経由) | 最適化後 |
|------|-------------------|---------|
| GCP 向け v4 経路 | WG → OPTAGE → 公衆 Internet → GCP | WG → GCE → SNAT → Google 内部 NW |
| GCP 向け v6 経路 | WG → OPTAGE → Internet → GCP | WG → GCE → NAT66 → Google 内部 NW |
| 自宅回線負荷 | 全トラフィックを消費 | GCP 向けをオフロード |
| r1 障害耐性 | r1 断 = 全断 | **r1 断でも GCP 向け通信は継続** |

## 4. デュアルプレフィックス RA 設計

NAT66 が必要ではあるが、デュアルプレフィックス RA は**経路分離と耐障害性のために維持する**。

### アドレス体系

| プレフィックス | 取得元 | 経路 | NAT | 用途 |
|--------------|--------|------|-----|------|
| OPTAGE /64 | DHCPv6-PD (r1 経由) | wg0 → r1 → OPTAGE | なし | 一般 Internet |
| GCP /64 | GCP VPC external IPv6 | wg1 → r2-gcp → Google | NAT66 | GCP + Google backbone 経由 |

### preferred-lifetime によるバイアス

GCP /64 の preferred-lifetime を短く (1800s) 設定し、OPTAGE /64 を長く (14400s) することで OS の RFC 6724 選択で OPTAGE を優先させる。GCE egress 課金の最適化が目的。

### RFC 8028 問題への対応

マルチプレフィックス環境のゲートウェイ紐付け未保証問題については、本設計では r3 が唯一のゲートウェイであり PBR で src prefix を見て振り分けるため、クライアント側の source address selection に依存しない。

## 5. GCP インフラ構成

### サブネット構成

| サブネット | IPv4 | IPv6 | 用途 |
|-----------|------|------|------|
| default (既存) | 10.174.0.0/20 | `2600:1900:41d0:9d::/64` (external) | r2-gcp 配置、NAT66 src |
| venue-v6-transit (新規) | 10.174.16.0/24 | `2600:1900:41d1:92::/64` (external) | 会場 RA 広告用 (VM なし) |

venue-v6-transit の /64 は会場で RA 広告されるが、Internet からこの /64 宛の戻りパケットは r2-gcp の NAT66 conntrack 経由で処理される (r2-gcp /96 宛として到着)。サブネット自体にパケットが到達する必要はない。

### r2-gcp インスタンス

| 項目 | 値 |
|------|-----|
| GCP プロジェクト | bwai-noc |
| ゾーン | asia-northeast2-a (大阪) |
| マシンタイプ | e2-small (イベント期間中、通常は e2-micro) |
| VyOS | 2026.03 Stream (自前 GCE イメージ) |
| 内部 IP | 10.174.0.7 |
| 外部 IP | 34.97.197.104 (予約 static) |
| AS | 64512 |

GCE イメージは VyOS Stream ISO から自前で raw ディスクに変換し GCS 経由で GCE カスタムイメージとして登録 (マーケットプレイス版 ~$100/月を回避)。

## 6. WireGuard メッシュと IPv6 拡張

### トポロジ

```
r1-home (AS65002)        r2-gcp (AS64512)        r3-venue (AS65001)
  wg0 ◄══════════════════════════════════════════► wg0   ← 直接 (優先)
  wg1 ◄════► wg1                        wg2 ◄════► wg1   ← GCP 経由 (フォールバック)
```

### P2P リンクアドレス (v4 + ULA v6)

| トンネル | IPv4 | IPv6 (ULA) |
|---------|------|-------------|
| r1 ↔ r3 | 10.255.0.1/30 ↔ .2 | fd00:255:0::1/126 ↔ ::2 |
| r1 ↔ r2-gcp | 10.255.1.1/30 ↔ .2 | fd00:255:1::1/126 ↔ ::2 |
| r3 ↔ r2-gcp | 10.255.2.1/30 ↔ .2 | fd00:255:2::1/126 ↔ ::2 |

r2-gcp 側は 1 ホストに r1 向け (wg1) / r3 向け (wg2) の 2 本を同居。listen port r2-gcp:wg1=51820, r2-gcp:wg2=51821。

BGP フェイルオーバー (r3 直結断 → r1 経由迂回、r1 直結断 → r3 経由迂回) に備え、各 peer に対向側のプレフィックスも allowed-ips に追加する。

## 7. r3 側 (会場 VyOS) の主要設定

- eth2.30/40 に GCP /64 アドレスを付与 (DNS listen と NDP 解決に必要)
- デュアルプレフィックス RA (OPTAGE + GCP)
- DNS: unbound の listen-address に v6 追加 (両プレフィックス対応)
- source-based PBR (local-route6): GCP /64 src → wg1 (r2-gcp)
- ndppd 更新: OPTAGE (wg0) + GCP (wg1) の両方に proxy ルール

詳細は [`venue-vyos.md`](venue-vyos.md) および [`../configs/r3-venue.conf`](../configs/r3-venue.conf) を参照。

## 8. r2-gcp 側 (GCE VyOS) の主要設定

### Fallback default route (r1 完全断対策)

```
set protocols static route 0.0.0.0/0 next-hop 10.174.0.1 distance 210
```

r1 死時は BGP default が消えるため、**distance 210 の static default が自動昇格**して VPC 経由で外部到達を継続する。平常時は BGP (distance 20) が best で FIB に入るので経路選択に影響なし。2026-04-15 のカオステストで r1 完全死時の疎通継続 (3 パケットロス/600) を実測。

### BGP import フィルタ (DENY-DEFAULT / DENY-DEFAULT-V6)

r1-home から `default-originate` で流れてくる `0.0.0.0/0` / `::/0` を r2-gcp が受け入れると、GCP の static default (AD210) が BGP default (AD20) に負けて r2 の全アウトバウンドが wg 経由に吸い込まれる。**全 neighbor の import で default route を拒否**する。

### NAT66 と v4 NAPT

- **NAT66**: 会場 GCP /64 src → r2-gcp /96 `snat prefix to` (nftables)、IID 下位 32bit 保持
- **v4 NAPT (MASQUERADE)**: 会場サブネット src + WG transfer (10.255.0.0/16) → GCE 内部 IP (`10.174.0.7`) にポート変換付き多対一変換。GCP 側で 1:1 NAT により外部 IP (`34.97.197.104`) へ

### Conntrack イベントログ (法執行対応)

r2-gcp でも NAT 変換マッピングを記録する。`conntrack -E` で v4 NAPT と v6 NAT66 の両方を syslog に出力:

- programname `conntrack-nat` (v4 NEW/DESTROY)、programname `conntrack-nat6` (v6 NEW/DESTROY)
- facility local2、送信先は local-server (192.168.11.2:514 TCP) — wg1 経由で到達
- 実装: `/etc/systemd/system/conntrack-logger.service` + `/usr/local/sbin/r2-conntrack-logger.sh`
- リポジトリ内: `scripts/r2-gcp/conntrack-logger.sh`、`scripts/vyos-common/conntrack-logger.service`

全体設計は [`logging-compliance.md`](logging-compliance.md) §4 参照。

### Syslog / TZ

- `system syslog remote 192.168.11.2 facility all level info protocol tcp port 514` (wg1 経由)
- `system time-zone UTC` — 全機器 UTC 統一

### Google IP レンジの広告方式

goog.json (94 本) の各 prefix を static route (next-hop = VPC GW `10.174.0.1`) で作成し、route-map `GOOG-OUT` で prefix-list `GOOG` に一致する static のみ BGP 広告する。実パケットは default と同じ経路で Google backbone に流れる (next-hop Null0 は FIB drop で NG)。

運用手順 (cron 更新、r1 連動、escape route) は [`../operations/goog-prefix-update.md`](../operations/goog-prefix-update.md) を参照。

### r1/r2 escape route

goog.json に r2-gcp 公開 IP (`34.97.197.104` ⊂ `34.64.0.0/10`) が含まれるため、BGP 広告後に WG 外殻パケットが wg1 に吸われてループする。r1 で `34.97.197.104/32 interface pppoe0` を static route として設定。

r2-gcp では GCE GW (10.174.0.1) への /32 host route を `dev eth0` で固定 (VyOS CLI は `onlink` 非対応のため kernel 直叩き) + r1 WAN IP (DDNS `tukushityann.net` 動的追従) の /32 escape + `policy local-route` で r2 自身 (src=10.174.0.7) を GCE GW に固定。

### sshd 修正 (起動時)

VyOS は `ssh.service` を disabled にし独自起動するが、`/run/sshd` (systemd の `ExecStartPre` で作成) が作られないため、VM 再起動後に SSH 接続の子プロセスが `Missing privilege separation directory: /run/sshd` で即死する。`/config/scripts/vyos-postconfig-bootup.script` に `mkdir -p /run/sshd` を追記して対策。

## 9. v6 で goog.json を BGP 広告しない理由

v4 は dst ベース、v6 は src ベース PBR で振り分けるため、v6 に BGP 広告を追加すると経路非対称が発生し conntrack/NAT66 state が破綻する。

v6 で確実に Google backbone 経由にしたいクライアントは GCP /64 を src に選ぶ (OS 設定や明示 bind) 必要がある。詳細は [`../investigation/asymmetric-routing-v6.md`](../investigation/asymmetric-routing-v6.md) を参照。

## 10. トラフィックフロー

### IPv6

```
[GCP prefix src]
会場デバイス (<gcp-prefix>::xxxx)
  → r3 eth2.30/40 → PBR → table 100 → wg1 → r2-gcp
    → NAT66: src → r2-gcp /96
      → eth0 → Google backbone → GCP / Internet

[OPTAGE prefix src]
会場デバイス (<optage-prefix>::xxxx)
  → r3 → デフォルトルート → wg0 → r1 → pppoe0 → OPTAGE → Internet (NAT なし, E2E)
```

### IPv4

```
[Google 宛 (goog.json)]
会場デバイス → r3 (BGP longest-match → GOOG prefix) → wg1 → r2-gcp (SNAT) → Google backbone

[その他]
会場デバイス → r3 (デフォルト) → wg0 → r1 → OPTAGE → Internet

[r1 完全断時のフォールバック]
会場デバイス → r3 → wg2 → r2-gcp (BGP default 消失 → static default 昇格)
  → eth0 → VPC → GCE 1:1 NAT (34.97.197.104) → Internet
```

### 2 段 NAT 構成 (r2 経由外部出口)

| 段 | 実施場所 | 変換 |
|---|---|---|
| 1 段目 (NAPT) | r2 VyOS `nat source rule 10/20` (masquerade) | src 192.168.0.0/16 / 10.255.0.0/16 → r2 eth0 内部 IP `10.174.0.7` |
| 2 段目 (1:1 NAT) | GCE VPC (透過) | `10.174.0.7` → External IP `34.97.197.104` |

r2 には External IP が直接割り当て済 (Cloud NAT ではなく GCE 1:1 NAT)。

## 11. 障害時の動作

| 障害 | OPTAGE src (v6) | GCP src (v6) | v4 GCP 向け | v4 非 Google 宛 |
|------|----------------|-------------|-------------|----------------|
| r1 正常 | wg0 → r1 ✓ | wg1 → r2-gcp ✓ | wg1 → r2-gcp ✓ | wg0 → r1 → OPTAGE ✓ |
| **wg0 単独断** (r1 生存) | **src 維持継続** ✓ (r3→wg1→r2→wg1→r1→pppoe0、loss ~0.5s) | **継続** ✓ | **継続** ✓ | r2 経由 VPC 出口に切替 ✓ (~0.4s) |
| **wg1 単独断** (r2 生存) | **継続** ✓ | **src 維持継続** ✓ (r3→wg0→r1→wg1→r2→NAT66、loss ~0.5s) | **継続** ✓ | **継続** ✓ |
| **r1 完全断** | **~6s で OPTAGE RA deprecate** → クライアント GCP src へ切替 | **継続** ✓ (loss 0%) | **継続** ✓ | r2 static fallback → VPC 経由 ✓ (~0.6s) |
| **r2 完全断** | **継続** ✓ | **~6s で GCP RA deprecate** → クライアント OPTAGE src へ切替 | v4 デフォルト経由で継続 ✓ | **継続** ✓ |

**v6 src 維持 3 拠点抜け** = 各拠点の `policy route6` (PBR) + static fallback (distance 210) + BGP 冗長 (BFD 0.4s) で実現。  
**v6 完全死時の自動切替** = `v6-route-watcher.sh` + `v6-health-monitor.sh --force-verify` で probe FAIL → RA preferred-lifetime=0。  
**v4 fast failover** = BFD profile FAST + BGP timers 3/9 + r2 static fallback default の組合せ。

## 12. 監視項目 (追加)

| 項目 | 方式 | 目的 |
|------|------|------|
| GCP /64 RA 到達確認 | r2-gcp → `<gcp-prefix>` 疎通チェック | RA 広告が正常か |
| PBR 動作確認 | r3 NetFlow で src prefix 別のトラフィック量 | 振り分けが想定通りか |
| GCE egress 量 | GCP Console / Cloud Monitoring | コスト監視 |
| wg1 スループット | r2-gcp iperf3 定期計測 | GCP 経路の品質 |

## 13. 確認事項とフォールバック

- **GCP 利用規約の該当性確認**: 実装前に Google 担当者に確認必須。分析は [`../policy/gcp-tos-compliance.md`](../policy/gcp-tos-compliance.md) を参照
- **コスト試算**: [`../investigation/gcp-cost-estimation.md`](../investigation/gcp-cost-estimation.md) (イベント期間 $15–40 程度)
- **NG 時フォールバック**: GCP トラフィック最適化を無効化し、r2-gcp は BGP フォールバック + ログ転送のみに留める

## その他の GCP 連携強化候補

BigQuery ストリーミング、Cloud Monitoring 外部監視、リアルタイムダッシュボード、Gemini 自然言語クエリ等の検討候補は [`../investigation/gcp-future-enhancements.md`](../investigation/gcp-future-enhancements.md) を参照。
