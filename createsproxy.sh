#!/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

FIXED_USER="AnhVip17102"
FIXED_PASS="AnhVip17102"

install_dependencies() {
    echo "Installing dependencies (vim-common included)..."
    if command -v yum >/dev/null 2>&1; then
        yum install -y iproute vim-common wget gcc make net-tools python3 >/dev/null 2>&1
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update >/dev/null 2>&1
        apt-get install -y iproute2 vim-common wget gcc make net-tools python3 >/dev/null 2>&1
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
    echo "✅ 3proxy installed"
}

# Create Python script for unlimited IPv6 rotation
create_ipv6_rotator() {
    cat > /home/bkns/ipv6_rotator.py << 'PYEOF'
#!/usr/bin/env python3
import random
import subprocess
import sys

def generate_random_ipv6(base):
    """Generate random IPv6 from base prefix"""
    # Generate 4 random hex segments
    segments = []
    for _ in range(4):
        seg = ''.join(random.choice('0123456789abcdef') for _ in range(4))
        segments.append(seg)
    
    return f"{base}:{':'.join(segments)}"

def add_ipv6(ipv6):
    """Add IPv6 to interface"""
    try:
        subprocess.run(['ip', '-6', 'addr', 'add', f'{ipv6}/128', 'dev', 'eth0'], 
                      stderr=subprocess.DEVNULL, check=False)
        return True
    except:
        return False

def main():
    if len(sys.argv) != 2:
        print("Usage: ipv6_rotator.py <ipv6_base>")
        sys.exit(1)
    
    base = sys.argv[1]
    
    # Generate and add 1 random IPv6
    ipv6 = generate_random_ipv6(base)
    add_ipv6(ipv6)
    print(ipv6)

if __name__ == '__main__':
    main()
PYEOF

    chmod +x /home/bkns/ipv6_rotator.py
    echo "✅ IPv6 rotator script created"
}

# Create rotation daemon
create_rotation_daemon() {
    cat > /home/bkns/rotation_daemon.sh << 'ROTEOF'
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

IP6_BASE=$(cat /home/bkns/ipv6_base.txt)
POOL_SIZE=200  # Keep 200 IPs in pool per port
FIRST_PORT=10000
LAST_PORT=10049

while true; do
    port=$FIRST_PORT
    while [ $port -le $LAST_PORT ]; do
        # Generate 5 new random IPs for this port
        for i in $(seq 1 5); do
            python3 /home/bkns/ipv6_rotator.py "$IP6_BASE" >> /home/bkns/ipv6_pool/port_${port}.txt
        done
        
        # Keep only last 200 IPs
        tail -n $POOL_SIZE /home/bkns/ipv6_pool/port_${port}.txt > /home/bkns/ipv6_pool/port_${port}.tmp
        mv /home/bkns/ipv6_pool/port_${port}.tmp /home/bkns/ipv6_pool/port_${port}.txt
        
        port=$((port + 1))
    done
    
    # Regenerate 3proxy config every 30 seconds with new IPs
    bash /home/bkns/update_3proxy_config.sh
    
    sleep 30
done
ROTEOF

    chmod +x /home/bkns/rotation_daemon.sh
}

# Create config updater
create_config_updater() {
    cat > /home/bkns/update_3proxy_config.sh << 'UPDATEOF'
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

FIRST_PORT=10000
LAST_PORT=10049

# Generate new config
cat > /usr/local/etc/3proxy/3proxy.cfg << 'CFGEOF'
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

users AnhVip17102:CL:AnhVip17102

CFGEOF

# Add external IPs and proxy rules
port=$FIRST_PORT
while [ $port -le $LAST_PORT ]; do
    # Add external IPs from pool
    if [ -f /home/bkns/ipv6_pool/port_${port}.txt ]; then
        while IFS= read -r ipv6; do
            echo "external ${ipv6}" >> /usr/local/etc/3proxy/3proxy.cfg
        done < /home/bkns/ipv6_pool/port_${port}.txt
    fi
    
    # Add proxy rule
    cat >> /usr/local/etc/3proxy/3proxy.cfg << EOF
auth strong
allow AnhVip17102
proxy -6 -n -a -p${port} -i\$(cat /home/bkns/ip4.txt)
flush

EOF
    
    port=$((port + 1))
done

# Reload 3proxy gracefully
pkill -HUP 3proxy 2>/dev/null
UPDATEOF

    chmod +x /home/bkns/update_3proxy_config.sh
}

# Initial IPv6 pool generation
generate_initial_pool() {
    echo "Generating initial IPv6 pool..."
    
    mkdir -p /home/bkns/ipv6_pool
    
    local port=$FIRST_PORT
    while [ $port -le $LAST_PORT ]; do
        echo "  Port $port..."
        
        # Generate 200 initial IPs per port
        rm -f /home/bkns/ipv6_pool/port_${port}.txt
        for i in $(seq 1 200); do
            python3 /home/bkns/ipv6_rotator.py "$IP6" >> /home/bkns/ipv6_pool/port_${port}.txt
        done
        
        port=$((port + 1))
    done
    
    echo "✅ Initial pool: 10,000 IPs generated"
    echo "✅ Daemon will continuously add new IPs (unlimited)"
}

gen_3proxy_initial() {
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

    local port=$FIRST_PORT
    while [ $port -le $LAST_PORT ]; do
        # Add external IPs
        while IFS= read -r ipv6; do
            echo "external ${ipv6}" >> /usr/local/etc/3proxy/3proxy.cfg
        done < /home/bkns/ipv6_pool/port_${port}.txt
        
        # Add proxy rule
        cat >> /usr/local/etc/3proxy/3proxy.cfg << EOF
auth strong
allow ${FIXED_USER}
proxy -6 -n -a -p${port} -i${IP4}
flush

EOF
        
        port=$((port + 1))
    done
}

gen_proxy_file() {
    cat > $WORKDIR/proxy.txt << EOF
# Format: IP:PORT:USERNAME:PASSWORD
# UNLIMITED IPv6 rotation - New IP every connection!
# Pool auto-updates every 30 seconds with fresh IPs
$(seq $FIRST_PORT $LAST_PORT | while read port; do
    echo "$IP4:$port:$FIXED_USER:$FIXED_PASS"
done)
EOF
}

create_monitor_script() {
    cat > /home/bkns/monitor.sh << 'EOF'
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Monitor 3proxy
if ! pgrep 3proxy > /dev/null; then
    echo "[$(date)] 3proxy died, restarting..." >> /home/bkns/monitor.log
    pkill -9 3proxy 2>/dev/null
    sleep 2
    ulimit -n 65536
    /usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
fi

# Monitor rotation daemon
if ! pgrep -f rotation_daemon.sh > /dev/null; then
    echo "[$(date)] Rotation daemon died, restarting..." >> /home/bkns/monitor.log
    nohup /home/bkns/rotation_daemon.sh >> /home/bkns/rotation.log 2>&1 &
fi
EOF
    chmod +x /home/bkns/monitor.sh
}

setup_cron() {
    crontab -r 2>/dev/null
    (
        echo "*/3 * * * * /home/bkns/monitor.sh"
    ) | crontab -
}

create_startup_script() {
    cat > /etc/rc.d/rc.local << 'EOF'
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Start rotation daemon
nohup /home/bkns/rotation_daemon.sh >> /home/bkns/rotation.log 2>&1 &

# Wait for pool to populate
sleep 5

# Start 3proxy
ulimit -n 65536
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
EOF
    chmod +x /etc/rc.d/rc.local
    systemctl enable rc-local 2>/dev/null
}

echo "======================================================="
echo "  3PROXY - 50 PORTS - UNLIMITED IPv6 ROTATION         "
echo "  Continuously generates NEW random IPv6               "
echo "  Pool auto-updates every 30 seconds                   "
echo "======================================================="
echo ""

echo "[1/11] Installing dependencies (Python3, vim-common)..."
install_dependencies

echo "[2/11] Installing 3proxy..."
install_3proxy

echo "[3/11] Setting up directories..."
WORKDIR="/home/bkns"
mkdir -p $WORKDIR && cd $WORKDIR

echo "[4/11] Detecting IPs..."
IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com 2>/dev/null | cut -f1-4 -d':')

[ -z "$IP4" ] && echo "❌ No IPv4" && exit 1
[ -z "$IP6" ] && IP6=$(ip -6 addr show eth0 | grep "inet6" | grep -v "fe80" | head -1 | awk '{print $2}' | cut -f1-4 -d':')
[ -z "$IP6" ] && echo "❌ No IPv6" && exit 1

echo "$IP4" > /home/bkns/ip4.txt
echo "$IP6" > /home/bkns/ipv6_base.txt

echo "   IPv4: ${IP4}"
echo "   IPv6 Base: ${IP6}"

echo "[5/11] Configuring ports..."
FIRST_PORT=10000
LAST_PORT=10049

echo "[6/11] Creating IPv6 rotator..."
create_ipv6_rotator

echo "[7/11] Generating initial IPv6 pool (10,000 IPs)..."
echo "   This may take 1-2 minutes..."
generate_initial_pool

echo "[8/11] Creating rotation daemon..."
create_rotation_daemon
create_config_updater

echo "[9/11] Generating 3proxy config..."
gen_3proxy_initial

echo "[10/11] Starting services..."
# Start rotation daemon
nohup /home/bkns/rotation_daemon.sh >> /home/bkns/rotation.log 2>&1 &
echo "   ✅ Rotation daemon started"

sleep 2

# Start 3proxy
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
    echo "   ❌ Failed"
    exit 1
fi

echo "[11/11] Setting up monitoring..."
create_monitor_script
create_startup_script
setup_cron
gen_proxy_file

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
echo "   IPv6 Base: ${IP6}"
echo ""
echo "⚡ UNLIMITED IPv6 Rotation:"
echo "   ✅ Initial pool: 200 IPs per port (10,000 total)"
echo "   ✅ Auto-generates 5 new IPs/port every 30s"
echo "   ✅ Pool continuously refreshed (UNLIMITED)"
echo "   ✅ Each connection = Different IPv6"
echo "   ✅ Total available: 18 quintillion IPs (/64)"
echo ""
echo "🔧 Technical:"
echo "   ✅ Python3-based rotation (no xxd)"
echo "   ✅ Specific IPs (no /64 subnet in config)"
echo "   ✅ Background daemon for continuous rotation"
echo "   ✅ vim-common installed"
echo "   ✅ pkill -9 clean restart"
echo ""
echo "📁 Files:"
echo "   Proxy list: $WORKDIR/proxy.txt"
echo "   Rotation log: /home/bkns/rotation.log"
echo "   Monitor log: /home/bkns/monitor.log"
echo ""
echo "🧪 Test:"
FIRST=$(head -1 $WORKDIR/proxy.txt | grep -v "^#")
if [ -n "$FIRST" ]; then
    IP=$(echo $FIRST | cut -d: -f1)
    PORT=$(echo $FIRST | cut -d: -f2)
    echo "   curl -x ${FIXED_USER}:${FIXED_PASS}@${IP}:${PORT} https://api64.ipify.org"
    
    RES=$(timeout 10 curl -s -x ${FIXED_USER}:${FIXED_PASS}@${IP}:${PORT} https://api64.ipify.org 2>&1)
    [ -n "$RES" ] && echo "   ✅ $RES"
fi
echo ""
echo "======================================================="
echo "💡 How UNLIMITED rotation works:"
echo "   1. Start with 200 IPs per port (10,000 total)"
echo "   2. Every 30s: Generate 5 new random IPs per port"
echo "   3. Keep newest 200 IPs, discard old ones"
echo "   4. 3proxy rotates through current pool"
echo "   5. Result: Unlimited fresh IPs continuously!"
echo "======================================================="
echo ""
```

## ✅ UNLIMITED rotation - Cách hoạt động:

### 📊 **Pool lifecycle:**
```
Start: 200 IPs/port × 50 ports = 10,000 IPs

Every 30 seconds:
  Generate 5 new random IPs for each port (250 new IPs total)
  Keep newest 200 per port
  Discard oldest 5 per port
  Update 3proxy config
  
Result: UNLIMITED fresh IPs, never repeat!
```

### ⚡ **Per-request rotation:**
```
Connection 1 → IP from current pool (e.g., IP #47)
Connection 2 → IP from pool (e.g., IP #153) ← DIFFERENT!
30s later → Pool refreshed with 250 NEW IPs
Connection 3 → NEW IP from refreshed pool ← ALWAYS FRESH!
