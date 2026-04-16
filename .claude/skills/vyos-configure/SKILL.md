---
name: vyos-configure
description: VyOS に設定を投入する。設定の追加(set)・削除(delete)を API 経由で実行する。ユーザーが VyOS の設定変更・投入を求めたときに使用する
argument-hint: "[router] [description] (e.g., r3 WireGuard ピア追加)"
allowed-tools:
  - Bash(curl:*)
---

# VyOS 設定投入

VyOS REST API `/configure` エンドポイントを使って設定を投入する。

**これは破壊的操作である。投入前に必ず内容をユーザーに提示し、確認を取ること。**

## ルーター対応表

| 名前 | 役割 | エンドポイント |
|------|------|--------------|
| r1 | 自宅 VyOS | https://192.168.10.1 |
| r2 | GCP VyOS | https://10.255.255.2 (dum0、BGP 冗長) |
| r3 | 会場 VyOS | https://192.168.11.1 |

API キー: `BwAI`（全ルーター共通）

## 引数

- `$0`: ルーター名（r1 または r3）
- `$1` 以降: 変更内容の説明

## 実行手順（必ずこの順序で）

### 1. 設計書・コンテキストの確認
ユーザーの要求と `docs/design/` の関連設計書から、投入すべきコマンドを特定する。

### 2. コマンドの組み立て
VyOS CLI パスを JSON 配列形式に変換する。

```json
{
  "key": "BwAI",
  "commands": [
    {"op": "set", "path": ["interfaces", "wireguard", "wg0", "peer", "peer1", "allowed-ips", "10.0.0.0/24"]},
    {"op": "delete", "path": ["firewall", "name", "OLD_RULE"]}
  ]
}
```

- **`op: "set"`**: 設定の作成・変更
- **`op: "delete"`**: 設定の削除

### 3. ユーザーへの確認提示
投入するコマンドを一覧表示し、**必ず確認を取る**。以下のフォーマットで提示する:

```
対象ルーター: r3 (会場 VyOS / 192.168.11.1)
操作内容:
  [set]    interfaces wireguard wg0 peer peer1 allowed-ips 10.0.0.0/24
  [delete] firewall name OLD_RULE

この設定を投入しますか？
```

### 4. API 実行
確認が取れたら curl で投入する:

```bash
curl -s -k -X POST https://<ENDPOINT>/configure \
  -H "Content-Type: application/json" \
  -d '{
    "key": "BwAI",
    "commands": [
      {"op": "set", "path": [...]},
      ...
    ]
  }'
```

### 5. 結果確認
- レスポンスを確認し、成功/失敗をレポートする
- 必要に応じて `/vyos-retrieve` で設定が反映されたことを確認する
- 設定を永続化する場合は `/vyos-save` の実行をユーザーに提案する

## 注意事項

- 複数コマンドは1回の API コールにまとめる（アトミックに適用される）
- `delete` 操作は特に慎重に。対象パス以下の全設定が削除される
- エラー時はロールバックされるが、部分適用の可能性もあるため結果を必ず確認する
