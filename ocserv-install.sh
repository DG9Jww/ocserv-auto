#!/bin/bash

# =================================================================
# OpenConnect VPN (ocserv) 一键安装脚本 (支持证书认证 + P12加密)
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
echo "1) 域名模式 (推荐: 服务器用 Let's Encrypt，客户端认证用私有 CA 证书)"
echo "2) IP 模式 (全部使用自签名证书)"
read -p "请选择安装模式 [1-2]: " MODE

if [ "$MODE" == "1" ]; then
    read -p "请输入你的域名 (例如 vpn.example.com): " DOMAIN
    read -p "请输入你的邮箱 (用于 Let's Encrypt 通知，推荐gmail): " EMAIL
else
    DOMAIN=$PUBLIC_IP
fi

read -p "设置 VPN 用户名: " VPN_USER
read -p "设置 VPN 密码 (同时作为 P12 证书密码): " VPN_PASS

# 1. 安装基础依赖
echo "正在安装依赖项..."
apt-get update
apt-get install -y ocserv gnutls-bin iptables certbot cron

# 2. 证书处理
mkdir -p /etc/ocserv/certs
cd /etc/ocserv/certs

echo "正在生成私有 CA (用于客户端证书认证)..."
cat << _EOF_ > ca.tmpl
cn = "VPN Internal CA"
organization = "MyVPN"
serial = 1
expiration_days = 3650
ca
signing_key
cert_signing_key
crl_signing_key
_EOF_

certtool --generate-privkey --outfile ca-key.pem
certtool --generate-self-signed --load-privkey ca-key.pem --template ca.tmpl --outfile ca-cert.pem

if [ "$MODE" == "1" ]; then
    echo "申请 Let's Encrypt 服务器证书..."
    systemctl stop nginx || true
    certbot certonly --standalone --preferred-challenges http --agree-tos --email "$EMAIL" -d "$DOMAIN" --non-interactive
    
    SERVER_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    SERVER_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
else
    echo "生成自签名服务器证书..."
    cat << _EOF_ > server.tmpl
cn = "$PUBLIC_IP"
organization = "MyVPN"
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
auth = "certificate"
enable-auth = "plain[passwd=/etc/ocserv/ocpasswd]"

tcp-port = 443
# udp-port = 443
# 如果不是BBR加速，则开启UDP速度更快
run-as-user = ocserv
run-as-group = ocserv
socket-file = /var/run/ocserv-socket
chroot-dir = /var/lib/ocserv

server-cert = $SERVER_CERT
server-key = $SERVER_KEY
ca-cert = /etc/ocserv/certs/ca-cert.pem

cert-user-oid = 2.5.4.3

keepalive = 30
dpd = 90
mobile-dpd = 300
try-mtu-discovery = true
idle-timeout=1200
mobile-idle-timeout=1800

max-clients = 128
max-same-clients = 2

default-domain = $DOMAIN
ipv4-network = 10.10.10.0
ipv4-netmask = 255.255.255.0

dns = 8.8.8.8
dns = 1.1.1.1
# dns加密
tunnel-all-dns = true
cisco-client-compat = true
EOF

# 4. 创建 VPN 账户
touch /etc/ocserv/ocpasswd
echo "$VPN_PASS" | ocpasswd -c /etc/ocserv/ocpasswd "$VPN_USER"

# 5. 生成加密的客户端 P12 证书
echo "正在为用户 $VPN_USER 生成客户端证书..."
cat << _EOF_ > client.tmpl
cn = "$VPN_USER"
unit = "$VPN_USER"
expiration_days = 3650
signing_key
tls_www_client
_EOF_

certtool --generate-privkey --outfile "${VPN_USER}-key.pem"
certtool --generate-certificate --load-privkey "${VPN_USER}-key.pem" \
    --load-ca-certificate ca-cert.pem --load-ca-privkey ca-key.pem \
    --template client.tmpl --outfile "${VPN_USER}-cert.pem"

# 使用设置的 VPN 密码加密 P12 文件
certtool --to-p12 --load-privkey "${VPN_USER}-key.pem" \
    --load-certificate "${VPN_USER}-cert.pem" \
    --pkcs-cipher 3des-pkcs12 \
    --password "$VPN_PASS" \
    --outfile "/root/${VPN_USER}.p12" \
    --outder --p12-name="$VPN_USER"

# 6. 开启内核转发与 TCP BBR 优化
echo "优化系统内核参数..."
cat << EOF > /etc/sysctl.d/60-ocserv.conf
net.ipv4.ip_forward = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
sysctl -p /etc/sysctl.d/60-ocserv.conf

# 7. 配置防火墙
ETH_INTERFACE=$(ip route get 8.8.8.8 | awk -- '{printf $5}')
iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o "$ETH_INTERFACE" -j MASQUERADE
iptables -A FORWARD -s 10.10.10.0/24 -j ACCEPT

# 8. 启动服务
systemctl enable ocserv
systemctl restart ocserv

echo "--------------------------------------------------"
echo "安装完成！"
echo "服务器地址: $DOMAIN"
echo "用户名: $VPN_USER"
echo "VPN 密码 / 证书密码: $VPN_PASS"
echo "证书文件: /root/${VPN_USER}.p12"
echo "--------------------------------------------------"
echo "注意：导入证书到客户端时，请使用上面显示的密码。"
