#!/bin/bash

# ==========================================================
# ocserv + Cisco Secure Client 自动部署
#
# 认证:
#   Username + Password
#
# 证书:
#   Let's Encrypt IP Certificate
#
# 支持:
#   Ubuntu 22.04/24.04
#   Debian 11/12
#
# ==========================================================


set -e


if [ "$EUID" -ne 0 ]; then
    echo "请使用 root 执行"
    exit 1
fi


echo "======================================"
echo " ocserv VPN Auto Installer"
echo " Cisco Secure Client Compatible"
echo "======================================"


# -------------------------------
# 基础信息
# -------------------------------


PUBLIC_IP=$(curl -4 -s https://api.ipify.org)


if [ -z "$PUBLIC_IP" ]; then
    echo "无法获取公网IP"
    exit 1
fi


echo "检测公网IP:"
echo "$PUBLIC_IP"


read -p "VPN用户名: " VPN_USER


read -s -p "VPN密码: " VPN_PASS
echo



# -------------------------------
# 安装依赖
# -------------------------------


apt update


apt install -y \
curl \
snapd \
iptables \
ocserv \
gnutls-bin
# iptables-persistent 




# -------------------------------
# 安装新版 certbot
# -------------------------------


if command -v certbot >/dev/null
then

    echo "certbot already installed"

else

    apt update
    apt install -y certbot

fi


if ! certbot help | grep -q "ip-address"
then

    echo "Current certbot does not support IP certificate"
    echo "Installing latest certbot using snap"


    apt remove -y certbot || true


    apt install -y snapd


    snap install core

    snap refresh core


    snap install --classic certbot


    ln -sf /snap/bin/certbot /usr/bin/certbot

fi


echo "certbot version:"
certbot --version



# -------------------------------
# 停止ocserv
# 避免443冲突
# -------------------------------


systemctl stop ocserv || true



# -------------------------------
# 申请 Let's Encrypt IP证书
# -------------------------------


echo "申请 Let's Encrypt IP Certificate"
echo "请确保安全组开放:"
echo "TCP 80"
echo "TCP 443"
echo "UDP 443"

certbot certonly \
--standalone \
--preferred-profile shortlived \
--ip-address "$PUBLIC_IP" \
--agree-tos \
--non-interactive



CERT_DIR="/etc/letsencrypt/live/$PUBLIC_IP"


SERVER_CERT="$CERT_DIR/fullchain.pem"

SERVER_KEY="$CERT_DIR/privkey.pem"



if [ ! -f "$SERVER_CERT" ]; then

    echo "证书申请失败"

    exit 1

fi



echo "证书:"
echo "$SERVER_CERT"



# -------------------------------
# 配置 ocserv
# -------------------------------


mkdir -p /etc/ocserv


cat > /etc/ocserv/ocserv.conf <<EOF


# ==============================
# Authentication
# ==============================


auth = "plain[passwd=/etc/ocserv/ocpasswd]"



# ==============================
# Listen
# ==============================


tcp-port = 443

udp-port = 443



# ==============================
# Runtime
# ==============================


run-as-user = ocserv

run-as-group = ocserv



socket-file = /var/run/ocserv-socket



device = vpns



# 不使用chroot
# 避免socket路径问题



# ==============================
# Certificate
# ==============================


server-cert = $SERVER_CERT

server-key = $SERVER_KEY



# ==============================
# Session
# ==============================


max-clients = 128

max-same-clients = 2


keepalive = 30

dpd = 90

mobile-dpd = 300


try-mtu-discovery = true


idle-timeout = 1200

mobile-idle-timeout = 1800



# ==============================
# Network
# ==============================


ipv4-network = 10.10.10.0

ipv4-netmask = 255.255.255.0



dns = 8.8.8.8

dns = 1.1.1.1



tunnel-all-dns = true



default-domain = $PUBLIC_IP



# Cisco compatibility

cisco-client-compat = true


EOF




# -------------------------------
# 创建VPN用户
# -------------------------------


touch /etc/ocserv/ocpasswd


echo "$VPN_PASS" | \
ocpasswd \
-c /etc/ocserv/ocpasswd \
"$VPN_USER"




# -------------------------------
# 开启IP Forward
# -------------------------------


cat > /etc/sysctl.d/60-ocserv.conf <<EOF

net.ipv4.ip_forward = 1

net.core.default_qdisc = fq

net.ipv4.tcp_congestion_control = bbr

EOF



sysctl --system




# -------------------------------
# NAT
# -------------------------------


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



# netfilter-persistent save




# -------------------------------
# 自动续期
# -------------------------------


cat > /etc/systemd/system/ocserv-cert-renew.service <<EOF

[Unit]

Description=Renew Let's Encrypt IP certificate for ocserv



[Service]

Type=oneshot

ExecStart=/bin/bash -c '/usr/bin/certbot renew --quiet --deploy-hook "systemctl restart ocserv"'

EOF



cat > /etc/systemd/system/ocserv-cert-renew.timer <<EOF

[Unit]

Description= Certbot renew every three days



[Timer]

OnCalendar=*-*-*/3 03:00:00

Persistent=true



[Install]

WantedBy=timers.target

EOF



systemctl daemon-reload


systemctl enable ocserv-cert-renew.timer

systemctl start ocserv-cert-renew.timer




# -------------------------------
# 启动ocserv
# -------------------------------


systemctl enable ocserv


systemctl restart ocserv




echo ""
echo "======================================"
echo " 安装完成"
echo "======================================"

echo ""

echo "Cisco Secure Client:"
echo ""

echo "Server:"
echo "$PUBLIC_IP"

echo ""

echo "Username:"
echo "$VPN_USER"

echo ""

echo "Password:"
echo "$VPN_PASS"


echo ""

echo "认证方式:"
echo "Username + Password"


echo ""

echo "检查状态:"
echo "systemctl status ocserv"


echo "======================================"
