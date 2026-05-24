#!/bin/bash

set -e

WORKDIR="/opt/warp"
SERVICE_NAME="wireproxy"

green() {
    echo -e "\033[32m$1\033[0m"
}

red() {
    echo -e "\033[31m$1\033[0m"
}

yellow() {
    echo -e "\033[33m$1\033[0m"
}

check_root() {
    if [ "$(id -u)" != "0" ]; then
        red "请使用 root 权限运行"
        exit 1
    fi
}

detect_os() {

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID=$ID
    else
        red "无法识别系统"
        exit 1
    fi

    export DEBIAN_FRONTEND=noninteractive

    if [[ "$OS_ID" =~ ^(centos|rhel|almalinux|rocky)$ ]]; then
        OS_FAMILY="rhel"
    elif [[ "$OS_ID" =~ ^(debian|ubuntu)$ ]]; then
        OS_FAMILY="debian"
    else
        red "不支持的系统: $OS_ID"
        exit 1
    fi
}

install_deps() {

    green "安装依赖..."

    if [[ "$OS_FAMILY" == "rhel" ]]; then

        yum -y update
        yum -y install curl wget tar sudo

    else

        apt update -y
        apt install -y curl wget tar sudo

    fi
}

open_firewall() {

    green "开放防火墙端口..."

    if [[ "$OS_FAMILY" == "rhel" ]]; then

        if command -v firewall-cmd >/dev/null 2>&1; then
            firewall-cmd --permanent --add-port=${SOCKS_PORT}/tcp || true
            firewall-cmd --reload || true
        fi

    else

        if command -v ufw >/dev/null 2>&1; then
            ufw allow ${SOCKS_PORT}/tcp || true
        fi

    fi
}

close_firewall() {

    yellow "关闭防火墙端口..."

    if [[ "$OS_FAMILY" == "rhel" ]]; then

        if command -v firewall-cmd >/dev/null 2>&1; then
            firewall-cmd --permanent --remove-port=${SOCKS_PORT}/tcp || true
            firewall-cmd --reload || true
        fi

    else

        if command -v ufw >/dev/null 2>&1; then
            ufw delete allow ${SOCKS_PORT}/tcp || true
        fi

    fi
}

check_port() {

    if ss -lnt | grep -q ":${SOCKS_PORT} "; then
        red "端口 ${SOCKS_PORT} 已被占用"
        exit 1
    fi
}

install_warp() {

    clear

    SERVER_IP=$(curl -s4 ip.sb || curl -s4 ifconfig.me || echo "YOUR_SERVER_IP")

    green "===== 安装 WARP + wireproxy ====="

    echo ""

    read -p "请输入 SOCKS5 端口 [默认:40000]: " SOCKS_PORT
    SOCKS_PORT=${SOCKS_PORT:-40000}

    echo ""

    read -p "请输入 SOCKS5 用户名 [默认:${SERVER_IP}]: " SOCKS_USER
    SOCKS_USER=${SOCKS_USER:-${SERVER_IP}}

    echo ""

    RANDOM_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)

    read -p "请输入 SOCKS5 密码 [默认:${RANDOM_PASS}]: " SOCKS_PASS
    SOCKS_PASS=${SOCKS_PASS:-${RANDOM_PASS}}

    echo ""

    green "配置如下:"
    echo "端口: ${SOCKS_PORT}"
    echo "用户名: ${SOCKS_USER}"
    echo "密码: ${SOCKS_PASS}"

    echo ""

    read -p "确认安装？[y/n]: " CONFIRM

    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        red "已取消"
        exit 0
    fi

    check_port

    mkdir -p ${WORKDIR}

    cd ${WORKDIR}

    install_deps

    green "下载 wgcf..."

    wget -O wgcf \
    https://github.com/ViRb3/wgcf/releases/download/v2.2.30/wgcf_2.2.30_linux_amd64

    chmod +x wgcf

    green "注册 WARP..."

    yes | ./wgcf register

    green "生成 WARP 配置..."

    ./wgcf generate

    green "下载 wireproxy..."

    wget -O wireproxy.tar.gz \
    https://github.com/pufferffish/wireproxy/releases/download/v1.0.9/wireproxy_linux_amd64.tar.gz

    tar -zxvf wireproxy.tar.gz

    chmod +x wireproxy

    mv -f wireproxy /usr/local/bin/

    green "追加 SOCKS5 配置..."

    cat >> wgcf-profile.conf <<EOF

[Socks5]
BindAddress = 0.0.0.0:${SOCKS_PORT}
Username = ${SOCKS_USER}
Password = ${SOCKS_PASS}
EOF

    green "创建 systemd 服务..."

    cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=Wireproxy WARP Proxy
After=network.target

[Service]
Type=simple

WorkingDirectory=${WORKDIR}

ExecStart=/usr/local/bin/wireproxy -c ${WORKDIR}/wgcf-profile.conf

Restart=always
RestartSec=5

Environment=GOGC=30

MemoryLimit=300M

LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload

    systemctl enable ${SERVICE_NAME}

    systemctl restart ${SERVICE_NAME}

    open_firewall

    sleep 5

    echo ""

    green "===== 服务状态 ====="

    systemctl --no-pager status ${SERVICE_NAME} || true

    echo ""

    green "===== 端口监听 ====="

    ss -lntp | grep ${SOCKS_PORT} || true

    echo ""

    green "===== WARP 状态检测 ====="

    WARP_STATUS=$(curl -s \
    --connect-timeout 15 \
    --socks5-hostname 127.0.0.1:${SOCKS_PORT} \
    --proxy-user "${SOCKS_USER}:${SOCKS_PASS}" \
    https://www.cloudflare.com/cdn-cgi/trace | grep warp= || true)

   if echo "${WARP_STATUS}" | grep -q "warp=on"; then

    green "WARP 运行正常"

    echo ""

    green "===== WARP 出口信息 ====="

    WARP_IPV4=$(curl -s4 \
    --connect-timeout 15 \
    --socks5-hostname 127.0.0.1:${SOCKS_PORT} \
    --proxy-user "${SOCKS_USER}:${SOCKS_PASS}" \
    ipv4.ip.sb || true)

    WARP_IPV6=$(curl -s6 \
    --connect-timeout 15 \
    --socks5-hostname 127.0.0.1:${SOCKS_PORT} \
    --proxy-user "${SOCKS_USER}:${SOCKS_PASS}" \
    ipv6.ip.sb || true)

    echo "WARP IPv4: ${WARP_IPV4:-获取失败}"

    if [[ -n "$WARP_IPV6" ]]; then
        echo "WARP IPv6: ${WARP_IPV6}"
    else
        yellow "WARP IPv6: 当前不可用"
    fi

    echo ""

    green "===== WARP 网络状态 ====="

    if [[ -n "$WARP_IPV4" && -n "$WARP_IPV6" ]]; then

        green "双栈模式: IPv4 + IPv6"

    elif [[ -n "$WARP_IPV4" ]]; then

        yellow "单栈模式: 仅 IPv4"

    elif [[ -n "$WARP_IPV6" ]]; then

        yellow "单栈模式: 仅 IPv6"

    else

        red "WARP 网络异常"

    fi

else

    red "WARP 检测失败"

fi

    echo ""

    green "===== 安装完成 ====="

    echo ""

    echo "SOCKS5 信息:"
    echo "地址: ${SERVER_IP}"
    echo "端口: ${SOCKS_PORT}"
    echo "用户名: ${SOCKS_USER}"
    echo "密码: ${SOCKS_PASS}"

    echo ""

    echo "连接格式:"
    echo "${SERVER_IP}:${SOCKS_PORT}:${SOCKS_USER}:${SOCKS_PASS}"

    echo ""

    echo "测试 IPv4:"
    echo "curl --socks5-hostname 127.0.0.1:${SOCKS_PORT} --proxy-user '${SOCKS_USER}:${SOCKS_PASS}' ipv4.ip.sb"

    echo ""

    echo "测试 WARP:"
    echo "curl --socks5-hostname 127.0.0.1:${SOCKS_PORT} --proxy-user '${SOCKS_USER}:${SOCKS_PASS}' https://www.cloudflare.com/cdn-cgi/trace | grep warp"

    echo ""

    echo "测试 IPv6:"
    echo "curl --socks5-hostname 127.0.0.1:${SOCKS_PORT} --proxy-user '${SOCKS_USER}:${SOCKS_PASS}' ipv6.ip.sb"

    echo ""

    echo "更换 WARP 出口 IP:"
    echo "systemctl restart ${SERVICE_NAME}"

    echo ""

    echo "查看实时日志:"
    echo "journalctl -u ${SERVICE_NAME} -f"

    echo ""
}

uninstall_warp() {

    clear

    yellow "===== 卸载 WARP + wireproxy ====="

    echo ""

    read -p "确认卸载？[y/n]: " CONFIRM

    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        red "已取消"
        exit 0
    fi

    SOCKS_PORT=$(grep BindAddress ${WORKDIR}/wgcf-profile.conf 2>/dev/null | awk -F ':' '{print $2}')

    systemctl stop ${SERVICE_NAME} 2>/dev/null || true

    systemctl disable ${SERVICE_NAME} 2>/dev/null || true

    rm -f /etc/systemd/system/${SERVICE_NAME}.service

    systemctl daemon-reload

    close_firewall

    rm -rf ${WORKDIR}

    rm -f /usr/local/bin/wireproxy

    green "卸载完成"
}

show_menu() {

    clear

    green "================================="
    green " WARP + wireproxy 管理脚本"
    green "================================="

    echo ""

    echo "1. 安装 WARP SOCKS5"
    echo "2. 卸载 WARP SOCKS5"
    echo "0. 退出"

    echo ""
}

main() {

    check_root

    detect_os

    show_menu

    read -p "请输入选项: " CHOICE

    case "$CHOICE" in
        1)
            install_warp
            ;;
        2)
            uninstall_warp
            ;;
        0)
            exit 0
            ;;
        *)
            red "无效选项"
            exit 1
            ;;
    esac
}

main
