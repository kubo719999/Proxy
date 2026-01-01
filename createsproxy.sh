#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
exec >> /home/bkns/rotation.log 2>&1

WORKDIR="/home/bkns"
WORKDATA="${WORKDIR}/data.txt"
IFACE="eth0"

USER="AnhVip17102"
PASS="AnhVip17102"

FIRST_PORT=22000
LAST_PORT=22049
TOTAL_PORT=50

echo "[$(date)] ===== ROTATE START ====="

# 1️⃣ XÓA TOÀN BỘ IPv6 GLOBAL CŨ (TRÁNH NGẼN & TRÀN RAM)
echo "[$(date)] Removing old IPv6..."
ip -6 addr show dev $IFACE scope global | awk '/inet6/ {print $2}' | while read ip; do
    ip -6 addr del $ip dev $IFACE 2>/dev/null
done
sleep 1

# 2️⃣ LẤY IPv6 PREFIX CHUẨN
IP6_PREFIX=$(ip -6 addr show dev $IFACE scope global | awk '/inet6/ {print $2}' | head -n1 | cut -d'/' -f1 | cut -f1-4 -d':')
IP4=$(curl -4 -s --max-time 5 icanhazip.com)
[ -z "$IP4" ] && IP4=$(ip -4 addr show $IFACE | awk '/inet /{print $2}' | cut -d/ -f1)

if [[ -z "$IP6_PREFIX" || -z "$IP4" ]]; then
    echo "[$(date)] ❌ ERROR: IP PREFIX FAIL"
    exit 1
fi

echo "[$(date)] IPv4: $IP4 | IPv6 Prefix: $IP6_PREFIX"

# 3️⃣ HÀM RANDOM IPv6
gen_ipv6() {
    printf "%s:%04x:%04x:%04x:%04x\n" "$IP6_PREFIX" $RANDOM $RANDOM $RANDOM $RANDOM
}

# 4️⃣ TẠO DATA 50 PORT CỐ ĐỊNH
> ${WORKDATA}.new
for port in $(seq $FIRST_PORT $LAST_PORT); do
    IPV6=$(gen_ipv6)
    echo "$USER/$PASS/$IP4/$port/$IPV6" >> ${WORKDATA}.new
    ip -6 addr add $IPV6/64 dev $IFACE 2>/dev/null
done

sleep 2

COUNT=$(ip -6 addr show dev $IFACE scope global | wc -l)
echo "[$(date)] IPv6 added: $COUNT / $TOTAL_PORT"

# 5️⃣ GHI FILE 3PROXY (PORT GIỮ NGUYÊN → KHÔNG DIE)
echo "[$(date)] Writing 3proxy config..."
{
echo "daemon"
echo "maxconn 2000"
echo "nserver 1.1.1.1"
echo "nserver 8.8.4.4"
echo "timeouts 1 5 30 60 180 1800 15 60"
echo "auth strong"
echo "users $USER:CL:$PASS"

awk -F "/" '{print "allow " $1 "\nproxy -6 -n -a -p" $4 " -i" $3 " -e"$5 "\nflush"}' ${WORKDATA}.new
} > /usr/local/etc/3proxy/3proxy.cfg

mv ${WORKDATA}.new ${WORKDATA}
awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2}' ${WORKDATA} > ${WORKDIR}/proxy.txt

# 6️⃣ RESTART 3PROXY AN TOÀN (KHÔNG -9)
echo "[$(date)] Restarting 3proxy..."
pkill 3proxy 2>/dev/null
sleep 2
ulimit -n 10048
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg

sleep 2
pgrep 3proxy && echo "[$(date)] ✅ ROTATE SUCCESS" || echo "[$(date)] ❌ ROTATE FAIL"
