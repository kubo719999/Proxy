#!/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c5
    echo
}

array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
    ip64() {
        echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }
    echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

install_dependencies() {
    echo "Installing dependencies..."
    if command -v yum >/dev/null 2>&1; then
        yum install -y iproute vim-common wget gcc make >/dev/null 2>&1
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update >/dev/null 2>&1
        apt-get install -y iproute2 vim-common wget gcc make >/dev/null 2>&1
    fi
}

install_3proxy() {
    echo "installing 3proxy"
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
        echo "user$port/$(random)/$IP4/$port/$(gen64 $IP6)"
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

# Simple hex generator without xxd
gen_hex() {
    od -An -tx1 -N8 /dev/urandom | tr -d ' \n' | head -c 16
}

log_msg "========== Starting Zero-Downtime Rotation =========="

# Get IPv6 prefix from data.txt (most reliable)
IP6=$(head -1 $WORKDATA 2>/dev/null | cut -d'/' -f5 | cut -f1-4 -d':')

if [ -z "$IP6" ]; then
    log_msg "ERROR: Cannot determine IPv6 prefix from data.txt"
    exit 1
fi

log_msg "IPv6 Prefix: $IP6"

# Backup
cp $WORKDATA ${WORKDATA}.backup
log_msg "Backup created"

# Generate NEW IPv6 addresses (WITHOUT xxd)
awk -v ip6="$IP6" -F "/" '
BEGIN {
    srand();
    hex="0123456789abcdef";
}
{
    # Generate 16 random hex chars
    new_suffix = "";
    for(i=1; i<=16; i++) {
        new_suffix = new_suffix substr(hex, int(rand()*16)+1, 1);
    }
    
    # Format as IPv6: IP6:XXXX:XXXX:XXXX:XXXX
    part1 = substr(new_suffix, 1, 4);
    part2 = substr(new_suffix, 5, 4);
    part3 = substr(new_suffix, 9, 4);
    part4 = substr(new_suffix, 13, 4);
    
    new_ip6 = ip6 ":" part1 ":" part2 ":" part3 ":" part4;
    
    print $1 "/" $2 "/" $3 "/" $4 "/" new_ip6;
}' $WORKDATA > ${WORKDATA}.new

# Validate
if [ ! -s ${WORKDATA}.new ]; then
    log_msg "ERROR: Failed to generate new data"
    rm -f ${WORKDATA}.new
    exit 1
fi

LINES=$(wc -l < ${WORKDATA}.new)
log_msg "Generated $LINES new IPv6 addresses"

# Replace data
mv ${WORKDATA}.new $WORKDATA

# STEP 1: Add NEW IPs
log_msg "Step 1/4: Adding new IPv6 addresses..."
if command -v ip >/dev/null 2>&1; then
    awk -F "/" '{system("ip -6 addr add " $5 "/64 dev eth0 2>/dev/null")}' ${WORKDATA}
else
    awk -F "/" '{system("ifconfig eth0 inet6 add " $5 "/64 2>/dev/null")}' ${WORKDATA}
fi
log_msg "New IPv6 addresses added"

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

# Add users line
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

# STEP 3: Reload 3proxy
log_msg "Step 3/4: Reloading 3proxy (graceful reload)..."

# Kill all 3proxy instances first
pkill -9 3proxy 2>/dev/null
sleep 2

# Start fresh
log_msg "Starting 3proxy with new config..."
ulimit -n 65536
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
sleep 3

if pgrep 3proxy > /dev/null; then
    log_msg "✅ 3proxy started successfully"
else
    log_msg "❌ ERROR: Failed to start 3proxy"
    # Restore backup
    cp ${WORKDATA}.backup $WORKDATA
    exit 1
fi

# STEP 4: Cleanup old IPs (async)
log_msg "Step 4/4: Scheduling cleanup of old IPs..."
(
    sleep 30
    
    # Get valid IPs
    awk -F "/" '{print $5}' ${WORKDATA} > /tmp/valid_ips.txt
    
    # Remove old IPs
    if command -v ip >/dev/null 2>&1; then
        ip -6 addr show eth0 2>/dev/null | grep "inet6" | grep -v "fe80" | awk '{print $2}' | cut -d'/' -f1 | while read ipaddr; do
            if ! grep -q "^${ipaddr}$" /tmp/valid_ips.txt; then
                ip -6 addr del ${ipaddr}/64 dev eth0 2>/dev/null
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Cleaned: $ipaddr" >> ${LOGFILE}
            fi
        done
    fi
    
    rm -f /tmp/valid_ips.txt
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Cleanup completed" >> ${LOGFILE}
) &

log_msg "Cleanup scheduled"

# Verify
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
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ 3proxy restarted (PID: $(pgrep 3proxy))" >> /home/bkns/monitor.log
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ Failed to restart" >> /home/bkns/monitor.log
    fi
fi
EOF
    chmod +x /home/bkns/monitor.sh
}

setup_cron_rotation() {
    echo "Setting up cron jobs..."
    
    # Clear old jobs
    crontab -r 2>/dev/null
    
    # Add new jobs
    (
        echo "*/5 * * * * /home/bkns/rotate_ipv6.sh >> /home/bkns/rotate.log 2>&1"
        echo "*/3 * * * * /home/bkns/monitor.sh"
    ) | crontab -
    
    echo "✅ Cron configured"
}

echo "======================================"
echo "  3PROXY - 50 PORTS - ROTATION 5MIN  "
echo "======================================"
echo ""

echo "[1/9] Installing dependencies..."
install_dependencies

echo "[2/9] Installing 3proxy..."
install_3proxy

echo "[3/9] Setting up directories..."
WORKDIR="/home/bkns"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p $WORKDIR && cd $WORKDIR

echo "[4/9] Detecting IPs..."
IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com 2>/dev/null | cut -f1-4 -d':')

if [ -z "$IP4" ]; then
    echo "ERROR: Cannot detect IPv4"
    exit 1
fi

if [ -z "$IP6" ]; then
    IP6=$(ip -6 addr show eth0 2>/dev/null | grep "inet6" | grep -v "fe80" | head -1 | awk '{print $2}' | cut -f1-4 -d':')
    if [ -z "$IP6" ]; then
        echo "ERROR: Cannot detect IPv6"
        exit 1
    fi
fi

echo "   IPv4: ${IP4}"
echo "   IPv6: ${IP6}"

echo "[5/9] Generating 50 proxies..."
FIRST_PORT=10000
LAST_PORT=10049

gen_data > $WORKDIR/data.txt
echo "   Ports: 10000-10049"

echo "[6/9] Configuring IPv6..."
gen_ifconfig > $WORKDIR/boot_ifconfig.sh
chmod +x $WORKDIR/boot_ifconfig.sh
bash $WORKDIR/boot_ifconfig.sh

echo "[7/9] Generating config..."
gen_3proxy > /usr/local/etc/3proxy/3proxy.cfg

echo "[8/9] Auto-start setup..."
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
    echo "✅ 3proxy started (PID: $(pgrep 3proxy))"
else
    echo "⚠️  Failed to start"
fi

echo ""
create_rotate_script
create_monitor_script
setup_cron_rotation
gen_proxy_file_for_user

rm -rf /root/setup.sh /root/3proxy-* 3proxy-0.8.13 2>/dev/null

echo ""
echo "======================================"
echo "✅ DONE - 50 Proxies Ready"
echo "======================================"
echo "Proxy list: $WORKDIR/proxy.txt"
echo "Rotation: Every 5 minutes"
echo ""
FIRST_PROXY=$(head -1 $WORKDIR/proxy.txt)
[ -n "$FIRST_PROXY" ] && echo "Test: curl -x $(echo $FIRST_PROXY | awk -F: '{print $3":"$4"@"$1":"$2}') https://api64.ipify.org"
echo "======================================"
