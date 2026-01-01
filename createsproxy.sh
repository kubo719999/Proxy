# 1. Stop cron
crontab -r

# 2. Cleanup
pkill -9 3proxy 2>/dev/null
ip -6 addr show eth0 | grep 'inet6.*scope global' | awk '{print $2}' | cut -d'/' -f1 | while read ip; do
    ip -6 addr del ${ip}/64 dev eth0 2>/dev/null
done

# 3. Generate data.txt và proxy.txt
cd /home/bkns

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

# Create data.txt
> /home/bkns/data.txt
for port in $(seq 10000 10049); do
    echo "AnhVip17102/AnhVip17102/$IP4/$port/$(gen64 $IP6)" >> /home/bkns/data.txt
done

echo "Generated $(wc -l < /home/bkns/data.txt) proxies"

# Create proxy.txt
awk -F "/" '{print $3":"$4":AnhVip17102:AnhVip17102"}' /home/bkns/data.txt > /home/bkns/proxy.txt

# Add IPv6
awk -F "/" '{system("ip -6 addr add " $5 "/64 dev eth0 2>/dev/null")}' /home/bkns/data.txt

# Create 3proxy config
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

awk -F "/" '{print "auth strong\nallow AnhVip17102\nproxy -6 -n -a -p" $4 " -i" $3 " -e" $5 "\nflush\n"}' /home/bkns/data.txt >> /usr/local/etc/3proxy/3proxy.cfg

# Start 3proxy
ulimit -n 65536
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &

sleep 3

# Verify
echo ""
echo "=== VERIFICATION ==="
echo "Proxies: $(wc -l < /home/bkns/data.txt)"
echo "IPs: $(ip -6 addr show eth0 | grep -c 'inet6.*scope global')"
echo "3proxy PID: $(pgrep 3proxy || echo 'FAILED')"
echo "Proxy file: $([ -f /home/bkns/proxy.txt ] && echo 'EXISTS' || echo 'MISSING')"

# Enable cron
(
    echo "*/10 * * * * /home/bkns/rotate_ipv6.sh >> /home/bkns/rotate.log 2>&1"
    echo "*/3 * * * * /home/bkns/monitor.sh"
    echo "0 3 * * * /home/bkns/cleanup_logs.sh"
    echo "0 */6 * * * /home/bkns/emergency_cleanup.sh >> /home/bkns/emergency_cleanup.log 2>&1"
) | crontab -

echo ""
echo "✅ Setup completed!"
echo ""
echo "Test proxy:"
FIRST=$(head -1 /home/bkns/proxy.txt)
echo "curl -x AnhVip17102:AnhVip17102@$(echo $FIRST | cut -d: -f1):$(echo $FIRST | cut -d: -f2) https://api64.ipify.org"
