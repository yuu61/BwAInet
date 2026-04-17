# ログ照会対応クエリ集

法執行機関からの照会に対する各種ログの検索パターン。ログ相関モデルは [`../design/logging-compliance.md`](../design/logging-compliance.md) を参照。

## NetFlow (nfdump)

```bash
# 特定 IP の全通信フロー
nfdump -R /var/log/nfcapd -o long "src ip 192.168.40.123 or dst ip 192.168.40.123"

# 特定時間帯の通信
nfdump -R /var/log/nfcapd -t 2026/08/10.14:00:00-2026/08/10.15:00:00

# 特定ポートへの通信 (例: HTTPS)
nfdump -R /var/log/nfcapd "dst port 443 and src ip 192.168.40.123"

# 通信量トップ 10 (IP 別)
nfdump -R /var/log/nfcapd -s srcip -n 10
```

## DNS クエリログ

```bash
grep "example.com" /var/log/syslog | grep "dns-forwarding"
grep "192.168.40.123" /var/log/syslog | grep "dns-forwarding"
```

## DHCP リースログ (Kea forensic)

```bash
grep "aa:bb:cc:dd:ee:ff" /var/log/kea/kea-legal*.txt
grep "192.168.40.123" /var/log/kea/kea-legal*.txt
```

## NDP ダンプ (IPv6 ↔ MAC)

```bash
grep "aa:bb:cc:dd:ee:ff" /var/log/syslog | grep "ndp-dump"
grep "2001:db8::abcd" /var/log/syslog | grep "ndp-dump"
```

## Conntrack NAT ログ

### r1 の NAPT 変換 (OPTAGE 経由)

```bash
# 内部 IP → グローバル IP:port の変換を引く
grep "conntrack-nat" /var/log/syslog | grep "src=192.168.40.123"

# 外部からの照会 (グローバル IP:port → 内部) の逆引き
grep "conntrack-nat" /var/log/syslog | grep "dport=12345"

# 特定時間帯
grep "conntrack-nat" /var/log/syslog | grep "1723286[4-5]"
```

### r2-gcp の NAT66 / v4 SNAT

```bash
# NAT66 変換 (外部 IPv6 → 会場デバイスの SLAAC)
grep "conntrack-nat" /var/log/syslog | grep "dst=2600:1900:41d0:9d:"

# v4 SNAT (GCE 内部 IP = 外部 34.97.197.104 → 会場デバイス)
grep "conntrack-nat" /var/log/syslog | grep "dst=10.174.0.7"

# 特定内部 IP の Google 向け通信
grep "conntrack-nat" /var/log/syslog | grep "src=192.168.40.123"
```

## 総合追跡テンプレート

「2026-08-10 14:30 に example.com にアクセスしたデバイスは？」

```bash
# Step 1: DNS ログから example.com を引いた client IP を特定
grep "example.com" /var/log/syslog | grep "dns-forwarding"

# Step 2: その IP の DHCP リースから MAC と hostname を特定
grep "192.168.40.123" /var/log/kea/kea-legal*.txt

# Step 3: その MAC の IPv6 アドレスも特定
grep "<mac-address>" /var/log/syslog | grep "ndp-dump"

# Step 4: 両 IP の NetFlow を取得
nfdump -R /var/log/nfcapd "src ip 192.168.40.123 or dst ip 192.168.40.123"

# Step 5: NAPT 変換マッピングを取得
grep "conntrack-nat" /var/log/syslog | grep "src=192.168.40.123"
```

## 読み方メモ

### Conntrack の tuple

```
[NEW] tcp 6 120 SYN_SENT src=192.168.40.123 dst=93.184.216.34 sport=54321 dport=443 [UNREPLIED] src=93.184.216.34 dst=<pppoe0-ip> sport=443 dport=12345
```

- **original tuple**: `src=192.168.40.123 sport=54321` → 内部クライアント
- **reply tuple**: `dst=<pppoe0-ip> dport=12345` → NAT 後のグローバル IP:port
- NEW → セッション確立、DESTROY → セッション終了

### NAT66 の IID 保持

r2-gcp の `snat prefix to /96` により元の IID 下位 32bit が変換先でも保持される。外部から `dst=2600:1900:41d0:9d::ae8a:591f` で戻ってきたパケットの IID 下位 32bit (`ae8a:591f`) がそのまま会場デバイスの SLAAC アドレスの IID として一致する。衝突は SLAAC ランダム IID のため会場規模では事実上発生しないが、完全保証ではないため conntrack ログを併用する。

## 関連

- [`../design/logging-compliance.md`](../design/logging-compliance.md) — ログ相関モデル、記録対象
- [`log-sealing.md`](log-sealing.md) — 封印・GCS 転送手順
- [`../policy/logging-policy.md`](../policy/logging-policy.md) — 記録ポリシー
