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
log_msg "Proxies: $PROXY_COUNT"

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

# CRITICAL: Create temp file with unique name
TMPFILE="/tmp/keep_rotate_$$_$(date +%s).txt"

# Save new IPs to keep list
awk -F "/" '{print $5}' ${WORKDATA}.new > "$TMPFILE"
KEEP_COUNT=$(wc -l < "$TMPFILE")
log_msg "New IPs to keep: $KEEP_COUNT"

# Update data.txt
mv ${WORKDATA}.new $WORKDATA

# Add new IPs (duplicates auto-ignored by kernel)
log_msg "Adding new IPs..."
awk -F "/" '{system("ip -6 addr add " $5 "/64 dev eth0 2>/dev/null")}' ${WORKDATA}

sleep 2

# Generate 3proxy config
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

# Reload 3proxy
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
[ -z "$NEW_PID" ] && log_msg "ERROR: 3proxy failed to start" && exit 1
log_msg "3proxy PID: $NEW_PID"

# Wait for 3proxy to stabilize
sleep 5

# CLEANUP - SAFE METHOD
log_msg "Starting cleanup..."
BEFORE=$(ip -6 addr show eth0 2>/dev/null | grep -c 'inet6.*scope global')
log_msg "IPs before cleanup: $BEFORE"

# Create temp files
ALL_IPS="/tmp/all_ips_$$_$(date +%s).txt"
DELETE_IPS="/tmp/delete_ips_$$_$(date +%s).txt"

# Get all current IPs on interface
ip -6 addr show eth0 2>/dev/null | grep 'inet6.*scope global' | awk '{print $2}' | cut -d'/' -f1 | sort > "$ALL_IPS"

# Find IPs to delete (all_ips - keep_ips)
comm -23 "$ALL_IPS" "$TMPFILE" > "$DELETE_IPS"

# Delete old IPs
DELETED=0
if [ -s "$DELETE_IPS" ]; then
    while IFS= read -r ip; do
        if ip -6 addr del ${ip}/64 dev eth0 2>/dev/null; then
            DELETED=$((DELETED + 1))
        fi
    done < "$DELETE_IPS"
fi

sleep 2

AFTER=$(ip -6 addr show eth0 2>/dev/null | grep -c 'inet6.*scope global')

log_msg "Cleanup: Before=$BEFORE After=$AFTER Deleted=$DELETED Target=$KEEP_COUNT"

# Cleanup temp files
rm -f "$TMPFILE" "$ALL_IPS" "$DELETE_IPS"

# Verify and auto-fix
if [ "$AFTER" -ne "$PROXY_COUNT" ]; then
    log_msg "MISMATCH: Expected=$PROXY_COUNT Got=$AFTER - Auto fixing..."
    
    # Re-add all proxy IPs to ensure we have all 50
    awk -F "/" '{system("ip -6 addr add " $5 "/64 dev eth0 2>/dev/null")}' ${WORKDATA}
    
    sleep 2
    
    AFTER=$(ip -6 addr show eth0 2>/dev/null | grep -c 'inet6.*scope global')
    log_msg "After fix: $AFTER IPs"
fi

log_msg "========== Done: Proxies=$PROXY_COUNT IPs=$AFTER PID=$NEW_PID =========="
ROTEOF

chmod +x /home/bkns/rotate_ipv6.sh

echo "✅ Script fixed with unique temp files!"
