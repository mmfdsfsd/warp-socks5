#!/bin/bash

set -e

echo "===== WARP + wireproxy 自动安装 ====="

WORKDIR=/opt/warp
SOCKS_PORT=40000

mkdir -p $WORKDIR
cd $WORKDIR

echo "安装依赖..."
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID=$ID
else
    echo "无法识别系统类型"
    exit 1
fi
# 统一非交互模式（避免卡死）
export DEBIAN_FRONTEND=noninteractive
if [[ "$OS_ID" =~ ^(centos|rhel|almalinux|rocky)$ ]]; then
    echo "检测到 RHEL 系-系统: $OS_ID"
    PKG_UPDATE="yum -y update"
    PKG_INSTALL="yum -y install"
elif [[ "$OS_ID" =~ ^(debian|ubuntu)$ ]]; then
    echo "检测到 Debian 系-系统: $OS_ID"
    PKG_UPDATE="apt update -y"
    PKG_INSTALL="apt install -y"
else
    echo "不支持的系统: $OS_ID"
    exit 1
fi
# 执行
eval "$PKG_UPDATE"
eval "$PKG_INSTALL curl wget sudo tar"

echo "下载 wgcf..."
wget -O wgcf https://github.com/ViRb3/wgcf/releases/download/v2.2.30/wgcf_2.2.30_linux_amd64
chmod +x wgcf

echo "注册 WARP..."
yes | ./wgcf register

echo "生成 WireGuard 配置..."
./wgcf generate

echo "下载 wireproxy..."
wget https://github.com/windtf/wireproxy/releases/download/v1.1.2/wireproxy_linux_amd64.tar.gz
tar -zxvf wireproxy_linux_amd64.tar.gz
chmod +x wireproxy
mv wireproxy /usr/local/bin/

PRIVATE_KEY=$(grep PrivateKey wgcf-profile.conf | awk '{print $3}')
PUBLIC_KEY=$(grep PublicKey wgcf-profile.conf | awk '{print $3}')
ADDRESS=$(grep Address wgcf-profile.conf | awk '{print $3}')

echo "生成 wireproxy 配置..."
cat > wireproxy.conf <<EOF
[Interface]
PrivateKey = $PRIVATE_KEY
Address = $ADDRESS
DNS = 1.1.1.1

[Peer]
PublicKey = $PUBLIC_KEY
Endpoint = engage.cloudflareclient.com:2408
AllowedIPs = 0.0.0.0/0

[Socks5]
BindAddress = 127.0.0.1:$SOCKS_PORT
EOF

echo "创建 systemd 服务..."
cat > /etc/systemd/system/wireproxy.service <<EOF
[Unit]
Description=Wireproxy WARP Proxy
After=network.target

[Service]
Type=simple
MemoryLimit=300M
MemorySwapLimit=600M
Environment=GOGC=30
WorkingDirectory=$WORKDIR
ExecStart=/usr/local/bin/wireproxy -c $WORKDIR/wireproxy.conf
Restart=always
RestartSec=5s
StartLimitInterval=0

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable wireproxy
systemctl restart wireproxy

echo ""
echo "===== 安装完成 ====="
echo "SOCKS5 地址:"
echo "IP: 127.0.0.1"
echo "PORT: $SOCKS_PORT"
echo ""
echo "测试Warp是否连接上:"
echo "curl --socks5-hostname 127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace | grep warp"
echo "测试Warp的IP:"
echo "curl --socks5-hostname 127.0.0.1:40000 ip.sb"
echo "更换Warp的接入IP:"
echo "systemctl restart wireproxy"

