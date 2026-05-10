#!/bin/bash

# =========================================
# wireproxy socks5 自动检测 + 自动重启
# 直接读取 wgcf-profile.conf
# =========================================

exec 9>/tmp/wireproxy.lock
flock -n 9 || exit 1

green() { echo -e "\033[32m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }

WORKDIR="/opt/warp"
WGCF_CONF="${WORKDIR}/wgcf-profile.conf"
FAIL_FILE="/tmp/wireproxy_fail_count"
MAX_FAIL=3

SITES=(
    "https://ip.sb"
    "https://ip.me"
    "https://api.ipify.org"
)

# =========================================
# 检查配置文件
# =========================================
if [[ ! -f "$WGCF_CONF" ]]; then
    red "wgcf-profile.conf 不存在: $WGCF_CONF"
    exit 1
fi

# =========================================
# 读取 SOCKS5 配置
# =========================================
SOCKS_PORT=$(grep '^BindAddress' "$WGCF_CONF" | awk -F':' '{print $2}' | xargs)
SOCKS_ADDR="127.0.0.1:${SOCKS_PORT}"

SOCKS_USERNAME=$(grep '^Username' "$WGCF_CONF" | awk -F'=' '{print $2}' | xargs)
SOCKS_PASSWORD=$(grep '^Password' "$WGCF_CONF" | awk -F'=' '{print $2}' | xargs)

SOCKS_USER="${SOCKS_USERNAME}:${SOCKS_PASSWORD}"

# =========================================
# 开始检测
# =========================================
SUCCESS=0

for SITE in "${SITES[@]}"; do

    HTTP_CODE=$(curl -s \
        --connect-timeout 10 \
        --max-time 15 \
        --socks5-hostname ${SOCKS_ADDR} \
        --proxy-user "${SOCKS_USER}" \
        -o /dev/null \
        -w "%{http_code}" \
        ${SITE})

    if [[ "$HTTP_CODE" == "200" ]]; then
        SUCCESS=1
        break
    fi

done

# =========================================
# 成功
# =========================================
if [[ "$SUCCESS" == "1" ]]; then

    echo "$(date '+%F %T')"
    green "===== WARP连接正常 ====="

    echo ""
    green "===== IPv4 ====="
    curl -4 -s \
        --connect-timeout 5 \
        --max-time 10 \
        --socks5-hostname ${SOCKS_ADDR} \
        --proxy-user "${SOCKS_USER}" \
        https://ipv4.ip.sb

    echo ""

    green "===== IPv6 ====="
    curl -6 -s \
        --connect-timeout 5 \
        --max-time 10 \
        --socks5-hostname ${SOCKS_ADDR} \
        --proxy-user "${SOCKS_USER}" \
        https://ipv6.ip.sb 2>/dev/null

    echo ""
    echo 0 > ${FAIL_FILE}
    exit 0
fi

# =========================================
# 失败计数
# =========================================
FAIL_COUNT=$(cat ${FAIL_FILE} 2>/dev/null || echo 0)
FAIL_COUNT=$((FAIL_COUNT + 1))

echo "$(date '+%F %T') WARP检测失败，第 ${FAIL_COUNT} 次"
echo ${FAIL_COUNT} > ${FAIL_FILE}

# =========================================
# 自动重启
# =========================================
if [[ "$FAIL_COUNT" -ge "$MAX_FAIL" ]]; then

    echo "$(date '+%F %T') 连续失败，重启 wireproxy"

    systemctl restart wireproxy

    sleep 5

    echo "$(date '+%F %T') wireproxy 重启完成"

    echo 0 > ${FAIL_FILE}
fi
