#!/bin/bash

set -e

echo "===== WARP + wireproxy 自动安装 ====="

WORKDIR=/opt/warp
SOCKS_PORT=40000

mkdir -p $WORKDIR
cd $WORKDIR

echo "安装依赖..."
apt update
apt install -y curl wget sudo tar

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
WorkingDirectory=$WORKDIR
ExecStart=/usr/local/bin/wireproxy -c $WORKDIR/wireproxy.conf
Restart=always

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
echo "curl --socks5-hostname 127.0.0.1:$SOCKS_PORT ip.sb"

