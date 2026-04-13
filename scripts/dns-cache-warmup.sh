#!/bin/bash
# dns-cache-warmup.sh — r3 の DNS キャッシュをランダムなドメインで事前投入する
#
# r3 の VyOS task-scheduler で定期実行:
#   set system task-scheduler task dns-warmup interval 60
#   set system task-scheduler task dns-warmup executable path /config/scripts/dns-cache-warmup.sh
#
# 動作:
#   人気ドメインリストからランダムに選択し、A / AAAA レコードを問い合わせて
#   PowerDNS Recursor のキャッシュを温める。
#   イベント開始前に実行しておくことで、参加者の初回アクセスの遅延を軽減する。

set -u

DNS_SERVER="192.168.11.1"
QUERIES_PER_RUN=50
LOG_TAG="dns-warmup"
TIMEOUT=2

log() { logger -t "$LOG_TAG" "$1"; }

# --- 人気ドメインリスト ---
# 検索・ポータル、SNS、動画・配信、CDN・クラウド、開発者向け、通信・メール、
# ニュース・メディア、EC、ゲーム、教育・その他 から幅広く選定
DOMAINS=(
    # 検索・ポータル
    google.com
    google.co.jp
    www.google.com
    www.google.co.jp
    yahoo.co.jp
    bing.com
    duckduckgo.com

    # SNS・コミュニケーション
    twitter.com
    x.com
    facebook.com
    instagram.com
    threads.net
    linkedin.com
    reddit.com
    discord.com
    discord.gg
    slack.com
    line.me
    tiktok.com

    # 動画・配信・音楽
    youtube.com
    www.youtube.com
    youtu.be
    i.ytimg.com
    yt3.ggpht.com
    googlevideo.com
    netflix.com
    twitch.tv
    nicovideo.jp
    live.nicovideo.jp
    abema.tv
    spotify.com
    music.apple.com
    soundcloud.com

    # CDN・クラウド・インフラ
    cloudflare.com
    cdn.cloudflare.net
    cloudfront.net
    akamaized.net
    fastly.net
    googleapis.com
    gstatic.com
    googleusercontent.com
    fbcdn.net
    amazonaws.com
    s3.amazonaws.com
    azure.com
    blob.core.windows.net

    # 開発者・技術
    github.com
    raw.githubusercontent.com
    github.io
    gitlab.com
    stackoverflow.com
    npmjs.com
    registry.npmjs.org
    pypi.org
    hub.docker.com
    rubygems.org
    crates.io
    pkg.go.dev

    # Apple / Microsoft / Google サービス
    apple.com
    icloud.com
    microsoft.com
    login.microsoftonline.com
    office.com
    live.com
    outlook.com
    drive.google.com
    docs.google.com
    mail.google.com
    calendar.google.com
    meet.google.com

    # ニュース・メディア
    nhk.or.jp
    bbc.com
    cnn.com
    reuters.com
    nikkei.com
    asahi.com
    mainichi.jp
    wikipedia.org
    en.wikipedia.org
    ja.wikipedia.org

    # EC・決済
    amazon.co.jp
    amazon.com
    rakuten.co.jp
    mercari.com
    paypal.com
    stripe.com

    # ゲーム
    steampowered.com
    store.steampowered.com
    steamcommunity.com
    epicgames.com
    playstation.net
    xbox.com
    nintendo.co.jp

    # 教育・その他
    zoom.us
    webex.com
    notion.so
    figma.com
    canva.com
    openai.com
    anthropic.com
    chatgpt.com

    # DNS・セキュリティ
    one.one.one.one
    dns.google
    quad9.net
    letsencrypt.org
    pki.goog

    # 日本のサービス
    docomo.ne.jp
    au.com
    softbank.jp
    ntt.com
    sakura.ad.jp
    hatena.ne.jp
    qiita.com
    zenn.dev
    connpass.com
    cookpad.com
    tabelog.com
    yahoo.co.jp
    weather.yahoo.co.jp
)

DOMAIN_COUNT=${#DOMAINS[@]}

if ! command -v dig > /dev/null 2>&1; then
    log "ERROR: dig command not found"
    exit 1
fi

log "start: warming up DNS cache ($QUERIES_PER_RUN queries from $DOMAIN_COUNT domains)"

success=0
fail=0

for ((i = 0; i < QUERIES_PER_RUN; i++)); do
    idx=$((RANDOM % DOMAIN_COUNT))
    domain="${DOMAINS[$idx]}"

    # A レコード
    if dig @"$DNS_SERVER" "$domain" A +short +time="$TIMEOUT" +tries=1 > /dev/null 2>&1; then
        success=$((success + 1))
    else
        fail=$((fail + 1))
        log "FAIL: $domain A"
    fi

    # AAAA レコード
    if dig @"$DNS_SERVER" "$domain" AAAA +short +time="$TIMEOUT" +tries=1 > /dev/null 2>&1; then
        success=$((success + 1))
    else
        fail=$((fail + 1))
        log "FAIL: $domain AAAA"
    fi
done

log "done: success=$success fail=$fail (total=$((success + fail)) queries)"
