#!/bin/bash
# ==========================================================
# AUTO CREATE + ROTATE IPV6 PROXY
# USER/PASS: AnhVip17102
# PORT: 22000 - 22049 (50 PORT)
# ROTATE: 10 MINUTES
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
CRON_TIME="*/10 * * * *"

mkdir -p $WORKDIR
touch $LOGFILE

# ================= CREATE ROTATE SCRIPT =================
cat > $ROTATE_SCRIPT << 'EOF'
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
exec >> /home/bkns/rotation.log 2>&1

WORKDIR="/home/bkns"
WORKDATA="$WORKDIR/data.txt"
IFACE="eth0"

USER="AnhVip17102"
PASS="AnhVip17102"

FIRST_PORT=22000
LAST_PORT=22049

echo "[$(date)] ===== ROTATE START ====="

# REMOVE OLD IPV6
ip -6 addr show dev $IFACE scope global | awk '/inet6/ {print $2}' | while read ip; do
    ip -6 addr del $ip dev $IFACE 2>/dev/null
done
sleep 1

# GET IP
IP6_PREFIX=$(ip -6 addr show dev $IFACE scope global | awk '/inet6/ {print $2}' | head -n1 | cut -d'/' -f1 | cut -f1-4 -d':')
IP4=$(curl -4 -s --max-time 5 icanhazip.com)
[ -z "$IP4" ] && IP4=$(ip -4 addr show $IFACE | awk '/inet /{print $2}' | cut -d/ -f1)

if [[ -z "$IP6_PREFIX" || -z "$IP4" ]]; then
    echo "[$(date)] ERROR: IP DETECT FAIL"
    exit 1
fi

gen_ipv6() {
    printf "%s:%04x:%04x:%04x:%04x\n" "$IP6_PREFIX" $RANDOM $RANDOM $RANDOM $RANDOM
}

> ${WORKDATA}.new
for port in $(seq $FIRST_PORT $LAST_PORT); do
    IPV6=$(gen_ipv6)
    echo "$USER/$PASS/$IP4/$port/$IPV6" >> ${WORKDATA}.new
    ip -6 addr add $IPV6/64 dev $IFACE 2>/dev/null
done

sleep 2

# WRITE 3PROXY CONFIG
{
echo "daemon"
echo "maxconn 2000"
echo "nserver 1.1.1.1"
echo "nserver 8.8.4.4"
echo "auth strong"
echo "users $USER:CL:$PASS"

awk -F "/" '{print "allow " $1 "\nproxy -6 -n -a -p" $4 " -i" $3 " -e"$5 "\nflush"}' ${WORKDATA}.new
} > /usr/local/etc/3proxy/3proxy.cfg

mv ${WORKDATA}.new ${WORKDATA}
awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2}' ${WORKDATA} > $WORKDIR/proxy.txt

# RESTART 3PROXY
pkill 3proxy 2>/dev/null
sleep 2
ulimit -n 10048
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg

pgrep 3proxy && echo "[$(date)] ROTATE OK" || echo "[$(date)] ROTATE FAIL"
EOF

chmod +x $ROTATE_SCRIPT

# ================= ADD CRON =================
CRON_CMD="/bin/bash $ROTATE_SCRIPT"
(crontab -l 2>/dev/null | grep -F "$CRON_CMD") >/dev/null
if [ $? -ne 0 ]; then
    (crontab -l 2>/dev/null; echo "$CRON_TIME $CRON_CMD") | crontab -
fi

# ================= RUN FIRST TIME =================
bash $ROTATE_SCRIPT

echo "=========================================="
echo "INSTALL DONE!"
echo "PROXY FILE: /home/bkns/proxy.txt"
echo "LOG FILE  : /home/bkns/rotation.log"
echo "ROTATE    : EVERY 10 MINUTES"
echo "USER/PASS : AnhVip17102"
echo "=========================================="
