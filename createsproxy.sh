# Xóa rotation.log cũ để dễ theo dõi
> /home/bkns/rotation.log

# Tạo lại script rotate_ip.sh HOÀN TOÀN MỚI
cat > /home/bkns/rotate_ip.sh << 'EOFSCRIPT'
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
WORKDIR="/home/bkns"
WORKDATA="${WORKDIR}/data.txt"
FIRST_PORT=22000
LAST_PORT=22049

rotate_ipv6() {
    echo "[$(date)] Starting IP rotation..."
    
    # Xóa IPv6 cũ
    echo "[$(date)] Removing old IPv6 addresses..."
    for addr in $(ip -6 addr show dev eth0 | grep -E 'inet6 2403' | awk '{print $2}'); do
        ip -6 addr del $addr dev eth0 2>/dev/null
    done
    
    sleep 1
    
    # Lấy IPv6 prefix
    IP6=$(ip -6 route show default | awk '{print $3}' | cut -f1-4 -d':')
    IP4=$(curl -4 -s --max-time 5 icanhazip.com 2>/dev/null)
    [ -z "$IP4" ] && IP4=$(ip -4 addr show eth0 | grep inet | awk '{print $2}' | cut -d'/' -f1)
    
    if [ -z "$IP6" ] || [ -z "$IP4" ]; then
        echo "[$(date)] ERROR: IP6='$IP6', IP4='$IP4'"
        return 1
    fi
    
    echo "[$(date)] IPv6: $IP6 | IPv4: $IP4"
    
    # Generate IPv6
    array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
    gen64() {
        ip64() { echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"; }
        echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
    }
    
    # Tạo data mới
    echo "[$(date)] Generating 50 proxies..."
    > ${WORKDATA}.new
    for port in $(seq $FIRST_PORT $LAST_PORT); do
        echo "AnhVip17102/AnhVip17102/$IP4/$port/$(gen64 $IP6)" >> ${WORKDATA}.new
    done
    
    # Add IPv6
    echo "[$(date)] Adding IPv6 addresses..."
    awk -F "/" '{print "ip -6 addr add " $5 "/64 dev eth0 2>/dev/null"}' ${WORKDATA}.new | bash
    sleep 2
    
    IPV6_COUNT=$(ip -6 addr show dev eth0 | grep 2403 | wc -l)
    echo "[$(date)] IPv6 added: $IPV6_COUNT/50"
    
    # Config 3proxy
    echo "[$(date)] Updating 3proxy config..."
    cat > /usr/local/etc/3proxy/3proxy.cfg <<EOFCONFIG
daemon
maxconn 2000
nserver 1.1.1.1
nserver 8.8.4.4
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
stacksize 6291456 
flush
auth strong
users $(awk -F "/" 'BEGIN{ORS="";} {print $1 ":CL:" $2 " "}' ${WORKDATA}.new)
$(awk -F "/" '{print "auth strong\nallow " $1 "\nproxy -6 -n -a -p" $4 " -i" $3 " -e"$5"\nflush"}' ${WORKDATA}.new)
EOFCONFIG
    
    mv ${WORKDATA}.new ${WORKDATA}
    awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2}' ${WORKDATA} > ${WORKDIR}/proxy.txt
    
    # Restart 3proxy
    echo "[$(date)] Restarting 3proxy..."
    pkill -9 3proxy 2>/dev/null
    sleep 1
    ulimit -n 10048
    /usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
    sleep 2
    
    if pgrep 3proxy >/dev/null; then
        echo "[$(date)] ✓ SUCCESS! IPv6: $IPV6_COUNT"
    else
        echo "[$(date)] ✗ FAILED! 3proxy not running"
        return 1
    fi
}

rotate_ipv6
EOFSCRIPT

chmod +x /home/bkns/rotate_ip.sh

# Test ngay
echo "=== TESTING SCRIPT ===" && bash /home/bkns/rotate_ip.sh
