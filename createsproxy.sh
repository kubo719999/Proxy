#!/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c5
    echo
}

array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
    ip64() {
        echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }
    echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

install_3proxy() {
    echo "installing 3proxy"
    URL="https://github.com/z3APA3A/3proxy/archive/refs/tags/0.8.13.tar.gz"
    wget -qO- $URL | tar -xzf-
    cd 3proxy-0.8.13
    make -f Makefile.Linux
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp src/3proxy /usr/local/etc/3proxy/bin/
    cd $WORKDIR
}

gen_3proxy() {
    cat <<EOF
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

users $(awk -F "/" 'BEGIN{ORS="";} {print $1 ":CL:" $2 " "}' ${WORKDATA})

$(awk -F "/" '{print "auth strong\n" \
"allow " $1 "\n" \
"proxy -6 -n -a -p" $4 " -i" $3 " -e"$5"\n" \
"flush\n"}' ${WORKDATA})
EOF
}

gen_proxy_file_for_user() {
    cat >proxy.txt <<EOF
$(awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2 }' ${WORKDATA})
EOF
}

gen_data() {
    seq $FIRST_PORT $LAST_PORT | while read port; do
        echo "AnhVip17102/AnhVip17102/$IP4/$port/$(gen64 $IP6)"
    done
}

gen_ifconfig() {
    cat <<EOF
$(awk -F "/" '{print "ip -6 addr add " $5 "/64 dev eth0"}' ${WORKDATA})
EOF
}

# Script rotating IP mỗi 10 phút với xóa IPv6 cũ
gen_rotate_script() {
    cat >$WORKDIR/rotate_ip.sh <<'EOFROTATE'
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
WORKDIR="/home/bkns"
WORKDATA="${WORKDIR}/data.txt"
FIRST_PORT=22000
LAST_PORT=22099

rotate_ipv6() {
    echo "[$(date)] Starting IP rotation..."
    
    # Xóa tất cả IPv6 cũ trên interface eth0 (chỉ global, không xóa link-local)
    echo "[$(date)] Removing old IPv6 addresses..."
    for addr in $(ip -6 addr show dev eth0 | grep 'inet6 2' | grep -v fe80 | awk '{print $2}'); do
        ip -6 addr del $addr dev eth0 2>/dev/null
    done
    
    # Chờ network ổn định
    sleep 1
    
    # Lấy IPv6 prefix từ DEFAULT GATEWAY
    IP6=$(ip -6 route show default | awk '{print $3}' | cut -f1-4 -d':')
    
    # Lấy IPv4
    IP4=$(curl -4 -s --max-time 5 icanhazip.com 2>/dev/null)
    if [ -z "$IP4" ]; then
        IP4=$(ip -4 addr show eth0 | grep inet | awk '{print $2}' | cut -d'/' -f1)
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
    
    # Tạo data.txt mới với 100 port
    echo "[$(date)] Generating new proxy data..."
    > ${WORKDATA}.new
    for port in $(seq $FIRST_PORT $LAST_PORT); do
        echo "AnhVip17102/AnhVip17102/$IP4/$port/$(gen64 $IP6)" >> ${WORKDATA}.new
    done
    
    # Tạo script add IPv6 mới
    awk -F "/" '{print "ip -6 addr add " $5 "/64 dev eth0 2>/dev/null"}' ${WORKDATA}.new > ${WORKDIR}/boot_ifconfig.sh.new
    chmod +x ${WORKDIR}/boot_ifconfig.sh.new
    
    # Apply IPv6 addresses mới
    echo "[$(date)] Adding 100 new IPv6 addresses..."
    bash ${WORKDIR}/boot_ifconfig.sh.new 2>&1 | grep -v "File exists"
    
    # Chờ network ổn định
    sleep 2
    
    # Verify số lượng IPv6 đã add
    IPV6_COUNT=$(ip -6 addr show dev eth0 | grep 'inet6 2' | grep -v fe80 | wc -l)
    echo "[$(date)] IPv6 addresses added: $IPV6_COUNT/100"
    
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
    OLD_PID=$(pgrep -f "3proxy /usr/local/etc/3proxy/3proxy.cfg" | head -1)
    
    # Start 3proxy mới
    ulimit -n 10048
    /usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
    NEW_PID=$!
    
    # Chờ 3proxy mới start xong
    sleep 3
    
    # Kill process cũ nếu còn tồn tại và khác PID mới
    if [ ! -z "$OLD_PID" ] && [ "$OLD_PID" != "$NEW_PID" ]; then
        kill -9 $OLD_PID 2>/dev/null
    fi
    
    # Verify 3proxy đang chạy
    if pgrep -f "3proxy /usr/local/etc/3proxy/3proxy.cfg" > /dev/null; then
        PROXY_COUNT=$(netstat -tunlp 2>/dev/null | grep 3proxy | wc -l)
        echo "[$(date)] ✓ IPv6 rotation completed successfully!"
        echo "[$(date)] ✓ 3proxy is running (PID: $(pgrep -f '3proxy /usr/local/etc/3proxy/3proxy.cfg' | head -1))"
        echo "[$(date)] ✓ Active proxy ports: $PROXY_COUNT"
        echo "[$(date)] ✓ Port range: $FIRST_PORT-$LAST_PORT"
        echo "[$(date)] ✓ IPv6 addresses: $IPV6_COUNT"
    else
        echo "[$(date)] ✗ ERROR: 3proxy failed to start!"
        return 1
    fi
}

rotate_ipv6
EOFROTATE
    chmod +x $WORKDIR/rotate_ip.sh
}

# Tạo cron job cho rotating mỗi 10 phút
setup_rotation() {
    # Xóa cron job cũ nếu có
    crontab -l 2>/dev/null | grep -v "rotate_ip.sh" | crontab -
    
    # Thêm cron job chạy mỗi 10 phút
    (crontab -l 2>/dev/null; echo "*/10 * * * * /home/bkns/rotate_ip.sh >> /home/bkns/rotation.log 2>&1") | crontab -
    echo "✓ IP rotation scheduled every 10 minutes"
}

echo "installing apps"
yum install -y gcc net-tools curl wget >/dev/null

install_3proxy

echo "working folder = /home/bkns"
WORKDIR="/home/bkns"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p $WORKDIR && cd $WORKDIR

IP4=$(curl -4 -s icanhazip.com)
IP6=$(ip -6 route show default 2>/dev/null | awk '{print $3}' | cut -f1-4 -d':')

# Fallback nếu không lấy được IP6 từ gateway
if [ -z "$IP6" ]; then
    IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')
fi

echo "Internal IP = ${IP4}. External sub for IP6 = ${IP6}"

# 100 port: từ 22000 đến 22099
FIRST_PORT=22000
LAST_PORT=22099

gen_data >$WORKDIR/data.txt
gen_ifconfig >$WORKDIR/boot_ifconfig.sh
chmod +x boot_*.sh

gen_3proxy >/usr/local/etc/3proxy/3proxy.cfg

cat >>/etc/rc.d/rc.local <<EOF
bash ${WORKDIR}/boot_ifconfig.sh
ulimit -n 10048
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
EOF

chmod +x /etc/rc.d/rc.local
systemctl enable rc-local 2>/dev/null
systemctl start rc-local 2>/dev/null

bash /etc/rc.local

gen_proxy_file_for_user

# Tạo script và setup rotation
gen_rotate_script
setup_rotation

rm -rf /root/setup.sh
rm -rf /root/3proxy-3proxy-0.8.6
rm -rf 3proxy-0.8.13

echo ""
echo "=========================================="
echo "✓ Proxy Setup Completed!"
echo "=========================================="
echo "Total Proxies: 100"
echo "Port Range: 22000-22099"
echo "Username: AnhVip17102"
echo "Password: AnhVip17102"
echo "IP Rotation: Every 10 minutes"
echo "Proxy List: /home/bkns/proxy.txt"
echo "Rotation Log: /home/bkns/rotation.log"
echo "=========================================="
echo ""
echo "Monitor rotation: tail -f /home/bkns/rotation.log"
echo ""
