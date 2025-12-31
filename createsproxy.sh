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
$(awk -F "/" '{print "ifconfig eth0 inet6 add " $5 "/64"}' ${WORKDATA})
EOF
}

create_rotate_script() {
    cat > /home/bkns/rotate_ipv6.sh << 'ROTEOF'
#!/bin/bash
WORKDIR="/home/bkns"
WORKDATA="${WORKDIR}/data.txt"
LOGFILE="${WORKDIR}/rotate.log"

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $LOGFILE
}

array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)

log_msg "========== Starting Zero-Downtime Rotation =========="

# Get IPv6 prefix from existing config
IP6=$(ip -6 addr show eth0 | grep "inet6" | grep -v "fe80" | head -1 | awk '{print $2}' | cut -f1-4 -d':')

if [ -z "$IP6" ]; then
    log_msg "ERROR: Cannot determine IPv6 prefix"
    exit 1
fi

log_msg "IPv6 Prefix: $IP6"

# Backup current data
cp $WORKDATA ${WORKDATA}.backup
log_msg "Backup created"

# Generate NEW IPv6 addresses (keep username/password/IP4/port)
awk -v ip6="$IP6" -F "/" 'BEGIN {
    srand();
}
{
    # Generate random hex for IPv6 suffix
    cmd = "head -c 8 /dev/urandom | xxd -p | head -c 16";
    cmd | getline rand1;
    close(cmd);
    
    # Format: IP6:XXXX:XXXX:XXXX:XXXX
    new_ip6 = ip6 ":" substr(rand1,1,4) ":" substr(rand1,5,4) ":" substr(rand1,9,4) ":" substr(rand1,13,4);
    
    print $1 "/" $2 "/" $3 "/" $4 "/" new_ip6;
}' $WORKDATA > ${WORKDATA}.new

# Validate new data
if [ ! -s ${WORKDATA}.new ]; then
    log_msg "ERROR: Failed to generate new data"
    rm -f ${WORKDATA}.new
    exit 1
fi

LINES=$(wc -l < ${WORKDATA}.new)
log_msg "Generated $LINES new IPv6 addresses"

# Replace data file
mv ${WORKDATA}.new $WORKDATA

# STEP 1: Add NEW IPv6 addresses (old ones still active)
log_msg "Step 1/4: Adding new IPv6 addresses..."
awk -F "/" '{system("ip -6 addr add " $5 "/64 dev eth0 2>/dev/null")}' ${WORKDATA}
log_msg "New IPv6 addresses added (old ones still active)"

sleep 2

# STEP 2: Regenerate 3proxy config with NEW IPs
log_msg "Step 2/4: Regenerating config..."
cat > /usr/local/etc/3proxy/3proxy.cfg <<EOF
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

# STEP 3: Reload 3proxy config (NO RESTART - using HUP signal)
log_msg "Step 3/4: Reloading 3proxy config (no restart)..."
if pgrep 3proxy > /dev/null; then
    PROXY_PID=$(pgrep 3proxy)
    kill -HUP $PROXY_PID
    log_msg "Sent HUP signal to 3proxy (PID: $PROXY_PID)"
    sleep 2
    
    if pgrep 3proxy > /dev/null; then
        log_msg "✅ 3proxy reloaded successfully (still running)"
    else
        log_msg "⚠️ 3proxy died during reload, restarting..."
        ulimit -n 65536
        /usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
        sleep 3
        
        if pgrep 3proxy > /dev/null; then
            log_msg "✅ 3proxy restarted successfully"
        else
            log_msg "❌ ERROR: Failed to restart 3proxy"
            exit 1
        fi
    fi
else
    log_msg "⚠️ 3proxy not running, starting..."
    ulimit -n 65536
    /usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
    sleep 3
    
    if pgrep 3proxy > /dev/null; then
        log_msg "✅ 3proxy started successfully"
    else
        log_msg "❌ ERROR: Failed to start 3proxy"
        exit 1
    fi
fi

# STEP 4: Schedule cleanup of old IPs (async, after 30 seconds)
log_msg "Step 4/4: Scheduling cleanup of old IPv6 addresses (in 30s)..."
(
    sleep 30
    
    # Get current valid IPs from data.txt
    awk -F "/" '{print $5}' ${WORKDATA} > /tmp/valid_ips.txt
    
    # Remove IPs that are NOT in valid list
    ip -6 addr show eth0 | grep "inet6" | grep -v "fe80" | awk '{print $2}' | cut -d'/' -f1 | while read ip; do
        if ! grep -q "^${ip}$" /tmp/valid_ips.txt; then
            ip -6 addr del ${ip}/64 dev eth0 2>/dev/null
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Cleaned up old IP: $ip" >> ${LOGFILE}
        fi
    done
    
    rm -f /tmp/valid_ips.txt
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Cleanup completed" >> ${LOGFILE}
) &

CLEANUP_PID=$!
log_msg "Cleanup scheduled in background (PID: $CLEANUP_PID)"

# Verify everything is running
if pgrep 3proxy > /dev/null; then
    PROXY_COUNT=$(wc -l < $WORKDATA)
    PORT_COUNT=$(netstat -tlnp 2>/dev/null | grep 3proxy | wc -l)
    log_msg "✅ SUCCESS: Rotation completed with ZERO downtime"
    log_msg "   Active proxies: $PROXY_COUNT"
    log_msg "   Listening ports: $PORT_COUNT"
    log_msg "   3proxy PID: $(pgrep 3proxy)"
else
    log_msg "❌ ERROR: 3proxy not running after rotation!"
    exit 1
fi

log_msg "========== Rotation Completed Successfully =========="
echo ""
ROTEOF

    chmod +x /home/bkns/rotate_ipv6.sh
}

create_monitor_script() {
    cat > /home/bkns/monitor.sh << 'EOF'
#!/bin/bash
# Monitor script - checks every 3 minutes

if ! pgrep 3proxy > /dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: 3proxy not running, restarting..." >> /home/bkns/monitor.log
    ulimit -n 65536
    /usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
    sleep 3
    if pgrep 3proxy > /dev/null; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ 3proxy restarted successfully" >> /home/bkns/monitor.log
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ Failed to restart 3proxy" >> /home/bkns/monitor.log
    fi
fi
EOF
    chmod +x /home/bkns/monitor.sh
}

setup_cron_rotation() {
    echo "Setting up auto-rotation every 5 minutes..."
    
    # Remove existing rotation jobs
    crontab -l 2>/dev/null | grep -v "rotate_ipv6.sh" | grep -v "monitor.sh" | crontab - 2>/dev/null
    
    # Add rotation job (every 5 minutes)
    (crontab -l 2>/dev/null; echo "*/5 * * * * /home/bkns/rotate_ipv6.sh >> /home/bkns/rotate.log 2>&1") | crontab -
    
    # Add monitor job (every 3 minutes)
    (crontab -l 2>/dev/null; echo "*/3 * * * * /home/bkns/monitor.sh") | crontab -
    
    echo "✅ Cron jobs configured:"
    echo "   - IPv6 rotation: Every 5 minutes"
    echo "   - Health monitor: Every 3 minutes"
}

echo "======================================"
echo "  3PROXY - 50 PORTS - ROTATION 5MIN  "
echo "======================================"
echo ""

echo "[1/8] Installing 3proxy..."
install_3proxy

echo "[2/8] Setting up working directory..."
WORKDIR="/home/bkns"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p $WORKDIR && cd $WORKDIR

echo "[3/8] Detecting IP addresses..."
IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com 2>/dev/null | cut -f1-4 -d':')

if [ -z "$IP4" ]; then
    echo "ERROR: Cannot detect IPv4 address"
    exit 1
fi

if [ -z "$IP6" ]; then
    echo "WARNING: Cannot detect IPv6, trying alternative method..."
    IP6=$(ip -6 addr show eth0 | grep "inet6" | grep -v "fe80" | head -1 | awk '{print $2}' | cut -f1-4 -d':')
    if [ -z "$IP6" ]; then
        echo "ERROR: Cannot detect IPv6 address"
        exit 1
    fi
fi

echo "   IPv4: ${IP4}"
echo "   IPv6 Prefix: ${IP6}"

echo "[4/8] Generating proxy data (50 ports)..."
FIRST_PORT=10000
LAST_PORT=10049
TOTAL_PROXIES=50

gen_data > $WORKDIR/data.txt
echo "   Generated $TOTAL_PROXIES proxies (ports $FIRST_PORT-$LAST_PORT)"

echo "[5/8] Configuring IPv6 addresses..."
gen_ifconfig > $WORKDIR/boot_ifconfig.sh
chmod +x $WORKDIR/boot_ifconfig.sh
bash $WORKDIR/boot_ifconfig.sh
echo "   Added 50 IPv6 addresses to eth0"

echo "[6/8] Generating 3proxy configuration..."
gen_3proxy > /usr/local/etc/3proxy/3proxy.cfg

echo "[7/8] Setting up auto-start on boot..."
cat > /etc/rc.d/rc.local <<EOF
#!/bin/bash
bash ${WORKDIR}/boot_ifconfig.sh
ulimit -n 65536
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
EOF

chmod +x /etc/rc.d/rc.local
systemctl enable rc-local 2>/dev/null
systemctl start rc-local 2>/dev/null

echo "[8/8] Starting 3proxy..."
ulimit -n 65536
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
sleep 3

if pgrep 3proxy > /dev/null; then
    echo "✅ 3proxy started successfully (PID: $(pgrep 3proxy))"
else
    echo "⚠️  Warning: 3proxy may not have started properly"
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
rm -rf /root/setup.sh 2>/dev/null
rm -rf /root/3proxy-* 2>/dev/null
rm -rf 3proxy-0.8.13 2>/dev/null

echo ""
echo "======================================"
echo "✅ INSTALLATION COMPLETED"
echo "======================================"
echo ""
echo "📊 Configuration:"
echo "   Total Proxies: 50"
echo "   Port Range: 10000-10049"
echo "   IPv4: $IP4"
echo "   IPv6 Prefix: $IP6"
echo ""
echo "📁 Files:"
echo "   Proxy List: $WORKDIR/proxy.txt"
echo "   Rotation Log: $WORKDIR/rotate.log"
echo "   Monitor Log: $WORKDIR/monitor.log"
echo ""
echo "⚙️  Features:"
echo "   ✅ Zero-downtime rotation: Every 5 minutes"
echo "   ✅ Health monitoring: Every 3 minutes"
echo "   ✅ Auto-start on boot"
echo "   ✅ Graceful reload (no restart)"
echo ""
echo "🔧 Commands:"
echo "   View proxies: cat $WORKDIR/proxy.txt"
echo "   View log: tail -f $WORKDIR/rotate.log"
echo "   Manual rotation: bash $WORKDIR/rotate_ipv6.sh"
echo "   Check status: ps aux | grep 3proxy"
echo "   View cron: crontab -l"
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
echo "======================================"
echo "🎉 Proxy system ready!"
echo "======================================"
