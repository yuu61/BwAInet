# インシデント記録: Wi-Fi 瞬断・ローミング失敗・AP 脱落の複合障害 (2026-04-20)

## 概要

イベント初日の運用中に、Wi-Fi 瞬断、クライアント接続失敗、AP 脱落が断続的に発生した。調査の結果、互いに関連する複数の原因 (DFS / チャネル幅 / WLC アップリンク断 / AP 世代混在 / クライアント側プロファイル残存) が重なっていることが判明した。

| 項目 | 内容 |
|---|---|
| 発生日 | 2026-04-20 (11:00 JST 以降、継続中) |
| 影響範囲 | 15 階 (NOC): 一時的な瞬断。16 階 (ap-16x 系): 断続的に長時間切断、現在 ap-161-1 (`a4:6c:2a:3c:29:84`) が Not Joined のまま |
| 影響内容 | クライアントの瞬断、DHCP/SLAAC アドレス消失、特定 PC の継続接続失敗、ローミング失敗 |
| 暫定対応 | (a) CleanAir ED-RRM 無効化、W56 (100-140) 全除外、chan-width 40MHz 化。(b) Aggressive Load Balancing (Client-Count Based) 投入。(c) WLAN 2 を WPA3 SAE から WPA2 PSK に変更 |
| 状態 | 暫定対応中。ap-161-1 の物理復旧、sw02 syslog 不到達解決、AP 世代混在の恒久方針が未実施 |

## 検知の流れ

1. **11:00 JST 以降**: WebRTC 画面共有 (vdo.ninja) 利用者から 153 系 AP 配下で瞬断の報告。
2. Loki + WLC msglog 調査でクライアント数が `ap-153-5` に集中 (不均衡) を確認。さらに DFS チャネル (W56) 使用中の CleanAir ED-RRM 強制 channel change が頻発していることを確認。
3. `show advanced 802.11a channel` で chan-width = 80MHz、同時稼働 AP が 9 台で CCI が発生しやすい状態と判明。
4. 昼休憩に DCA/TPC を強制実行して RF 再構成を実施。
5. 午後、「接続できませんでした」とのクライアント報告が NOC メンバーの別 PC / スマホから上がり、WLC msglog で Auth Flood シグネチャ発火、`MAX_EAP_RETRIES`、`SUBNET_MISMATCH` 等のエラーを確認。
6. 同時刻帯の sw01 syslog 精査で **`Gi 0/8 (T1-Trunk-WLC3504)` が 04:07:49 UTC → 04:55:39 UTC の 48 分間 DOWN** していたことを発見 → WLC と sw01/sw02 配下 AP 間の CAPWAP control 断が根本原因と判明。
7. 13:30 JST (04:30 UTC) 以降、調査対象を 16 階 AP (`ap-16x 系`) に切替。ap-161-1 が 2 度のタイムアウトで切断後、**現在も Not Joined**。ap-161-2 は 2.4GHz Radio 0 が一時 disable で assoc 拒否。
8. AP 機種を `show ap inventory all` で確認し、**AP3700 (Wave 1) 8 台は WPA3 SAE 非対応、AP3800 (Wave 2) 11 台のみ対応** という世代混在を把握。
9. 「このPCが暗号化方式が変わってるみたいな感じで蹴られている」という報告 → WLAN 側は既に WPA2 PSK only に変更済で、**クライアント (Windows) 側に古い WPA3 SAE プロファイルが残存**していることが原因と特定。

## 原因

### 一次原因: DFS / chan-width / CleanAir ED-RRM によるループ的瞬断

- 5GHz DCA で W56 (ch 100-140) を利用可能にしていたため、DFS radar イベントで 60 秒 CAC を経た強制 channel change が発生。
- chan-width 80MHz + 9 AP 同時稼働で CCI が発生し、CleanAir ED-RRM がこれをトリガーとして更なる channel change を誘発 → ループ的に瞬断が繰り返された。

### 二次原因: AP 世代混在 (WPA3 サポート差) と WLAN セキュリティ設定

- 会場 AP の内訳:
  - **AIR-AP3802I (AP3800、Wave 2)**: 11 台。ap-151, ap-153-1〜6, ap-154-2, ap-161-2, ap-161-3。**WPA3 SAE 対応 (AireOS 8.10+)**。
  - **AIR-CAP3702I (AP3700、Wave 1)**: 8 台。ap-west01, ap-163, ap-165-1〜4, ap-161-1, ap-jihanki, APb0aa.77ed.b980。**WPA3 SAE 非対応**。
- 16 階は AP3700 主体のため、WPA3 SAE で設定していた当初、この帯域でローミングしようとするクライアントは association 失敗。WPA2/WPA3 Transition Mode でも AP3700 側で capability 差で弾かれるケースあり。
- 最終的に WLAN 2 を WPA2 PSK (AKM: PSK + PSK-SHA2、PMF Optional、FT Adaptive) に統一。

### 三次原因: sw01 Gi 0/8 (WLC アップリンク) の 48 分間ダウン

- `T1-Trunk-WLC3504` が 2026-04-20 04:07:49 UTC → 04:55:39 UTC の間、リンクダウン。原因は物理的な抜け/不良、PoE 過電流、STP 問題のいずれかを疑うが未特定。
- ダウン期間中、WLC → AP への CAPWAP control が途絶し、WPA3 SAE の中央認証が失敗。AP Message Timeout で DTLS セッションが落ち、配下の全クライアントが強制切断された。
- 16 階 AP (sw02 配下) もアップリンクで sw01 を経由しているため同時に影響を受けた。

### 四次原因: クライアント側 WLAN プロファイルの残存

- WLAN 2 を WPA3 SAE から WPA2 PSK に変更した後、既接続だったクライアント (Windows 等) の WLAN プロファイルは SSID 名で cache され、旧 WPA3 SAE + PMKSA cache で association 試行を続ける。
- AP 側が reject し、Windows はこの SSID を「接続失敗」扱いにして UI 上で一覧の下位に表示する挙動となる (PC `F8:FE:5E:34:78:C6` で確認)。

## 対応経緯 (UTC、2026-04-20)

| 時刻 (UTC / JST) | 出来事 |
|---|---|
| 02:00 / 11:00 | 153 系 AP で瞬断の報告開始 (WebRTC 画面共有利用時) |
| 02:30 / 11:30 | Loki + WLC msglog で ap-153-5 へのクライアント集中と DFS チャネル変更を確認 |
| 03:00 / 12:00 | WLAN 1/2 に `config load-balancing aggressive` (Client-Count Based) 投入 + save |
| 03:30 / 12:30 | 昼休憩時、RRM 強制実行。CleanAir ED-RRM 無効化、W56 (100-140) 全除外、chan-width 40MHz 化 |
| 03:40 / 12:40 | DCA 規定サイクル (10 分) 後、ap-153-3/4/5 の W56 残留解消を確認 |
| 04:07:49 / 13:07 | sw01 `Gi 0/8 (T1-Trunk-WLC3504)` リンクダウン (原因未特定) |
| 04:49:22 / 13:49 | ap-161-2 AP Message Timeout (DTLS 切断) |
| 04:53:56 / 13:53 | ap-161-1 (`a4:6c:2a:64:ae:c0`) AP Message Timeout |
| 04:55:04 / 13:55 | ap-161-2 DTLS 再 establish |
| 04:55:23 / 13:55 | ap-161-2 で `Dot11Radio 0 is not Enabled` により `f2:a6:ca:8f:66:eb` の assoc を拒否 |
| 04:55:39 / 13:55 | sw01 Gi 0/8 リンク UP (自然復旧) |
| 04:57:24 / 13:57 | ap-161-1 (`192.168.11.28`) DTLS 再 establish |
| 05:01:46 / 14:01 | ap-161-1 (`a4:6c:2a:3c:29:84`) Echo Timer Expiry で削除 → **現在も Not Joined** |
| 05:30 頃 / 14:30 | 16 階 AP 調査で `show ap inventory all` から AP 世代混在を確認、WPA3 非対応 AP を特定 |
| 06:00 頃 / 15:00 | WLAN 1/2 の security が既に WPA2 PSK only (SAE disabled、PMF Optional、FT Adaptive) であることを確認。PC 側プロファイル残存が主要因と判定 |

## 残課題

- **(必須) ap-161-1 (`a4:6c:2a:3c:29:84`、192.168.11.28) 復旧** — 16 階に物理確認に行き、PoE LED、LAN リンク LED、ケーブル接続を確認。sw02 配下の該当ポート状態を `show interfaces status` / `show power inline` で特定。
- **(必須) sw02 syslog 不到達の解消** — sw02 → CT 200 (192.168.11.2) tcp 601 に設定済みだが Loki に届いていない。CT 200 で `tcpdump -i any port 601` で到達確認、sw02 で `show logging` で送信状況確認。監視盲点になっている。
- **(必須) sw01 Gi 0/8 48 分間ダウンの根本原因特定** — 明示的な shutdown ログなし。PoE 過電流・ケーブル不良・STP/Storm-Control などを順に切り分け。本来 WLC は冗長化すべきポイント。
- **(推奨) ap-161-2 の 2.4GHz Radio 0 強制 enable** — `config 802.11b enable ap-161-2`。
- **(推奨) 7 台の Not Joined AP の棚卸し** — `show ap join stats summary all` に `24:16:9d:f3:d4:60`、`f0:1d:2d:80:52:a0`、`f0:1d:2d:81:96:e0`、`f0:1d:2d:81:ea:60`、`a4:6c:2a:3c:29:84`、`f0:1d:2d:82:e2:20`、`a4:6c:2a:64:ae:c0` あり。試験機の残骸 or 本番で落ちた AP かの切り分けが必要。
- **(運用) クライアント側 WLAN プロファイル削除のアナウンス** — 「繋がらない場合は `netsh wlan delete profile name="…"` でプロファイル削除して再接続」を周知。特に 2026-04-20 時点で WPA3 SAE で一度接続したユーザーが対象。
- **(恒久) AP 世代混在方針** — 次回以降、混在させる場合は最初から WPA2 PSK (AKM: PSK + PSK-SHA2、PMF Optional、FT Adaptive) を前提設計。AP3700 (Wave 1) は WPA3 で使わない。
- **(再発防止) DFS / CleanAir ED-RRM / chan-width の会場プリセット** — W56 除外、chan-width ≤ 40MHz、ED-RRM 無効を VyOS/WLC のイベント用テンプレートとして標準化。

## 学び

- **DFS チャネル (W56) は会場で使わない** — 60 秒 CAC は無線サービス継続が必要なイベントに致命的。日本電波法上の制約と併せて事前に `channel delete` で除外する。
- **高密度環境では chan-width は 40MHz 以下** — AP 密度が高い会場で 80MHz を使うと CCI が支配的になり、CleanAir ED-RRM と共振してループ的瞬断を招く。
- **CleanAir ED-RRM は運用中は disable** — 環境変化に過剰反応して自爆するケースが多い。必要なら `show advanced 802.11a channel cleanair-event` 等でイベント監視のみ行う。
- **Cisco AP の世代差 (Wave 1 / Wave 2) による WPA3 サポート差を事前に確認する** — `show ap inventory all` で PID から Wave 1/2 を識別できる。AireOS 8.10 の WPA3 SAE は **Wave 2 以降のみ**。事前のインベントリ把握が不可欠。
- **Aironet の型番 100 番差は「性能差」ではなく「世代差」** — 今回の初期判断で 3700 と 3800 を「同じ世代の性能違い」と思い込んだが、実際には Cisco の命名規則で **1700/2700/3700 = Wave 1 (802.11ac Wave 1、MU-MIMO 非対応)**、**1800/2800/3800 = Wave 2 (802.11ac Wave 2、MU-MIMO 対応、後の AireOS で WPA3 対応)** と世代が分かれている。さらに Catalyst 9100 系が Wi-Fi 6 世代。型番末尾 (3702I / 3802I の "I") は筐体形状 (Internal antenna) を指し、性能とは別軸。**次回以降は型番の百位を世代識別子として扱い、事前仕様確認を必須化する**。
- **WLC は AP 世代差を吸収しない機能がある** — 今回「WLC がコントローラとして差分を全部吸収してくれる」という前提を置いていたが、WPA3 SAE・802.11ax・MU-MIMO などは **AP 側のハードウェア/ファーム能力に依存** し、WLC が介在しても実装されない。WLC が透過的に扱ってくれるのは `config ap …` 系の設定配布 (電源・チャネル・SSID assign 等) であって、**無線仕様そのものを AP 側でエミュレートすることはできない**。混在環境では機能の下限を Wave 1 に合わせるか、SSID を分離する必要がある。
- **WLC ↔ コアスイッチ間アップリンクは二重化必須** — 単一リンクが 48 分ダウンすると全 AP が落ちる。LACP 2 ポート以上が望ましい。
- **SSID のセキュリティ設定変更はクライアントに副作用がある** — Windows/Android のプロファイル cache は SSID 名で紐付く。PMKSA cache、AKM 違いによる association 失敗が発生するため、変更時にはユーザーへのプロファイル削除手順を用意する。
- **sw02 のような「ログが来ていないスイッチ」は監視盲点となる** — CAPWAP の挙動を追うときにポートフラップが見えないと原因特定に大きな遅延が出る。forensic ログ系統の完備と併せて、運用監視系でも全スイッチの syslog 到達をヘルスチェックするべき。
