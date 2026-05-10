#!/bin/bash

set -e

WORKDIR="/opt/warp"
SERVICE_NAME="wireproxy"
MONITOR_SCRIPT="/root/wireproxy_monitor.sh"
CONFIG_FILE="/root/.wireproxy_monitor.conf"
FAIL_FILE="/tmp/wireproxy_fail_count"

green() { echo -e "\033[32m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }

check_root() {
    [[ "$(id -u)" != "0" ]] && red "请使用 root 运行" && exit 1
}

detect_os() {
    . /etc/os-release
    OS_ID=$ID

    if [[ "$OS_ID" =~ ^(centos|rhel|almalinux|rocky)$ ]]; then
        OS_FAMILY="rhel"
    elif [[ "$OS_ID" =~ ^(debian|ubuntu)$ ]]; then
        OS_FAMILY="debian"
    else
        red "不支持系统: $OS_ID"
        exit 1
    fi

    export DEBIAN_FRONTEND=noninteractive
}

install_deps() {
    green "安装依赖..."

    if [[ "$OS_FAMILY" == "rhel" ]]; then
        yum -y install curl wget tar sudo
    else
        apt update -y
        apt install -y curl wget tar sudo
    fi
}

open_firewall() {
    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port=${SOCKS_PORT}/tcp || true
        firewall-cmd --reload || true
    fi

    if command -v ufw >/dev/null 2>&1; then
        ufw allow ${SOCKS_PORT}/tcp || true
    fi
}

close_firewall() {
    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --remove-port=${SOCKS_PORT}/tcp || true
        firewall-cmd --reload || true
    fi

    if command -v ufw >/dev/null 2>&1; then
        ufw delete allow ${SOCKS_PORT}/tcp || true
    fi
}

check_port() {
    ss -lnt | grep -q ":${SOCKS_PORT} " && red "端口占用" && exit 1
}

write_monitor() {

cat > ${MONITOR_SCRIPT} <<EOF
#!/bin/bash

exec 9>/tmp/wireproxy.lock
flock -n 9 || exit 1

SOCKS_ADDR="127.0.0.1:${SOCKS_PORT}"
SOCKS_USER="${SOCKS_USER}:${SOCKS_PASS}"

FAIL_FILE="${FAIL_FILE}"
MAX_FAIL=3

SITES=(
    "https://ip.sb"
    "https://ip.me"
    "https://api.ipify.org"
)

SUCCESS=0

for SITE in "\${SITES[@]}"; do
    HTTP_CODE=\$(curl -s --connect-timeout 10 --max-time 15 \
        --socks5-hostname \${SOCKS_ADDR} \
        --proxy-user "\${SOCKS_USER}" \
        -o /dev/null -w "%{http_code}" \${SITE})

    if [[ "\$HTTP_CODE" == "200" ]]; then
        SUCCESS=1
        break
    fi
done

if [[ "\$SUCCESS" == "1" ]]; then
    echo 0 > \${FAIL_FILE}
    exit 0
fi

FAIL_COUNT=\$(cat \${FAIL_FILE} 2>/dev/null || echo 0)
FAIL_COUNT=\$((FAIL_COUNT + 1))
echo \${FAIL_COUNT} > \${FAIL_FILE}

if [[ "\$FAIL_COUNT" -ge "\$MAX_FAIL" ]]; then
    systemctl restart ${SERVICE_NAME}
    sleep 5
    echo 0 > \${FAIL_FILE}
fi
EOF

chmod +x ${MONITOR_SCRIPT}
}

write_cron() {
    CRON_CMD="* * * * * /bin/bash ${MONITOR_SCRIPT} >/dev/null 2>&1"

    if ! crontab -l 2>/dev/null | grep -q "${MONITOR_SCRIPT}"; then
        (crontab -l 2>/dev/null; echo "${CRON_CMD}") | crontab -
        green "cron 已写入"
    else
        yellow "cron 已存在"
    fi
}

install_warp() {

    clear
    SERVER_IP=$(curl -s4 ip.sb || echo "YOUR_IP")

    green "===== WARP + wireproxy 安装 ====="

    read -p "SOCKS端口(40000): " SOCKS_PORT
    SOCKS_PORT=${SOCKS_PORT:-40000}

    read -p "用户名(${SERVER_IP}): " SOCKS_USER
    SOCKS_USER=${SOCKS_USER:-${SERVER_IP}}

    SOCKS_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)
    read -p "密码(${SOCKS_PASS}): " input_pass
    SOCKS_PASS=${input_pass:-${SOCKS_PASS}}

    check_port
    install_deps

    mkdir -p ${WORKDIR}
    cd ${WORKDIR}

    green "下载 wgcf..."
    wget -q https://github.com/ViRb3/wgcf/releases/download/v2.2.30/wgcf_2.2.30_linux_amd64
    chmod +x wgcf

    yes | ./wgcf register
    ./wgcf generate

    sed -i '/\[Interface\]/a MTU = 1280' wgcf-profile.conf

    green "下载 wireproxy..."
    wget -q https://github.com/pufferffish/wireproxy/releases/download/v1.0.9/wireproxy_linux_amd64.tar.gz
    tar -xzf wireproxy_linux_amd64.tar.gz
    chmod +x wireproxy
    mv wireproxy /usr/local/bin/

    cat >> wgcf-profile.conf <<EOF

[Socks5]
BindAddress = 0.0.0.0:${SOCKS_PORT}
Username = ${SOCKS_USER}
Password = ${SOCKS_PASS}
EOF

    cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=WARP wireproxy
After=network.target

[Service]
Type=simple
WorkingDirectory=${WORKDIR}
ExecStart=/usr/local/bin/wireproxy -c ${WORKDIR}/wgcf-profile.conf
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ${SERVICE_NAME}
    systemctl restart ${SERVICE_NAME}

    open_firewall

    sleep 5

    green "生成监控脚本 + cron"
    write_monitor
    write_cron

    green "===== 安装完成 ====="

    echo "IP: ${SERVER_IP}"
    echo "PORT: ${SOCKS_PORT}"
    echo "USER: ${SOCKS_USER}"
    echo "PASS: ${SOCKS_PASS}"
    echo ""
    echo "测试:"
    echo "curl --socks5-hostname 127.0.0.1:${SOCKS_PORT} --proxy-user '${SOCKS_USER}:${SOCKS_PASS}' ip.sb"
}

uninstall_warp() {

    yellow "===== 卸载 ====="

    read -p "确认卸载? [y/n]: " c
    [[ ! "$c" =~ ^[Yy]$ ]] && exit 0

    systemctl stop ${SERVICE_NAME} 2>/dev/null || true
    systemctl disable ${SERVICE_NAME} 2>/dev/null || true
    rm -f /etc/systemd/system/${SERVICE_NAME}.service
    systemctl daemon-reload

    rm -rf ${WORKDIR}
    rm -f /usr/local/bin/wireproxy

    rm -f ${MONITOR_SCRIPT}
    rm -f ${CONFIG_FILE}
    rm -f ${FAIL_FILE}

    crontab -l 2>/dev/null | grep -v "${MONITOR_SCRIPT}" | crontab -

    close_firewall

    green "卸载完成"
}

menu() {
    clear
    echo "1. 安装 WARP SOCKS5"
    echo "2. 卸载 WARP SOCKS5"
    echo "0. 退出"
}

main() {
    check_root
    detect_os
    menu
    read -p "选择: " opt

    case "$opt" in
        1) install_warp ;;
        2) uninstall_warp ;;
        *) exit 0 ;;
    esac
}

main
