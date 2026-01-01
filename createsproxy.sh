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

PROXY_COUNT=$(wc -l < $WORKDATA)

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

log_msg "Generated $PROXY_COUNT new IPs"

# Update data.txt
mv ${WORKDATA}.new $WORKDATA

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

# STEP 1: DELETE ALL OLD IPv6
log_msg "Deleting all old IPv6..."
BEFORE=$(ip -6 addr show eth0 2>/dev/null | grep -c 'inet6.*scope global')

ip -6 addr show eth0 2>/dev/null | grep 'inet6.*scope global' | awk '{print $2}' | cut -d'/' -f1 | while read ip; do
    ip -6 addr del ${ip}/64 dev eth0 2>/dev/null
done

sleep 2

AFTER_DELETE=$(ip -6 addr show eth0 2>/dev/null | grep -c 'inet6.*scope global')
log_msg "Deleted: Before=$BEFORE After=$AFTER_DELETE"

# STEP 2: ADD NEW IPv6
log_msg "Adding new IPv6..."
awk -F "/" '{system("ip -6 addr add " $5 "/64 dev eth0 2>/dev/null")}' ${WORKDATA}

sleep 2

AFTER_ADD=$(ip -6 addr show eth0 2>/dev/null | grep -c 'inet6.*scope global')
log_msg "Added $AFTER_ADD new IPs"

# STEP 3: Reload 3proxy
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

sleep 3

# Final check
FINAL=$(ip -6 addr show eth0 2>/dev/null | grep -c 'inet6.*scope global')

if [ "$FINAL" -ne "$PROXY_COUNT" ]; then
    log_msg "WARNING: IPs=$FINAL Expected=$PROXY_COUNT - Re-adding..."
    awk -F "/" '{system("ip -6 addr add " $5 "/64 dev eth0 2>/dev/null")}' ${WORKDATA}
    sleep 1
    FINAL=$(ip -6 addr show eth0 2>/dev/null | grep -c 'inet6.*scope global')
fi

log_msg "========== Done: Proxies=$PROXY_COUNT IPs=$FINAL PID=$NEW_PID =========="
ROTEOF

chmod +x /home/bkns/rotate_ipv6.sh

echo "✅ Rotation script created!"
