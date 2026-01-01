#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# ===== CONFIG =====
WORKDIR="/home/bkns"
WORKDATA="${WORKDIR}/data.txt"
LOGFILE="${WORKDIR}/rotate.log"
CFG="/usr/local/etc/3proxy/3proxy.cfg"
ETH="eth0"

FIXED_USER="AnhVip17102"
FIXED_PASS="AnhVip17102"

MAX_PROXY=100

# ===== FUNCTION =====
log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

# ===== LOG ROTATE =====
if [ -f "$LOGFILE" ]; then
    SIZE=$(du -m "$LOGFILE" | cut -f1)
    [ "$SIZE" -gt 10 ] && tail -n 1000 "$LOGFILE" > "${LOGFILE}.tmp" && mv "${LOGFILE}.tmp" "$LOGFILE"
fi

log_msg "========== ROTATE START =========="

# ===== CHECK DATA =====
[ ! -f "$WORKDATA" ] && log_msg "ERROR: data.txt not found" && exit 1

# ===== LIMIT 100 PROXY =====
head -n $MAX_PROXY "$WORKDATA" > "${WORKDATA}.limit"
mv "${WORKDATA}.limit" "$WORKDATA"

PROXY_COUNT=$(wc -l < "$WORKDATA")
[ "$PROXY_COUNT" -eq 0 ] && log_msg "ERROR: No proxy data" && exit 1

# ===== GET IPV6 PREFIX =====
IP6_PREFIX=$(head -1 "$WORKDATA" | cut -d'/' -f5 | cut -d':' -f1-4)
[ -z "$IP6_PREFIX" ] && log_msg "ERROR: IPv6 prefix not found" && exit 1

cp "$WORKDATA" "${WORKDATA}.bak"

# ===== GENERATE NEW IPV6 =====
awk -v prefix="$IP6_PREFIX" -v u="$FIXED_USER" -v p="$FIXED_PASS" -F "/" '
BEGIN {
    srand()
    hex="0123456789abcdef"
}
{
    s=""
    for(i=1;i<=16;i++) s=s substr(hex, int(rand()*16)+1, 1)
    ip=prefix ":" substr(s,1,4) ":" substr(s,5,4) ":" substr(s,9,4) ":" substr(s,13,4)
    print u "/" p "/" $3 "/" $4 "/" ip
}' "$WORKDATA" > "${WORKDATA}.new"

mv "${WORKDATA}.new" "$WORKDATA"
log_msg "Generated $PROXY_COUNT new IPv6"

# ===== GENERATE 3PROXY CONFIG =====
cat > "${CFG}.new" <<EOF
daemon
maxconn 2000
nserver 1.1.1.1
nserver 8.8.8.8
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
EOF

awk -F "/" -v user="$FIXED_USER" '{
    print "auth strong"
    print "allow " user
    print "proxy -6 -n -a -p" $4 " -i" $3 " -e" $5
    print "flush"
}' "$WORKDATA" >> "${CFG}.new"

mv "${CFG}.new" "$CFG"

# ===== DELETE ALL OLD IPV6 =====
log_msg "Deleting old IPv6..."
ip -6 addr show "$ETH" | grep 'inet6.*scope global' | awk '{print $2}' | cut -d/ -f1 | while read ip; do
    ip -6 addr del "$ip/64" dev "$ETH" 2>/dev/null
done

sleep 2

# ===== ADD NEW IPV6 =====
log_msg "Adding new IPv6..."
awk -F "/" '{system("ip -6 addr add " $5 "/64 dev '"$ETH"' 2>/dev/null"); system("sleep 0.02")}' "$WORKDATA"

sleep 2

FINAL_IP=$(ip -6 addr show "$ETH" | grep 'scope global' | wc -l)
log_msg "IPv6 active: $FINAL_IP"

# ===== RELOAD 3PROXY =====
log_msg "Reloading 3proxy..."
PID=$(pgrep 3proxy)

if [ -n "$PID" ]; then
    kill -HUP "$PID"
    sleep 3
fi

if ! pgrep 3proxy >/dev/null; then
    pkill -9 3proxy 2>/dev/null
    ulimit -n 65536
    /usr/local/etc/3proxy/bin/3proxy "$CFG" &
    sleep 3
fi

NEW_PID=$(pgrep 3proxy)
[ -z "$NEW_PID" ] && log_msg "ERROR: 3proxy failed" && exit 1

log_msg "========== DONE: Proxy=$PROXY_COUNT IPv6=$FINAL_IP PID=$NEW_PID =========="
