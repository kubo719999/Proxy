#!/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

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

$(awk -F "/" '{print "proxy -6 -n -a -p" $3 " -i" $2 " -e"$4"\n" \
"flush\n"}' ${WORKDATA})
EOF
}

gen_proxy_file_for_user() {
    cat >proxy.txt <<EOF
$(awk -F "/" '{print $2 ":" $3}' ${WORKDATA})
EOF
}

gen_data() {
    seq $FIRST_PORT $LAST_PORT | while read port; do
        echo "noauth/$IP4/$port/$(gen64 $IP6)"
    done
}

gen_ifconfig() {
    cat <<EOF
$(awk -F "/" '{print "ifconfig eth0 inet6 add " $4 "/64"}' ${WORKDATA})
EOF
}

echo "installing apps"

install_3proxy

echo "working folder = /home/bkns"
WORKDIR="/home/bkns"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p $WORKDIR && cd $WORKDIR

IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')

echo "Internal IP = ${IP4}. External sub for IP6 = ${IP6}"

# Random port range trong IANA Dynamic/Private range (49152-64535)
# Đảm bảo có đủ 1000 ports liên tục
MAX_START_PORT=63536  # 64535 - 999 = 63536
RANDOM_START=$((RANDOM % (MAX_START_PORT - 49152 + 1) + 49152))
FIRST_PORT=$RANDOM_START
LAST_PORT=$((FIRST_PORT + 999))

echo "========================================"
echo "Random Port Range Selected"
echo "========================================"

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

# Lưu port range để sau này còn biết
echo "$FIRST_PORT-$LAST_PORT" > $WORKDIR/port_range.txt

rm -rf /root/setup.sh
rm -rf /root/3proxy-3proxy-0.8.6

echo "========================================"
echo "✅ Proxy Setup Complete!"
echo "========================================"
echo "Mode: No Authentication"
echo "Port range: $FIRST_PORT-$LAST_PORT (1000 ports)"
echo "Scan probability: ~2-5% (Random Dynamic range)"
echo "Proxy list: ${WORKDIR}/proxy.txt"
echo "Port range saved: ${WORKDIR}/port_range.txt"
echo "========================================"
echo ""
echo "Example proxy format in proxy.txt:"
echo "$IP4:$FIRST_PORT"
echo "$IP4:$((FIRST_PORT + 1))"
echo "..."
echo "========================================"
