#!/bin/bash

# ==========================================================
# ocserv 一键安装脚本
# Cisco Secure Client / AnyConnect
# 认证方式: 用户名 + 密码
#
# Ubuntu 18.04/20.04/22.04/24.04
# Debian 10+
# ==========================================================


set -e


if [ "$EUID" -ne 0 ]; then
    echo "请使用 root 运行"
    exit 1
fi


echo "===================================="
echo " OpenConnect VPN Server Installer"
echo "===================================="


PUBLIC_IP=$(curl -s https://api.ipify.org)


read -p "VPN用户名: " VPN_USER

read -s -p "VPN密码: " VPN_PASS
echo


echo ""
echo "选择服务器证书方式:"
echo "1) 域名 + Let's Encrypt"
echo "2) IP地址 + 自签名证书"

read -p "请选择 [1-2]: " CERT_MODE



apt update

apt install -y \
ocserv \
gnutls-bin \
iptables \
certbot \
curl \
openssl



mkdir -p /etc/ocserv/certs



# ------------------------------------------------
# 服务器证书
# ------------------------------------------------


if [ "$CERT_MODE" = "1" ]; then


    read -p "请输入域名: " DOMAIN

    read -p "请输入邮箱: " EMAIL


    certbot certonly \
    --standalone \
    --agree-tos \
    --email "$EMAIL" \
    -d "$DOMAIN" \
    --non-interactive


    SERVER_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    SERVER_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"


else


    DOMAIN="$PUBLIC_IP"


    cd /etc/ocserv/certs


    cat > server.tmpl <<EOF

cn = $PUBLIC_IP

organization = MyVPN

expiration_days = 3650

signing_key

encryption_key

tls_www_server

EOF



    certtool \
    --generate-privkey \
    --outfile server-key.pem



    certtool \
    --generate-self-signed \
    --load-privkey server-key.pem \
    --template server.tmpl \
    --outfile server-cert.pem



    SERVER_CERT="/etc/ocserv/certs/server-cert.pem"

    SERVER_KEY="/etc/ocserv/certs/server-key.pem"


fi




# ------------------------------------------------
# ocserv 配置
# ------------------------------------------------


cat > /etc/ocserv/ocserv.conf <<EOF


auth = "plain[passwd=/etc/ocserv/ocpasswd]"


tcp-port = 443

udp-port = 443



run-as-user = ocserv

run-as-group = ocserv



socket-file = /var/run/ocserv-socket

chroot-dir = /var/lib/ocserv



server-cert = $SERVER_CERT

server-key = $SERVER_KEY



device = vpns



max-clients = 128

max-same-clients = 3



keepalive = 30

dpd = 90

mobile-dpd = 300



try-mtu-discovery = true


idle-timeout = 1200

mobile-idle-timeout = 1800



ipv4-network = 10.10.10.0

ipv4-netmask = 255.255.255.0



dns = 8.8.8.8

dns = 1.1.1.1



tunnel-all-dns = true


default-domain = $DOMAIN


cisco-client-compat = true


EOF




# ------------------------------------------------
# 创建用户
# ------------------------------------------------


touch /etc/ocserv/ocpasswd


echo "$VPN_PASS" | \
ocpasswd \
-c /etc/ocserv/ocpasswd \
"$VPN_USER"




# ------------------------------------------------
# 开启转发
# ------------------------------------------------


cat > /etc/sysctl.d/60-ocserv.conf <<EOF

net.ipv4.ip_forward = 1

net.core.default_qdisc=fq

net.ipv4.tcp_congestion_control=bbr

EOF


sysctl --system



# ------------------------------------------------
# 防火墙 NAT
# ------------------------------------------------


NIC=$(ip route get 8.8.8.8 | awk '{print $5}')


iptables -t nat \
-A POSTROUTING \
-s 10.10.10.0/24 \
-o "$NIC" \
-j MASQUERADE


iptables \
-A FORWARD \
-s 10.10.10.0/24 \
-j ACCEPT


iptables \
-A FORWARD \
-d 10.10.10.0/24 \
-j ACCEPT



# 保存iptables

apt install -y iptables-persistent


netfilter-persistent save




# ------------------------------------------------
# 启动
# ------------------------------------------------


systemctl enable ocserv

systemctl restart ocserv



echo ""
echo "===================================="
echo "安装完成"
echo "===================================="

echo "服务器:"
echo "$DOMAIN"

echo ""

echo "用户名:"
echo "$VPN_USER"

echo ""

echo "密码:"
echo "$VPN_PASS"


echo ""

echo "Cisco Secure Client:"
echo "AnyConnect VPN"
echo "地址: $DOMAIN"

echo "认证方式:"
echo "Username + Password"

echo "===================================="
