---
name: vyos-save
description: VyOS の設定をディスクに保存する。設定変更後の永続化に使用する
argument-hint: "[router] (e.g., r3)"
allowed-tools:
  - Bash(curl:*)
---

# VyOS 設定保存

VyOS REST API `/config-file` エンドポイントを使って、現在の running-config をディスクに保存する。

**save を実行しないと、再起動時に設定が失われる。`/vyos-configure` 実行後に必ず提案すること。**

## ルーター対応表

| 名前 | 役割 | エンドポイント |
|------|------|--------------|
| r1 | 自宅 VyOS | https://192.168.10.1 |
| r2 | GCP VyOS | https://10.255.255.2 (dum0、BGP 冗長) |
| r3 | 会場 VyOS | https://192.168.11.1 |

API キー: `BwAI`（全ルーター共通）

## 引数

- `$0`: ルーター名（r1 または r3）

## 実行手順

### 1. ユーザーへの確認
設定を保存する対象ルーターを確認する:

```
対象ルーター: r3 (会場 VyOS / 192.168.11.1)
running-config をディスクに保存します。よろしいですか？
```

### 2. 保存実行

```bash
curl -s -k -X POST https://<ENDPOINT>/config-file \
  -H "Content-Type: application/json" \
  -d '{
    "key": "BwAI",
    "op": "save"
  }'
```

### 3. 結果確認
レスポンスを確認し、保存の成功/失敗をレポートする。

## 設定ファイルの読み込み（load）

特定のファイルから設定を読み込む場合:

```bash
curl -s -k -X POST https://<ENDPOINT>/config-file \
  -H "Content-Type: application/json" \
  -d '{
    "key": "BwAI",
    "op": "load",
    "file": "/config/backup.boot"
  }'
```

**load は現在の設定を上書きするため、実行前に必ず確認を取ること。**
