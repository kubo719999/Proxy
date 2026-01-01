#!/bin/bash
# ==========================================================
# AUTO CREATE + ROTATE IPV6 PROXY
# V3 SAFE VERSION: NO NET LOSS - NO RAM LEAK - NO PARALLEL
# ==========================================================

PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

WORKDIR="/home/bkns"
ROTATE_SCRIPT="$WORKDIR/rotate_ip.sh"
LOGFILE="$WORKDIR/rotation.log"
IFACE="eth0"

USER="AnhVip17102"
PASS="AnhVip17102"

FIRST_PORT=22000
LAST_PORT=22049
TOTAL_PORT=50
CRON_TIME="*/10 * * * *"

mkdir -p "$WORKDIR"
touch "$LOGFILE"

# ================= CREATE ROTATE SCRIPT =================
cat > "$ROTATE_SCRIPT" << 'EOF'
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
exec >> /home/bkns/rotation.log 2>&1

# ===== LOCK: PREVENT PARALLEL RUN =====
LOCKFILE="/var/run/rotate_ipv6.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
    echo "[$(date)] Another rotate instance is running. Exit."
    exit 0
fi

WORKDIR="/home/bkns"
WORKDATA="$WORKDIR/data.txt"
IFACE="eth0"

USER="AnhVip17102"
PASS="AnhVip17102"

FIRST_PORT=22000
LAST_PORT=22049
TOTAL_PORT=50

echo "[$(date)] ===== ROTATE START ====="

# ===== 1. ENSURE BASE IPV6 EXISTS =====
BASE_IPV6=$(ip -6 addr show dev "$IFACE" scope global | awk '/inet6/ {print $2}' | head -n1 | cut -d/ -f1)

if [ -z "$BASE_IPV6" ]; then
    PREFIX=$(ip -6 route | awk '/\/64/ && !/fe80/ {print $1}' | head -n1 | cut -d/ -f1)
    if [ -z "$PREFIX" ]; then
        echo "[$(date)] ERROR: NO IPV6 /64 ROUTE"
        exit 1
    fi
    BASE_IPV6=$(echo "$PREFIX" | sed 's/::$//'):100
    ip -6 addr add "$BASE_IPV6/64" dev "$IFACE"
    sleep 1
fi

echo "[$(date)] BASE IPV6: $BASE_IPV6"

# ===== 2. LOCK IPV6 SOURCE =====
GW_IPV6=$(ip -6 route | awk '/default/ {print $3}')
ip -6 route replace default via "$GW_IPV6" dev "$IFACE" src "$BASE_IPV6"
ip -6 route flush cache

# ===== 3. REMOVE OLD PROXY IPV6 (KEEP BASE) =====
echo "[$(date)] Removing old proxy IPv6..."
ip -6 addr show dev "$IFACE" scope global | awk '/inet6/ {print $2}' | while read ip; do
    if [[ "$ip" != "$BASE_IPV6/64" ]]; then
        ip -6 addr del "$ip" dev "$IFACE" 2>/dev/null
    fi
done
sleep 1

# ===== 4. GET PREFIX FROM BASE =====
IP6_PREFIX=$(echo "$BASE_IPV6" | cut -f1-4 -d':')

IP4=$(curl -4 -s --max-time 5 icanhazip.com)
[ -z "$IP4" ] && IP4=$(ip -4 addr show "$IFACE" | awk '/inet /{print $2}' | cut -d/ -f1)

if [[ -z "$IP6_PREFIX" || -z "$IP4" ]]; then
    echo "[$(date)] ERROR: IP DETECT FAILED"
    exit 1
fi

# ===== 5. GENERATE IPV6 =====
gen_ipv6() {
    printf "%s:%04x:%04x:%04x:%04x\n" "$IP6_PREFIX" $RANDOM $RANDOM $RANDOM $RANDOM
}

# ===== 6. CREATE NEW 50 IPV6 =====
> "${WORKDATA}.new"
for port in $(seq $FIRST_PORT $LAST_PORT); do
    IPV6=$(gen_ipv6)
    echo "$USER/$PASS/$IP4/$port/$IPV6" >> "${WORKDATA}.new"
    ip -6 addr add "$IPV6/64" dev "$IFACE" 2>/dev/null
done

sleep 2
COUNT=$(ip -6 addr show dev "$IFACE" scope global | wc -l)
echo "[$(date)] TOTAL IPV6 NOW: $COUNT (BASE + PROXY)"

# ===== 7. WRITE 3PROXY CONFIG =====
{
echo "daemon"
echo "maxconn 2000"
echo "nserver 1.1.1.1"
echo "nserver 8.8.4.4"
echo "timeouts 1 5 30 60 180 1800 15 60"
echo "auth strong"
echo "users $USER:CL:$PASS"
awk -F "/" '{print "allow " $1 "\nproxy -6 -n -a -p" $4 " -i" $3 " -e"$5 "\nflush"}' "${WORKDATA}.new"
} > /usr/local/etc/3proxy/3proxy.cfg

mv "${WORKDATA}.new" "$WORKDATA"
awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2}' "$WORKDATA" > "$WORKDIR/proxy.txt"

# ===== 8. RESTART 3PROXY SAFELY =====
pkill 3proxy 2>/dev/null
sleep 2
ulimit -n 10048
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg

if pgrep 3proxy >/dev/null; then
    echo "[$(date)] ROTATE SUCCESS"
else
    echo "[$(date)] ROTATE FAILED"
fi

echo "[$(date)] ===== ROTATE END ====="
EOF

chmod +x "$ROTATE_SCRIPT"

# ================= ADD CRON (ONCE) =================
CRON_CMD="/bin/bash $ROTATE_SCRIPT"
(crontab -l 2>/dev/null | grep -F "$CRON_CMD") >/dev/null
if [ $? -ne 0 ]; then
    (crontab -l 2>/dev/null; echo "$CRON_TIME $CRON_CMD") | crontab -
fi

# ================= RUN FIRST TIME =================
bash "$ROTATE_SCRIPT"

echo "=========================================="
echo "INSTALL DONE - V3 (NO PARALLEL)"
echo "PROXY FILE : /home/bkns/proxy.txt"
echo "LOG FILE   : /home/bkns/rotation.log"
echo "ROTATE     : EVERY 10 MINUTES"
echo "USER/PASS  : AnhVip17102"
echo "=========================================="
