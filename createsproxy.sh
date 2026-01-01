#!/bin/bash
# ==========================================================
# IPV6 PROXY ROTATOR - V5 NEW LOGIC (STABLE)
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

# ===== LOCK (NO PARALLEL) =====
LOCKFILE="/var/run/rotate_ipv6.lock"
exec 9>"$LOCKFILE"
flock -n 9 || exit 0

WORKDIR="/home/bkns"
DATAFILE="$WORKDIR/data.txt"
IFACE="eth0"

USER="AnhVip17102"
PASS="AnhVip17102"

FIRST_PORT=22000
LAST_PORT=22049

echo "[$(date)] ===== ROTATE START ====="

# ===== 1. GET IPV6 PREFIX FROM ROUTE =====
PREFIX=$(ip -6 route | awk '/\/64/ && !/fe80/ {print $1}' | head -n1 | cut -d/ -f1)
if [ -z "$PREFIX" ]; then
    echo "NO IPV6 /64 ROUTE"
    exit 1
fi

BASE_IPV6="$(echo "$PREFIX" | sed 's/::$//'):100"

# ===== 2. ENSURE BASE EXISTS =====
if ! ip -6 addr show dev "$IFACE" | grep -q "$BASE_IPV6"; then
    ip -6 addr add "$BASE_IPV6/64" dev "$IFACE"
    sleep 1
fi

# ===== 3. LOCK SOURCE =====
GW=$(ip -6 route | awk '/default/ {print $3}')
ip -6 route replace default via "$GW" dev "$IFACE" src "$BASE_IPV6"
ip -6 route flush cache

echo "BASE IPV6: $BASE_IPV6"

# ===== 4. REMOVE OLD PROXY IPV6 (ONLY WHAT WE CREATED) =====
if [ -f "$DATAFILE" ]; then
    awk -F "/" '{print $5}' "$DATAFILE" | while read ip; do
        ip -6 addr del "$ip/64" dev "$IFACE" 2>/dev/null
    done
fi

sleep 1

# ===== 5. GENERATE NEW IPV6 =====
IP6_PREFIX=$(echo "$BASE_IPV6" | cut -f1-4 -d':')
IP4=$(curl -4 -s --max-time 5 icanhazip.com)
[ -z "$IP4" ] && IP4=$(ip -4 addr show "$IFACE" | awk '/inet /{print $2}' | cut -d/ -f1)

gen_ipv6() {
    printf "%s:%04x:%04x:%04x:%04x\n" "$IP6_PREFIX" $RANDOM $RANDOM $RANDOM $RANDOM
}

> "${DATAFILE}.new"
for port in $(seq $FIRST_PORT $LAST_PORT); do
    IPV6=$(gen_ipv6)
    echo "$USER/$PASS/$IP4/$port/$IPV6" >> "${DATAFILE}.new"
    ip -6 addr add "$IPV6/64" dev "$IFACE"
done

mv "${DATAFILE}.new" "$DATAFILE"

COUNT=$(ip -6 addr show dev "$IFACE" scope global | wc -l)
echo "TOTAL IPV6: $COUNT (BASE + 50)"

# ===== 6. WRITE 3PROXY CONFIG =====
{
echo "daemon"
echo "maxconn 2000"
echo "nserver 1.1.1.1"
echo "nserver 8.8.4.4"
echo "timeouts 1 5 30 60 180 1800 15 60"
echo "auth strong"
echo "users $USER:CL:$PASS"
awk -F "/" '{print "allow " $1 "\nproxy -6 -n -a -p" $4 " -i" $3 " -e"$5 "\nflush"}' "$DATAFILE"
} > /usr/local/etc/3proxy/3proxy.cfg

awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2}' "$DATAFILE" > "$WORKDIR/proxy.txt"

# ===== 7. RESTART 3PROXY =====
pkill 3proxy 2>/dev/null
sleep 2
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg

echo "[$(date)] ===== ROTATE END ====="
EOF

chmod +x "$ROTATE_SCRIPT"

# ================= ADD CRON =================
CRON_CMD="/bin/bash $ROTATE_SCRIPT"
(crontab -l 2>/dev/null | grep -F "$CRON_CMD") >/dev/null || \
(crontab -l 2>/dev/null; echo "$CRON_TIME $CRON_CMD") | crontab -

# ================= FIRST RUN =================
bash "$ROTATE_SCRIPT"

echo "=========================================="
echo "INSTALL DONE - V5 NEW LOGIC"
echo "PROXY FILE : /home/bkns/proxy.txt"
echo "LOG FILE   : /home/bkns/rotation.log"
echo "ROTATE     : EVERY 10 MINUTES"
echo "USER/PASS  : AnhVip17102"
echo "=========================================="
