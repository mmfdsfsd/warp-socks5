#!/bin/bash

exec 9>/tmp/wireproxy.lock
flock -n 9 || exit 1

SOCKS_ADDR="127.0.0.1:40000"
SOCKS_USER="103.197.71.63:123456789"

SITES=(
    "https://ip.sb"
    "https://ip.me"
    "https://api.ipify.org"
)

FAIL_FILE="/tmp/wireproxy_fail_count"
MAX_FAIL=3

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

if [[ "$SUCCESS" == "1" ]]; then
    echo "$(date '+%F %T') WARP连接正常"
    echo ""

    echo "IPv4:"
    curl -4 -s \
        --connect-timeout 5 \
        --max-time 10 \
        --socks5-hostname ${SOCKS_ADDR} \
        --proxy-user "${SOCKS_USER}" \
        https://ipv4.ip.sb

    echo ""

    echo "IPv6:"
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

FAIL_COUNT=$(cat ${FAIL_FILE} 2>/dev/null || echo 0)
FAIL_COUNT=$((FAIL_COUNT + 1))

echo "$(date '+%F %T') WARP检测失败，第 ${FAIL_COUNT} 次"

echo ${FAIL_COUNT} > ${FAIL_FILE}

if [[ "$FAIL_COUNT" -ge "$MAX_FAIL" ]]; then
    echo "$(date '+%F %T') 连续失败达到阈值，重启 wireproxy"

    systemctl restart wireproxy

    sleep 5

    echo "$(date '+%F %T') wireproxy 重启完成"

    echo 0 > ${FAIL_FILE}
fi
