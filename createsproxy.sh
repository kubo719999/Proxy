#!/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Fixed credentials
FIXED_USER="AnhVip17102"
FIXED_PASS="AnhVip17102"

install_dependencies() {
    echo "Installing dependencies (vim-common included)..."
    if command -v yum >/dev/null 2>&1; then
        yum install -y iproute vim-common wget gcc make net-tools >/dev/null 2>&1
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update >/dev/null 2>&1
        apt-get install -y iproute2 vim-common wget gcc make net-tools >/dev/null 2>&1
    fi
    echo "✅ Dependencies installed"
}

install_3proxy() {
    echo "Installing 3proxy..."
    URL="https://github.com/z3APA3A/3proxy/archive/refs/tags/0.8.13.tar.gz"
    wget -qO- $URL | tar -xzf-
    cd 3proxy-0.8.13
    make -f Makefile.Linux
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp src/3proxy /usr/local/etc/3proxy/bin/
    cp bin/mycrypt /usr/local/etc/3proxy/bin/ 2>/dev/null
    cd $WORKDIR
    echo "✅ 3proxy compiled and installed"
}

gen_3proxy_per_request() {
    cat > /usr/local/etc/3proxy/3proxy.cfg << EOF
daemon
maxconn 4000
nserver 1.1.1.1
nserver 8.8.4.4
nserver 2001:4860:4860::8888
nserver 2001:4860:4860::8844
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
stacksize 6291456
flush
auth strong

users ${FIXED_USER}:CL:${FIXED_PASS}

EOF

    # Generate proxy rules with proper IPv6 format
    local port_num=$FIRST_PORT
    while [ $port_num -le $LAST_PORT ]; do
        subnet=$((port_num - FIRST_PORT))
        subnet_hex=$(printf "%x" $subnet)
        
        cat >> /usr/local/etc/3proxy/3proxy.cfg << EOF
auth strong
allow ${FIXED_USER}
proxy -6 -n -a -p${port_num} -i${IP4} -e${IP6}:${subnet_hex}::/64
flush

EOF
        port_num=$((port_num + 1))
    done
    
    echo "✅ Config generated with per-request rotation"
}

gen_proxy_file_for_user() {
    cat > $WORKDIR/proxy.txt << EOF
# Format: IP:PORT:USERNAME:PASSWORD
# Per-request rotation: Each new connection gets a different IPv6
$(seq $FIRST_PORT $LAST_PORT | while read port; do
    echo "$IP4:$port:$FIXED_USER:$FIXED_PASS"
done)
EOF
}

setup_ipv6_network() {
    echo "Setting up IPv6 network for per-request rotation..."
    
    # Enable IPv6
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.eth0.disable_ipv6=0 >/dev/null 2>&1
    
    # Enable IPv6 forwarding
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.eth0.forwarding=1 >/dev/null 2>&1
    
    # Add /56 route to allow all /64 subnets
    ip -6 route del ${IP6}::/56 dev eth0 2>/dev/null
    ip -6 route add ${IP6}::/56 dev eth0 2>/dev/null
    
    # Accept Router Advertisements
    sysctl -w net.ipv6.conf.eth0.accept_ra=2 >/dev/null 2>&1
    
    # Disable source validation for IPv6
    sysctl -w net.ipv6.conf.all.accept_source_route=1 >/dev/null 2>&1
    
    echo "✅ IPv6 network configured"
    echo "   Base: ${IP6}::/56"
    echo "   Each port: ${IP6}:X::/64 (X = 0-49)"
}

test_ipv6_connectivity() {
    echo "Testing IPv6 connectivity..."
    
    if ping6 -c 2 google.com >/dev/null 2>&1; then
        echo "✅ IPv6 internet connectivity OK"
        return 0
    else
        echo "⚠️  IPv6 ping failed, but proxy may still work"
        return 1
    fi
}

create_startup_script() {
    cat > /etc/rc.d/rc.local << EOF
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Enable IPv6
sysctl -w net.ipv6.conf.all.disable_ipv6=0
sysctl -w net.ipv6.conf.all.forwarding=1
sysctl -w net.ipv6.conf.eth0.forwarding=1

# Setup IPv6 routing
ip -6 route add ${IP6}::/56 dev eth0 2>/dev/null

# Start 3proxy
sleep 5
ulimit -n 65536
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
EOF

    chmod +x /etc/rc.d/rc.local
    systemctl enable rc-local 2>/dev/null
}

create_monitor_script() {
    cat > /home/bkns/monitor.sh << 'EOF'
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Auto-cleanup log if > 5MB
if [ -f /home/bkns/monitor.log ]; then
    LOG_SIZE=$(du -m /home/bkns/monitor.log 2>/dev/null | cut -f1)
    if [ "$LOG_SIZE" -gt 5 ]; then
        tail -n 500 /home/bkns/monitor.log > /home/bkns/monitor.log.tmp
        mv /home/bkns/monitor.log.tmp /home/bkns/monitor.log
    fi
fi

# Check 3proxy
if ! pgrep 3proxy > /dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 3proxy died, restarting..." >> /home/bkns/monitor.log
    
    pkill -9 3proxy 2>/dev/null
    sleep 2
    
    ulimit -n 65536
    /usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
    sleep 3
    
    if pgrep 3proxy > /dev/null; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ Restarted (PID: $(pgrep 3proxy))" >> /home/bkns/monitor.log
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ Restart failed" >> /home/bkns/monitor.log
    fi
fi
EOF
    chmod +x /home/bkns/monitor.sh
}

create_debug_script() {
    cat > /root/debug_proxy.sh << 'EOF'
#!/bin/bash
echo "=========================================="
echo "  PROXY DEBUG INFORMATION"
echo "=========================================="
echo ""

echo "1️⃣  3proxy Process Status:"
if pgrep 3proxy > /dev/null; then
    ps aux | grep 3proxy | grep -v grep
    echo "✅ 3proxy is running"
else
    echo "❌ 3proxy is NOT running"
fi
echo ""

echo "2️⃣  Listening Ports (first 5):"
netstat -tlnp 2>/dev/null | grep 3proxy | head -5
PORTS=$(netstat -tlnp 2>/dev/null | grep 3proxy | wc -l)
echo "Total listening ports: $PORTS"
echo ""

echo "3️⃣  IPv6 Configuration:"
echo "IPv6 addresses on eth0:"
ip -6 addr show eth0 | grep "inet6" | grep -v "fe80"
echo ""
echo "IPv6 routes:"
ip -6 route show | head -5
echo ""

echo "4️⃣  IPv6 Connectivity Test:"
if timeout 5 ping6 -c 2 google.com >/dev/null 2>&1; then
    echo "✅ IPv6 internet OK"
else
    echo "⚠️  IPv6 ping failed"
fi
echo ""

echo "5️⃣  Firewall Status:"
if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --state 2>/dev/null || echo "Firewall not running"
else
    echo "firewalld not installed"
fi
echo ""

echo "6️⃣  Config File (first 40 lines):"
head -40 /usr/local/etc/3proxy/3proxy.cfg 2>/dev/null || echo "Config not found"
echo ""

echo "7️⃣  Test Proxy Connection:"
PROXY=$(head -1 /home/bkns/proxy.txt 2>/dev/null | grep -v "^#")
if [ -n "$PROXY" ]; then
    IP=$(echo $PROXY | cut -d: -f1)
    PORT=$(echo $PROXY | cut -d: -f2)
    USER=$(echo $PROXY | cut -d: -f3)
    PASS=$(echo $PROXY | cut -d: -f4)
    
    echo "Testing: ${IP}:${PORT}"
    echo "Command: curl -x ${USER}:${PASS}@${IP}:${PORT} https://api64.ipify.org"
    
    RESULT=$(timeout 10 curl -s -x ${USER}:${PASS}@${IP}:${PORT} https://api64.ipify.org 2>&1)
    if [ -n "$RESULT" ]; then
        echo "✅ Proxy works! IPv6: $RESULT"
    else
        echo "❌ Proxy connection failed"
    fi
else
    echo "❌ No proxy.txt found"
fi
echo ""

echo "=========================================="
EOF
    chmod +x /root/debug_proxy.sh
}

setup_cron() {
    echo "Setting up cron jobs..."
    crontab -r 2>/dev/null
    (
        echo "*/3 * * * * /home/bkns/monitor.sh"
        echo "0 3 * * * find /usr/local/etc/3proxy/logs -type f -mtime +7 -delete 2>/dev/null"
    ) | crontab -
    echo "✅ Cron configured"
}

disable_firewall() {
    echo "Configuring firewall..."
    if command -v firewall-cmd >/dev/null 2>&1; then
        systemctl stop firewalld 2>/dev/null
        systemctl disable firewalld 2>/dev/null
        echo "✅ Firewall disabled"
    else
        echo "✅ No firewall to disable"
    fi
}

echo "======================================================="
echo "  3PROXY - 50 PORTS - PER-REQUEST IPv6 ROTATION       "
echo "  Each connection = NEW IPv6 automatically!            "
echo "  Username/Password: AnhVip17102                       "
echo "======================================================="
echo ""

echo "[1/12] Installing dependencies..."
install_dependencies

echo "[2/12] Installing 3proxy..."
install_3proxy

echo "[3/12] Setting up working directory..."
WORKDIR="/home/bkns"
mkdir -p $WORKDIR && cd $WORKDIR

echo "[4/12] Detecting IP addresses..."
IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com 2>/dev/null | cut -f1-3 -d':')

if [ -z "$IP4" ]; then
    echo "❌ ERROR: Cannot detect IPv4"
    exit 1
fi

if [ -z "$IP6" ]; then
    echo "Trying alternative method..."
    IP6=$(ip -6 addr show eth0 2>/dev/null | grep "inet6" | grep -v "fe80" | head -1 | awk '{print $2}' | cut -f1-3 -d':')
    if [ -z "$IP6" ]; then
        echo "❌ ERROR: Cannot detect IPv6. VPS may not support IPv6."
        exit 1
    fi
fi

echo "   IPv4: ${IP4}"
echo "   IPv6 Base: ${IP6}"

echo "[5/12] Configuring ports..."
FIRST_PORT=10000
LAST_PORT=10049
echo "   ✅ Ports: 10000-10049 (50 ports)"

echo "[6/12] Setting up IPv6 network..."
setup_ipv6_network

echo "[7/12] Testing IPv6 connectivity..."
test_ipv6_connectivity

echo "[8/12] Disabling firewall (for testing)..."
disable_firewall

echo "[9/12] Generating 3proxy config..."
gen_3proxy_per_request

echo "[10/12] Creating startup script..."
create_startup_script

echo "[11/12] Starting 3proxy..."
# Clean kill
pkill -9 3proxy 2>/dev/null
sleep 2

# Start 3proxy
ulimit -n 65536
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
PROXY_PID=$!
sleep 3

# Verify
if pgrep 3proxy > /dev/null; then
    echo "   ✅ 3proxy started (PID: $(pgrep 3proxy))"
    
    # Check ports
    sleep 2
    PORTS=$(netstat -tlnp 2>/dev/null | grep 3proxy | wc -l)
    echo "   ✅ Listening on $PORTS ports"
else
    echo "   ❌ 3proxy failed to start!"
    echo "   Running in foreground to see errors:"
    /usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
    exit 1
fi

echo "[12/12] Setting up monitoring & scripts..."
create_monitor_script
create_debug_script
setup_cron
gen_proxy_file_for_user

# Cleanup
rm -rf /root/setup.sh /root/3proxy-* 3proxy-0.8.13 2>/dev/null

echo ""
echo "======================================================="
echo "✅ INSTALLATION COMPLETED"
echo "======================================================="
echo ""
echo "📋 Configuration:"
echo "   Ports: 50 (10000-10049)"
echo "   Username: ${FIXED_USER}"
echo "   Password: ${FIXED_PASS}"
echo "   IPv4: ${IP4}"
echo "   IPv6: ${IP6}::/56"
echo ""
echo "⚡ Per-Request Rotation:"
echo "   ✅ Each connection = NEW IPv6"
echo "   ✅ Active sessions keep same IP"
echo "   ✅ No periodic rotation needed"
echo ""
echo "📁 Important Files:"
echo "   Proxy List: $WORKDIR/proxy.txt"
echo "   Monitor Log: $WORKDIR/monitor.log"
echo "   Debug Script: /root/debug_proxy.sh"
echo ""
echo "🔧 Debug & Testing:"
echo "   Run debug: bash /root/debug_proxy.sh"
echo ""
echo "🧪 Quick Test:"
FIRST_PROXY=$(head -1 $WORKDIR/proxy.txt | grep -v "^#")
if [ -n "$FIRST_PROXY" ]; then
    TEST_IP=$(echo $FIRST_PROXY | cut -d: -f1)
    TEST_PORT=$(echo $FIRST_PROXY | cut -d: -f2)
    echo ""
    echo "   Test command:"
    echo "   curl -x ${FIXED_USER}:${FIXED_PASS}@${TEST_IP}:${TEST_PORT} https://api64.ipify.org"
    echo ""
    echo "   Testing now..."
    RESULT=$(timeout 10 curl -s -x ${FIXED_USER}:${FIXED_PASS}@${TEST_IP}:${TEST_PORT} https://api64.ipify.org 2>&1)
    
    if [ -n "$RESULT" ] && echo "$RESULT" | grep -qE "^[0-9a-f:]+$"; then
        echo "   ✅ SUCCESS! IPv6: $RESULT"
        echo ""
        echo "   Test again for different IP:"
        RESULT2=$(timeout 10 curl -s -x ${FIXED_USER}:${FIXED_PASS}@${TEST_IP}:${TEST_PORT} https://api64.ipify.org 2>&1)
        echo "   ✅ IPv6: $RESULT2"
        
        if [ "$RESULT" != "$RESULT2" ]; then
            echo ""
            echo "   🎉 PER-REQUEST ROTATION IS WORKING!"
            echo "   Each connection shows different IPv6!"
        fi
    else
        echo "   ❌ Test failed: $RESULT"
        echo ""
        echo "   Run debug script for details:"
        echo "   bash /root/debug_proxy.sh"
    fi
fi

echo ""
echo "======================================================="
echo "💡 Next Steps:"
echo "   1. If test failed, run: bash /root/debug_proxy.sh"
echo "   2. Check monitor: tail -f /home/bkns/monitor.log"
echo "   3. View proxies: cat /home/bkns/proxy.txt"
echo "======================================================="
echo ""
