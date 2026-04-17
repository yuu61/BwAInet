# golinks (go.bwai)

会場内 `http://go.bwai/<key>` → 302 リダイレクタ。

運用手順の全文は [`docs/operations/golinks.md`](../../../docs/operations/golinks.md) を参照。このディレクトリは実装 (Go + Containerfile) と初期 CSV のみ。

## ファイル

- `main.go` — 標準ライブラリのみ、CSV mtime polling で 2 秒間隔リロード
- `go.mod` — 依存なし
- `Containerfile` — multi-stage、distroless で静的バイナリのみ同梱
- `golinks.csv` — 初期エントリ (r3 に配置する際は `/config/containers/golinks/golinks.csv` へ)

## ローカル動作確認

```bash
go run . -csv ./golinks.csv -addr :8080
# 別ターミナルで
curl -I http://localhost:8080/gcp
curl -I http://localhost:8080/          # ルートは -root で指定した URL
```

フラグ:

- `-csv` : CSV ファイルパス (既定 `/etc/golinks/golinks.csv`)
- `-addr` : HTTP リッスンアドレス (既定 `:80`)
- `-root` : `/` アクセス時のリダイレクト先 (既定は connpass イベントページ)

`SIGTERM` / `SIGINT` を受けると in-flight リクエストを最大 10 秒待ってから graceful shutdown する。
