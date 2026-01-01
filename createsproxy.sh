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
$(awk -F "/" '{print "ifconfig eth0 inet6 add " $5 "/64"}' ${WORKDATA})
EOF
}

# Script rotating IP mỗi 10 phút với xóa IPv6 cũ
gen_rotate_script() {
    cat >$WORKDIR/rotate_ip.sh <<'EOF'
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
        ifconfig eth0 inet6 del ${ipv6}/64 2>/dev/null
    done
    
    # Flush tất cả IPv6 addresses trên eth0 để đảm bảo
    ip -6 addr flush dev eth0 scope global 2>/dev/null
    
    # Chờ một chút để hệ thống ổn định
    sleep 2
    
    # Lấy IPv6 prefix mới
    IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')
    IP4=$(curl -4 -s icanhazip.com)
    
    if [ -z "$IP6" ] || [ -z "$IP4" ]; then
        echo "[$(date)] ERROR: Cannot get IP addresses. Skipping rotation."
        return 1
    fi
    
    echo "[$(date)] New IPv6 prefix: $IP6, IPv4: $IP4"
    
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
    awk -F "/" '{print "ifconfig eth0 inet6 add " $5 "/64"}' ${WORKDATA}.new > ${WORKDIR}/boot_ifconfig.sh.new
    chmod +x ${WORKDIR}/boot_ifconfig.sh.new
    
    # Apply IPv6 addresses mới
    echo "[$(date)] Adding new IPv6 addresses..."
    bash ${WORKDIR}/boot_ifconfig.sh.new
    
    # Chờ network ổn định
    sleep 2
    
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
    /usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
    
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
    else
        echo "[$(date)] ERROR: 3proxy failed to start!"
        return 1
    fi
}

rotate_ipv6
EOF
    chmod +x $WORKDIR/rotate_ip.sh
}

# Tạo cron job cho rotating
setup_rotation() {
    # Xóa cron job cũ nếu có
    crontab -l 2>/dev/null | grep -v "rotate_ip.sh" | crontab -
    
    # Thêm cron job chạy mỗi 10 phút
    (crontab -l 2>/dev/null; echo "*/10 * * * * /home/bkns/rotate_ip.sh >> /home/bkns/rotation.log 2>&1") | crontab -
    echo "IP rotation scheduled every 10 minutes"
}

echo "installing apps"
yum install -y gcc net-tools curl wget >/dev/null

install_3proxy

echo "working folder = /home/bkns"
WORKDIR="/home/bkns"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p $WORKDIR && cd $WORKDIR

IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')

echo "Internal IP = ${IP4}. External sub for IP6 = ${IP6}"

# Chỉ 50 port: từ 22000 đến 22049
FIRST_PORT=22000
LAST_PORT=22049

gen_data >$WORKDIR/data.txt
gen_ifconfig >$WORKDIR/boot_ifconfig.sh
chmod +x boot_*.sh /etc/rc.d/rc.local

gen_3proxy >/usr/local/etc/3proxy/3proxy.cfg

cat >>/etc/rc.d/rc.local <<EOF
bash ${WORKDIR}/boot_ifconfig.sh
ulimit -n 10048
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
EOF

chmod +x /etc/rc.d/rc.local
systemctl enable rc-local
systemctl start rc-local

bash /etc/rc.local

gen_proxy_file_for_user

# Tạo script và setup rotation
gen_rotate_script
setup_rotation

rm -rf /root/setup.sh
rm -rf /root/3proxy-3proxy-0.8.6

echo ""
echo "=========================================="
echo "Proxy Setup Completed!"
echo "=========================================="
echo "Total Proxies: 50"
echo "Port Range: 22000-22049"
echo "Username: AnhVip17102"
echo "Password: AnhVip17102"
echo "IP Rotation: Every 10 minutes"
echo "Proxy List: /home/bkns/proxy.txt"
echo "=========================================="
