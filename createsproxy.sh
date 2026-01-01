cat > /home/bkns/rotate_ip.sh << 'EOFSCRIPT'
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
WORKDIR="/home/bkns"
WORKDATA="${WORKDIR}/data.txt"
FIRST_PORT=22000
LAST_PORT=22049

rotate_ipv6() {
    echo "[$(date)] Starting IP rotation..."
    
    # Lưu danh sách IPv6 cũ từ data.txt
    OLD_IPV6=$(awk -F "/" '{print $5}' ${WORKDATA} 2>/dev/null)
    
    # Xóa tất cả IPv6 cũ trên interface eth0 (chỉ global)
    echo "[$(date)] Removing old IPv6 addresses..."
    for addr in $(/usr/sbin/ip -6 addr show dev eth0 | grep -E 'inet6 2403|inet6 2' | grep -v fe80 | awk '{print $2}'); do
        /usr/sbin/ip -6 addr del $addr dev eth0 2>/dev/null
    done
    
    sleep 1
    
    # Lấy IPv6 prefix từ DEFAULT GATEWAY
    IP6=$(/usr/sbin/ip -6 route show default | awk '{print $3}' | cut -f1-4 -d':')
    
    # Lấy IPv4
    IP4=$(curl -4 -s --max-time 5 icanhazip.com 2>/dev/null)
    if [ -z "$IP4" ]; then
        IP4=$(/usr/sbin/ip -4 addr show eth0 | grep inet | awk '{print $2}' | cut -d'/' -f1)
    fi
    
    if [ -z "$IP6" ] || [ -z "$IP4" ]; then
        echo "[$(date)] ERROR: Cannot get IP. IP6='$IP6', IP4='$IP4'"
        return 1
    fi
    
    echo "[$(date)] Using IPv6 prefix: $IP6"
    echo "[$(date)] Using IPv4: $IP4"
    
    # Hàm generate IPv6
    array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
    gen64() {
        ip64() {
            echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
        }
        echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
    }
    
    # Tạo data.txt mới
    echo "[$(date)] Generating new proxy data..."
    > ${WORKDATA}.new
    for port in $(seq $FIRST_PORT $LAST_PORT); do
        echo "AnhVip17102/AnhVip17102/$IP4/$port/$(gen64 $IP6)" >> ${WORKDATA}.new
    done
    
    # Tạo script add IPv6
    awk -F "/" '{print "/usr/sbin/ip -6 addr add " $5 "/64 dev eth0"}' ${WORKDATA}.new > ${WORKDIR}/boot_ifconfig.sh.new
    chmod +x ${WORKDIR}/boot_ifconfig.sh.new
    
    # Apply IPv6 addresses mới
    echo "[$(date)] Adding 50 new IPv6 addresses..."
    bash ${WORKDIR}/boot_ifconfig.sh.new 2>&1 | grep -v "File exists"
    
    sleep 2
    
    # Verify số lượng IPv6
    IPV6_COUNT=$(/usr/sbin/ip -6 addr show dev eth0 | grep -E 'inet6 2403' | wc -l)
    echo "[$(date)] IPv6 count: $IPV6_COUNT/50"
    
    # Regenerate 3proxy config
    echo "[$(date)] Regenerating 3proxy config..."
    cat > /usr/local/etc/3proxy/3proxy.cfg.new <<EOFCONFIG
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

$(awk -F "/" '{print "auth strong\nallow " $1 "\nproxy -6 -n -a -p" $4 " -i" $3 " -e"$5"\nflush\n"}' ${WORKDATA}.new)
EOFCONFIG
    
    mv ${WORKDATA}.new ${WORKDATA}
    mv ${WORKDIR}/boot_ifconfig.sh.new ${WORKDIR}/boot_ifconfig.sh
    mv /usr/local/etc/3proxy/3proxy.cfg.new /usr/local/etc/3proxy/3proxy.cfg
    
    awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2 }' ${WORKDATA} > ${WORKDIR}/proxy.txt
    
    # Restart 3proxy
    echo "[$(date)] Restarting 3proxy..."
    pkill -9 3proxy 2>/dev/null
    sleep 2
    ulimit -n 10048
    /usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
    
    sleep 2
    
    if pgrep 3proxy > /dev/null; then
        echo "[$(date)] ✓ SUCCESS! Rotation completed"
        echo "[$(date)] ✓ 3proxy running"
        echo "[$(date)] ✓ IPv6: $IPV6_COUNT addresses"
    else
        echo "[$(date)] ✗ ERROR: 3proxy not running!"
        return 1
    fi
}

rotate_ipv6
EOFSCRIPT

chmod +x /home/bkns/rotate_ip.sh
