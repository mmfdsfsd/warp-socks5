#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
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
    # 自动添加 cron
    # =========================================

    CRON_CMD="* * * * * /bin/bash /opt/warp/wireproxy_monitor.sh >/dev/null 2>&1"

    if ! crontab -l 2>/dev/null | grep -Fq "/opt/warp/wireproxy_monitor.sh"; then

        (
            crontab -l 2>/dev/null
            echo "${CRON_CMD}"
        ) | crontab -

        green "已自动添加 cron 定时检测"
        echo ""
        echo "${CRON_CMD}"
        echo ""
    else
        yellow "cron 定时任务已存在"
        echo ""
    fi

# =========================================
# 读取 SOCKS5 配置
# =========================================
# 使用 awk 提取冒号后的端口号，确保只匹配 [Socks5] 下方的 BindAddress
SOCKS_PORT=$(grep -A 5 "\[Socks5\]" "$WGCF_CONF" | grep "BindAddress" | awk -F':' '{print $2}' | xargs)
SOCKS_ADDR="127.0.0.1:${SOCKS_PORT}"


# 提取账号密码
SOCKS_USERNAME=$(grep -A 5 "\[Socks5\]" "$WGCF_CONF" | grep "^Username" | awk -F'=' '{print $2}' | xargs)
SOCKS_PASSWORD=$(grep -A 5 "\[Socks5\]" "$WGCF_CONF" | grep "^Password" | awk -F'=' '{print $2}' | xargs)
SOCKS_USER="${SOCKS_USERNAME}:${SOCKS_PASSWORD}"

# =========================================
# 开始检测
# =========================================
SUCCESS=0

for SITE in "${SITES[@]}"; do

    HTTP_CODE=$(curl -s \
        --connect-timeout 3 \
        --max-time 5 \
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
    green "===== WARP-IPv4 ====="
    curl -4 -s \
        --connect-timeout 3 \
        --max-time 5 \
        --socks5-hostname ${SOCKS_ADDR} \
        --proxy-user "${SOCKS_USER}" \
        https://ipv4.ip.sb 

    green "===== WARP-IPv6 ====="
    curl -6 -s \
        --connect-timeout 3 \
        --max-time 5 \
        --socks5-hostname ${SOCKS_ADDR} \
        --proxy-user "${SOCKS_USER}" \
        https://ipv6.ip.sb 2>/dev/null
		
	echo ""
    green "WARP检测正常，立即结束并退出当前脚本，返回状态码 0"
    exit 0
fi

# =========================================
# 检测失败立即重启
# =========================================

red "$(date '+%F %T') WARP检测失败，正在重启 wireproxy"

systemctl restart wireproxy
sleep 5
systemctl status wireproxy

green "$(date '+%F %T') wireproxy 重启完成"
	echo ""
    green "===== WARP-IPv4 ====="
    curl -4 -s \
        --connect-timeout 3 \
        --max-time 5 \
        --socks5-hostname ${SOCKS_ADDR} \
        --proxy-user "${SOCKS_USER}" \
        https://ipv4.ip.sb 

    green "===== WARP-IPv6 ====="
    curl -6 -s \
        --connect-timeout 3 \
        --max-time 5 \
        --socks5-hostname ${SOCKS_ADDR} \
        --proxy-user "${SOCKS_USER}" \
        https://ipv6.ip.sb 2>/dev/null
