# Stop monitoring
# Nhấn Ctrl+C để thoát tail -f

# Chạy cài đặt đầy đủ
cd /root

# 1. Install dependencies
echo "Installing dependencies..."
yum install -y iproute vim-common wget gcc make net-tools

# 2. Install 3proxy
echo "Installing 3proxy..."
rm -rf 3proxy-0.8.13 3proxy.tar.gz
wget -q https://github.com/z3APA3A/3proxy/archive/refs/tags/0.8.13.tar.gz -O 3proxy.tar.gz
tar -xzf 3proxy.tar.gz
cd 3proxy-0.8.13
make -f Makefile.Linux
mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
cp src/3proxy /usr/local/etc/3proxy/bin/
cd /root
rm -rf 3proxy-0.8.13 3proxy.tar.gz

echo "3proxy installed: $(ls -lh /usr/local/etc/3proxy/bin/3proxy)"

# 3. Get IPs
IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com 2>/dev/null | cut -f1-4 -d':')

if [ -z "$IP6" ]; then
    IP6=$(ip -6 addr show eth0 2>/dev/null | grep "inet6" | grep -v "fe80" | head -1 | awk '{print $2}' | cut -f1-4 -d':')
fi

echo "IPv4: $IP4"
echo "IPv6: $IP6"

# 4. Create data.txt if not exists
if [ ! -f /home/bkns/data.txt ]; then
    echo "Creating data.txt..."
    mkdir -p /home/bkns
    
    gen64() {
        array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
        ip64() {
            echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
        }
        echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
    }
    
    > /home/bkns/data.txt
    for port in $(seq 10000 10049); do
        echo "AnhVip17102/AnhVip17102/$IP4/$port/$(gen64 $IP6)" >> /home/bkns/data.txt
    done
fi

# 5. Create proxy.txt
awk -F "/" '{print $3":"$4":AnhVip17102:AnhVip17102"}' /home/bkns/data.txt > /home/bkns/proxy.txt
echo "Created proxy.txt: $(wc -l < /home/bkns/proxy.txt) lines"

# 6. Add IPv6 if needed
CURRENT_IPS=$(ip -6 addr show eth0 | grep -c 'inet6.*scope global')
if [ "$CURRENT_IPS" -lt 50 ]; then
    echo "Adding IPv6 addresses..."
    awk -F "/" '{system("ip -6 addr add " $5 "/64 dev eth0 2>/dev/null")}' /home/bkns/data.txt
fi

# 7. Create 3proxy config
cat > /usr/local/etc/3proxy/3proxy.cfg << 'EOFCFG'
daemon
maxconn 2000
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

EOFCFG

awk -F "/" '{print "auth strong\nallow AnhVip17102\nproxy -6 -n -a -p" $4 " -i" $3 " -e" $5 "\nflush"}' /home/bkns/data.txt >> /usr/local/etc/3proxy/3proxy.cfg

# 8. Start 3proxy
pkill -9 3proxy 2>/dev/null
sleep 2
ulimit -n 65536
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
sleep 3

# 9. Create support scripts
cat > /home/bkns/monitor.sh << 'EOF'
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
pgrep 3proxy > /dev/null || { pkill -9 3proxy 2>/dev/null; sleep 2; ulimit -n 65536; /usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &; }
EOF

cat > /home/bkns/emergency_cleanup.sh << 'EOF'
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
[ ! -f "/home/bkns/data.txt" ] && exit 1
awk -F "/" '{print $5}' /home/bkns/data.txt | sort > /tmp/keep_ec.txt
BEFORE=$(ip -6 addr show eth0 | grep -c 'inet6.*scope global')
[ "$BEFORE" -lt 100 ] && rm -f /tmp/keep_ec.txt && exit 0
ip -6 addr show eth0 | grep 'inet6.*scope global' | awk '{print $2}' | cut -d'/' -f1 | while read ip; do grep -Fxq "$ip" /tmp/keep_ec.txt || ip -6 addr del ${ip}/64 dev eth0 2>/dev/null; done
rm -f /tmp/keep_ec.txt
EOF

cat > /home/bkns/cleanup_logs.sh << 'EOF'
#!/bin/bash
for log in /home/bkns/*.log; do [ -f "$log" ] && [ $(du -m "$log" 2>/dev/null | cut -f1) -gt 10 ] && tail -n 1000 "$log" > "${log}.tmp" && mv "${log}.tmp" "$log"; done
EOF

chmod +x /home/bkns/{monitor,emergency_cleanup,cleanup_logs}.sh

# 10. Setup auto-start
cat > /etc/rc.d/rc.local << 'EOF'
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
awk -F "/" '{system("ip -6 addr add " $5 "/64 dev eth0 2>/dev/null")}' /home/bkns/data.txt
ulimit -n 65536
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
EOF
chmod +x /etc/rc.d/rc.local
systemctl enable rc-local 2>/dev/null

# 11. Final verification
echo ""
echo "================================================================"
echo "INSTALLATION COMPLETED"
echo "================================================================"
echo "Proxies: $(wc -l < /home/bkns/data.txt)"
echo "IPs: $(ip -6 addr show eth0 | grep -c 'inet6.*scope global')"
echo "3proxy: $(pgrep 3proxy || echo 'NOT RUNNING')"
echo "Proxy file: $([ -f /home/bkns/proxy.txt ] && wc -l < /home/bkns/proxy.txt || echo '0') lines"
echo ""

# Test
if [ -f /home/bkns/proxy.txt ]; then
    FIRST=$(head -1 /home/bkns/proxy.txt)
    IP=$(echo $FIRST | cut -d: -f1)
    PORT=$(echo $FIRST | cut -d: -f2)
    echo "Testing proxy: $IP:$PORT"
    curl -x AnhVip17102:AnhVip17102@${IP}:${PORT} https://api64.ipify.org
    echo ""
fi

echo ""
echo "View proxies: cat /home/bkns/proxy.txt"
echo "Monitor: tail -f /home/bkns/rotate.log"
echo "================================================================"
```

---

## ✅ KẾT QUẢ MONG ĐỢI:
```
3proxy installed: /usr/local/etc/3proxy/bin/3proxy
Created proxy.txt: 50 lines

================================================================
INSTALLATION COMPLETED
================================================================
Proxies: 50
IPs: 50
3proxy: 12345
Proxy file: 50 lines

Testing proxy: 42.96.12.130:10000
2403:6a40:0:12:xxxx:xxxx:xxxx:xxxx
