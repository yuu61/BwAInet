# go.bwai (会場内リンク短縮) 運用手順

## 概要

会場内で `http://go.bwai/<key>` でアクセスすると、CSV に登録した URL に 302 リダイレクトする。Google 社内の `go/` と同じコンセプトだが、single-label は主要ブラウザで検索に流れてしまうため、ドット入りの `go.bwai` を採用している (詳細は検討経緯は省略、`docs/design/` に記録なし)。

- **ドメイン**: `go.bwai` (r3 の authoritative-domain で A レコード)
- **ルート** (`http://go.bwai/`): `https://gdgkwansai.connpass.com/event/381901/` に固定リダイレクト (main.go の `rootRedirect`)
- **配置**: r3-venue の podman コンテナ (host network で :80 listen)
- **CSV**: `/config/containers/golinks/golinks.csv` を bind mount、編集後 2 秒以内に反映 (mtime polling、コンテナ再起動不要)

## アーキテクチャ

```
クライアント (VLAN 11/30/40)
  │ http://go.bwai/<key>
  ▼
r3 VyOS  DNS forwarding  → A: 192.168.11.1 (+ 30.1, 40.1)
r3 VyOS  container golinks (:80) → 302 Found → <target>
                 ↑
                 └─ /config/containers/golinks/golinks.csv (bind mount, ro)
```

## CSV フォーマット

```csv
# key,target
gcp,https://trygcp.dev/claim/build-ai-gdg-kwansai-2026
event,https://gdgkwansai.connpass.com/event/381901/
zabbix,192.168.30.3
grafana,192.168.30.3:3000
wiki/setup,https://example.com/setup
```

- target が `http://` / `https://` で始まらなければ `http://` を自動補完
- key は `/` 含み可 (例: `wiki/setup` → `http://go.bwai/wiki/setup`)
- `#` から行末はコメント
- 完全一致のみ (prefix match なし)
- 重複キーは後勝ち (標準 Go の map 上書き)

## イメージのビルドと配布

r3 (VyOS) で直接 `podman build` は運用上避ける。**手元でビルドして podman load で投入**するのが正規手順。CSV 変更だけなら再ビルド不要 (bind mount + mtime polling で反映)、Go コード変更時のみ以下を実施。

```bash
cd scripts/r3-venue/golinks

# ビルド (手元マシン)
podman build -t golinks:latest -f Containerfile .

# tar にエクスポートして r3 へ転送
podman save golinks:latest -o golinks.tar
scp golinks.tar vyos@r3-venue:/tmp/

# r3 で load
ssh vyos@r3-venue 'sudo podman load -i /tmp/golinks.tar && rm /tmp/golinks.tar'
```

初回のみ `set container name golinks image 'localhost/golinks:latest'` を VyOS に投入 (後述)。イメージを更新した場合は `restart container golinks` (または `podman restart golinks`) で新イメージを反映。

> 将来ビルドを自動化するなら GitHub Actions で ghcr.io/yuu61/golinks を発行する案もあるが、現状はリポジトリ private 運用の兼ね合いで保留。

## VyOS 設定 (初回投入)

### 0. 事前チェック

- r3 の tcp/80 が空いていること (VyOS の Web UI は無効、golinks 投入後に `ss -tlnp | grep :80` で確認)
- `/config/containers/` ディレクトリが存在すること (他コンテナの前例なし、新規作成で OK)

### 1. CSV を r3 に配置

```bash
# r3 にて
sudo mkdir -p /config/containers/golinks
sudo cp /tmp/golinks.csv /config/containers/golinks/golinks.csv
sudo chmod 644 /config/containers/golinks/golinks.csv
```

### 2. コンテナ設定 (/vyos-configure skill 経由)

```
set container name golinks allow-host-networks
set container name golinks image 'localhost/golinks:latest'
set container name golinks description 'go.bwai link redirector'
set container name golinks volume csv source '/config/containers/golinks'
set container name golinks volume csv destination '/etc/golinks'
set container name golinks volume csv mode 'ro'
set container name golinks restart 'on-failure'
```

### 3. DNS (authoritative A レコード)

**推奨: 単一 IP (192.168.11.1)**。r3 は全 VLAN の IP で :80 listen しているが、どの IP も r3 自身なので input filter にしかかからない。VLAN40-INPUT は tcp/22・udp/161・tcp/179 のみ drop で tcp/80 は accept。他 VLAN 宛の forward drop (VLAN40-FORWARD rule 10-30) は r3 own IP には適用されない。

```
set service dns forwarding authoritative-domain 'bwai' records a 'go' address '192.168.11.1'
```

複数 A を並べるのは負荷分散したい場合のみ。**Happy Eyeballs (RFC 8305) は A+AAAA の間でのみ競争し、複数 A の間では走らない** — ブラウザは返却順に順次試行するため、先頭 IP が遅いと全体が遅くなる。VLAN 30 側は到達性 OK なので問題ないが、予測可能性のため単一 IP を推奨。

### 4. commit/save

```
commit
save
```

## 動作確認

```bash
# DNS 解決
dig @192.168.40.1 go.bwai A

# ルート (connpass 固定)
curl -I http://go.bwai/
# → 302 Location: https://gdgkwansai.connpass.com/event/381901/

# エントリ
curl -I http://go.bwai/gcp
# → 302 Location: https://trygcp.dev/claim/...

# 階層キー
curl -I http://go.bwai/wiki/setup
# → 302 Location: http://...

# 404
curl -I http://go.bwai/nonexistent
# → 404 Not Found
```

## CSV 運用 (日常的な追加・削除)

```bash
# r3 にて
sudo vi /config/containers/golinks/golinks.csv
# 保存すると 2 秒以内に自動反映、コンテナ再起動不要

# 反映確認
podman logs golinks --tail 3
# → "loaded N entries from /etc/golinks/golinks.csv"
```

CSV は `/config` 配下なので VyOS の config backup に含まれる。

## トラブルシュート

- **curl すると接続拒否**: `podman ps` で golinks が running か確認
- **`reload failed: open ...`**: mount 設定と CSV パスの不一致。`podman inspect golinks` で volume マウント先を確認
- **DNS が SERVFAIL**: `bwai` ゾーンの他の名前 (例: `r3-venue.eth2-vlan11.bwai`) は PTR target として使われているだけで forward A は未定義。名前は `go.bwai` のみ解決される設計
- **スマホで `go/gcp` と打って検索に流れる**: 仕様。single-label は主要ブラウザで検索扱い (Firefox のみ `browser.fixup.dns_first_for_single_words=true` で回避可)。`go.bwai/gcp` を使うこと
