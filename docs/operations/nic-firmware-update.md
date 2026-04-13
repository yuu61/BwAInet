# Intel X710 NIC ファームウェア更新・チューニング手順

会場 Proxmox (MS-01) の Intel X710 SFP+ 10GbE (nic2, nic3) に対する FW 更新と i40e パフォーマンスチューニングの手順。設計根拠は [`../design/venue-proxmox.md`](../design/venue-proxmox.md) を参照。

## FW 9.56 への更新

### 背景

9.20 以下の旧 FW では kernel 6.x 側 libie の MAC フィルタ追加時に `LIBIE_AQ_RC_ENOSPC` エラーが発生し、overflow promiscuous モードへ強制遷移してブリッジ経由の TX 性能が著しく劣化する。Intel NVM Update Package (Release 31.1 = FW 9.56) で両ポートを更新する。

### 手順

```bash
cd /root/nvm/NVMUpdatePackage/700_Series/700Series/Linux_x64
./nvmupdate64e -u -l update.log -o result.xml -b -c nvmupdate.cfg
# 完了後、Proxmox host を reboot して新 FW 反映
```

両ポート (nic2, nic3) は同一チップ内 function なので同時更新される。

### 確認

```bash
ethtool -i nic3 | grep firmware-version
# firmware-version: 9.56 0x...
```

## i40e パフォーマンスチューニング (nic3 WAN)

WG トンネル越しの高スループット維持のため、`/etc/network/interfaces` の nic3 定義に post-up hook で以下を永続適用している。

| 項目 | 値 | 理由 |
|------|-----|------|
| ring RX/TX | 4096 (default 512) | burst 時の drop 耐性確保。max 8160 の半分で latency 影響を最小化 |
| ntuple-filters | off | NIC 側 flow director が unintended に flow を特定 queue に steer するのを抑止 |

combined (channels) はデフォルトの 20 を維持する。IRQ 分散を最大化するため減らさない。

### `/etc/network/interfaces` 抜粋

```
iface nic3 inet manual
        post-up ethtool -G nic3 rx 4096 tx 4096 || true
        post-up ethtool -K nic3 ntuple off || true
```

### 手動確認

```bash
ethtool -g nic3   # ring buffer
ethtool -k nic3 | grep ntuple
ethtool -l nic3   # channels
```

## SFP+ モジュールに関する注意

- Intel 純正または DAC ケーブル推奨
- 自宅 r1 の FS SFP-10GM-T-30 (10GBase-T SFP+) は NVM 9.56 で使用可能。7.00 ではベンダーロックあり

## 関連

- [`../design/venue-proxmox.md`](../design/venue-proxmox.md) — NIC 選定理由と設計判断
- [`../design/home-vyos.md`](../design/home-vyos.md) — r1 側 X710-DA4 の構成
- [`../investigation/wg-throughput-measurement.md`](../investigation/wg-throughput-measurement.md) — 実測値
