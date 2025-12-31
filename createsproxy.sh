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
    cd $WORKDIR
    echo "✅ 3proxy compiled and installed"
}

# Generate random IPv6 for each port (AWK-based, no xxd)
gen_random_ipv6() {
    local base=$1
    local subnet=$2
    
    # Generate random hex using AWK
    awk -v base="$base" -v subnet="$subnet" 'BEGIN {
        srand();
        hex = "0123456789abcdef";
        
        # Generate 3 random segments (48 bits)
        for(i=1; i<=3; i++) {
            seg = "";
            for(j=1; j<=4; j++) {
                seg = seg substr(hex, int(rand()*16)+1, 1);
            }
            if(i==1) suffix = seg;
            else suffix = suffix ":" seg;
        }
        
        # Format: BASE:SUBNET:RAND:RAND:RAND
        printf "%s:%02x:%s\n", base, subnet, suffix;
    }'
}

# Pre-generate IPv6 pool for each port
create_ipv6_pool() {
    echo "Generating IPv6 pool..."
    mkdir -p /home/bkns/ipv6_pool
    
    local port=$FIRST_PORT
    while [ $port -le $LAST_PORT ]; do
        subnet=$((port - FIRST_PORT))
        
        # Generate 100 IPv6s per port for rotation
        rm -f /home/bkns/ipv6_pool/port_${port}.txt
        for i in $(seq 1 100); do
            gen_random_ipv6 "$IP6" "$subnet" >> /home/bkns/ipv6_pool/port_${port}.txt
        done
        
        port=$((port + 1))
    done
    
    echo "✅ Generated 5000 IPv6 addresses (100 per port)"
}

# Add all IPv6 to interface
setup_ipv6_addresses() {
    echo "Adding IPv6 addresses to interface..."
    
    local count=0
    for file in /home/bkns/ipv6_pool/port_*.txt; do
        while IFS= read -r ipv6; do
            ip -6 addr add ${ipv6}/64 dev eth0 2>/dev/null && count=$((count + 1))
        done < "$file"
    done
    
    echo "✅ Added $count IPv6 addresses to eth0"
}

gen_3proxy_with_rotation() {
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

    # For each port, use external directive with multiple IPs
    local port=$FIRST_PORT
    while [ $port -le $LAST_PORT ]; do
        # Get all IPs for this port
        local ip_file="/home/bkns/ipv6_pool/port_${port}.txt"
        
        # Add external IPs
        while IFS= read -r ipv6; do
            echo "external ${ipv6}" >> /usr/local/etc/3proxy/3proxy.cfg
        done < "$ip_file"
        
        # Add proxy rule (3proxy will rotate through external IPs)
        cat >> /usr/local/etc/3proxy/3proxy.cfg << EOF
auth strong
allow ${FIXED_USER}
proxy -6 -n -a -p${port} -i${IP4}
flush

EOF
        
        port=$((port + 1))
    done
    
    echo "✅ Config generated with IP pool rotation"
}

gen_proxy_file_for_user() {
    cat > $WORKDIR/proxy.txt << EOF
# Format: IP:PORT:USERNAME:PASSWORD
# Automatic IPv6 rotation on each connection
$(seq $FIRST_PORT $LAST_PORT | while read port; do
    echo "$IP4:$port:$FIXED_USER:$FIXED_PASS"
done)
EOF
}

setup_ipv6_network() {
    echo "Configuring IPv6 network..."
    
    # Enable IPv6
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.eth0.forwarding=1 >/dev/null 2>&1
    
    echo "✅ IPv6 enabled"
}

create_rotation_script() {
    cat > /home/bkns/rotate_ipv6_pool.sh << 'ROTEOF'
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# This script rotates IPv6 pool every 10 minutes

WORKDIR="/home/bkns"
IP6=$(head -1 ${WORKDIR}/ipv6_base.txt)
FIRST_PORT=10000
LAST_PORT=10049

gen_random_ipv6() {
    local base=$1
    local subnet=$2
    
    awk -v base="$base" -v subnet="$subnet" 'BEGIN {
        srand();
        hex = "0123456789abcdef";
        
        for(i=1; i<=3; i++) {
            seg = "";
            for(j=1; j<=4; j++) {
                seg = seg substr(hex, int(rand()*16)+1, 1);
            }
            if(i==1) suffix = seg;
            else suffix = suffix ":" seg;
        }
        
        printf "%s:%02x:%s\n", base, subnet, suffix;
    }'
}

echo "[$(date)] Starting IPv6 pool rotation..."

# Generate new IPs
port=$FIRST_PORT
while [ $port -le $LAST_PORT ]; do
    subnet=$((port - FIRST_PORT))
    
    # Keep old IPs
    mv /home/bkns/ipv6_pool/port_${port}.txt /home/bkns/ipv6_pool/port_${port}.old 2>/dev/null
    
    # Generate new IPs
    for i in $(seq 1 100); do
        gen_random_ipv6 "$IP6" "$subnet" >> /home/bkns/ipv6_pool/port_${port}.txt
    done
    
    # Add new IPs to interface
    while IFS= read -r ipv6; do
        ip -6 addr add ${ipv6}/64 dev eth0 2>/dev/null
    done < /home/bkns/ipv6_pool/port_${port}.txt
    
    port=$((port + 1))
done

# Reload 3proxy config
pkill -HUP 3proxy

# Wait 60s then remove old IPs
(
    sleep 60
    for file in /home/bkns/ipv6_pool/port_*.old; do
        [ -f "$file" ] || continue
        while IFS= read -r ipv6; do
            ip -6 addr del ${ipv6}/64 dev eth0 2>/dev/null
        done < "$file"
        rm -f "$file"
    done
    echo "[$(date)] Old IPs cleaned up"
) &

echo "[$(date)] Rotation completed"
ROTEOF

    chmod +x /home/bkns/rotate_ipv6_pool.sh
}

create_startup_script() {
    cat > /etc/rc.d/rc.local << EOF
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Enable IPv6
sysctl -w net.ipv6.conf.all.disable_ipv6=0
sysctl -w net.ipv6.conf.all.forwarding=1

# Add IPv6 addresses
for file in /home/bkns/ipv6_pool/port_*.txt; do
    while IFS= read -r ipv6; do
        ip -6 addr add \${ipv6}/64 dev eth0 2>/dev/null
    done < "\$file"
done

# Start 3proxy
sleep 3
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

if [ -f /home/bkns/monitor.log ]; then
    LOG_SIZE=$(du -m /home/bkns/monitor.log 2>/dev/null | cut -f1)
    [ "$LOG_SIZE" -gt 5 ] && tail -n 500 /home/bkns/monitor.log > /home/bkns/monitor.log.tmp && mv /home/bkns/monitor.log.tmp /home/bkns/monitor.log
fi

if ! pgrep 3proxy > /dev/null; then
    echo "[$(date)] 3proxy died, restarting..." >> /home/bkns/monitor.log
    pkill -9 3proxy 2>/dev/null
    sleep 2
    ulimit -n 65536
    /usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
    sleep 3
    pgrep 3proxy > /dev/null && echo "[$(date)] ✅ Restarted" >> /home/bkns/monitor.log
fi
EOF
    chmod +x /home/bkns/monitor.sh
}

setup_cron() {
    crontab -r 2>/dev/null
    (
        echo "*/10 * * * * /home/bkns/rotate_ipv6_pool.sh >> /home/bkns/rotate.log 2>&1"
        echo "*/3 * * * * /home/bkns/monitor.sh"
    ) | crontab -
}

echo "======================================================="
echo "  3PROXY - 50 PORTS - IPv6 POOL ROTATION              "
echo "  100 IPs per port, auto-rotate every 10 minutes      "
echo "======================================================="
echo ""

echo "[1/11] Installing dependencies..."
install_dependencies

echo "[2/11] Installing 3proxy..."
install_3proxy

echo "[3/11] Setting up directories..."
WORKDIR="/home/bkns"
mkdir -p $WORKDIR && cd $WORKDIR

echo "[4/11] Detecting IPs..."
IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com 2>/dev/null | cut -f1-3 -d':')

[ -z "$IP4" ] && echo "❌ No IPv4" && exit 1
[ -z "$IP6" ] && IP6=$(ip -6 addr show eth0 | grep "inet6" | grep -v "fe80" | head -1 | awk '{print $2}' | cut -f1-3 -d':')
[ -z "$IP6" ] && echo "❌ No IPv6" && exit 1

echo "$IP6" > /home/bkns/ipv6_base.txt

echo "   IPv4: ${IP4}"
echo "   IPv6: ${IP6}"

echo "[5/11] Configuring ports..."
FIRST_PORT=10000
LAST_PORT=10049

echo "[6/11] Generating IPv6 pool (5000 IPs)..."
create_ipv6_pool

echo "[7/11] Setting up IPv6 network..."
setup_ipv6_network

echo "[8/11] Adding IPv6 to interface..."
setup_ipv6_addresses

echo "[9/11] Generating 3proxy config..."
gen_3proxy_with_rotation

echo "[10/11] Starting 3proxy..."
pkill -9 3proxy 2>/dev/null
sleep 2
ulimit -n 65536
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
sleep 3

if pgrep 3proxy > /dev/null; then
    PORTS=$(netstat -tlnp 2>/dev/null | grep 3proxy | wc -l)
    echo "   ✅ 3proxy started (PID: $(pgrep 3proxy))"
    echo "   ✅ Listening on $PORTS ports"
else
    echo "   ❌ Failed to start"
    exit 1
fi

echo "[11/11] Setting up rotation & monitoring..."
create_rotation_script
create_startup_script
create_monitor_script
setup_cron
gen_proxy_file_for_user

echo ""
echo "======================================================="
echo "✅ INSTALLATION COMPLETED"
echo "======================================================="
echo ""
echo "📋 Configuration:"
echo "   Ports: 50 (10000-10049)"
echo "   IPv6 Pool: 5000 IPs (100 per port)"
echo "   Rotation: Every 10 minutes"
echo ""
echo "🧪 Test:"
FIRST_PROXY=$(head -1 $WORKDIR/proxy.txt | grep -v "^#")
if [ -n "$FIRST_PROXY" ]; then
    IP=$(echo $FIRST_PROXY | cut -d: -f1)
    PORT=$(echo $FIRST_PROXY | cut -d: -f2)
    echo "   curl -x ${FIXED_USER}:${FIXED_PASS}@${IP}:${PORT} https://api64.ipify.org"
    
    RES=$(timeout 10 curl -s -x ${FIXED_USER}:${FIXED_PASS}@${IP}:${PORT} https://api64.ipify.org 2>&1)
    [ -n "$RES" ] && echo "   ✅ $RES" || echo "   ⚠️ Test failed"
fi
echo ""
echo "======================================================="
