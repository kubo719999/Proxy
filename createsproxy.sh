#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

FIXED_USER="AnhVip17102"
FIXED_PASS="AnhVip17102"

install_deps() {
    echo "[1/10] Installing dependencies..."
    if command -v yum >/dev/null 2>&1; then
        yum install -y epel-release >/dev/null 2>&1
        yum install -y gcc make git wget iproute vim-common ndppd >/dev/null 2>&1
    else
        apt-get update >/dev/null 2>&1
        apt-get install -y gcc make git wget iproute2 vim-common ndppd >/dev/null 2>&1
    fi
    echo "    Done"
}

install_3proxy() {
    echo "[2/10] Installing 3proxy..."
    cd /root
    wget -q https://github.com/z3APA3A/3proxy/archive/refs/tags/0.8.13.tar.gz
    tar -xzf 0.8.13.tar.gz
    cd 3proxy-0.8.13
    make -f Makefile.Linux >/dev/null 2>&1
    mkdir -p /usr/local/3proxy/{bin,conf}
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
    [ -z "$IP6_PREFIX" ] && echo "    No IPv6" && exit 1
    
    IFACE=$(ip -6 route get $IP6_FULL 2>/dev/null | grep -oP 'dev \K\S+' | head -1)
    [ -z "$IFACE" ] && IFACE="eth0"
    
    echo "    IPv4: $IP4"
    echo "    IPv6: $IP6_PREFIX::/64"
    echo "    Interface: $IFACE"
}

setup_ndp_proxy() {
    echo "[4/10] Setting up NDP proxy..."
    
    cat > /etc/ndppd.conf << EOF
route-ttl 30000

proxy $IFACE {
    router yes
    timeout 500
    ttl 30000
    
    rule $IP6_PREFIX::/64 {
        auto
    }
}
EOF
    
    systemctl enable ndppd >/dev/null 2>&1
    systemctl restart ndppd
    
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.$IFACE.proxy_ndp=1 >/dev/null 2>&1
    
    echo "    Done"
}

create_random_ip_script() {
    echo "[5/10] Creating random IP generator..."
    
    cat > /usr/local/3proxy/bin/random_ipv6.sh << 'RANDEOF'
#!/bin/bash
PREFIX=$(cat /tmp/ipv6_prefix.txt)

rand_hex() {
    echo $((RANDOM % 65536)) | awk '{printf "%04x", $1}'
}

echo "${PREFIX}:$(rand_hex):$(rand_hex):$(rand_hex):$(rand_hex)"
RANDEOF
    
    chmod +x /usr/local/3proxy/bin/random_ipv6.sh
    echo "$IP6_PREFIX" > /tmp/ipv6_prefix.txt
    
    echo "    Done"
}

create_3proxy_wrapper() {
    echo "[6/10] Creating per-port proxy wrappers..."
    
    mkdir -p /usr/local/3proxy/wrappers
    
    for port in $(seq 10000 10049); do
        cat > /usr/local/3proxy/wrappers/port_${port}.sh << WRAPEOF
#!/bin/bash
RANDOM_IP6=\$(/usr/local/3proxy/bin/random_ipv6.sh)

exec /usr/local/3proxy/bin/3proxy << EOF
daemon
maxconn 100
nserver 1.1.1.1
nserver 8.8.4.4
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
auth strong
users ${FIXED_USER}:CL:${FIXED_PASS}
log /usr/local/3proxy/logs/port_${port}.log
logformat "- +_L%t.%. %N.%p %E %U %C:%c %R:%r %O %I %h %T"
auth strong
allow ${FIXED_USER}
proxy -6 -n -a -p${port} -i${IP4} -e\${RANDOM_IP6}
flush
EOF
WRAPEOF
        chmod +x /usr/local/3proxy/wrappers/port_${port}.sh
    done
    
    echo "    Done"
}

create_supervisor() {
    echo "[7/10] Creating supervisor daemon..."
    
    cat > /usr/local/3proxy/bin/supervisor.sh << 'SUPEOF'
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

LOG="/var/log/3proxy_supervisor.log"

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $LOG
}

start_port() {
    local port=$1
    local wrapper="/usr/local/3proxy/wrappers/port_${port}.sh"
    
    if pgrep -f "3proxy.*-p${port}" >/dev/null; then
        return 0
    fi
    
    nohup bash $wrapper >> /var/log/3proxy_port_${port}.log 2>&1 &
    sleep 0.1
}

log_msg "Supervisor started"

while true; do
    for port in $(seq 10000 10049); do
        if ! pgrep -f "3proxy.*-p${port}" >/dev/null; then
            log_msg "Port $port down, restarting..."
            start_port $port
        fi
    done
    
    sleep 10
done
SUPEOF
    
    chmod +x /usr/local/3proxy/bin/supervisor.sh
    
    echo "    Done"
}

start_services() {
    echo "[8/10] Starting services..."
    
    mkdir -p /usr/local/3proxy/logs
    
    pkill -9 3proxy 2>/dev/null
    pkill -f supervisor.sh 2>/dev/null
    sleep 2
    
    for port in $(seq 10000 10049); do
        bash /usr/local/3proxy/wrappers/port_${port}.sh &
        sleep 0.05
    done
    
    sleep 3
    
    RUNNING=$(pgrep -f 3proxy | wc -l)
    echo "    Started $RUNNING instances"
    
    nohup /usr/local/3proxy/bin/supervisor.sh >/dev/null 2>&1 &
    echo "    Supervisor running"
}

create_autostart() {
    echo "[9/10] Setting up autostart..."
    
    cat > /etc/systemd/system/3proxy-unlimited.service << 'SVCEOF'
[Unit]
Description=3proxy Unlimited IPv6
After=network.target ndppd.service

[Service]
Type=forking
ExecStart=/usr/local/3proxy/bin/start_all.sh
ExecStop=/usr/bin/pkill -9 3proxy
Restart=always

[Install]
WantedBy=multi-user.target
SVCEOF
    
    cat > /usr/local/3proxy/bin/start_all.sh << 'STARTEOF'
#!/bin/bash
for port in $(seq 10000 10049); do
    bash /usr/local/3proxy/wrappers/port_${port}.sh &
    sleep 0.05
done

sleep 3
nohup /usr/local/3proxy/bin/supervisor.sh >/dev/null 2>&1 &
STARTEOF
    
    chmod +x /usr/local/3proxy/bin/start_all.sh
    
    systemctl daemon-reload
    systemctl enable 3proxy-unlimited >/dev/null 2>&1
    
    echo "    Done"
}

create_proxy_list() {
    echo "[10/10] Generating proxy list..."
    
    cat > /root/proxy.txt << EOF
# 3PROXY UNLIMITED IPv6 - 50 Ports
# Format: IP:PORT:USER:PASS

EOF
    
    for port in $(seq 10000 10049); do
        echo "${IP4}:${port}:${FIXED_USER}:${FIXED_PASS}" >> /root/proxy.txt
    done
    
    echo "    List saved to /root/proxy.txt"
}

cleanup() {
    rm -rf /root/3proxy-* /root/proxy.sh 2>/dev/null
}

echo "=============================================="
echo "  3PROXY UNLIMITED IPv6"
echo "=============================================="
echo ""

install_deps
install_3proxy
detect_network
setup_ndp_proxy
create_random_ip_script
create_3proxy_wrapper
create_supervisor
start_services
create_autostart
create_proxy_list
cleanup

echo ""
echo "=============================================="
echo "INSTALLATION COMPLETE"
echo "=============================================="
echo ""
echo "Ports: 50 (10000-10049)"
echo "Username: ${FIXED_USER}"
echo "Password: ${FIXED_PASS}"
echo "IPv4: ${IP4}"
echo "IPv6: ${IP6_PREFIX}::/64"
echo ""
echo "Proxy list: /root/proxy.txt"
echo "Supervisor log: /var/log/3proxy_supervisor.log"
echo ""
echo "Test: curl -x ${FIXED_USER}:${FIXED_PASS}@${IP4}:10000 https://api64.ipify.org"
echo ""
echo "=============================================="
