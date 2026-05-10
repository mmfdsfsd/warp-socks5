#!/bin/bash

# =========================================
# wireproxy socks5 自动检测 + 自动重启
# 首次运行自动配置
# 自动写入 cron
# =========================================

# 防止重复运行
exec 9>/tmp/wireproxy.lock
flock -n 9 || exit 1

CONFIG_FILE="/opt/warp/wireproxy_monitor.conf"
FAIL_FILE="/tmp/wireproxy_fail_count"

MAX_FAIL=3

SITES=(
    "https://ip.sb"
    "https://ip.me"
    "https://api.ipify.org"
)

# =========================================
# 首次运行配置向导
# =========================================

if [[ ! -f "${CONFIG_FILE}" ]]; then

    clear

    echo "========================================="
    echo " wireproxy socks5 自动检测配置向导"
    echo "========================================="
    echo ""

    read -p "请输入 socks5 地址 (例如 127.0.0.1:40000): " SOCKS_ADDR

    read -p "请输入 socks5 用户名: " SOCKS_USERNAME

    read -p "请输入 socks5 密码: " SOCKS_PASSWORD
    echo ""

    cat > "${CONFIG_FILE}" <<EOF
SOCKS_ADDR="${SOCKS_ADDR}"
SOCKS_USERNAME="${SOCKS_USERNAME}"
SOCKS_PASSWORD="${SOCKS_PASSWORD}"
EOF

    chmod 600 "${CONFIG_FILE}"

    echo ""
    echo "配置已保存:"
    echo "${CONFIG_FILE}"
    echo ""

    # =========================================
    # 自动添加 cron
    # =========================================

    CRON_CMD="* * * * * /bin/bash /root/wireproxy_monitor.sh >/dev/null 2>&1"

    if ! crontab -l 2>/dev/null | grep -Fq "/root/wireproxy_monitor.sh"; then

        (
            crontab -l 2>/dev/null
            echo "${CRON_CMD}"
        ) | crontab -

        echo "已自动添加 cron 定时检测"
        echo ""
        echo "${CRON_CMD}"
        echo ""
    else
        echo "cron 定时任务已存在"
        echo ""
    fi

fi

# =========================================
# 读取配置
# =========================================

source "${CONFIG_FILE}"

SOCKS_USER="${SOCKS_USERNAME}:${SOCKS_PASSWORD}"

SUCCESS=0

# =========================================
# 开始检测
# =========================================

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
# 检测成功
# =========================================

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
    echo ""

    echo "IPv6:"
    curl -6 -s \
        --connect-timeout 5 \
        --max-time 10 \
        --socks5-hostname ${SOCKS_ADDR} \
        --proxy-user "${SOCKS_USER}" \
        https://ipv6.ip.sb 2>/dev/null

    echo ""
    echo ""

    echo 0 > ${FAIL_FILE}

    exit 0

fi

# =========================================
# 检测失败
# =========================================

FAIL_COUNT=$(cat ${FAIL_FILE} 2>/dev/null || echo 0)

FAIL_COUNT=$((FAIL_COUNT + 1))

echo "$(date '+%F %T') WARP检测失败，第 ${FAIL_COUNT} 次"

echo ${FAIL_COUNT} > ${FAIL_FILE}

# =========================================
# 达到阈值自动重启
# =========================================

if [[ "$FAIL_COUNT" -ge "$MAX_FAIL" ]]; then

    echo "$(date '+%F %T') 连续失败达到阈值，重启 wireproxy"

    systemctl restart wireproxy

    sleep 5

    echo "$(date '+%F %T') wireproxy 重启完成"

    echo 0 > ${FAIL_FILE}

fi
