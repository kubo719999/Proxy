#!/bin/bash
# ==========================================================
# IPV6 PROXY ROTATOR - V6 (NO IP ADD, ROUTE ONLY)
# WORKS ON ALL VPS
# ==========================================================

WORKDIR="/home/bkns"
ROTATE_SCRIPT="$WORKDIR/rotate_ip.sh"
LOGFILE="$WORKDIR/rotation.log"

USER="AnhVip17102"
PASS="AnhVip17102"

FIRST_PORT=22000
LAST_PORT=22049
CRON_TIME="*/10 * * * *"

mkdir -p "$WORKDIR"
touch "$LOGFILE"

cat > "$ROTATE_SCRIPT" << 'EOF'
#!/bin/bash
exec >> /home/bkns/rotation.log 2>&1

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

echo "===== ROTATE START ====="

# ===== GET IPV6 PREFIX FROM ROUTE =====
PREFIX=$(ip -6 route | awk '/\/64/ && !/fe80/ {print $1}' | head -n1 | cut -d/ -f1)
[ -z "$PREFIX" ] && echo "NO IPV6 PREFIX" && exit 1

IP6_PREFIX=$(echo "$PREFIX" | cut -f1-4 -d':')

IP4=$(curl -4 -s --max-time 5 icanhazip.com)
[ -z "$IP4" ] && IP4=$(ip -4 addr show "$IFACE" | awk '/inet /{print $2}' | cut -d/ -f1)

gen_ipv6() {
    printf "%s:%04x:%04x:%04x:%04x\n" "$IP6_PREFIX" $RANDOM $RANDOM $RANDOM $RANDOM
}

> "$DATAFILE"
for port in $(seq $FIRST_PORT $LAST_PORT); do
    IPV6=$(gen_ipv6)
    echo "$USER/$PASS/$IP4/$port/$IPV6" >> "$DATAFILE"
done

# ===== WRITE 3PROXY CONFIG =====
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

pkill 3proxy 2>/dev/null
sleep 1
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg

echo "===== ROTATE END ====="
EOF

chmod +x "$ROTATE_SCRIPT"

(crontab -l 2>/dev/null | grep -F "$ROTATE_SCRIPT") || \
(crontab -l 2>/dev/null; echo "$CRON_TIME /bin/bash $ROTATE_SCRIPT") | crontab -

bash "$ROTATE_SCRIPT"

echo "INSTALL DONE - V6 ROUTE MODE"
echo "PROXY FILE : /home/bkns/proxy.txt"
echo "ROTATE     : EVERY 10 MINUTES"
echo "USER/PASS  : AnhVip17102"
