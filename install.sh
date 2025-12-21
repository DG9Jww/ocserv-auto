#!/bin/bash

# =================================================================
# OpenConnect VPN (ocserv) 一键安装脚本
# 适用系统: Ubuntu 18.04+/20.04+/22.04+, Debian 10+
# =================================================================

set -e

# 检查是否为 Root 运行
if [[ $EUID -ne 0 ]]; then
   echo "请以 root 权限运行此脚本"
   exit 1
fi

# 获取当前公网 IP
PUBLIC_IP=$(curl -s https://api.ipify.org || wget -qO- https://api.ipify.org)

echo "--------------------------------------------------"
echo "欢迎使用 ocserv 自动配置脚本"
echo "--------------------------------------------------"
echo "1) 域名模式 (推荐: 使用 Let's Encrypt 证书，客户端不报错)"
echo "2) IP 模式 (使用自签名证书)"
read -p "请选择安装模式 [1-2]: " MODE

if [ "$MODE" == "1" ]; then
    read -p "请输入你的域名 (例如 vpn.example.com): " DOMAIN
    read -p "请输入你的邮箱 (用于 Let's Encrypt 通知): " EMAIL
else
    DOMAIN=$PUBLIC_IP
fi

read -p "设置 VPN 用户名: " VPN_USER
read -p "设置 VPN 密码: " VPN_PASS

# 1. 安装基础依赖
echo "正在安装依赖项..."
apt-get update
apt-get install -y ocserv gnutls-bin iptables certbot cron

# 2. 证书处理
mkdir -p /etc/ocserv/certs
cd /etc/ocserv/certs

if [ "$MODE" == "1" ]; then
    echo "申请 Let's Encrypt 证书..."
    # 停止占用 80 端口的服务以申请证书
    systemctl stop nginx || true
    certbot certonly --standalone --preferred-challenges http --agree-tos --email "$EMAIL" -d "$DOMAIN" --non-interactive
    
    SERVER_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    SERVER_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
else
    echo "生成自签名证书..."
    # 生成 CA
    cat << _EOF_ > ca.tmpl
cn = "VPN CA"
organization = "Network"
serial = 1
expiration_days = 3650
ca
signing_key
cert_signing_key
crl_signing_key
_EOF_

    certtool --generate-privkey --outfile ca-key.pem
    certtool --generate-self-signed --load-privkey ca-key.pem --template ca.tmpl --outfile ca-cert.pem

    # 生成服务器证书
    cat << _EOF_ > server.tmpl
cn = "$PUBLIC_IP"
organization = "Network"
expiration_days = 3650
signing_key
encryption_key
tls_www_server
_EOF_

    certtool --generate-privkey --outfile server-key.pem
    certtool --generate-certificate --load-privkey server-key.pem --load-ca-certificate ca-cert.pem --load-ca-privkey ca-key.pem --template server.tmpl --outfile server-cert.pem

    SERVER_CERT="/etc/ocserv/certs/server-cert.pem"
    SERVER_KEY="/etc/ocserv/certs/server-key.pem"
fi

# 3. 写入 ocserv 配置文件
echo "配置 ocserv.conf..."
cat << EOF > /etc/ocserv/ocserv.conf
auth = "plain[passwd=/etc/ocserv/ocpasswd]"
tcp-port = 443
# 根据 LinuxBabe 建议，如果开启 BBR，可以关闭 UDP 以获得更稳定的体验
# udp-port = 443

run-as-user = ocserv
run-as-group = ocserv
socket-file = /var/run/ocserv-socket
chroot-dir = /var/lib/ocserv

server-cert = $SERVER_CERT
server-key = $SERVER_KEY

# 优化设置
keepalive = 30
dpd = 90
mobile-dpd = 300
try-mtu-discovery = true
idle-timeout=1200
mobile-idle-timeout=1800

max-clients = 128
max-same-clients = 2

default-domain = $DOMAIN

# 内部 IP 范围 (避开 192.168.1.x 以防止与家用路由器冲突)
ipv4-network = 10.10.10.0
ipv4-netmask = 255.255.255.0

dns = 8.8.8.8
dns = 1.1.1.1

# dns也加密，可选
tunnel-all-dns = true
cisco-client-compat = true

# 路由设置: 默认全代理
# 如果需要分流，可以在这里修改 route
EOF

# 4. 创建 VPN 账户
echo "$VPN_PASS" | ocpasswd -c /etc/ocserv/ocpasswd "$VPN_USER"

# 5. 开启内核转发与 TCP BBR 优化
echo "优化系统内核参数 (IP Forwarding & BBR)..."
cat << EOF > /etc/sysctl.d/60-ocserv.conf
net.ipv4.ip_forward = 1
#如果不开启bbr，使用udp，则不用写下面两条配置，且ocserv配置文件里面打开upd-port选项
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
sysctl -p /etc/sysctl.d/60-ocserv.conf

# 6. 配置防火墙 (iptables)
echo "配置防火墙转发规则..."
# 获取主网卡名
ETH_INTERFACE=$(ip route get 8.8.8.8 | awk -- '{printf $5}')
iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o "$ETH_INTERFACE" -j MASQUERADE
iptables -A FORWARD -s 10.10.10.0/24 -j ACCEPT

# 7. 启动服务
systemctl enable ocserv
systemctl restart ocserv

echo "--------------------------------------------------"
echo "安装完成！"
echo "服务器地址: $DOMAIN"
echo "端口: 443"
echo "用户名: $VPN_USER"
echo "密码: $VPN_PASS"
echo "--------------------------------------------------"
if [ "$MODE" == "2" ]; then
    echo "注意：由于使用 IP 模式（自签名证书），连接时请在客户端勾选 'AnyConnect 能够连接到不可信的服务器'。"
fi
