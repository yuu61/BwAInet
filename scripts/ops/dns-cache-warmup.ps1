#!/usr/bin/env pwsh
# dns-cache-warmup.ps1 — r3 の DNS キャッシュを人気ドメイン上位 N 件で事前投入する (PowerShell 7 / Windows 版)
#
# 使い方:
#   pwsh ./dns-cache-warmup.ps1
#   pwsh ./dns-cache-warmup.ps1 -DnsServer 192.168.11.1 -TopN 10000
#   $env:DNS_SERVER='192.168.11.1'; pwsh ./dns-cache-warmup.ps1
#
# 動作:
#   Cisco Umbrella Top 1M を $env:TEMP\dns-cache-warmup にダウンロード・展開し、
#   上位 TopN 件すべてについて A/AAAA を問い合わせ、
#   r3 の PowerDNS Recursor キャッシュを温める。CSV は 24 時間キャッシュし、
#   以降の実行では再ダウンロードしない。
#
# 必要環境: PowerShell 7+, Windows (Resolve-DnsName の DnsClient モジュールが必要)

[CmdletBinding()]
param(
    [string]$DnsServer = $(if ($env:DNS_SERVER) { $env:DNS_SERVER } else { '192.168.11.1' }),
    [int]$TopN = $(if ($env:TOP_N) { [int]$env:TOP_N } else { 100 })
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$UmbrellaUrl = 'https://s3-us-west-1.amazonaws.com/umbrella-static/top-1m.csv.zip'
$CacheDir = Join-Path ([System.IO.Path]::GetTempPath()) 'dns-cache-warmup'
$ZipFile = Join-Path $CacheDir 'top-1m.csv.zip'
$CsvFile = Join-Path $CacheDir 'top-1m.csv'
$CacheMaxAge = [TimeSpan]::FromHours(24)

function Write-WarmupLog {
    param([string]$Message)
    [Console]::Error.WriteLine("[dns-warmup] $Message")
}

# --- 入力検証 ---
if ($TopN -lt 1) {
    Write-WarmupLog "ERROR: TopN must be >= 1 (got: $TopN)"
    exit 1
}

if (-not (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue)) {
    Write-WarmupLog "ERROR: Resolve-DnsName not available (Windows + DnsClient module required)"
    exit 1
}

New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null

# --- Umbrella Top 1M の取得 (24h キャッシュ) ---
$needDownload = $true
if (Test-Path $CsvFile) {
    $age = (Get-Date) - (Get-Item $CsvFile).LastWriteTime
    if ($age -lt $CacheMaxAge) {
        $needDownload = $false
        Write-WarmupLog ("using cached CSV (age={0:N0}s)" -f $age.TotalSeconds)
    }
}

if ($needDownload) {
    Write-WarmupLog "downloading Umbrella Top 1M from $UmbrellaUrl"
    try {
        Invoke-WebRequest -Uri $UmbrellaUrl -OutFile $ZipFile -UseBasicParsing
    }
    catch {
        Write-WarmupLog "ERROR: download failed: $_"
        exit 1
    }
    try {
        Expand-Archive -Path $ZipFile -DestinationPath $CacheDir -Force
    }
    catch {
        Write-WarmupLog "ERROR: extract failed: $_"
        exit 1
    }
    Write-WarmupLog "extracted: $CsvFile"
}

# --- 上位 TopN 件を読み込み、総行数もカウント ---
$total = 0
$domains = [System.Collections.Generic.List[string]]::new($TopN)
$reader = [System.IO.File]::OpenText($CsvFile)
try {
    while (-not $reader.EndOfStream) {
        $line = $reader.ReadLine()
        $total++
        if ($domains.Count -lt $TopN) {
            $domain = ($line -split ',', 2)[1]
            if ($domain) { $domains.Add($domain) }
        }
    }
}
finally {
    $reader.Dispose()
}

Write-WarmupLog "start: querying top $($domains.Count) of $total domains via $DnsServer"

# --- A/AAAA 問い合わせ ---
$success = 0
$fail = 0

foreach ($domain in $domains) {
    foreach ($type in 'A', 'AAAA') {
        try {
            $null = Resolve-DnsName -Name $domain -Type $type -Server $DnsServer `
                -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop
            $success++
        }
        catch {
            $fail++
        }
    }
}

Write-WarmupLog "done: success=$success fail=$fail (total=$($success + $fail) queries)"
