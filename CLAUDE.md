# CLAUDE.md

## プロジェクト概要

BwAI in Kwansai 2026 のイベント会場ネットワークインフラの設計・構築リポジトリ。
会場のプロキシ環境に依存しない自前ネットワークを VPN トンネル経由で提供する。

## 技術スタック

- **ルーター**
  - r1-home (自宅, AS65002): VyOS ベアメタル。家族用 LAN + WireGuard + BGP
  - r3-venue (会場, AS65001): VyOS VM on Proxmox VE (Minisforum MS-01)
  - r2-gcp (GCP, AS64512): GCE 上の VyOS (e2-micro, 大阪リージョン) トランジットルーター
  - 会場上流 (blackbox): 会場設備・管理外
- **VPN**: WireGuard フルメッシュ (r1/r3/r2-gcp)。プロキシ回避時は wstunnel over WebSocket/TLS (VyOS 上の podman コンテナ)
- **ルーティング**: eBGP フルメッシュ。通常は r1↔r3 直接、障害時は r2-gcp 経由にフォールバック (AS path で自然選択、local-preference で微調整)
- **VLAN**: 11 (mgmt, v4 only), 30 (staff+live, v4+v6), 40 (user, v4+v6)。VLAN 30/40 は同一 /64 を共有
- **IPv6**: OPTAGE /64 (r1 DHCPv6-PD 由来) と GCP /64 (venue-v6-transit サブネット) の 2 プレフィックスを VLAN 30/40 で同時 RA 広告。r3 の source-based PBR で src prefix に応じて出口振り分け (OPTAGE src → wg0→r1、GCP src → wg1→r2-gcp→NAT66)。自宅 LAN は v4 only
- **監視**: Zabbix + Grafana (+ Prometheus SNMP Exporter, NetFlow v9, rsyslog)
- **ログ集約**: rsyslog → GCE → GCS (法執行機関対応、保存期間 180 日)
- **仮想基盤**: Proxmox VE (会場: Minisforum MS-01 借用機)
- **スクリプト**: Bash (`curl` で VyOS API 経由), Python 3 (初期投入用)
- **VyOS バージョン**: 2026.03 (Circinus, rolling release)

## リポジトリ構成

```
BwAI.md                  # ネットワーク構成図 (Mermaid)
docs/
  requirements/          # PRD, 要件定義
  design/                # architecture.md, home-vyos.md, venue-vyos.md, venue-proxmox.md, venue-switch*.md, gcp-integration.md, logging-compliance.md 等
  investigation/         # 事前調査レポート (pcap, 回線, GCP, MTU, AP 等)
  operations/            # 運用手順 (WAN 切替, ログ調査, ファーム更新, goog prefix 等)
  policy/                # AUP, ログ保存ポリシー, GCP ToS 準拠
  configs/               # ルーター/スイッチの設定スナップショット (r1-home.conf, r3-venue.conf, sw01/02.conf)
  network-overview.md    # 非エンジニア向け概要
scripts/                 # VyOS 設定/運用スクリプト (Python + Bash, pd-update-venue, wg-tracker 等)
shumoku/                 # ネットワーク図/トポロジ定義 (network.yaml, diagram.html)
```

## コーディング規約

- ドキュメントは日本語で記述する
- コミットメッセージは日本語または英語 (既存のスタイルに合わせる)
- 設計書は Markdown 形式で `docs/design/` に配置する
- 運用手順は `docs/operations/`、ポリシーは `docs/policy/` に分離する

## VyOS API 操作

- VyOS API への操作は skill（`/vyos-show`, `/vyos-retrieve`, `/vyos-configure`, `/vyos-save`）を使用する
- Python スクリプトを生成するのではなく、`curl` で Bash から直接 API を実行する
- 設定投入前に内容を提示し確認を取ること（破壊的操作のため）
- skill の詳細は `.claude/skills/vyos-*/SKILL.md` を参照

## ネットワーク設計のポイント

- 会場上流がプロキシ環境のため、全トラフィックを WireGuard トンネルで自宅経由に迂回
- プロキシ解除不可時は wstunnel (WSS/TCP 443) にフォールバック、上位は常に wg0 で統一
- WireGuard MTU は 1400 に統一 (GCP VPC MTU 1460 がボトルネック)、MSS clamping 併用
- IPv6 デュアルプレフィックス RA: OPTAGE /64 (preferred=14400s、優先) + GCP /64 (preferred=1800s)。VLAN 30/40 で同一 /64 を共有。OPTAGE プレフィックスは r1 の WAN で DHCPv6-PD 受信 → `scripts/pd-update-venue.sh` (r1 の task-scheduler 1分間隔) が変更検知して r3 の VyOS API に push して eth2.30/40 アドレスと RA 設定を更新。GCP プレフィックスは r2 の GCP 固定 /64 を r3 に静的配置
- IPv4 は dst ベース (goog.json を BGP 広告)、IPv6 は src ベース PBR で振り分け。v6 で goog BGP 広告しない理由は非対称ルーティングで NAT66 conntrack が破綻するため
- GCP /96 外アドレスは drop される制約のため、r2-gcp で NAT66 (`snat prefix to /96`) を実施
- VLAN 40 (user) から VLAN 11 (mgmt) はデフォルト GW のみ許可、それ以外拒否
- DNS/DHCP は r3 の VyOS に統合 (DHCPv6 は廃止、SLAAC + NDP dump で代替)
- GCE/GCS 向けトラフィックは r2-gcp 経由、家族 LAN 向けは r1 直接、で非対称ルーティング回避
- venue Proxmox (MS-01) は借用品。GCS 転送完了確認後に初期化・返送する
