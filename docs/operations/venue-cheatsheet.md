# 会場下見・本番投入 チートシート

会場下見および本番投入時に、**ラップトップ (Windows 11 + Docker Desktop)** と **r3 VyOS** で叩くコマンドを時系列フロー順にまとめたもの。上から順に読めば現地で迷わない構成。

---

## 0. 接続情報 (共通)

| 項目 | 値 |
|---|---|
| 自宅 WAN FQDN | `tukushityann.net` (DDNS) |
| 自宅 WAN 実 IP | `101.143.12.214` (DDNS 障害時のフォールバック) |
| 自宅 r1 (LAN) | `192.168.10.1` |
| 自宅 wstunnel-server | `192.168.10.4:443` (r1 DNAT rule 30 経由で到達) |
| 自宅 r1 WireGuard | `192.168.10.1:51820` (wstunnel の UDP 転送先) |
| r3 mgmt IP | `192.168.11.1` |
| r3 API base URL | `https://192.168.11.1` |
| **VyOS API キー (r1/r3 共通)** | **`BwAI`** |
| SSH ユーザー | `vyos` |
| ラップトップ wstunnel-client コンテナ | `wstunnel-client` (127.0.0.1:51821/udp で listen) |

### r3 への到達手段

- **mgmt VLAN 直結** (推奨): ラップトップを r3 の mgmt ポートに挿して `192.168.11.0/24` からアクセス
- **SSH**: `ssh vyos@192.168.11.1`
- **API**: ラップトップから `curl` (セクション 12 参照)

---

## 1. 出発前チェック (自宅で、モバイル回線経由)

**必ず Wi-Fi を切ってモバイル回線/テザリングに切り替えてから実行**。自宅 LAN からだと hairpin NAT が効かず r1 VyOS の nginx (403) が返ってしまうため、本番経路の事前確認にならない。

```powershell
# 自宅 wstunnel-server 生存確認 (期待: HTTP 400 + Invalid request)
curl -k -v --max-time 10 https://tukushityann.net/ 2>&1 | Select-Object -Last 15
```

**成功判定**:
```
HTTP/1.1 400 Bad Request
content-length: 15
(Server ヘッダなし)
Invalid request
```

✅ この 3 点が揃えば本番経路が生きている → 出発 OK。

### ラップトップ wstunnel-client コンテナの生存確認

```powershell
docker ps -a --filter name=wstunnel-client
```

停止中なら `docker start wstunnel-client`。存在しない場合はセクション 4.3 で再作成。

---

## 2. 現地到着後、ラップトップで上流到達性確認

ラップトップを会場 LAN/Wi-Fi に接続し、**まず軽量 curl** で TCP 443 が貫通するか確認:

```powershell
curl -k -v --max-time 10 https://tukushityann.net/ 2>&1 | Select-String -Pattern "HTTP/|Invalid|Server|Certificate"
```

**判定表**:

| 返り値 | 意味 | 次のアクション |
|---|---|---|
| `HTTP/1.1 400 Bad Request` + `Invalid request` + Server ヘッダ無し | ✅ **本番経路 OK** (wstunnel-server が応答) | セクション 4 で完全 E2E 確認へ |
| `403 Forbidden` + `Server: nginx` | r1 VyOS の nginx が横取り中 | 自宅 r1 の `service https listen-address` / DNAT rule 30 を確認 |
| TLS エラー / 自己署名以外の証明書 | TLS インスペクション疑い | セクション 3.2 で証明書を詳細確認 |
| 接続拒否 / タイムアウト | TCP 443 ブロック or HTTP プロキシ強制 | セクション 3 で会場ポリシー調査 |

---

## 3. 会場上流ポリシー詳細調査 (ラップトップ)

### 3.1 TCP outbound (443 / 80 両方)

```powershell
curl -k -s -o NUL -w "HTTP443 %{http_code}`n" --max-time 5 https://tukushityann.net/
curl    -s -o NUL -w "HTTP80  %{http_code}`n" --max-time 5 http://tukushityann.net/
Test-NetConnection tukushityann.net -Port 443
Test-NetConnection tukushityann.net -Port 80
```

### 3.2 TLS インスペクション有無 (中間で証明書差し替え)

```powershell
curl -k -v --max-time 5 https://tukushityann.net/ 2>&1 | Select-String -Pattern "subject|issuer|Certificate"
```

- **wstunnel の自己署名 (Certificate が 299 バイト前後、subject/issuer が同じ)** → 干渉なし
- **正規 CA 発行の証明書 (777 バイト前後、nginx/squid/ZScaler 等の issuer)** → TLS インスペクション中 → wstunnel 機能不可

### 3.3 IPv6 到達性

```powershell
Test-NetConnection 2001:4860:4860::8888 -Port 443
ipconfig | Select-String "IPv6"
```

### 3.4 DNS 強制の有無

```powershell
nslookup tukushityann.net
nslookup tukushityann.net 8.8.8.8
```

両者が一致しない or 8.8.8.8 に届かなければ **DNS 強制あり**。

### 3.5 HTTP プロキシ強制の検出

```powershell
curl -v --max-time 5 http://example.com/ 2>&1 | Select-String -Pattern "Via|X-Cache|Proxy|Server"
```

透過プロキシがあれば `Via:` / `X-Cache:` 等のヘッダが入る。

---

## 4. ラップトップ wstunnel client で完全 E2E 確認

curl だけでは TLS+HTTP までしか確認できないので、wstunnel client コンテナで **WebSocket upgrade + UDP トンネル確立** まで実際に通す。

### 4.1 「最初の 3 行」

```powershell
# ① コンテナ稼働確認
docker ps --filter name=wstunnel-client --format "{{.Names}}  {{.Status}}  {{.Ports}}"

# ② UDP 刺激パケット送信
$udp = New-Object System.Net.Sockets.UdpClient; $udp.Send([Text.Encoding]::ASCII.GetBytes("test"), 4, "127.0.0.1", 51821) | Out-Null; $udp.Close(); Write-Host "sent"

# ③ ログ確認
docker logs --tail 20 wstunnel-client
```

**期待する ③ のログ** (成功時):
```
Starting wstunnel client v10.5.2
Starting UDP server listening cnx on 0.0.0.0:51821 with cnx timeout of 0s
New UDP connection from 172.17.0.1:xxxxx
Opening TCP connection to tukushityann.net:443
Doing TLS handshake using SNI DnsName("tukushityann.net") with the server tukushityann.net:443
```

エラー行 (`404`, `eof`, `NoCipherSuitesInCommon`, `UnknownCA`) が続かなければ wstunnel は完全動作。

### 4.2 失敗時の代表エラーと原因

| ログ抜粋 | 原因 | 対策 |
|---|---|---|
| `Invalid status code: 404` | 相手が wstunnel ではない HTTP サーバー (nginx 等横取り) | DNS/DDNS、自宅側 DNAT rule 30、r1 の `service https listen-address` |
| `TLS handshake eof` / `received fatal alert: UnknownCA` | クライアント側が自己署名を拒否 | 通常 v10 は skip。追加フラグ未設定を確認 |
| `Failed to resolve` | 会場 DNS が `tukushityann.net` を引けない | 8.8.8.8 等で nslookup、DNS 強制を疑う |
| `connect: Connection refused/timed out` | 会場上流で TCP 443 ブロック | HTTP プロキシ併用 (4.3 パターン②) に切替 |
| `Address already in use` | 51821 を別プロセスが占有 | `docker rm -f wstunnel-client` → 別プロセス確認 |
| `dumb-init: client: No such file` | command 先頭の絶対パスが抜け | セクション 4.3 基本形で再作成 |

### 4.3 コンテナの起動/停止/再作成

#### 状態管理

```powershell
docker ps -a --filter name=wstunnel-client
docker start   wstunnel-client
docker stop    wstunnel-client
docker restart wstunnel-client
docker logs -f wstunnel-client    # 追従表示、Ctrl+C で抜ける
docker rm -f   wstunnel-client    # 検証完了後のクリーンアップ
```

#### 基本形 (FQDN 接続)

```powershell
docker rm -f wstunnel-client
docker run -d `
  --name wstunnel-client `
  --restart unless-stopped `
  -p 127.0.0.1:51821:51821/udp `
  ghcr.io/erebe/wstunnel:latest `
  /home/app/wstunnel client -L "udp://0.0.0.0:51821:192.168.10.1:51820?timeout_sec=0" "wss://tukushityann.net:443"
```

#### パターン ①: IP 直指定 (DDNS トラブル時)

```powershell
docker rm -f wstunnel-client
docker run -d --name wstunnel-client --restart unless-stopped `
  -p 127.0.0.1:51821:51821/udp `
  ghcr.io/erebe/wstunnel:latest `
  /home/app/wstunnel client -L "udp://0.0.0.0:51821:192.168.10.1:51820?timeout_sec=0" "wss://101.143.12.214:443"
```

#### パターン ②: HTTP プロキシ併用 (透過プロキシ環境)

```powershell
docker rm -f wstunnel-client
docker run -d --name wstunnel-client --restart unless-stopped `
  -p 127.0.0.1:51821:51821/udp `
  ghcr.io/erebe/wstunnel:latest `
  /home/app/wstunnel client `
    -L "udp://0.0.0.0:51821:192.168.10.1:51820?timeout_sec=0" `
    --http-proxy "<proxy-host>:<port>" `
    "wss://tukushityann.net:443"
```

#### パターン ③: デバッグログ有効化

基本形に `-e RUST_LOG=debug` を追加するだけ。

### 4.4 UDP 送信の別手段

```powershell
# PowerShell 標準 (上記と同じ)
$udp = New-Object System.Net.Sockets.UdpClient; $udp.Send([Text.Encoding]::ASCII.GetBytes("test"), 4, "127.0.0.1", 51821) | Out-Null; $udp.Close()

# Python (入っていれば)
python -c "import socket; s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.sendto(b'test', ('127.0.0.1', 51821))"

# ncat (Nmap 同梱)
echo test | ncat -u -w1 127.0.0.1 51821
```

---

## 5. r3 を物理設置 → 直接接続の生存確認

r3 を会場の上流スイッチ・ルータに接続し、電源投入。

### 5.1 r3 ログイン後の最初の 3 行

```bash
# ① 上流インターネット到達性
ping -c 3 8.8.8.8

# ② wstunnel 経路到達確認 (期待: HTTP 400 = wstunnel-server 応答)
curl -k -s -o /dev/null -w "HTTP %{http_code}\n" --max-time 5 https://tukushityann.net/

# ③ WireGuard 直接接続の生存確認
sudo wg show wg0 | grep -E "latest handshake|endpoint"
```

### 5.2 判定表

| ①ping | ②HTTP | ③wg handshake | 判定 |
|---|---|---|---|
| OK | 400 | 数分以内 | **完全正常**、直接接続で運用 (何もしない) |
| OK | 400 | なし/古い | **UDP 51820 ブロック** → セクション 6 で wstunnel 切替 |
| OK | タイムアウト/TLS エラー | - | **TCP 443 ブロック or TLS インスペクション** → HTTP プロキシ併用が必要 |
| NG | - | - | 上流死亡、物理/IP/PPPoE 等を疑う |

---

## 6. wstunnel 有効化フロー (ポート制限発動時)

### 6.1 現在の wstunnel command を確認

```bash
curl -k https://192.168.11.1/retrieve \
  -H "Content-Type: application/json" \
  -d '{"key":"BwAI","op":"showConfig","path":["container","name","wstunnel","command"]}'
```

### 6.2 wstunnel command を投入 (必ず API 経由)

> ⚠️ **VyOS CLI では `?` が補完トリガーになり投入不可**。必ず REST API で。

```bash
curl -k -X POST https://192.168.11.1/configure \
  -H "Content-Type: application/json" \
  -d '{
    "key":"BwAI",
    "commands":[
      {"op":"delete","path":["container","name","wstunnel","command"]},
      {"op":"set","path":["container","name","wstunnel","command",
        "/home/app/wstunnel client -L udp://127.0.0.1:51821:192.168.10.1:51820?timeout_sec=0 wss://tukushityann.net:443"]}
    ]
  }'

curl -k -X POST https://192.168.11.1/config-file \
  -H "Content-Type: application/json" \
  -d '{"key":"BwAI","op":"save"}'
```

### 6.3 HTTP プロキシ併用時の command

wss URL の直前に `--http-proxy <proxy-host>:<port>` を追加した形を投入:

```
/home/app/wstunnel client -L udp://127.0.0.1:51821:192.168.10.1:51820?timeout_sec=0 --http-proxy 192.0.2.1:8080 wss://tukushityann.net:443
```

### 6.4 wstunnel コンテナ再起動 / ログ確認

```bash
# コンテナ再作成 (設定反映後)
sudo podman restart wstunnel

# ログ確認
show container log wstunnel
sudo podman logs --tail 30 wstunnel
```

**期待ログ**:
```
Starting wstunnel client v10.5.2
Starting UDP server listening cnx on 127.0.0.1:51821 with cnx timeout of 0s
```

### 6.5 r3 側で wstunnel E2E 疎通テスト (wg0 を切り替える前)

```bash
python3 -c "import socket; s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.sendto(b'test', ('127.0.0.1', 51821))"
show container log wstunnel | tail -20
```

成功時:
```
New UDP connection from 127.0.0.1:xxxxx
Opening TCP connection to tukushityann.net:443
Doing TLS handshake using SNI DnsName("tukushityann.net")
```

### 6.6 wg0 peer endpoint を wstunnel 経由に切替

CLI OK (`?` を含まないので問題なし):

```
configure
set interfaces wireguard wg0 peer r1-home endpoint '127.0.0.1:51821'
commit
save
exit
```

### 6.7 通常 (直接) 接続に戻す

```
configure
set interfaces wireguard wg0 peer r1-home endpoint '101.143.12.214:51820'
commit
save
exit
```

---

## 7. WireGuard / BGP / 経路確認 (r3)

### 7.1 WireGuard

```bash
show interfaces wireguard
show interfaces wireguard wg0
show interfaces wireguard wg1

sudo wg show wg0     # handshake 時刻、転送量
sudo wg show wg1     # GCP 向け (r2 との peer)
sudo wg show all

ping 192.168.10.1    # r1 LAN 直接
ping 10.255.0.1      # r1 transit (wg0)
ping 10.255.2.2      # r2-gcp transit (wg1)
```

### 7.2 BGP

```bash
show ip bgp summary          # ネイバー状態 (Establish / Active / Idle)
show ip bgp                  # 受信経路一覧
show ip bgp neighbors
show ip bgp neighbors 10.255.0.1
show ipv6 bgp summary
show ip bgp 0.0.0.0/0        # デフォルトルート学習状況
show ip route bgp            # BGP 由来の RIB
show ip route                # 全経路
```

### 7.3 コンテナ / サービス / DHCP

```bash
show container
show container container
show container log wstunnel
sudo podman ps -a
sudo podman inspect wstunnel | grep -A5 '"Cmd"'

show dhcp server statistics
show dhcp server leases
show dns forwarding statistics
```

---

## 8. 切り分け: ラップトップ vs r3

| ラップトップ | r3 | 判定 |
|---|---|---|
| ✅ 成功 | ❌ 失敗 | **r3 側の問題** (コンテナ設定 / command 構文 / wg0 port 衝突 / restart policy) |
| ❌ 失敗 | ❌ 失敗 | **会場ネットワーク側の問題** (TCP 443 ブロック / TLS インスペクション / DNS 強制) |
| ✅ 成功 | ✅ 成功 | 両者 OK、本番投入可能 |
| ❌ 失敗 | ✅ 成功 | ラップトップ固有問題 (Docker NW / Firewall / ルーティング) を疑う |

---

## 9. トラブルシューティング

### 9.1 ライブモニタリング (r3)

```bash
monitor log
monitor log | grep -iE "wstunnel|bgp|wireguard"
monitor traffic interface eth0
monitor traffic interface eth0 filter 'tcp port 443'
monitor traffic interface eth0 filter 'udp port 51820'
```

### 9.2 経路トレース

```bash
# r3 側
traceroute 192.168.10.1
traceroute -T -p 443 tukushityann.net
mtr --report --report-cycles 10 192.168.10.1
```

```powershell
# ラップトップ側
tracert tukushityann.net
Test-NetConnection tukushityann.net -Port 443 -TraceRoute
```

### 9.3 DNS / 名前解決

```bash
# r3
dig tukushityann.net
dig tukushityann.net @8.8.8.8
dig tukushityann.net @192.168.11.1   # r3 内蔵フォワーダ
```

```powershell
# ラップトップ
nslookup tukushityann.net
nslookup tukushityann.net 8.8.8.8
```

### 9.4 r3 設定確認 (grep)

```bash
show configuration commands | grep wstunnel
show configuration commands | grep wireguard
show configuration commands | grep bgp
show configuration commands | grep 'nat source'
show log tail 50
show log | grep -iE "wstunnel|wireguard|bgp"
```

### 9.5 ラップトップ側コンテナトラブル

```powershell
docker logs wstunnel-client 2>&1 | Select-Object -Last 30
netstat -ano | Select-String ":51821"
# Docker Desktop 自体の再起動
Get-Process "Docker Desktop" | Stop-Process -Force
Start-Process "C:\Program Files\Docker\Docker\Docker Desktop.exe"
```

---

## 10. 緊急リカバリ

### r3 (詰んだら)

```
configure
rollback 1           # 直前の commit に戻す
commit
exit
```

設定ファイルから再読込:
```
configure
load /config/config.boot
commit
exit
```

### ラップトップ

```powershell
docker rm -f wstunnel-client
# 基本形で再作成 (セクション 4.3)
```

---

## 11. 片付け (下見終了後)

```powershell
# ラップトップ検証用コンテナ削除
docker rm -f wstunnel-client

# イメージも完全削除したい場合のみ
docker rmi ghcr.io/erebe/wstunnel:latest
```

r3 は現地に設置したままなら触らない。撤収する場合は `poweroff` をAPI経由で:

```bash
curl -k -X POST https://192.168.11.1/poweroff \
  -H "Content-Type: application/json" \
  -d '{"key":"BwAI","op":"poweroff"}'
```

---

## 12. API リファレンス (ラップトップから r3 を叩く)

### 設定取得

```bash
curl -k https://192.168.11.1/retrieve \
  -H "Content-Type: application/json" \
  -d '{"key":"BwAI","op":"showConfig","path":["interfaces","wireguard","wg0"]}'
```

### show コマンド実行

```bash
curl -k https://192.168.11.1/show \
  -H "Content-Type: application/json" \
  -d '{"key":"BwAI","op":"show","path":["ip","bgp","summary"]}'

curl -k https://192.168.11.1/show \
  -H "Content-Type: application/json" \
  -d '{"key":"BwAI","op":"show","path":["container","log","wstunnel"]}'
```

### 設定投入 (例: endpoint 切替)

```bash
curl -k -X POST https://192.168.11.1/configure \
  -H "Content-Type: application/json" \
  -d '{"key":"BwAI","commands":[
    {"op":"set","path":["interfaces","wireguard","wg0","peer","r1-home","endpoint","127.0.0.1:51821"]}
  ]}'
```

### 保存

```bash
curl -k -X POST https://192.168.11.1/config-file \
  -H "Content-Type: application/json" \
  -d '{"key":"BwAI","op":"save"}'
```

### エンドポイント一覧 (よく使う)

| エンドポイント | op | 用途 |
|---|---|---|
| `/configure` | (commands 配列) | 設定投入 (set/delete) |
| `/retrieve` | `showConfig` | 設定ツリー取得 |
| `/retrieve` | `returnValues` | 値一覧 |
| `/retrieve` | `exists` | パス存在確認 |
| `/show` | `show` | op-mode show コマンド実行 |
| `/config-file` | `save` | 設定保存 |
| `/config-file` | `load` | 設定読込 |
| `/reset` | `reset` | BGP neighbor reset 等 |
| `/reboot` | `reboot` | 再起動 |
| `/poweroff` | `poweroff` | シャットダウン |

---

## 13. 持ち物チェックリスト

- [ ] ラップトップ (Docker Desktop 起動確認)
- [ ] `wstunnel-client` コンテナが残っていることを確認 (`docker ps -a`)
- [ ] このチートシート (`docs/operations/venue-cheatsheet.md`) を印刷 or オフライン閲覧可能にしておく
- [ ] r3 API キー `BwAI`、mgmt IP `192.168.11.1`
- [ ] 自宅 FQDN `tukushityann.net`、WAN 実 IP `101.143.12.214` (DDNS 障害時用)
- [ ] モバイル回線 / テザリング (会場 Wi-Fi 以外の代替経路)
- [ ] **出発直前のモバイル回線チェック** (セクション 1): `curl -k https://tukushityann.net/` → `HTTP 400 Invalid request` 確認
- [ ] r3 (本番投入時): 電源、LAN ケーブル、mgmt 接続用の有線アダプタ

### Tips / 既知の罠

- **PowerShell では `?` を含む URL はダブルクォートで囲む** (ワイルドカード解釈回避)
- **Git Bash で docker run にコンテナ内パス (`/home/app/...`) を渡すなら `MSYS_NO_PATHCONV=1` をつける**
- **VyOS CLI では `?` `/` `\` が補完トリガー** で set コマンドが打ち切られる → command 系は必ず REST API 経由
- **SoftEther VPN Client の接続ポートは 80** (443 は wstunnel 専用)。クライアント設定が 443 だと wstunnel-server が応答して NoCipherSuitesInCommon エラーになる
- **Docker Desktop のコンテナからの inbound は全て `172.17.0.1` にマスカレード**される → 送信元 IP での制限/分析は不可
- **自宅 LAN 内から `tukushityann.net` を叩くと r1 VyOS の nginx (API, 403) が返る** ことがある (ヘアピン NAT が効かないため)。外部経路確認は必ずモバイル回線から
