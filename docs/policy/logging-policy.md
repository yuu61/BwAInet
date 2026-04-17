# 通信ログ保存ポリシー (法執行機関対応)

法執行機関からの照会に対し、通信記録を適切に提出できる体制の基本方針。実装詳細は [`../design/logging-compliance.md`](../design/logging-compliance.md)、運用手順は [`../operations/log-sealing.md`](../operations/log-sealing.md) を参照。

## 基本方針

- IP ペイロード (通信内容) は**記録しない**
- 通信メタデータ (誰が・いつ・どこと) のみを記録
- 全ログを相互に紐付けて追跡可能にする
- **保存期間: 180 日**
- 利用規約 (AUP) で通信記録の取得を告知し、公序良俗に反する通信を禁止する

## 利用規約 (AUP)

会場掲示・配布用の本文は [`aup.md`](aup.md) に分離。本ポリシーは AUP に基づく記録の方針を規定する。

## 記録対象と非記録対象

| 記録する | 記録しない |
|---|---|
| 5-tuple (src/dst IP, src/dst port, protocol) | IP ペイロード (通信内容) |
| タイムスタンプ, バイト数, パケット数 | HTTP URL / ヘッダ / ボディ |
| DNS クエリ名 (qname) + 応答コード | DNS 応答レコード値 |
| DHCP リース (IP ↔ MAC ↔ hostname) | ユーザー個人の認証情報 |
| NDP テーブル (IPv6 ↔ MAC) | |
| NAPT 変換マッピング (内部 IP:port ↔ グローバル IP:port) | |
| NAT66 変換マッピング (GCP /64 SLAAC ↔ r2-gcp /96) | |
| v4 SNAT 変換マッピング (内部 IP:port ↔ GCE IP:port) | |

## ランダム MAC アドレスへの対応方針

iOS 14+ / Android 10+ / Windows 11 / macOS 15 はデフォルトでランダム MAC を使用するが、**per-SSID 固定** (同一 SSID 接続中は同じランダム MAC 維持) であるため、イベント期間中のログ相関には影響しない。

人物特定については:

- DHCP hostname ("〇〇のiPhone" 等) + ランダム MAC + IP + 通信時刻を記録として保持
- それ以上の人物特定 (ランダム MAC → 物理デバイス → 所有者) が必要な場合は**捜査機関側の権限で対応**
- 参加者はエンジニアが中心でリテラシーが高いため、Captive Portal / 802.1X による本人確認は行わない

Cisco AireOS 8.10 の LAA Mac Denial 機能は iOS/Android の大半をブロックするため**使用しない**。

## 保存期間と保存先

| ログ種別 | ローカル (local-server CT, NVMe #2) | GCS (`bwai-forensic-2026`) |
|---|---|---|
| NetFlow (nfcapd) | イベント期間中のみ | **180 日 (WORM)** |
| DNS クエリログ | イベント期間中のみ | **180 日 (WORM)** |
| DHCP forensic log | イベント期間中のみ | **180 日 (WORM)** |
| NDP テーブルダンプ | イベント期間中のみ | **180 日 (WORM)** |
| Conntrack NAT ログ (r1) | イベント期間中のみ | **180 日 (WORM)** |
| Conntrack NAT ログ (r2-gcp) | イベント期間中のみ | **180 日 (WORM)** |

venue Proxmox (MS-01) は借用機のため、イベント終了後に自宅ラボへ搬送し、**GCS 転送完了を確認してから**初期化・返送する。長期保管は GCS で行う。

## 正当性証明の三層構造

| 層 | 手法 | 証明できること |
|---|---|---|
| 1. 人的証人 | SHA-256 ハッシュを複数 NOC メンバーが独立保存 | 封印時点のハッシュが合意されていたこと |
| 2. 第三者証明 | RFC 3161 TSA タイムスタンプ | 封印ファイルが特定時刻に存在し、以降改変されていないこと |
| 3. 物理的保護 | GCS Retention Policy (ロック済み) | ログ本体が保持期間中に削除・改変されていないこと |

## DHCPv6 廃止の方針的根拠

DHCPv6 サーバーは廃止し、IPv6 アドレス割り当ては SLAAC に一本化した。

1. **iOS/Android が DHCPv6 IA_NA 非対応** — モバイルデバイスが DHCPv6 でアドレスを取得できない
2. **RFC 6724 によるソースアドレス選択が OS 依存** — DHCPv6 アドレスが PBR に使われる保証なし
3. **MAC ↔ IPv6 追跡は NDP テーブルダンプでカバー済み**

| OS | DHCPv6 IA_NA | SLAAC | RDNSS |
|---|---|---|---|
| Windows 11 | 対応 | 対応 | 対応 |
| macOS 15 | 対応 | 対応 | 対応 |
| iOS 18 | **非対応** | 対応 | 対応 |
| Android 15 | **非対応** | 対応 | 対応 (必須) |

## 関連

- [`aup.md`](aup.md) — 利用規約 (会場掲示・配布用)
- [`../design/logging-compliance.md`](../design/logging-compliance.md) — ログ相関モデル、収集実装
- [`../operations/log-sealing.md`](../operations/log-sealing.md) — 封印・GCS WORM 手順
- [`../operations/log-query-cookbook.md`](../operations/log-query-cookbook.md) — 照会対応クエリ例
- [`gcp-tos-compliance.md`](gcp-tos-compliance.md) — GCP 利用規約該当性
