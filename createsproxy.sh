# Stop tất cả
crontab -r 2>/dev/null
pkill -9 3proxy 2>/dev/null

# Xóa IPv6 cũ (nếu có)
ip -6 addr show eth0 2>/dev/null | grep 'inet6.*scope global' | awk '{print $2}' | cut -d'/' -f1 | while read ip; do
    ip -6 addr del ${ip}/64 dev eth0 2>/dev/null
done

# Tạo thư mục
mkdir -p /home/bkns

# Get IPs
IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com 2>/dev/null | cut -f1-4 -d':')

if [ -z "$IP6" ]; then
    IP6=$(ip -6 addr show eth0 2>/dev/null | grep "inet6" | grep -v "fe80" | head -1 | awk '{print $2}' | cut -f1-4 -d':')
fi

echo "IPv4: $IP4"
echo "IPv6: $IP6"

# Generate random IPv6
gen64() {
    array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
    ip64() {
        echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }
    echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

# Create data.txt - 100 PORTS
echo "Creating data.txt for 100 ports..."
> /home/bkns/data.txt
for port in $(seq 10000 10099); do
    echo "AnhVip17102/AnhVip17102/$IP4/$port/$(gen64 $IP6)" >> /home/bkns/data.txt
done

echo "Generated $(wc -l < /home/bkns/data.txt) proxies"

# Create proxy.txt
awk -F "/" '{print $3":"$4":AnhVip17102:AnhVip17102"}' /home/bkns/data.txt > /home/bkns/proxy.txt

# Add IPv6
echo "Adding IPv6 addresses..."
awk -F "/" '{system("ip -6 addr add " $5 "/64 dev eth0 2>/dev/null")}' /home/bkns/data.txt
sleep 2

# Create 3proxy config - 100 PORTS
cat > /usr/local/etc/3proxy/3proxy.cfg << 'EOFCFG'
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

EOFCFG

awk -F "/" '{print "auth strong\nallow AnhVip17102\nproxy -6 -n -a -p" $4 " -i" $3 " -e" $5 "\nflush"}' /home/bkns/data.txt >> /usr/local/etc/3proxy/3proxy.cfg

# Start 3proxy
echo "Starting 3proxy..."
pkill -9 3proxy 2>/dev/null
sleep 2
ulimit -n 65536
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
sleep 3

# Create rotation script - 100 PORTS
cat > /home/bkns/rotate_ipv6.sh << 'ROTEOF'
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
WORKDIR="/home/bkns"
WORKDATA="${WORKDIR}/data.txt"
LOGFILE="${WORKDIR}/rotate.log"
FIXED_USER="AnhVip17102"
FIXED_PASS="AnhVip17102"

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $LOGFILE
}

if [ -f "$LOGFILE" ]; then
    LOG_SIZE=$(du -m "$LOGFILE" 2>/dev/null | cut -f1)
    [ "$LOG_SIZE" -gt 10 ] && tail -n 1000 "$LOGFILE" > "${LOGFILE}.tmp" && mv "${LOGFILE}.tmp" "$LOGFILE"
fi

log_msg "========== Rotation Start =========="

IP6=$(head -1 $WORKDATA 2>/dev/null | cut -d'/' -f5 | cut -f1-4 -d':')
[ -z "$IP6" ] && log_msg "ERROR: No IPv6" && exit 1

PROXY_COUNT=$(wc -l < $WORKDATA)
cp $WORKDATA ${WORKDATA}.backup

awk -v ip6="$IP6" -v user="$FIXED_USER" -v pass="$FIXED_PASS" -F "/" '
BEGIN {
    srand();
    hex="0123456789abcdef";
}
{
    new_suffix = "";
    for(i=1; i<=16; i++) {
        new_suffix = new_suffix substr(hex, int(rand()*16)+1, 1);
    }
    
    part1 = substr(new_suffix, 1, 4);
    part2 = substr(new_suffix, 5, 4);
    part3 = substr(new_suffix, 9, 4);
    part4 = substr(new_suffix, 13, 4);
    
    new_ip6 = ip6 ":" part1 ":" part2 ":" part3 ":" part4;
    print user "/" pass "/" $3 "/" $4 "/" new_ip6;
}' $WORKDATA > ${WORKDATA}.new

[ ! -s ${WORKDATA}.new ] && log_msg "ERROR: Gen failed" && exit 1
mv ${WORKDATA}.new $WORKDATA

cat > /usr/local/etc/3proxy/3proxy.cfg.new << 'EOFCFG'
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
EOFCFG

echo "users ${FIXED_USER}:CL:${FIXED_PASS}" >> /usr/local/etc/3proxy/3proxy.cfg.new

awk -v user="$FIXED_USER" -F "/" '{
    print "auth strong";
    print "allow " user;
    print "proxy -6 -n -a -p" $4 " -i" $3 " -e" $5;
    print "flush";
}' ${WORKDATA} >> /usr/local/etc/3proxy/3proxy.cfg.new

mv /usr/local/etc/3proxy/3proxy.cfg.new /usr/local/etc/3proxy/3proxy.cfg

log_msg "Deleting all old IPv6..."
BEFORE=$(ip -6 addr show eth0 2>/dev/null | grep -c 'inet6.*scope global')

ip -6 addr show eth0 2>/dev/null | grep 'inet6.*scope global' | awk '{print $2}' | cut -d'/' -f1 | while read ip; do
    ip -6 addr del ${ip}/64 dev eth0 2>/dev/null
done

sleep 2

log_msg "Adding new IPv6..."
awk -F "/" '{system("ip -6 addr add " $5 "/64 dev eth0 2>/dev/null")}' ${WORKDATA}

sleep 2

OLD_PID=$(pgrep 3proxy)

if [ -n "$OLD_PID" ]; then
    kill -HUP $OLD_PID 2>/dev/null
    sleep 5
    
    if ! pgrep 3proxy > /dev/null; then
        pkill -9 3proxy 2>/dev/null
        sleep 2
        ulimit -n 65536
        /usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
        sleep 3
    fi
else
    ulimit -n 65536
    /usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
    sleep 3
fi

NEW_PID=$(pgrep 3proxy)
FINAL=$(ip -6 addr show eth0 2>/dev/null | grep -c 'inet6.*scope global')

[ "$FINAL" -ne "$PROXY_COUNT" ] && awk -F "/" '{system("ip -6 addr add " $5 "/64 dev eth0 2>/dev/null")}' ${WORKDATA} && sleep 1 && FINAL=$(ip -6 addr show eth0 2>/dev/null | grep -c 'inet6.*scope global')

log_msg "========== Done: Proxies=$PROXY_COUNT IPs=$FINAL PID=$NEW_PID =========="
ROTEOF

chmod +x /home/bkns/rotate_ipv6.sh

# Create support scripts
cat > /home/bkns/monitor.sh << 'EOF'
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
pgrep 3proxy > /dev/null || { pkill -9 3proxy 2>/dev/null; sleep 2; ulimit -n 65536; /usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &; }
IP_COUNT=$(ip -6 addr show eth0 | grep -c 'inet6.*scope global' 2>/dev/null)
[ "$IP_COUNT" -gt 150 ] && /home/bkns/emergency_cleanup.sh
EOF

cat > /home/bkns/emergency_cleanup.sh << 'EOF'
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
[ ! -f "/home/bkns/data.txt" ] && exit 1
awk -F "/" '{print $5}' /home/bkns/data.txt | sort > /tmp/keep_ec.txt
BEFORE=$(ip -6 addr show eth0 | grep -c 'inet6.*scope global')
[ "$BEFORE" -lt 150 ] && rm -f /tmp/keep_ec.txt && exit 0
ip -6 addr show eth0 | grep 'inet6.*scope global' | awk '{print $2}' | cut -d'/' -f1 | while read ip; do grep -Fxq "$ip" /tmp/keep_ec.txt || ip -6 addr del ${ip}/64 dev eth0 2>/dev/null; done
rm -f /tmp/keep_ec.txt
EOF

cat > /home/bkns/cleanup_logs.sh << 'EOF'
#!/bin/bash
for log in /home/bkns/*.log; do [ -f "$log" ] && [ $(du -m "$log" 2>/dev/null | cut -f1) -gt 10 ] && tail -n 1000 "$log" > "${log}.tmp" && mv "${log}.tmp" "$log"; done
EOF

chmod +x /home/bkns/{monitor,emergency_cleanup,cleanup_logs}.sh

# Setup cron - 10 PHÚT
crontab -r 2>/dev/null
(
    echo "*/10 * * * * /home/bkns/rotate_ipv6.sh >> /home/bkns/rotate.log 2>&1"
    echo "*/3 * * * * /home/bkns/monitor.sh"
    echo "0 3 * * * /home/bkns/cleanup_logs.sh"
    echo "0 */6 * * * /home/bkns/emergency_cleanup.sh >> /home/bkns/emergency_cleanup.log 2>&1"
) | crontab -

# Auto-start
cat > /etc/rc.d/rc.local << 'EOF'
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
awk -F "/" '{system("ip -6 addr add " $5 "/64 dev eth0 2>/dev/null")}' /home/bkns/data.txt
ulimit -n 65536
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
EOF
chmod +x /etc/rc.d/rc.local
systemctl enable rc-local 2>/dev/null

echo ""
echo "================================================================"
echo "✅ COMPLETED - 100 PORTS, 10 MINUTE ROTATION"
echo "================================================================"
echo "Proxies: $(wc -l < /home/bkns/data.txt)"
echo "IPs: $(ip -6 addr show eth0 | grep -c 'inet6.*scope global')"
echo "3proxy: $(pgrep 3proxy || echo 'FAILED')"
echo "Proxy file: $(wc -l < /home/bkns/proxy.txt) lines"
echo ""
echo "Test: curl -x AnhVip17102:AnhVip17102@$IP4:10000 https://api64.ipify.org"
echo "View: cat /home/bkns/proxy.txt"
echo "Monitor: tail -f /home/bkns/rotate.log"
echo "================================================================"
