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

create_ipv6_generator() {
    cat > /home/bkns/gen_ipv6.sh << 'GENEOF'
#!/bin/bash
IP6_BASE="$1"

awk -v base="$IP6_BASE" 'BEGIN {
    srand();
    hex = "0123456789abcdef";
    
    suffix = "";
    for(i=1; i<=16; i++) {
        suffix = suffix substr(hex, int(rand()*16)+1, 1);
    }
    
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

create_socks_frontend() {
    cat > /home/bkns/socks_frontend.py << 'PYEOF'
#!/usr/bin/env python3
import socket
import subprocess
import threading
import random

IP6_BASE = open('/home/bkns/ipv6_base.txt').read().strip()
IP4 = open('/home/bkns/ip4.txt').read().strip()

def gen_ipv6():
    parts = []
    for _ in range(4):
        parts.append(''.join(random.choice('0123456789abcdef') for _ in range(4)))
    return f"{IP6_BASE}:{':'.join(parts)}"

def add_ipv6(ipv6):
    subprocess.run(['ip', '-6', 'addr', 'add', f'{ipv6}/128', 'dev', 'eth0'],
                  stderr=subprocess.DEVNULL)

def handle_connection(client_sock, port, ipv6):
    try:
        backend = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        backend.connect(('127.0.0.1', port + 10000))
        
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
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(('0.0.0.0', port))
    sock.listen(100)
    
    print(f"Port {port} listening")
    
    while True:
        client, addr = sock.accept()
        ipv6 = gen_ipv6()
        add_ipv6(ipv6)
        
        t = threading.Thread(target=handle_connection, args=(client, port, ipv6))
        t.daemon = True
        t.start()

if __name__ == '__main__':
    threads = []
    
    for port in range(10000, 10050):
        t = threading.Thread(target=start_port, args=(port,))
        t.daemon = True
        t.start()
        threads.append(t)
    
    print("UNLIMITED IPv6 Per-Request Proxy Started!")
    print("Ports: 10000-10049")
    
    for t in threads:
        t.join()
PYEOF
    chmod +x /home/bkns/socks_frontend.py
    echo "✅ SOCKS5 frontend created"
}

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
$(seq $FIRST_PORT $LAST_PORT | while read port; do
    echo "$IP4:$port:$FIXED_USER:$FIXED_PASS"
done)
EOF
}

create_monitor_script() {
    cat > /home/bkns/monitor.sh << 'EOF'
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

if ! pgrep 3proxy > /dev/null; then
    echo "[$(date)] 3proxy died, restarting..." >> /home/bkns/monitor.log
    pkill -9 3proxy 2>/dev/null
    sleep 2
    ulimit -n 65536
    /usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
fi

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

ulimit -n 65536
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &

sleep 3

nohup python3 /home/bkns/socks_frontend.py >> /home/bkns/frontend.log 2>&1 &
EOF
    chmod +x /etc/rc.d/rc.local
    systemctl enable rc-local 2>/dev/null
}

echo "======================================================="
echo "  3PROXY - 50 PORTS - UNLIMITED IPv6 PER-REQUEST      "
echo "======================================================="
echo ""

echo "[1/9] Installing dependencies..."
install_dependencies

echo "[2/9] Installing 3proxy..."
install_3proxy

echo "[3/9] Setting up directories..."
WORKDIR="/home/bkns"
mkdir -p $WORKDIR && cd $WORKDIR

echo "[4/9] Detecting IPs..."
IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com 2>/dev/null | cut -f1-4 -d':')

[ -z "$IP4" ] && echo "ERROR: No IPv4" && exit 1
[ -z "$IP6" ] && IP6=$(ip -6 addr show eth0 | grep "inet6" | grep -v "fe80" | head -1 | awk '{print $2}' | cut -f1-4 -d':')
[ -z "$IP6" ] && echo "ERROR: No IPv6" && exit 1

echo "$IP4" > /home/bkns/ip4.txt
echo "$IP6" > /home/bkns/ipv6_base.txt

echo "   IPv4: ${IP4}"
echo "   IPv6: ${IP6}"

echo "[5/9] Configuring ports..."
FIRST_PORT=10000
LAST_PORT=10049

echo "[6/9] Creating IPv6 generator..."
create_ipv6_generator

echo "[7/9] Creating SOCKS frontend..."
create_socks_frontend

echo "[8/9] Configuring 3proxy..."
create_3proxy_backend

echo "[9/9] Starting services..."

pkill -9 3proxy 2>/dev/null
sleep 2
ulimit -n 65536
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
sleep 2

if pgrep 3proxy > /dev/null; then
    echo "   Backend started"
else
    echo "   Backend failed"
    exit 1
fi

nohup python3 /home/bkns/socks_frontend.py >> /home/bkns/frontend.log 2>&1 &
sleep 3

if pgrep -f socks_frontend.py > /dev/null; then
    echo "   Frontend started"
else
    echo "   Frontend failed"
    exit 1
fi

create_monitor_script
create_startup_script
setup_cron
gen_proxy_file

rm -rf /root/setup.sh /root/3proxy-* 3proxy-0.8.13 2>/dev/null

echo ""
echo "======================================================="
echo "INSTALLATION COMPLETED"
echo "======================================================="
echo ""
echo "Ports: 50 (10000-10049)"
echo "User: ${FIXED_USER}"
echo "Pass: ${FIXED_PASS}"
echo "IPv4: ${IP4}"
echo "IPv6: ${IP6}"
echo ""
echo "UNLIMITED per-request rotation - Each connection = NEW IPv6"
echo "======================================================="
echo ""
