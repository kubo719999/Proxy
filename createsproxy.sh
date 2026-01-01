#!/bin/bash
WORKDIR="/home/bkns"
WORKDATA="${WORKDIR}/data.txt"
FIRST_PORT=22000
LAST_PORT=22049

rotate_ipv6() {
    echo "[$(date)] Starting IP rotation..."
    
    # Lưu danh sách IPv6 cũ từ data.txt
    OLD_IPV6=$(awk -F "/" '{print $5}' ${WORKDATA})
    
    # Xóa tất cả IPv6 cũ trên interface eth0
    echo "[$(date)] Removing old IPv6 addresses..."
    for ipv6 in $OLD_IPV6; do
        ip -6 addr del ${ipv6}/64 dev eth0 2>/dev/null
    done
    
    # Flush tất cả IPv6 addresses trên eth0 (trừ link-local)
    for addr in $(ip -6 addr show dev eth0 | grep 'inet6 2' | awk '{print $2}'); do
        ip -6 addr del $addr dev eth0 2>/dev/null
    done
    
    # Chờ một chút để hệ thống ổn định
    sleep 2
    
    # Lấy IPv6 prefix từ routing (không cần curl)
    IP6=$(ip -6 route show | grep 'proto kernel' | head -1 | awk '{print $1}' | cut -f1-4 -d':')
    
    # Lấy IPv4
    IP4=$(curl -4 -s icanhazip.com 2>/dev/null)
    if [ -z "$IP4" ]; then
        IP4=$(ip -4 addr show eth0 | grep inet | awk '{print $2}' | cut -d'/' -f1)
    fi
    
    if [ -z "$IP6" ] || [ -z "$IP4" ]; then
        echo "[$(date)] ERROR: Cannot get IP addresses. IP6=$IP6, IP4=$IP4"
        return 1
    fi
    
    echo "[$(date)] IPv6 prefix: $IP6, IPv4: $IP4"
    
    # Hàm generate IPv6
    array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
    gen64() {
        ip64() {
            echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
        }
        echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
    }
    
    # Tạo data.txt mới với 50 port
    echo "[$(date)] Generating new proxy data..."
    > ${WORKDATA}.new
    for port in $(seq $FIRST_PORT $LAST_PORT); do
        echo "AnhVip17102/AnhVip17102/$IP4/$port/$(gen64 $IP6)" >> ${WORKDATA}.new
    done
    
    # Tạo script ifconfig mới
    awk -F "/" '{print "ip -6 addr add " $5 "/64 dev eth0"}' ${WORKDATA}.new > ${WORKDIR}/boot_ifconfig.sh.new
    chmod +x ${WORKDIR}/boot_ifconfig.sh.new
    
    # Apply IPv6 addresses mới
    echo "[$(date)] Adding new IPv6 addresses..."
    bash ${WORKDIR}/boot_ifconfig.sh.new
    
    # Chờ network ổn định
    sleep 2
    
    # Verify số lượng IPv6 đã add
    IPV6_COUNT=$(ip -6 addr show dev eth0 | grep 'inet6 2' | wc -l)
    echo "[$(date)] Added $IPV6_COUNT IPv6 addresses"
    
    # Regenerate 3proxy config với data mới
    echo "[$(date)] Regenerating 3proxy config..."
    cat > /usr/local/etc/3proxy/3proxy.cfg.new <<EOFCONFIG
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

users $(awk -F "/" 'BEGIN{ORS="";} {print $1 ":CL:" $2 " "}' ${WORKDATA}.new)

$(awk -F "/" '{print "auth strong\n" \
"allow " $1 "\n" \
"proxy -6 -n -a -p" $4 " -i" $3 " -e"$5"\n" \
"flush\n"}' ${WORKDATA}.new)
EOFCONFIG
    
    # Di chuyển file mới thành file chính
    mv ${WORKDATA}.new ${WORKDATA}
    mv ${WORKDIR}/boot_ifconfig.sh.new ${WORKDIR}/boot_ifconfig.sh
    mv /usr/local/etc/3proxy/3proxy.cfg.new /usr/local/etc/3proxy/3proxy.cfg
    
    # Regenerate proxy.txt cho user
    awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2 }' ${WORKDATA} > ${WORKDIR}/proxy.txt
    
    # Restart 3proxy an toàn
    echo "[$(date)] Restarting 3proxy..."
    OLD_PID=$(pgrep -f "3proxy /usr/local/etc/3proxy/3proxy.cfg")
    
    # Start 3proxy mới
    ulimit -n 10048
    /usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
    
    # Chờ 3proxy mới start xong
    sleep 3
    
    # Kill process cũ nếu còn tồn tại
    if [ ! -z "$OLD_PID" ]; then
        kill -9 $OLD_PID 2>/dev/null
    fi
    
    # Verify 3proxy đang chạy
    if pgrep -f "3proxy /usr/local/etc/3proxy/3proxy.cfg" > /dev/null; then
        echo "[$(date)] IPv6 rotation completed successfully. 3proxy is running."
        echo "[$(date)] Active proxies: 50 (ports $FIRST_PORT-$LAST_PORT)"
        echo "[$(date)] IPv6 addresses: $IPV6_COUNT"
    else
        echo "[$(date)] ERROR: 3proxy failed to start!"
        return 1
    fi
}

rotate_ipv6
