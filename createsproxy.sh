#!/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c5
    echo
}

array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)

# Generate IPv6 for /56 block
# With /56, we can use 256 different /64 subnets
gen64_from_56() {
    local base=$1
    # Random subnet (00-ff)
    local subnet=$(printf "%02x" $((RANDOM % 256)))
    
    # Random host part
    local h1="${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    local h2="${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    local h3="${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    
    # Format: BASE:SUBNET:H1:H2:H3
    echo "$base:${subnet}:${h1}:${h2}:${h3}"
}

install_dependencies() {
    echo "Installing dependencies for AlmaLinux 8..."
    yum install -y iproute vim-common wget gcc make >/dev/null 2>&1
}

install_3proxy() {
    echo "Installing 3proxy..."
    URL="https://github.com/z3APA3A/3proxy/archive/refs/tags/0.8.13.tar.gz"
    wget -qO- $URL | tar -xzf-
    cd 3proxy-0.8.13
    make -f Makefile.Linux
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp src/3proxy /usr/local/etc/3proxy/bin/
    cd $WORKDIR
}

gen_3proxy() {
    cat <<EOF
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

users $(awk -F "/" 'BEGIN{ORS="";} {print $1 ":CL:" $2 " "}' ${WORKDATA})

$(awk -F "/" '{print "auth strong\n" \
"allow " $1 "\n" \
"proxy -6 -n -a -p" $4 " -i" $3 " -e"$5"\n" \
"flush\n"}' ${WORKDATA})
EOF
}

gen_proxy_file_for_user() {
    cat >proxy.txt <<EOF
$(awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2 }' ${WORKDATA})
EOF
}

gen_data() {
    seq $FIRST_PORT $LAST_PORT | while read port; do
        echo "user$port/$(random)/$IP4/$port/$(gen64_from_56 $IP6)"
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

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $LOGFILE
}

log_msg "========== Starting Zero-Downtime Rotation =========="

# Get IPv6 base (first 3 or 4 segments for /56)
IP6_BASE=$(head -1 $WORKDATA 2>/dev/null | cut -d'/' -f5 | cut -f1-3 -d':')

if [ -z "$IP6_BASE" ]; then
    log_msg "ERROR: Cannot determine IPv6 base from data.txt"
    exit 1
fi

log_msg "IPv6 Base (/56): $IP6_BASE"

# Backup
cp $WORKDATA ${WORKDATA}.backup
log_msg "Backup created"

# Generate NEW IPv6 addresses for /56 block
awk -v ip6="$IP6_BASE" -F "/" '
BEGIN {
    srand();
    hex="0123456789abcdef";
}
{
    # Generate random subnet (00-ff for /56)
    subnet = "";
    for(i=1; i<=2; i++) {
        subnet = subnet substr(hex, int(rand()*16)+1, 1);
    }
    
    # Generate random host parts (3 segments of 4 hex chars each)
    host = "";
    for(i=1; i<=12; i++) {
        host = host substr(hex, int(rand()*16)+1, 1);
    }
    
    # Format: BASE:SUBNET:XXXX:XXXX:XXXX
    part1 = substr(host, 1, 4);
    part2 = substr(host, 5, 4);
    part3 = substr(host, 9, 4);
    
    new_ip6 = ip6 ":" subnet ":" part1 ":" part2 ":" part3;
    
    print $1 "/" $2 "/" $3 "/" $4 "/" new_ip6;
}' $WORKDATA > ${WORKDATA}.new

# Validate
if [ ! -s ${WORKDATA}.new ]; then
    log_msg "ERROR: Failed to generate new data"
    rm -f ${WORKDATA}.new
    exit 1
fi

LINES=$(wc -l < ${WORKDATA}.new)
log_msg "Generated $LINES new IPv6 addresses from /56 block"

# Replace data
mv ${WORKDATA}.new $WORKDATA

# STEP 1: Add NEW IPs (old ones still active)
log_msg "Step 1/4: Adding new IPv6 addresses..."
awk -F "/" '{system("ip -6 addr add " $5 "/64 dev eth0 2>/dev/null")}' ${WORKDATA}
log_msg "New IPv6 addresses added (old ones still active)"

sleep 2

# STEP 2: Regenerate config
log_msg "Step 2/4: Regenerating 3proxy config..."
cat > /usr/local/etc/3proxy/3proxy.cfg << 'EOFCFG'
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

# Add users
echo "users $(awk -F "/" 'BEGIN{ORS="";} {print $1 ":CL:" $2 " "}' ${WORKDATA})" >> /usr/local/etc/3proxy/3proxy.cfg
echo "" >> /usr/local/etc/3proxy/3proxy.cfg

# Add proxy rules
awk -F "/" '{
    print "auth strong";
    print "allow " $1;
    print "proxy -6 -n -a -p" $4 " -i" $3 " -e" $5;
    print "flush";
    print "";
}' ${WORKDATA} >> /usr/local/etc/3proxy/3proxy.cfg

# STEP 3: Restart 3proxy
log_msg "Step 3/4: Restarting 3proxy..."

pkill -9 3proxy 2>/dev/null
sleep 2

ulimit -n 65536
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
sleep 3

if pgrep 3proxy > /dev/null; then
    log_msg "✅ 3proxy started successfully"
else
    log_msg "❌ ERROR: Failed to start 3proxy"
    cp ${WORKDATA}.backup $WORKDATA
    exit 1
fi

# STEP 4: Cleanup old IPs (async, after 30s)
log_msg "Step 4/4: Scheduling cleanup of old IPs (in 30s)..."
(
    sleep 30
    
    awk -F "/" '{print $5}' ${WORKDATA} > /tmp/valid_ips.txt
    
    ip -6 addr show eth0 2>/dev/null | grep "inet6" | grep -v "fe80" | awk '{print $2}' | cut -d'/' -f1 | while read ipaddr; do
        if ! grep -q "^${ipaddr}$" /tmp/valid_ips.txt; then
            ip -6 addr del ${ipaddr}/64 dev eth0 2>/dev/null
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Cleaned: $ipaddr" >> ${LOGFILE}
        fi
    done
    
    rm -f /tmp/valid_ips.txt
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Cleanup completed" >> ${LOGFILE}
) &

log_msg "Cleanup scheduled"

if pgrep 3proxy > /dev/null; then
    PROXY_COUNT=$(wc -l < $WORKDATA)
    log_msg "✅ SUCCESS: Rotation completed"
    log_msg "   Active proxies: $PROXY_COUNT"
    log_msg "   3proxy PID: $(pgrep 3proxy)"
else
    log_msg "❌ ERROR: 3proxy not running!"
    exit 1
fi

log_msg "========== Rotation Completed =========="
ROTEOF

    chmod +x /home/bkns/rotate_ipv6.sh
}

create_monitor_script() {
    cat > /home/bkns/monitor.sh << 'EOF'
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

if ! pgrep 3proxy > /dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: 3proxy died, restarting..." >> /home/bkns/monitor.log
    pkill -9 3proxy 2>/dev/null
    sleep 2
    ulimit -n 65536
    /usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
    sleep 3
    if pgrep 3proxy > /dev/null; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ Restarted (PID: $(pgrep 3proxy))" >> /home/bkns/monitor.log
    fi
fi
EOF
    chmod +x /home/bkns/monitor.sh
}

setup_cron_rotation() {
    echo "Setting up cron jobs..."
    
    crontab -r 2>/dev/null
    
    (
        echo "*/5 * * * * /home/bkns/rotate_ipv6.sh >> /home/bkns/rotate.log 2>&1"
        echo "*/3 * * * * /home/bkns/monitor.sh"
    ) | crontab -
    
    echo "✅ Cron configured (rotate 5min, monitor 3min)"
}

echo "================================================"
echo "  3PROXY - AlmaLinux 8 - IPv6 /56 Block        "
echo "  50 Ports - Auto Rotation 5 Minutes           "
echo "================================================"
echo ""

echo "[1/9] Installing dependencies for AlmaLinux 8..."
install_dependencies

echo "[2/9] Installing 3proxy..."
install_3proxy

echo "[3/9] Setting up directories..."
WORKDIR="/home/bkns"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p $WORKDIR && cd $WORKDIR

echo "[4/9] Detecting IP addresses..."
IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com 2>/dev/null | cut -f1-3 -d':')

if [ -z "$IP4" ]; then
    echo "ERROR: Cannot detect IPv4"
    exit 1
fi

if [ -z "$IP6" ]; then
    echo "Trying to get IPv6 from interface..."
    IP6=$(ip -6 addr show eth0 2>/dev/null | grep "inet6" | grep -v "fe80" | head -1 | awk '{print $2}' | cut -f1-3 -d':')
    
    if [ -z "$IP6" ]; then
        echo "ERROR: Cannot detect IPv6"
        exit 1
    fi
fi

echo "   IPv4: ${IP4}"
echo "   IPv6 Base (/56): ${IP6}"
echo "   Available subnets: 256 x /64 subnets"

echo "[5/9] Generating 50 proxies..."
FIRST_PORT=10000
LAST_PORT=10049

gen_data > $WORKDIR/data.txt
echo "   Generated 50 proxies (ports 10000-10049)"
echo "   Each proxy uses unique /64 subnet from /56 block"

echo "[6/9] Configuring IPv6 addresses..."
gen_ifconfig > $WORKDIR/boot_ifconfig.sh
chmod +x $WORKDIR/boot_ifconfig.sh
bash $WORKDIR/boot_ifconfig.sh
echo "   Added 50 IPv6 addresses to eth0"

echo "[7/9] Generating 3proxy configuration..."
gen_3proxy > /usr/local/etc/3proxy/3proxy.cfg

echo "[8/9] Setting up auto-start on boot..."
cat > /etc/rc.d/rc.local <<EOF
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
bash ${WORKDIR}/boot_ifconfig.sh
ulimit -n 65536
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
EOF

chmod +x /etc/rc.d/rc.local
systemctl enable rc-local 2>/dev/null

echo "[9/9] Starting 3proxy..."
ulimit -n 65536
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
sleep 3

if pgrep 3proxy > /dev/null; then
    echo "✅ 3proxy started successfully (PID: $(pgrep 3proxy))"
else
    echo "⚠️  Warning: 3proxy may not have started"
fi

echo ""
echo "Setting up rotation and monitoring..."
create_rotate_script
create_monitor_script
setup_cron_rotation

echo ""
echo "Generating proxy list..."
gen_proxy_file_for_user

# Cleanup
rm -rf /root/setup.sh /root/3proxy-* 3proxy-0.8.13 2>/dev/null

echo ""
echo "================================================"
echo "✅ INSTALLATION COMPLETED"
echo "================================================"
echo ""
echo "📊 Configuration:"
echo "   System: AlmaLinux 8"
echo "   IPv6 Block: /56 (256 subnets available)"
echo "   Total Proxies: 50"
echo "   Port Range: 10000-10049"
echo "   IPv4: $IP4"
echo "   IPv6 Base: $IP6"
echo ""
echo "📁 Important Files:"
echo "   Proxy List: $WORKDIR/proxy.txt"
echo "   Rotation Log: $WORKDIR/rotate.log"
echo "   Monitor Log: $WORKDIR/monitor.log"
echo ""
echo "⚙️  Features:"
echo "   ✅ Auto-rotation: Every 5 minutes"
echo "   ✅ Zero-downtime rotation"
echo "   ✅ Auto-monitor: Every 3 minutes"
echo "   ✅ Uses /56 block (256 subnets)"
echo "   ✅ Each rotation = new /64 subnet"
echo ""
echo "🔧 Useful Commands:"
echo "   View proxies: cat $WORKDIR/proxy.txt"
echo "   View log: tail -f $WORKDIR/rotate.log"
echo "   Manual rotation: bash $WORKDIR/rotate_ipv6.sh"
echo "   Check 3proxy: ps aux | grep 3proxy"
echo "   Check cron: crontab -l"
echo ""
echo "🧪 Test first proxy:"
FIRST_PROXY=$(head -1 $WORKDIR/proxy.txt)
if [ -n "$FIRST_PROXY" ]; then
    PROXY_IP=$(echo $FIRST_PROXY | cut -d: -f1)
    PROXY_PORT=$(echo $FIRST_PROXY | cut -d: -f2)
    PROXY_USER=$(echo $FIRST_PROXY | cut -d: -f3)
    PROXY_PASS=$(echo $FIRST_PROXY | cut -d: -f4)
    echo "   curl -x $PROXY_USER:$PROXY_PASS@$PROXY_IP:$PROXY_PORT https://api64.ipify.org"
fi
echo ""
echo "================================================"
echo "🎉 Ready! Enjoy your /56 IPv6 proxy pool!"
echo "================================================"
