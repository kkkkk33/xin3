#!/bin/bash
set -e

# ========== 配置区 ==========
TG_TOKEN="YOUR_TELEGRAM_BOT_TOKEN"
TG_CHAT_ID="YOUR_TELEGRAM_CHAT_ID"

# SNI 伪装目标
# 参考：www.microsoft.com, outlook.office365.com, aws.amazon.com
SNI_DOMAIN="www.microsoft.com"

TLS_PWD="YOUR_TLS_PASSWORD"
SS_PORT=10222
LISTEN_PORT=10111
JA3_PORT=8080
SOCKS_PORT=1080          # ss-local 的 SOCKS5 监听端口

# ⭐ 指纹版本配置区（改这里）⭐
# JA3Proxy 支持的浏览器指纹预设
#
# Chrome:
# chrome@99, chrome@100, chrome@101, chrome@104, chrome@107
# chrome@110, chrome@116, chrome@119, chrome@120, chrome@123
# chrome@124, chrome@131, chrome@133
#
# Safari:
# safari15_3, safari15_5, safari17_0, safari17_2_ios
# safari18_0, safari18_0_ios
#
# Firefox:
# firefox133
#
# Edge:
# edge99, edge101
#
# 通用:
# chrome, firefox, safari, edge, ios
TLS_FINGERPRINT="chrome@120"
# ============================


RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }


# ── 1. 安装 Docker ──────────────────────────────
log "检查 Docker 环境..."

if ! command -v docker &>/dev/null; then
    warn "Docker 未安装，正在安装..."

    apt-get update -qq
    apt-get install -y -qq docker.io

    systemctl start docker
    systemctl enable docker
fi

docker info &>/dev/null || err "Docker 守护进程未运行"


# ── 2. 清理 ─────────────────────────────────────
log "清理旧容器..."

docker rm -f ss-rust ss-local shadow-tls ja3proxy 2>/dev/null || true

sleep 1

fuser -k ${LISTEN_PORT}/tcp 2>/dev/null || true
fuser -k ${SS_PORT}/tcp     2>/dev/null || true
fuser -k ${JA3_PORT}/tcp    2>/dev/null || true
fuser -k ${SOCKS_PORT}/tcp  2>/dev/null || true

sleep 1


# ── 3. 生成证书（JA3Proxy 需要） ────────────────
log "生成 JA3Proxy 证书..."

mkdir -p ./credentials

if [ ! -f ./credentials/cert.pem ]; then
    openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes \
        -keyout ./credentials/key.pem \
        -out ./credentials/cert.pem \
        -subj "/CN=JA3Proxy" \
        2>/dev/null
fi


# ── 4. 启动内层 SS-Rust ────────────────────────
SS_KEY="YOUR_SHADOWSOCKS_PASSWORD"

log "启动 Shadowsocks-Rust..."

docker run -d \
    --name ss-rust \
    --restart always \
    --network host \
    ghcr.io/shadowsocks/ssserver-rust:latest \
    ssserver \
        --server-addr "127.0.0.1:${SS_PORT}" \
        --encrypt-method "2022-blake3-aes-128-gcm" \
        --password "${SS_KEY}" \
        --timeout 300 \
        -U

log "等待 Shadowsocks 启动..."

for i in $(seq 1 15); do
    if ss -tlnp 2>/dev/null | grep -q "${SS_PORT}"; then
        log "Shadowsocks 已监听 ${SS_PORT}"
        break
    fi

    sleep 1
done


# ── 5. 启动 ss-local（SOCKS5 → SS 转换层） ─────
log "启动 ss-local (socks5 -> ss)..."

docker run -d \
    --name ss-local \
    --restart always \
    --network host \
    ghcr.io/shadowsocks/sslocal-rust:latest \
    sslocal \
        --server-addr "127.0.0.1:${SS_PORT}" \
        --encrypt-method "2022-blake3-aes-128-gcm" \
        --password "${SS_KEY}" \
        --local-addr "127.0.0.1:${SOCKS_PORT}"

log "等待 ss-local 启动..."

for i in $(seq 1 15); do
    if ss -tlnp 2>/dev/null | grep -q "${SOCKS_PORT}"; then
        log "ss-local 已监听 ${SOCKS_PORT} (SOCKS5)"
        break
    fi

    sleep 1
done


# ── 6. 启动 JA3Proxy（核心：改写指纹） ────────
log "启动 JA3Proxy，指纹: ${TLS_FINGERPRINT} ..."

docker run -d \
    --name ja3proxy \
    --restart always \
    --network host \
    -v ./credentials:/app/credentials \
    ghcr.io/lylemi/ja3proxy:latest \
    --listen "127.0.0.1:${JA3_PORT}" \
    --ca-cert /app/credentials/cert.pem \
    --ca-key /app/credentials/key.pem \
    --tls-fingerprint "${TLS_FINGERPRINT}" \
    --upstream-proxy "socks5://127.0.0.1:${SOCKS_PORT}"

sleep 3


# ── 7. 启动外层 Shadow-TLS ─────────────────────
log "启动 Shadow-TLS..."

docker run -d \
    --name shadow-tls \
    --restart always \
    --network host \
    --entrypoint shadow-tls \
    ghcr.io/ihciah/shadow-tls:v0.2.23 \
    --v3 server \
    --listen "0.0.0.0:${LISTEN_PORT}" \
    --server "127.0.0.1:${SS_PORT}" \
    --tls "${SNI_DOMAIN}:443" \
    --password "${TLS_PWD}"

sleep 2


# ── 8. 验证容器状态 ────────────────────────────
log "验证容器状态..."

for c in ss-rust ss-local ja3proxy shadow-tls; do

    s=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)

    if [ "$s" != "running" ]; then
        warn "$c 状态异常: $s"
        docker logs "$c" 2>&1 | tail -15
    else
        log "$c 运行正常"
    fi

done


# ── 9. 检查监听端口 ───────────────────────────
log "检查监听端口..."

ss -lntp 2>/dev/null | grep -E \
":(${LISTEN_PORT}|${SS_PORT}|${JA3_PORT}|${SOCKS_PORT}) " || true

echo ""


# ── 10. 获取公网 IP ───────────────────────────
SERVER_IP=$(curl -s --max-time 10 ipv4.icanhazip.com || \
            curl -s --max-time 10 api.ipify.org)

[ -z "$SERVER_IP" ] && err "无法获取公网 IP"

log "服务器 IP: ${SERVER_IP}"


# ── 11. 生成小火箭节点链接 ─────────────────────
SS_B64=$(python3 -c "
import base64

raw = '2022-blake3-aes-128-gcm:${SS_KEY}'

print(
    base64.urlsafe_b64encode(raw.encode()).decode().rstrip('=')
)
")


STLS_B64=$(python3 -c "
import base64
import json

obj = {
    'version': '3',
    'host': '${SNI_DOMAIN}',
    'password': '${TLS_PWD}'
}

print(
    base64.urlsafe_b64encode(
        json.dumps(obj, separators=(',', ':')).encode()
    ).decode().rstrip('=')
)
")


SS_LINK="ss://${SS_B64}@${SERVER_IP}:${LISTEN_PORT}?shadow-tls=${STLS_B64}#JA3_${TLS_FINGERPRINT}"


# ── 12. 推送 Telegram + 汇总 ───────────────────
if [ -n "${TG_TOKEN}" ] && \
   [ "${TG_TOKEN}" != "YOUR_TELEGRAM_BOT_TOKEN" ]; then

    curl -s -X POST \
        "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT_ID}" \
        --data-urlencode "text=🔗 节点链接 (${TLS_FINGERPRINT}):
${SS_LINK}" \
        >/dev/null || true

fi


# ── 13. 最终输出 ───────────────────────────────
echo ""

echo "══════════════════════════════════════════════"
echo "  部署完成"
echo "══════════════════════════════════════════════"

echo "  服务器IP       : ${SERVER_IP}"
echo "  监听端口       : ${LISTEN_PORT}"
echo "  JA3指纹版本    : ${TLS_FINGERPRINT}"
echo "  SNI 域名       : ${SNI_DOMAIN}"

echo "══════════════════════════════════════════════"

echo "  一键链接:"
echo "  ${SS_LINK}"

echo "══════════════════════════════════════════════"

docker ps --format "table {{.Names}}\t{{.Status}}"
```

