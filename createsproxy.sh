#!/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

FIXED_USER="AnhVip17102"
FIXED_PASS="AnhVip17102"

array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
    ip64() {
        echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }
    echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

install_dependencies() {
    echo "Installing dependencies..."
    if command -v yum >/dev/null 2>&1; then
        yum install -y iproute wget gcc make >/dev/null 2>&1
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update >/dev/null 2>&1
        apt-get install -y iproute2 wget gcc make >/dev/null 2>&1
    fi
    echo "Done"
}

install_3proxy() {
    echo "Installing 3proxy..."
    cd /root
    wget -4 -q https://github.com/z3APA3A/3proxy/archive/refs/tags/0.8.13.tar.gz
    tar -xzf 0.8.13.tar.gz
    cd 3proxy-0.8.13
    make -f Makefile.Linux >/dev/null 2>&1
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp src/3proxy /usr/local/etc/3proxy/bin/
    cd /root
    rm -rf 3proxy-0.8.13 0.8.13.tar.gz
    echo "Done"
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
auth strong

users ${FIXED_USER}:CL:${FIXED_PASS}

$(awk -F "/" '{print "auth strong\n" \
"allow " ENVIRON["FIXED_USER"] "\n" \
"proxy -6 -n -a -p" $4 " -i" $3 " -e"$5"\n" \
"flush\n"}' ${WORKDATA})
EOF
}

gen_proxy_file_for_user() {
    cat >proxy.txt <<EOF
$(awk -v user="$FIXED_USER" -v pass="$FIXED_PASS" -F "/" '{print $3 ":" $4 ":" user ":" pass}' ${WORKDATA})
EOF
}

gen_data() {
    seq $FIRST_PORT $LAST_PORT | while read port; do
        echo "${FIXED_USER}/${FIXED_PASS}/$IP4/$port/$(gen64 $IP6)"
    done
}

gen_ifconfig() {
    cat <<EOF
$(awk -F "/" '{print "ip -6 addr add " $5 "/64 dev eth0 2>/dev/null"}' ${WORKDATA})
EOF
}

create_rotate_script() {
    cat > /home/bkns/rotate_ipv6.sh << 'ROTEOF'
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
WORKDIR="/home/bkns"
WORKDATA="${WORKDIR}/data.txt"
LOGFILE="${WORKDIR}/rotate.log"

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> $LOGFILE
}

if [ -f "$LOGFILE" ]; then
    LOG_SIZE=$(du -m "$LOGFILE" 2>/dev/null | cut -f1)
    [ "$LOG_SIZE" -gt 10 ] && tail -n 1000 "$LOGFILE" > "${LOGFILE}.tmp" && mv "${LOGFILE}.tmp" "$LOGFILE"
fi

log_msg "Starting rotation"

IP6=$(head -1 $WORKDATA | cut -d'/' -f5 | cut -f1-4 -d':')
[ -z "$IP6" ] && exit 1

cp $WORKDATA ${WORKDATA}.backup

awk -v ip6="$IP6" -F "/" '
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
    
    print $1 "/" $2 "/" $3 "/" $4 "/" new_ip6;
}' $WORKDATA > ${WORKDATA}.new

[ ! -s ${WORKDATA}.new ] && exit 1
mv ${WORKDATA}.new $WORKDATA

awk -F "/" '{system("ip -6 addr add " $5 "/64 dev eth0 2>/dev/null")}' ${WORKDATA}

sleep 2

cat > /usr/local/etc/3proxy/3proxy.cfg << 'EOFCFG'
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
users AnhVip17102:CL:AnhVip17102

EOFCFG

awk -F "/" '{
    print "auth strong";
    print "allow AnhVip17102";
    print "proxy -6 -n -a -p" $4 " -i" $3 " -e" $5;
    print "flush";
}' ${WORKDATA} >> /usr/local/etc/3proxy/3proxy.cfg

pkill -9 3proxy 2>/dev/null
sleep 2
ulimit -n 65536
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &

log_msg "Completed"
ROTEOF

    chmod +x /home/bkns/rotate_ipv6.sh
}

create_monitor_script() {
    cat > /home/bkns/monitor.sh << 'EOF'
#!/bin/bash
if ! pgrep 3proxy > /dev/null; then
    pkill -9 3proxy 2>/dev/null
    sleep 2
    ulimit -n 65536
    /usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
fi
EOF
    chmod +x /home/bkns/monitor.sh
}

setup_cron() {
    crontab -r 2>/dev/null
    (
        echo "*/10 * * * * /home/bkns/rotate_ipv6.sh"
        echo "*/3 * * * * /home/bkns/monitor.sh"
    ) | crontab -
}

echo "Installing..."

install_dependencies
install_3proxy

WORKDIR="/home/bkns"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p $WORKDIR && cd $WORKDIR

IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com 2>/dev/null | cut -f1-4 -d':')

[ -z "$IP4" ] && echo "No IPv4" && exit 1
[ -z "$IP6" ] && IP6=$(ip -6 addr show | grep "inet6" | grep -v "fe80" | head -1 | awk '{print $2}' | cut -f1-4 -d':')
[ -z "$IP6" ] && echo "No IPv6" && exit 1

FIRST_PORT=10000
LAST_PORT=10099

gen_data > $WORKDIR/data.txt

gen_ifconfig > $WORKDIR/boot_ifconfig.sh
chmod +x $WORKDIR/boot_ifconfig.sh
bash $WORKDIR/boot_ifconfig.sh

export FIXED_USER FIXED_PASS
gen_3proxy > /usr/local/etc/3proxy/3proxy.cfg

cat > /etc/rc.d/rc.local <<EOF
#!/bin/bash
bash ${WORKDIR}/boot_ifconfig.sh
ulimit -n 65536
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
EOF

chmod +x /etc/rc.d/rc.local

pkill -9 3proxy 2>/dev/null
sleep 2
ulimit -n 65536
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
sleep 3

create_rotate_script
create_monitor_script
setup_cron
gen_proxy_file_for_user

rm -rf /root/3proxy-* 2>/dev/null

echo ""
echo "DONE"
echo "Ports: 100 (10000-10099)"
echo "User/Pass: ${FIXED_USER}"
echo "IPv4: ${IP4}"
echo "IPv6: ${IP6}"
echo "Rotation: 10 minutes"
echo "Pool: 100 IPs"
echo ""
echo "List: /home/bkns/proxy.txt"
echo ""
