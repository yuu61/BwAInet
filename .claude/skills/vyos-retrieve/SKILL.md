---
name: vyos-retrieve
description: VyOS の設定値を取得・表示する。現在の設定確認、設定パスの存在チェック、値の一覧取得に使用する
argument-hint: "[router] [path...] (e.g., r3 interfaces wireguard)"
allowed-tools:
  - Bash(curl:*)
---

# VyOS 設定取得

VyOS REST API `/retrieve` エンドポイントを使って設定値を取得する。

## ルーター対応表

| 名前 | 役割 | エンドポイント |
|------|------|--------------|
| r1 | 自宅 VyOS | https://192.168.10.1 |
| r2 | GCP VyOS | https://10.255.255.2 (dum0、BGP 冗長) |
| r3 | 会場 VyOS | https://192.168.11.1 |

API キー: `BwAI`（全ルーター共通）

## 引数

- `$0`: ルーター名（r1 または r3）
- `$1` 以降: 設定パス（スペース区切り）

例: `/vyos-retrieve r3 interfaces wireguard` → r3 の WireGuard インターフェース設定を取得

## 利用可能な操作 (op)

### showConfig（デフォルト）
設定ツリーを JSON で取得する。パスを省略すると全設定を返す。

```bash
curl -s -k -X POST https://<ENDPOINT>/retrieve \
  -H "Content-Type: application/json" \
  -d '{
    "key": "BwAI",
    "op": "showConfig",
    "path": ["arg1", "arg2", ...],
    "configFormat": "json"
  }'
```

### returnValues
指定パスの値一覧を取得する。

```bash
curl -s -k -X POST https://<ENDPOINT>/retrieve \
  -H "Content-Type: application/json" \
  -d '{
    "key": "BwAI",
    "op": "returnValues",
    "path": ["arg1", "arg2", ...]
  }'
```

### exists
指定パスが存在するか確認する。

```bash
curl -s -k -X POST https://<ENDPOINT>/retrieve \
  -H "Content-Type: application/json" \
  -d '{
    "key": "BwAI",
    "op": "exists",
    "path": ["arg1", "arg2", ...]
  }'
```

## 実行手順

1. 引数からルーター名を取得し、エンドポイントを決定する（r1/r2/r3）
2. 残りの引数を path 配列に変換する
3. まず `showConfig` で設定を取得する（特に指定がなければ）
4. レスポンスの `data` フィールドを整形して表示する
5. 取得した設定を分析し、わかりやすく説明する

## よく使う取得パス例

- `interfaces` — 全インターフェース設定
- `interfaces wireguard` — WireGuard 設定
- `protocols bgp` — BGP 設定
- `service dhcp-server` — DHCP サーバー設定
- `service dns` — DNS 設定
- `firewall` — ファイアウォールルール
- `system` — システム設定
