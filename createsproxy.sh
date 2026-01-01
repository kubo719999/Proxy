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

# Save keep list FIRST
awk -F "/" '{print $5}' ${WORKDATA}.new | sort > /tmp/keep_ips.txt
KEEP_COUNT=$(wc -l < /tmp/keep_ips.txt)

mv ${WORKDATA}.new $WORKDATA

# Add new IPs
log_msg "Adding new IPs..."
awk -F "/" '{system("ip -6 addr add " $5 "/64 dev eth0 2>/dev/null")}' ${WORKDATA}

sleep 2

# Generate config
cat > /usr/local/etc/3proxy/3proxy.cfg.new << 'EOFCFG'
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
OLD_PID=$(pgrep 3proxy)
if [ -n "$OLD_PID" ]; then
    kill -HUP $OLD_PID 2>/dev/null
    sleep 5
    [ ! -n "$(pgrep 3proxy)" ] && pkill -9 3proxy && sleep 2 && ulimit -n 65536 && /usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
else
    ulimit -n 65536
    /usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
fi

sleep 3

# CLEANUP - FIXED VERSION
log_msg "Cleanup start..."

BEFORE=$(ip -6 addr show eth0 | grep -c 'inet6.*scope global')

# Get all current IPs
ip -6 addr show eth0 | grep 'inet6.*scope global' | awk '{print $2}' | cut -d'/' -f1 | sort > /tmp/all_ips.txt

# Find IPs to delete
comm -23 /tmp/all_ips.txt /tmp/keep_ips.txt > /tmp/delete_ips.txt

# Delete one by one
REMOVED=0
while IFS= read -r ip; do
    if ip -6 addr del ${ip}/64 dev eth0 2>/dev/null; then
        REMOVED=$((REMOVED + 1))
        log_msg "Deleted: $ip"
    fi
done < /tmp/delete_ips.txt

AFTER=$(ip -6 addr show eth0 | grep -c 'inet6.*scope global')

log_msg "Cleanup: Before=$BEFORE After=$AFTER Removed=$REMOVED Target=$KEEP_COUNT"

# Cleanup temp files
rm -f /tmp/keep_ips.txt /tmp/all_ips.txt /tmp/delete_ips.txt

# Verify and fix
PROXY_COUNT=$(wc -l < $WORKDATA)
TOTAL_IPS=$AFTER

if [ "$TOTAL_IPS" -ne "$PROXY_COUNT" ]; then
    log_msg "MISMATCH: Proxies=$PROXY_COUNT IPs=$TOTAL_IPS - FIXING"
    awk -F "/" '{system("ip -6 addr add " $5 "/64 dev eth0 2>/dev/null")}' ${WORKDATA}
    TOTAL_IPS=$(ip -6 addr show eth0 | grep -c 'inet6.*scope global')
    log_msg "Fixed: IPs now=$TOTAL_IPS"
fi

log_msg "========== Completed: Proxies=$PROXY_COUNT IPs=$TOTAL_IPS =========="
ROTEOF

chmod +x /home/bkns/rotate_ipv6.sh

echo "Script updated!"
