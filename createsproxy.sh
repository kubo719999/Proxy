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
        yum install -y iproute vim-common wget gcc make net-tools >/dev/null 2>&1
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update >/dev/null 2>&1
        apt-get install -y iproute2 vim-common wget gcc make net-tools >/dev/null 2>&1
    fi
    echo "Dependencies installed"
}

install_3proxy() {
    echo "Installing 3proxy..."
    URL="https://github.com/z3APA3A/3proxy/archive/refs/tags/0.8.13.tar.gz"
    wget -4 -qO- $URL | tar -xzf-
    cd 3proxy-0.8.13
    make -f Makefile.Linux
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp src/3proxy /usr/local/etc/3proxy/bin/
    cd $WORKDIR
    echo "3proxy installed"
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

cp $WORKDATA ${WORKDATA}.backup

# Generate new IPs
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

# Save keep list
awk -F "/" '{print $5}' ${WORKDATA}.new > /tmp/keep_rotation_$$.txt
KEEP_COUNT=$(wc -l < /tmp/keep_rotation_$$.txt)
log_msg "Will keep $KEEP_COUNT IPs"

# Update data
mv ${WORKDATA}.new $WORKDATA

# Add new IPs
log_msg "Adding new IPs..."
awk -F "/" '{system("ip -6 addr add " $5 "/64 dev eth0 2>/dev/null")}' ${WORKDATA}

sleep 2

# Generate config
cat > /usr/local/etc/3proxy/3proxy.cfg.new << 'EOFCFG'
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
EOFCFG

echo "users ${FIXED_USER}:CL:${FIXED_PASS}" >> /usr/local/etc/3proxy/3proxy.cfg.new

awk -v user="$FIXED_USER" -F "/" '{
    print "auth strong";
    print "allow " user;
    print "proxy -6 -n -a -p" $4 " -i" $3 " -e" $5;
    print "flush";
}' ${WORKDATA} >> /usr/local/etc/3proxy/3proxy.cfg.new

mv /usr/local/etc/3proxy/3proxy.cfg.new /usr/local/etc/3proxy/3proxy.cfg

# Reload
log_msg "Reloading 3proxy..."
OLD_PID=$(pgrep 3proxy)

if [ -n "$OLD_PID" ]; then
    kill -HUP $OLD_PID 2>/dev/null
    sleep 5
    
    if ! pgrep 3proxy > /dev/null; then
        log_msg "HUP failed, restarting..."
        pkill -9 3proxy 2>/dev/null
        sleep 2
        ulimit -n 65536
        /usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
        sleep 3
    fi
else
    log_msg "Starting 3proxy..."
    ulimit -n 65536
    /usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
    sleep 3
fi

NEW_PID=$(pgrep 3proxy)
[ -z "$NEW_PID" ] && log_msg "ERROR: 3proxy failed" && exit 1
log_msg "3proxy running (PID: $NEW_PID)"

# Wait for reload to complete
sleep 5

# Cleanup
log_msg "Starting cleanup..."
BEFORE=$(ip -6 addr show eth0 | grep -c 'inet6.*scope global')

# Get all IPs
ip -6 addr show eth0 | grep 'inet6.*scope global' | awk '{print $2}' | cut -d'/' -f1 > /tmp/all_ips_$$.txt

DELETED=0
while IFS= read -r ip; do
    if ! grep -Fxq "$ip" /tmp/keep_rotation_$$.txt; then
        if ip -6 addr del ${ip}/64 dev eth0 2>/dev/null; then
            DELETED=$((DELETED + 1))
        fi
    fi
done < /tmp/all_ips_$$.txt

AFTER=$(ip -6 addr show eth0 | grep -c 'inet6.*scope global')

log_msg "Cleanup: Before=$BEFORE After=$AFTER Deleted=$DELETED Target=$KEEP_COUNT"

rm -f /tmp/keep_rotation_$$.txt /tmp/all_ips_$$.txt

# Verify
PROXY_COUNT=$(wc -l < $WORKDATA)

if [ "$AFTER" -ne "$PROXY_COUNT" ]; then
    log_msg "MISMATCH: Proxies=$PROXY_COUNT IPs=$AFTER - Fixing..."
    awk -F "/" '{system("ip -6 addr add " $5 "/64 dev eth0 2>/dev/null")}' ${WORKDATA}
    AFTER=$(ip -6 addr show eth0 | grep -c 'inet6.*scope global')
    log_msg "After fix: $AFTER IPs"
fi

log_msg "========== Done: Proxies=$PROXY_COUNT IPs=$AFTER PID=$NEW_PID =========="
ROTEOF

    chmod +x /home/bkns/rotate_ipv6.sh
}

create_emergency_cleanup_script() {
    cat > /home/bkns/emergency_cleanup.sh << 'EMERGEOF'
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

LOGFILE="/home/bkns/emergency_cleanup.log"
CURRENT_IPS="/home/bkns/data.txt"

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $LOGFILE
}

log_msg "========== EMERGENCY CLEANUP =========="

[ ! -f "$CURRENT_IPS" ] && log_msg "ERROR: data.txt not found" && exit 1

awk -F "/" '{print $5}' $CURRENT_IPS > /tmp/keep_current.txt

BEFORE=$(ip -6 addr show eth0 | grep -c 'inet6.*scope global')
log_msg "IPv6 count: $BEFORE"

if [ "$BEFORE" -lt 100 ]; then
    log_msg "IP count normal"
    rm -f /tmp/keep_current.txt
    exit 0
fi

log_msg "WARNING: $BEFORE IPs - starting cleanup"

ip -6 addr show eth0 | grep 'inet6.*scope global' | awk '{print $2}' | cut -d'/' -f1 > /tmp/all_current.txt

DELETED=0
while IFS= read -r ip; do
    if ! grep -Fxq "$ip" /tmp/keep_current.txt; then
        ip -6 addr del ${ip}/64 dev eth0 2>/dev/null && DELETED=$((DELETED + 1))
    fi
done < /tmp/all_current.txt

rm -f /tmp/keep_current.txt /tmp/all_current.txt

AFTER=$(ip -6 addr show eth0 | grep -c 'inet6.*scope global')

log_msg "Done: Before=$BEFORE After=$AFTER Deleted=$DELETED"

if ! pgrep 3proxy > /dev/null; then
    log_msg "3proxy not running, restarting..."
    ulimit -n 65536
    /usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
    sleep 3
    log_msg "3proxy restarted (PID: $(pgrep 3proxy))"
fi
EMERGEOF

    chmod +x /home/bkns/emergency_cleanup.sh
}

create_monitor_script() {
    cat > /home/bkns/monitor.sh << 'EOF'
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

if [ -f /home/bkns/monitor.log ]; then
    LOG_SIZE=$(du -m /home/bkns/monitor.log 2>/dev/null | cut -f1)
    [ "$LOG_SIZE" -gt 5 ] && tail -n 500 /home/bkns/monitor.log > /home/bkns/monitor.log.tmp && mv /home/bkns/monitor.log.tmp /home/bkns/monitor.log
fi

if ! pgrep 3proxy > /dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 3proxy died, restarting..." >> /home/bkns/monitor.log
    pkill -9 3proxy 2>/dev/null
    sleep 2
    ulimit -n 65536
    /usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
    sleep 3
    [ -n "$(pgrep 3proxy)" ] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] Restarted (PID: $(pgrep 3proxy))" >> /home/bkns/monitor.log
fi

IP_COUNT=$(ip -6 addr show eth0 | grep -c 'inet6.*scope global' 2>/dev/null)
if [ "$IP_COUNT" -gt 100 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Too many IPs ($IP_COUNT), cleanup" >> /home/bkns/monitor.log
    /home/bkns/emergency_cleanup.sh >> /home/bkns/monitor.log 2>&1
fi
EOF
    chmod +x /home/bkns/monitor.sh
}

create_log_cleanup_script() {
    cat > /home/bkns/cleanup_logs.sh << 'EOF'
#!/bin/bash

for log in /home/bkns/*.log; do
    [ -f "$log" ] || continue
    SIZE=$(du -m "$log" 2>/dev/null | cut -f1)
    [ "$SIZE" -gt 10 ] && tail -n 1000 "$log" > "${log}.tmp" && mv "${log}.tmp" "$log"
done

[ -d /usr/local/etc/3proxy/logs ] && find /usr/local/etc/3proxy/logs -type f -mtime +7 -delete 2>/dev/null
EOF
    chmod +x /home/bkns/cleanup_logs.sh
}

setup_cron_rotation() {
    echo "Setting up cron jobs..."
    
    crontab -r 2>/dev/null
    
    (
        echo "*/10 * * * * /home/bkns/rotate_ipv6.sh >> /home/bkns/rotate.log 2>&1"
        echo "*/3 * * * * /home/bkns/monitor.sh"
        echo "0 3 * * * /home/bkns/cleanup_logs.sh"
        echo "0 */6 * * * /home/bkns/emergency_cleanup.sh >> /home/bkns/emergency_cleanup.log 2>&1"
    ) | crontab -
    
    echo "Cron configured"
}

echo "================================================================"
echo "  3PROXY - 50 PORTS (Optimized for Stability)                  "
echo "================================================================"

echo "[1/10] Installing dependencies..."
install_dependencies

echo "[2/10] Installing 3proxy..."
install_3proxy

echo "[3/10] Setting up directories..."
WORKDIR="/home/bkns"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p $WORKDIR && cd $WORKDIR

echo "[4/10] Detecting IPs..."
IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com 2>/dev/null | cut -f1-4 -d':')

[ -z "$IP4" ] && echo "No IPv4" && exit 1

if [ -z "$IP6" ]; then
    IP6=$(ip -6 addr show eth0 2>/dev/null | grep "inet6" | grep -v "fe80" | head -1 | awk '{print $2}' | cut -f1-4 -d':')
    [ -z "$IP6" ] && echo "No IPv6" && exit 1
fi

echo "   IPv4: ${IP4}"
echo "   IPv6: ${IP6}"

echo "[5/10] Generating 50 proxies..."
FIRST_PORT=10000
LAST_PORT=10049

gen_data > $WORKDIR/data.txt
echo "   Ports: 10000-10049"

echo "[6/10] Adding IPv6..."
gen_ifconfig > $WORKDIR/boot_ifconfig.sh
chmod +x $WORKDIR/boot_ifconfig.sh
bash $WORKDIR/boot_ifconfig.sh
echo "   Added 50 IPs"

echo "[7/10] Generating config..."
export FIXED_USER FIXED_PASS
gen_3proxy > /usr/local/etc/3proxy/3proxy.cfg
echo "   Config generated"

echo "[8/10] Setting up auto-start..."
cat > /etc/rc.d/rc.local <<EOF
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
bash ${WORKDIR}/boot_ifconfig.sh
ulimit -n 65536
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
EOF

chmod +x /etc/rc.d/rc.local
systemctl enable rc-local 2>/dev/null
echo "   Auto-start configured"

echo "[9/10] Starting 3proxy..."
pkill -9 3proxy 2>/dev/null
sleep 2
ulimit -n 65536
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
sleep 3

if pgrep 3proxy > /dev/null; then
    echo "   3proxy started (PID: $(pgrep 3proxy))"
else
    echo "   Startup issue"
fi

echo "[10/10] Setting up automation..."
create_rotate_script
create_emergency_cleanup_script
create_monitor_script
create_log_cleanup_script
setup_cron_rotation
gen_proxy_file_for_user

rm -rf /root/setup.sh /root/3proxy-* 3proxy-0.8.13 2>/dev/null

echo ""
echo "================================================================"
echo "INSTALLATION COMPLETED - 50 PORTS"
echo "================================================================"
echo ""
echo "Config:"
echo "   Ports: 50 (10000-10049)"
echo "   User: ${FIXED_USER}"
echo "   Pass: ${FIXED_PASS}"
echo "   IPv4: ${IP4}"
echo "   IPv6: ${IP6}"
echo ""
echo "Benefits of 50 ports:"
echo "   - 50% less resource usage"
echo "   - Faster rotation (less IPs to process)"
echo "   - More stable (less chance of errors)"
echo "   - Lower RAM (~200MB vs 400MB)"
echo ""
echo "Files:"
echo "   Proxy list: $WORKDIR/proxy.txt"
echo "   Rotation log: $WORKDIR/rotate.log"
echo ""
echo "Verify:"
echo "   echo \"Proxies: \$(wc -l < /home/bkns/data.txt) | IPs: \$(ip -6 addr show eth0 | grep -c 'inet6.*scope global')\""
echo ""
echo "Test:"
FIRST_PROXY=$(head -1 $WORKDIR/proxy.txt 2>/dev/null)
if [ -n "$FIRST_PROXY" ]; then
    PROXY_IP=$(echo $FIRST_PROXY | cut -d: -f1)
    PROXY_PORT=$(echo $FIRST_PROXY | cut -d: -f2)
    echo "   curl -x ${FIXED_USER}:${FIXED_PASS}@${PROXY_IP}:${PROXY_PORT} https://api64.ipify.org"
fi
echo ""
echo "================================================================"
