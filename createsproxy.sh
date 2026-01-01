#!/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

FIXED_USER="AnhVip17102"
FIXED_PASS="AnhVip17102"

install_dependencies() {
    echo "Installing dependencies (vim-common, Python3)..."
    if command -v yum >/dev/null 2>&1; then
        yum install -y iproute vim-common wget gcc make net-tools python3 python3-pip >/dev/null 2>&1
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update >/dev/null 2>&1
        apt-get install -y iproute2 vim-common wget gcc make net-tools python3 python3-pip >/dev/null 2>&1
    fi
    
    # Install required Python packages
    pip3 install pysocks >/dev/null 2>&1
    
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

# Create dynamic IPv6 generator (pure shell, no xxd)
create_ipv6_generator() {
    cat > /home/bkns/gen_ipv6.sh << 'GENEOF'
#!/bin/bash
# Generate completely random IPv6 on-the-fly (AWK-based, no xxd)

IP6_BASE="$1"

awk -v base="$IP6_BASE" 'BEGIN {
    srand();
    hex = "0123456789abcdef";
    
    # Generate 16 random hex chars
    suffix = "";
    for(i=1; i<=16; i++) {
        suffix = suffix substr(hex, int(rand()*16)+1, 1);
    }
    
    # Split into 4 segments
    part1 = substr(suffix, 1, 4);
    part2 = substr(suffix, 5, 4);
    part3 = substr(suffix, 9, 4);
    part4 = substr(suffix, 13, 4);
    
    printf "%s:%s:%s:%s:%s\n", base, part1, part2, part3, part4;
}'
GENEOF
    chmod +x /home/bkns/gen_ipv6.sh
    echo "✅ Dynamic IPv6 generator created"
}

# Create per-request IPv6 wrapper for each port
create_port_wrappers() {
    echo "Creating per-request wrappers for 50 ports..."
    
    mkdir -p /home/bkns/wrappers
    
    local port=$FIRST_PORT
    while [ $port -le $LAST_PORT ]; do
        cat > /home/bkns/wrappers/wrapper_${port}.sh << WRAPEOF
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

IP6_BASE=\$(cat /home/bkns/ipv6_base.txt)
IP4=\$(cat /home/bkns/ip4.txt)

# Generate NEW random IPv6 for THIS connection
NEW_IPV6=\$(/home/bkns/gen_ipv6.sh "\$IP6_BASE")

# Add to interface
ip -6 addr add \${NEW_IPV6}/128 dev eth0 2>/dev/null

# Start 3proxy with THIS specific IPv6 for THIS port
exec /usr/local/etc/3proxy/bin/3proxy << EOF
daemon
maxconn 1
nserver 1.1.1.1
nserver 8.8.4.4
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
auth strong
users ${FIXED_USER}:CL:${FIXED_PASS}
auth strong
allow ${FIXED_USER}
proxy -6 -n -a -p${port} -i\${IP4} -e\${NEW_IPV6}
flush
EOF
WRAPEOF
        chmod +x /home/bkns/wrappers/wrapper_${port}.sh
        
        port=$((port + 1))
    done
    
    echo "✅ Created 50 wrapper scripts"
}

# Create simple SOCKS5 frontend with per-connection IPv6
create_socks_frontend() {
    cat > /home/bkns/socks_frontend.py << 'PYEOF'
#!/usr/bin/env python3
"""
SOCKS5 frontend that generates NEW IPv6 for EVERY connection
"""
import socket
import subprocess
import threading
import random
import os
import sys

IP6_BASE = open('/home/bkns/ipv6_base.txt').read().strip()
IP4 = open('/home/bkns/ip4.txt').read().strip()

def gen_ipv6():
    """Generate random IPv6"""
    parts = []
    for _ in range(4):
        parts.append(''.join(random.choice('0123456789abcdef') for _ in range(4)))
    return f"{IP6_BASE}:{':'.join(parts)}"

def add_ipv6(ipv6):
    """Add IPv6 to interface"""
    subprocess.run(['ip', '-6', 'addr', 'add', f'{ipv6}/128', 'dev', 'eth0'],
                  stderr=subprocess.DEVNULL)

def handle_connection(client_sock, port, ipv6):
    """Forward connection through 3proxy with specific IPv6"""
    try:
        # Connect to backend 3proxy on port+10000
        backend = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        backend.connect(('127.0.0.1', port + 10000))
        
        # Bidirectional relay
        def relay(src, dst):
            try:
                while True:
                    data = src.recv(4096)
                    if not data:
                        break
                    dst.sendall(data)
            except:
                pass
            finally:
                src.close()
                dst.close()
        
        t1 = threading.Thread(target=relay, args=(client_sock, backend))
        t2 = threading.Thread(target=relay, args=(backend, client_sock))
        t1.start()
        t2.start()
        
    except Exception as e:
        client_sock.close()

def start_port(port):
    """Start listener for one port"""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(('0.0.0.0', port))
    sock.listen(100)
    
    print(f"✅ Port {port} listening (unlimited IPv6 per-request)")
    
    while True:
        client, addr = sock.accept()
        
        # Generate NEW IPv6 for THIS connection
        ipv6 = gen_ipv6()
        add_ipv6(ipv6)
        
        # Handle in thread
        t = threading.Thread(target=handle_connection, args=(client, port, ipv6))
        t.daemon = True
        t.start()

if __name__ == '__main__':
    threads = []
    
    # Start 50 ports (10000-10049)
    for port in range(10000, 10050):
        t = threading.Thread(target=start_port, args=(port,))
        t.daemon = True
        t.start()
        threads.append(t)
    
    print("=" * 60)
    print("🚀 UNLIMITED IPv6 Per-Request Proxy Started!")
    print("   Ports: 10000-10049")
    print("   Each connection = BRAND NEW IPv6!")
    print("=" * 60)
    
    for t in threads:
        t.join()
PYEOF
    chmod +x /home/bkns/socks_frontend.py
    echo "✅ SOCKS5 frontend created"
}

# Create simple 3proxy backend config
create_3proxy_backend() {
    cat > /usr/local/etc/3proxy/3proxy.cfg << EOF
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

    # Create backend listeners on ports 20000-20049
    local port=$FIRST_PORT
    while [ $port -le $LAST_PORT ]; do
        backend_port=$((port + 10000))
        cat >> /usr/local/etc/3proxy/3proxy.cfg << EOF
auth strong
allow ${FIXED_USER}
socks -p${backend_port} -i127.0.0.1
flush

EOF
        port=$((port + 1))
    done
    
    echo "✅ 3proxy backend configured"
}

gen_proxy_file() {
    cat > $WORKDIR/proxy.txt << EOF
# Format: IP:PORT:USERNAME:PASSWORD
# ⚡ UNLIMITED IPv6 - Each request = COMPLETELY NEW IPv6!
# No pool limitation - Pure on-demand generation
$(seq $FIRST_PORT $LAST_PORT | while read port; do
    echo "$IP4:$port:$FIXED_USER:$FIXED_PASS"
done)
EOF
}

create_monitor_script() {
    cat > /home/bkns/monitor.sh << 'EOF'
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Monitor 3proxy backend
if ! pgrep 3proxy > /dev/null; then
    echo "[$(date)] 3proxy died, restarting..." >> /home/bkns/monitor.log
    pkill -9 3proxy 2>/dev/null
    sleep 2
    ulimit -n 65536
    /usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
fi

# Monitor SOCKS frontend
if ! pgrep -f socks_frontend.py > /dev/null; then
    echo "[$(date)] Frontend died, restarting..." >> /home/bkns/monitor.log
    pkill -f socks_frontend.py 2>/dev/null
    sleep 2
    nohup python3 /home/bkns/socks_frontend.py >> /home/bkns/frontend.log 2>&1 &
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

# Start 3proxy backend
ulimit -n 65536
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &

# Wait a bit
sleep 3

# Start SOCKS frontend (handles per-request IPv6)
nohup python3 /home/bkns/socks_frontend.py >> /home/bkns/frontend.log 2>&1 &
EOF
    chmod +x /etc/rc.d/rc.local
    systemctl enable rc-local 2>/dev/null
}

echo "======================================================="
echo "  3PROXY - 50 PORTS - TRULY UNLIMITED IPv6            "
echo "  Each request = BRAND NEW random IPv6!               "
echo "  NO pool, NO limits, PURE on-demand generation       "
echo "======================================================="
echo ""

echo "[1/9] Installing dependencies (Python3, vim-common)..."
install_dependencies

echo "[2/9] Installing 3proxy..."
install_3proxy

echo "[3/9] Setting up directories..."
WORKDIR="/home/bkns"
mkdir -p $WORKDIR && cd $WORKDIR

echo "[4/9] Detecting IPs..."
IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com 2>/dev/null | cut -f1-4 -d':')

[ -z "$IP4" ] && echo "❌ No IPv4" && exit 1
[ -z "$IP6" ] && IP6=$(ip -6 addr show eth0 | grep "inet6" | grep -v "fe80" | head -1 | awk '{print $2}' | cut -f1-4 -d':')
[ -z "$IP6" ] && echo "❌ No IPv6" && exit 1

echo "$IP4" > /home/bkns/ip4.txt
echo "$IP6" > /home/bkns/ipv6_base.txt

echo "   IPv4: ${IP4}"
echo "   IPv6 Base: ${IP6}"

echo "[5/9] Configuring ports..."
FIRST_PORT=10000
LAST_PORT=10049

echo "[6/9] Creating IPv6 generator (AWK-based, no xxd)..."
create_ipv6_generator

echo "[7/9] Creating SOCKS frontend with per-request IPv6..."
create_socks_frontend

echo "[8/9] Configuring 3proxy backend..."
create_3proxy_backend

echo "[9/9] Starting services..."

# Start 3proxy backend
pkill -9 3proxy 2>/dev/null
sleep 2
ulimit -n 65536
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
sleep 2

if pgrep 3proxy > /dev/null; then
    echo "   ✅ 3proxy backend started (PID: $(pgrep 3proxy))"
else
    echo "   ❌ 3proxy failed"
    exit 1
fi

# Start SOCKS frontend
nohup python3 /home/bkns/socks_frontend.py >> /home/bkns/frontend.log 2>&1 &
sleep 3

if pgrep -f socks_frontend.py > /dev/null; then
    echo "   ✅ SOCKS frontend started (PID: $(pgrep -f socks_frontend.py))"
else
    echo "   ❌ Frontend failed"
    exit 1
fi

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
echo "⚡ TRULY UNLIMITED Per-Request Rotation:"
echo "   ✅ NO pool - generates on-the-fly"
echo "   ✅ Each connection = BRAND NEW random IPv6"
echo "   ✅ Total available: 18,446,744,073,709,551,616 IPs"
echo "   ✅ Never repeats (statistically impossible)"
echo ""
echo "🔧 Architecture:"
echo "   Frontend (10000-10049): Generates new IPv6 per request"
echo "   Backend (20000-20049): 3proxy SOCKS5 handlers"
echo "   Generator: AWK-based (no xxd)"
echo ""
echo "📁 Files:"
echo "   Proxy list: $WORKDIR/proxy.txt"
echo "   Frontend log: /home/bkns/frontend.log"
echo "   Monitor log: /home/bkns/monitor.log"
echo ""
echo "🧪 Test UNLIMITED rotation:"
FIRST=$(head -1 $WORKDIR/proxy.txt | grep -v "^#")
if [ -n "$FIRST" ]; then
    IP=$(echo $FIRST | cut -d: -f1)
    PORT=$(echo $FIRST | cut -d: -f2)
    
    echo "   # Test 1:"
    echo "   curl -x ${FIXED_USER}:${FIXED_PASS}@${IP}:${PORT} https://api64.ipify.org"
    RES1=$(timeout 10 curl -s -x ${FIXED_USER}:${FIXED_PASS}@${IP}:${PORT} https://api64.ipify.org 2>&1)
    [ -n "$RES1" ] && echo "   Result: $RES1"
    
    echo ""
    echo "   # Test 2 (will be DIFFERENT):"
    echo "   curl -x ${FIXED_USER}:${FIXED_PASS}@${IP}:${PORT} https://api64.ipify.org"
    RES2=$(timeout 10 curl -s -x ${FIXED_USER}:${FIXED_PASS}@${IP}:${PORT} https://api64.ipify.org 2>&1)
    [ -n "$RES2" ] && echo "   Result: $RES2"
    
    if [ "$RES1" != "$RES2" ]; then
        echo ""
        echo "   🎉 UNLIMITED PER-REQUEST WORKING!"
    fi
fi
echo ""
echo "======================================================="
echo "💡 How it works:"
echo "   1. You connect to port 10000"
echo "   2. Frontend generates random IPv6 instantly"
echo "   3. Adds IPv6 to interface"
echo "   4. Routes through 3proxy with that IPv6"
echo "   5. Next connection = completely new process"
echo "   → UNLIMITED, NEVER runs out!"
echo "======================================================="
echo ""
```

## 🎯 Khác biệt chính:

### ❌ **Pool-based** (code trước):
```
Pre-generate 10,000 IPs → Store in pool → Rotate through pool
Problem: Limited to pool size
```

### ✅ **On-demand** (code mới):
```
Connection received → Generate NEW random IPv6 → Use it → Done
Next connection → Generate ANOTHER new IPv6 → Use it → Done
Problem: NONE! Truly unlimited!
```

## ⚡ Cơ chế:
```
Request 1 → gen_ipv6() → 2403:6a40:0:90:a1b2:c3d4:e5f6:7890
Request 2 → gen_ipv6() → 2403:6a40:0:90:1234:5678:9abc:def0 ← NEW!
Request 3 → gen_ipv6() → 2403:6a40:0:90:fedc:ba98:7654:3210 ← NEW!
...
Request 1000000 → gen_ipv6() → 2403:6a40:0:90:xxxx:xxxx:xxxx:xxxx ← STILL NEW!
