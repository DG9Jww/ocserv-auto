#!/bin/bash

# ==========================================================
# ocserv Certificate Authentication Installer
#
# Support:
# Ubuntu 18.04/20.04/22.04
# Debian 10+
#
# Cisco Secure Client iOS Certificate Authentication
#
# No username/password required
# ==========================================================


set -e


if [[ $EUID -ne 0 ]]; then
    echo "Please run as root"
    exit 1
fi


echo "======================================"
echo " ocserv Certificate VPN Installer"
echo "======================================"


# -------------------------------
# Get public IP
# -------------------------------

PUBLIC_IP=$(curl -4 -s https://api.ipify.org)

if [ -z "$PUBLIC_IP" ]; then
    echo "Cannot detect public IP"
    exit 1
fi


echo "Public IP: $PUBLIC_IP"


# -------------------------------
# User
# -------------------------------

read -p "Input VPN certificate username: " VPN_USER


if [ -z "$VPN_USER" ]; then
    echo "Username cannot empty"
    exit 1
fi


# -------------------------------
# Install packages
# -------------------------------


apt update

apt install -y \
ocserv \
gnutls-bin \
iptables \
curl \
ufw


# -------------------------------
# Certificate directory
# -------------------------------

CERT_DIR=/etc/ocserv/certs

mkdir -p $CERT_DIR

cd $CERT_DIR



# ==========================================================
# Generate CA
# ==========================================================


echo "Generating CA certificate..."


cat > ca.tmpl <<EOF

cn = "MyVPN Root CA"

organization = "MyVPN"

serial = 1

expiration_days = 3650

ca

signing_key

cert_signing_key

crl_signing_key

EOF



certtool \
--generate-privkey \
--outfile ca-key.pem



certtool \
--generate-self-signed \
--load-privkey ca-key.pem \
--template ca.tmpl \
--outfile ca-cert.pem




# ==========================================================
# Server Certificate
# ==========================================================


echo "Generating server certificate..."


cat > server.tmpl <<EOF

cn = "$PUBLIC_IP"

organization = "MyVPN"


subject_alt_name = IPADDRESS:$PUBLIC_IP


expiration_days = 3650


signing_key

encryption_key

tls_www_server

EOF



certtool \
--generate-privkey \
--outfile server-key.pem



certtool \
--generate-certificate \
--load-ca-certificate ca-cert.pem \
--load-ca-privkey ca-key.pem \
--load-privkey server-key.pem \
--template server.tmpl \
--outfile server-cert.pem




# ==========================================================
# Client Certificate
# ==========================================================


echo "Generating client certificate..."



mkdir -p users/$VPN_USER


cat > client.tmpl <<EOF


cn = "$VPN_USER"

organization = "MyVPN"

unit = "VPN User"


expiration_days = 3650


signing_key

tls_www_client


EOF




certtool \
--generate-privkey \
--outfile users/$VPN_USER/$VPN_USER-key.pem




certtool \
--generate-certificate \
--load-ca-certificate ca-cert.pem \
--load-ca-privkey ca-key.pem \
--load-privkey users/$VPN_USER/$VPN_USER-key.pem \
--template client.tmpl \
--outfile users/$VPN_USER/$VPN_USER-cert.pem



# password for p12
read -s -p "Set certificate password: " P12_PASS

echo



certtool \
--to-p12 \
--load-privkey users/$VPN_USER/$VPN_USER-key.pem \
--load-certificate users/$VPN_USER/$VPN_USER-cert.pem \
--password "$P12_PASS" \
--outfile /root/${VPN_USER}.p12



# ==========================================================
# ocserv config
# ==========================================================


echo "Configuring ocserv..."



cat > /etc/ocserv/ocserv.conf <<EOF


auth = "certificate"


tcp-port = 443

udp-port = 443


run-as-user = ocserv

run-as-group = ocserv


socket-file = /var/run/ocserv-socket


server-cert = $CERT_DIR/server-cert.pem

server-key = $CERT_DIR/server-key.pem


ca-cert = $CERT_DIR/ca-cert.pem


cert-user-oid = 2.5.4.3



max-clients = 128

max-same-clients = 2



keepalive = 30

dpd = 90

mobile-dpd = 300



try-mtu-discovery = true


idle-timeout = 1200

mobile-idle-timeout = 1800



default-domain = $PUBLIC_IP



ipv4-network = 10.10.10.0

ipv4-netmask = 255.255.255.0



dns = 8.8.8.8

dns = 1.1.1.1



tunnel-all-dns = true



cisco-client-compat = true


EOF




# ==========================================================
# Kernel Forward
# ==========================================================


cat >/etc/sysctl.d/60-ocserv.conf <<EOF

net.ipv4.ip_forward = 1

EOF



sysctl -p /etc/sysctl.d/60-ocserv.conf




# ==========================================================
# Enable BBR
# ==========================================================


if sysctl net.ipv4.tcp_available_congestion_control | grep -q bbr
then

cat >> /etc/sysctl.d/60-ocserv.conf <<EOF

net.core.default_qdisc = fq

net.ipv4.tcp_congestion_control = bbr

EOF

sysctl -p /etc/sysctl.d/60-ocserv.conf

fi




# ==========================================================
# Firewall
# ==========================================================


IFACE=$(ip route get 8.8.8.8 | awk '{print $5}')



iptables -t nat \
-A POSTROUTING \
-s 10.10.10.0/24 \
-o $IFACE \
-j MASQUERADE



iptables \
-A FORWARD \
-s 10.10.10.0/24 \
-j ACCEPT


iptables \
-A FORWARD \
-d 10.10.10.0/24 \
-j ACCEPT



iptables \
-A FORWARD \
-m state \
--state RELATED,ESTABLISHED \
-j ACCEPT



ufw allow 443/tcp

ufw allow 443/udp




# ==========================================================
# Start
# ==========================================================


systemctl enable ocserv

systemctl restart ocserv



echo
echo "======================================"
echo " Installation Finished"
echo "======================================"

echo

echo "VPN Server:"
echo "$PUBLIC_IP"


echo

echo "Client:"
echo "/root/${VPN_USER}.p12"


echo

echo "CA certificate:"
echo "$CERT_DIR/ca-cert.pem"


echo

echo "Certificate Password:"
echo "$P12_PASS"


echo

echo "Import to iPhone:"
echo "1. Install ca-cert.pem"
echo "2. Install ${VPN_USER}.p12"
echo "3. Open Cisco Secure Client"
echo "4. Connect to $PUBLIC_IP"


echo

echo "Check service:"
echo "systemctl status ocserv"
