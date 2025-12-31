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
        echo "user$port/$(random)/$IP4/$port/$(gen64 $IP6)"
    done
}

gen_ifconfig() {
    cat <<EOF
$(awk -F "/" '{print "ifconfig eth0 inet6 add " $5 "/64"}' ${WORKDATA})
EOF
}

create_rotate_script() {
    cat > /home/bkns/rotate_ipv6.sh << 'ROTEOF'
#!/bin/bash
WORKDIR="/home/bkns"
WORKDATA="${WORKDIR}/data.txt"

array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
    ip64() {
        echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }
    echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')

echo "[$(date)] Starting IPv6 rotation..."

# Remove old IPv6 addresses
ip -6 addr show eth0 | grep "inet6" | grep -v "fe80" | grep -v "::1" | awk '{print $2}' | while read addr; do
    ip -6 addr del $addr dev eth0 2>/dev/null
done

# Generate new data with rotated IPv6
awk -v ip6="$IP6" -F "/" '{
    # Keep username, password, IP4, and port
    # Generate new random IPv6
    cmd = "array=(1 2 3 4 5 6 7 8 9 0 a b c d e f); echo \"" ip6 ":${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}:${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}:${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}:${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}\"";
    cmd | getline newipv6;
    close(cmd);
    print $1 "/" $2 "/" $3 "/" $4 "/" newipv6;
}' $WORKDATA > ${WORKDATA}.tmp && mv ${WORKDATA}.tmp $WORKDATA

# Apply new IPv6 addresses
awk -F "/" '{system("ip -6 addr add " $5 "/64 dev eth0")}' ${WORKDATA}

# Regenerate 3proxy config
gen_3proxy_rotate() {
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

users $(awk -F "/" 'BEGIN{ORS="";} {print $1 ":CL:" $2 " "}' ${WORKDATA})

$(awk -F "/" '{print "auth strong\n" \
"allow " $1 "\n" \
"proxy -6 -n -a -p" $4 " -i" $3 " -e"$5"\n" \
"flush\n"}' ${WORKDATA})
EOF
}

gen_3proxy_rotate > /usr/local/etc/3proxy/3proxy.cfg

# Restart 3proxy
killall 3proxy 2>/dev/null
sleep 2
ulimit -n 10048
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &

echo "[$(date)] IPv6 rotated successfully - Total IPs: $(wc -l < $WORKDATA)"
ROTEOF

    chmod +x /home/bkns/rotate_ipv6.sh
}

setup_cron_rotation() {
    echo "Setting up auto-rotation every 10 minutes..."
    
    # Remove existing cron job if any
    crontab -l 2>/dev/null | grep -v "rotate_ipv6.sh" | crontab -
    
    # Add new cron job
    (crontab -l 2>/dev/null; echo "*/10 * * * * /home/bkns/rotate_ipv6.sh >> /home/bkns/rotate.log 2>&1") | crontab -
    
    echo "Cron job added: IPv6 will rotate every 10 minutes"
    echo "Log file: /home/bkns/rotate.log"
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

FIRST_PORT=22000
LAST_PORT=22400

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

# Create rotation script
create_rotate_script

# Setup cron for auto-rotation
setup_cron_rotation

rm -rf /root/setup.sh
rm -rf /root/3proxy-3proxy-0.8.6

echo "========================================"
echo "Proxy setup completed!"
echo "Total proxies: $((LAST_PORT - FIRST_PORT + 1))"
echo "Port range: $FIRST_PORT - $LAST_PORT"
echo "Proxy list: $WORKDIR/proxy.txt"
echo "Auto-rotation: Every 10 minutes"
echo "Rotation log: /home/bkns/rotate.log"
echo "========================================"
echo "Starting Proxy"
