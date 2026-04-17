---
name: vyos-show
description: VyOS の show コマンドを実行して状態を確認する（BGP, ルーティング, インターフェース等）。ユーザーが VyOS の状態確認・表示を求めたときに使用する
argument-hint: "[router] [path...] (e.g., r3 ip bgp summary)"
allowed-tools:
  - Bash(curl:*)
---

# VyOS show コマンド実行

VyOS REST API `/show` エンドポイントを使って show コマンドを実行し、結果を表示する。

## ルーター対応表

| 名前 | 役割 | エンドポイント |
|------|------|--------------|
| r1 | 自宅 VyOS | https://192.168.10.1 |
| r2 | GCP VyOS | https://10.255.255.2 (dum0、BGP 冗長) |
| r3 | 会場 VyOS | https://192.168.11.1 |

API キー: `BwAI`（全ルーター共通）

## 引数

- `$0`: ルーター名（r1 または r3）
- `$1` 以降: show コマンドのパス（スペース区切り）

例: `/vyos-show r3 ip bgp summary` → `show ip bgp summary` を r3 で実行

## 実行手順

1. 引数からルーター名を取得し、エンドポイントを決定する
2. 残りの引数を path 配列に変換する
3. 以下の curl コマンドを実行する:

```bash
curl -s -k -X POST https://<ENDPOINT>/show \
  -H "Content-Type: application/json" \
  -d '{
    "key": "BwAI",
    "op": "show",
    "path": ["arg1", "arg2", ...]
  }'
```

4. レスポンスの `data` フィールドを整形して表示する
5. 結果を分析し、状態をわかりやすくレポートする

## よく使う show コマンド例

- `ip bgp summary` — BGP ピア一覧
- `ip bgp neighbor <IP>` — BGP ネイバー詳細
- `ip route` — ルーティングテーブル
- `interfaces` — インターフェース一覧
- `wireguard` — WireGuard トンネル状態
- `ip ospf neighbor` — OSPF ネイバー
- `dhcp server leases` — DHCP リース一覧
- `log` — システムログ
