#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# FORCE IPv4 for all downloads
export IPV6_DISABLE=1
echo "ip_resolve=4" >> /etc/wgetrc 2>/dev/null

FIXED_USER="AnhVip17102"
FIXED_PASS="AnhVip17102"

install_deps() {
    echo "[1/10] Installing dependencies..."
    
    # Force IPv4 for package managers
    if command -v yum >/dev/null 2>&1; then
        echo "ip_resolve=4" >> /etc/yum.conf 2>/dev/null
        yum install -y epel-release 2>&1 | grep -v "^$"
        yum install -y gcc make git wget iproute vim-common 2>&1 | grep -v "^$"
    else
        echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4
        apt-get update 2>&1 | grep -v "^$"
        apt-get install -y gcc make git wget iproute2 vim-common 2>&1 | grep -v "^$"
    fi
    echo "    Done"
}

install_3proxy() {
    echo "[2/10] Installing 3proxy..."
    cd /root
    
    # Force IPv4
    wget -4 -q https://github.com/z3APA3A/3proxy/archive/refs/tags/0.8.13.tar.gz
    tar -xzf 0.8.13.tar.gz
    cd 3proxy-0.8.13
    make -f Makefile.Linux >/dev/null 2>&1
    mkdir -p /usr/local/3proxy/{bin,conf,logs}
    cp src/3proxy /usr/local/3proxy/bin/
    cd /root
    rm -rf 3proxy-0.8.13 0.8.13.tar.gz
    echo "    Done"
}

detect_network() {
    echo "[3/10] Detecting network..."
    
    IP4=$(curl -4 -s icanhazip.com)
    IP6_FULL=$(curl -6 -s icanhazip.com 2>/dev/null)
    IP6_PREFIX=$(echo $IP6_FULL | cut -d: -f1-4)
    
    [ -z "$IP4" ] && echo "    No IPv4" && exit 1
    
    if [ -z "$IP6_PREFIX" ]; then
        IP6_PREFIX=$(ip -6 addr show eth0 | grep "inet6" | grep -v "fe80" | head -1 | awk '{print $2}' | cut -f1-4 -d':')
    fi
    
    [ -z "$IP6_PREFIX" ] && echo "    No IPv6" && exit 1
    
    IFACE=$(ip route get 8.8.8.8 | grep -oP 'dev \K\S+')
    [ -z "$IFACE" ] && IFACE="eth0"
    
    echo "    IPv4: $IP4"
    echo "    IPv6: $IP6_PREFIX::/64"
    echo "    Interface: $IFACE"
}

setup_ipv6_forwarding() {
    echo "[4/10] Setting up IPv6 forwarding..."
    
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.$IFACE.forwarding=1 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.all.proxy_ndp=1 >/dev/null 2>&1
    
    # Add route for /64
    ip -6 route add ${IP6_PREFIX}::/64 dev $IFACE 2>/dev/null
    
    echo "    Done"
}

create_random_ip_script() {
    echo "[5/10] Creating random IP generator..."
    
    cat > /usr/local/3proxy/bin/random_ipv6.sh << 'RANDEOF'
#!/bin/bash
PREFIX=$(cat /tmp/ipv6_prefix.txt)

rand_hex() {
    printf "%04x" $((RANDOM % 65536))
}

echo "${PREFIX}:$(rand_hex):$(rand_hex):$(rand_hex):$(rand_hex)"
RANDEOF
    
    chmod +x /usr/local/3proxy/bin/random_ipv6.sh
    echo "$IP6_PREFIX" > /tmp/ipv6_prefix.txt
    
    echo "    Done"
}

create_3proxy_config() {
    echo "[6/10] Creating 3proxy config..."
    
    cat > /usr/local/3proxy/conf/3proxy.cfg << EOF
daemon
maxconn 4000
nserver 1.1.1.1
nserver 8.8.4.4
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
stacksize 6291456
flush
auth strong

users ${FIXED_USER}:CL:${FIXED_PASS}

EOF

    for port in $(seq 10000 10049); do
        RANDOM_IP=$(/usr/local/3proxy/bin/random_ipv6.sh)
        
        # Add IP to interface
        ip -6 addr add ${RANDOM_IP}/128 dev $IFACE 2>/dev/null
        
        cat >> /usr/local/3proxy/conf/3proxy.cfg << EOF
auth strong
allow ${FIXED_USER}
proxy -6 -n -a -p${port} -i${IP4} -e${RANDOM_IP}
flush

EOF
    done
    
    echo "    Done"
}

create_rotation_script() {
    echo "[7/10] Creating rotation script..."
    
    cat > /usr/local/3proxy/bin/rotate.sh << 'ROTEOF'
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

IP4=$(cat /tmp/ip4.txt)
IP6_PREFIX=$(cat /tmp/ipv6_prefix.txt)
IFACE=$(cat /tmp/iface.txt)

cat > /usr/local/3proxy/conf/3proxy.cfg << EOF
daemon
maxconn 4000
nserver 1.1.1.1
nserver 8.8.4.4
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
stacksize 6291456
flush
auth strong

users AnhVip17102:CL:AnhVip17102

EOF

for port in $(seq 10000 10049); do
    rand_hex() { printf "%04x" $((RANDOM % 65536)); }
    RANDOM_IP="${IP6_PREFIX}:$(rand_hex):$(rand_hex):$(rand_hex):$(rand_hex)"
    
    ip -6 addr add ${RANDOM_IP}/128 dev $IFACE 2>/dev/null
    
    cat >> /usr/local/3proxy/conf/3proxy.cfg << EOF
auth strong
allow AnhVip17102
proxy -6 -n -a -p${port} -i${IP4} -e${RANDOM_IP}
flush

EOF
done

pkill -HUP 3proxy
ROTEOF
    
    chmod +x /usr/local/3proxy/bin/rotate.sh
    
    echo "$IP4" > /tmp/ip4.txt
    echo "$IFACE" > /tmp/iface.txt
    
    echo "    Done"
}

start_services() {
    echo "[8/10] Starting 3proxy..."
    
    pkill -9 3proxy 2>/dev/null
    sleep 2
    
    ulimit -n 65536
    /usr/local/3proxy/bin/3proxy /usr/local/3proxy/conf/3proxy.cfg &
    sleep 3
    
    if pgrep 3proxy >/dev/null; then
        echo "    3proxy running (PID: $(pgrep 3proxy))"
    else
        echo "    Failed to start"
        exit 1
    fi
}

create_autostart() {
    echo "[9/10] Setting up autostart..."
    
    cat > /etc/systemd/system/3proxy.service << 'SVCEOF'
[Unit]
Description=3proxy
After=network.target

[Service]
Type=forking
ExecStart=/usr/local/3proxy/bin/3proxy /usr/local/3proxy/conf/3proxy.cfg
ExecStop=/usr/bin/pkill -9 3proxy
Restart=always

[Install]
WantedBy=multi-user.target
SVCEOF
    
    systemctl daemon-reload
    systemctl enable 3proxy >/dev/null 2>&1
    
    # Setup rotation cron
    crontab -r 2>/dev/null
    echo "*/10 * * * * /usr/local/3proxy/bin/rotate.sh" | crontab -
    
    echo "    Done"
}

create_proxy_list() {
    echo "[10/10] Generating proxy list..."
    
    cat > /root/proxy.txt << EOF
# 3PROXY - 50 Ports - IPv6 Rotation every 10 min
EOF
    
    for port in $(seq 10000 10049); do
        echo "${IP4}:${port}:${FIXED_USER}:${FIXED_PASS}" >> /root/proxy.txt
    done
    
    echo "    Saved to /root/proxy.txt"
}

echo "=============================================="
echo "  3PROXY IPv6 ROTATION"
echo "=============================================="
echo ""

install_deps
install_3proxy
detect_network
setup_ipv6_forwarding
create_random_ip_script
create_3proxy_config
create_rotation_script
start_services
create_autostart
create_proxy_list

rm -rf /root/proxy.sh 2>/dev/null

echo ""
echo "=============================================="
echo "DONE"
echo "=============================================="
echo ""
echo "Ports: 10000-10049"
echo "User: ${FIXED_USER}"
echo "Pass: ${FIXED_PASS}"
echo "IPv4: ${IP4}"
echo "IPv6: ${IP6_PREFIX}::/64"
echo "Rotation: Every 10 minutes"
echo ""
echo "Test: curl -x ${FIXED_USER}:${FIXED_PASS}@${IP4}:10000 https://api64.ipify.org"
echo ""
