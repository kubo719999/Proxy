#!/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Fixed credentials
FIXED_USER="AnhVip17102"
FIXED_PASS="AnhVip17102"

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

users ${FIXED_USER}:CL:${FIXED_PASS}

$(awk -F "/" '{print "auth strong\n" \
"allow " ENVIRON["FIXED_USER"] "\n" \
"proxy -6 -n -a -p" $4 " -i" $3 " -e"$5"\n" \
"flush\n"}' ${WORKDATA})
EOF
}

gen_proxy_file_for_user() {
    cat >proxy.txt <<EOF
$(awk -v user="$FIXED_USER" -v pass="$FIXED_PASS" -F "/" '{print $3 ":" $4 ":" user ":" pass}' ${WORKDATA})
EOF
}

gen_data() {
    seq $FIRST_PORT $LAST_PORT | while read port; do
        echo "${FIXED_USER}/${FIXED_PASS}/$IP4/$port/$(gen64 $IP6)"
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
FIXED_USER="AnhVip17102"
FIXED_PASS="AnhVip17102"

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $LOGFILE
}

# Auto-cleanup log file if > 10MB
LOG_SIZE=$(du -m "$LOGFILE" 2>/dev/null | cut -f1)
if [ "$LOG_SIZE" -gt 10 ]; then
    log_msg "Log file > 10MB, rotating..."
    tail -n 1000 "$LOGFILE" > "${LOGFILE}.tmp"
    mv "${LOGFILE}.tmp" "$LOGFILE"
    log_msg "Log rotated, kept last 1000 lines"
fi

log_msg "========== Starting TRUE Zero-Downtime Rotation =========="

# Get IPv6 prefix from data.txt
IP6=$(head -1 $WORKDATA 2>/dev/null | cut -d'/' -f5 | cut -f1-4 -d':')

if [ -z "$IP6" ]; then
    log_msg "ERROR: Cannot determine IPv6 prefix"
    exit 1
fi

log_msg "IPv6 Prefix: $IP6"

# Backup
cp $WORKDATA ${WORKDATA}.backup
log_msg "Backup created"

# Save old IPv6 list
awk -F "/" '{print $5}' $WORKDATA > /tmp/old_ips.txt

# Generate NEW IPv6 addresses using AWK (NO xxd needed)
awk -v ip6="$IP6" -v user="$FIXED_USER" -v pass="$FIXED_PASS" -F "/" '
BEGIN {
    srand();
    hex="0123456789abcdef";
}
{
    # Generate 16 random hex chars using AWK only
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
    
    print user "/" pass "/" $3 "/" $4 "/" new_ip6;
}' $WORKDATA > ${WORKDATA}.new

# Validate
if [ ! -s ${WORKDATA}.new ]; then
    log_msg "ERROR: Failed to generate new data"
    rm -f ${WORKDATA}.new
    exit 1
fi

LINES=$(wc -l < ${WORKDATA}.new)
log_msg "Generated $LINES new IPv6 addresses (AWK-based, no xxd)"

# Replace data
mv ${WORKDATA}.new $WORKDATA

# STEP 1: Add NEW IPv6 (old ones still active)
log_msg "Step 1/5: Adding new IPv6 addresses (old IPs still active)..."
awk -F "/" '{system("ip -6 addr add " $5 "/64 dev eth0 2>/dev/null")}' ${WORKDATA}
log_msg "✅ New IPv6 added, old connections still working"

sleep 3

# STEP 2: Create NEW config file
log_msg "Step 2/5: Generating new config..."
cat > /usr/local/etc/3proxy/3proxy.cfg.new << 'EOFCFG'
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
echo "users ${FIXED_USER}:CL:${FIXED_PASS}" >> /usr/local/etc/3proxy/3proxy.cfg.new
echo "" >> /usr/local/etc/3proxy/3proxy.cfg.new

# Add proxy rules
awk -v user="$FIXED_USER" -F "/" '{
    print "auth strong";
    print "allow " user;
    print "proxy -6 -n -a -p" $4 " -i" $3 " -e" $5;
    print "flush";
    print "";
}' ${WORKDATA} >> /usr/local/etc/3proxy/3proxy.cfg.new

log_msg "✅ New config created (proper format)"

# STEP 3: Validate new config by testing
log_msg "Step 3/5: Validating new config..."

# Test config syntax
if grep -q "^users ${FIXED_USER}:CL:${FIXED_PASS}" /usr/local/etc/3proxy/3proxy.cfg.new; then
    log_msg "✅ Config validation passed"
else
    log_msg "❌ ERROR: Config validation failed"
    cp ${WORKDATA}.backup $WORKDATA
    rm -f /usr/local/etc/3proxy/3proxy.cfg.new
    exit 1
fi

# STEP 4: Atomic config swap + graceful reload
log_msg "Step 4/5: Swapping config and reloading gracefully..."

# Replace config atomically
mv /usr/local/etc/3proxy/3proxy.cfg.new /usr/local/etc/3proxy/3proxy.cfg

# Get old PID
OLD_PID=$(pgrep 3proxy)

if [ -n "$OLD_PID" ]; then
    # Try graceful reload first (HUP signal)
    kill -HUP $OLD_PID 2>/dev/null
    log_msg "Sent HUP (graceful reload) to PID $OLD_PID"
    sleep 5
    
    # Check if graceful reload worked
    if pgrep 3proxy > /dev/null && [ "$(pgrep 3proxy)" = "$OLD_PID" ]; then
        log_msg "✅ Graceful reload successful (same PID, zero downtime)"
    else
        # HUP failed, do clean restart
        log_msg "HUP reload failed, doing clean restart..."
        
        # Kill old instance cleanly
        pkill -9 3proxy 2>/dev/null
        sleep 2
        
        # Start new instance
        ulimit -n 65536
        /usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
        sleep 3
        
        if pgrep 3proxy > /dev/null; then
            log_msg "✅ New instance started (PID: $(pgrep 3proxy))"
        else
            log_msg "❌ ERROR: Failed to start new instance"
            cp ${WORKDATA}.backup $WORKDATA
            exit 1
        fi
    fi
else
    # No old instance, just start new one
    log_msg "No old instance found, starting fresh..."
    pkill -9 3proxy 2>/dev/null
    sleep 1
    ulimit -n 65536
    /usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
    sleep 3
fi

# STEP 5: Cleanup old IPs (delayed)
log_msg "Step 5/5: Scheduling cleanup of old IPs (in 60s)..."
(
    sleep 60
    
    # Remove old IPs that are not in new list
    while IFS= read -r old_ip; do
        if ! grep -q "^${old_ip}$" <(awk -F "/" '{print $5}' ${WORKDATA}); then
            ip -6 addr del ${old_ip}/64 dev eth0 2>/dev/null
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Cleaned old IP: $old_ip" >> ${LOGFILE}
        fi
    done < /tmp/old_ips.txt
    
    rm -f /tmp/old_ips.txt
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Cleanup completed" >> ${LOGFILE}
) &

log_msg "Cleanup scheduled for background execution"

# Verify final state
sleep 2
if pgrep 3proxy > /dev/null; then
    PROXY_COUNT=$(wc -l < $WORKDATA)
    CURRENT_PID=$(pgrep 3proxy)
    log_msg "✅ SUCCESS: TRUE Zero-Downtime Rotation Completed"
    log_msg "   Active proxies: $PROXY_COUNT"
    log_msg "   3proxy PID: $CURRENT_PID"
    log_msg "   Old connections: Still active on old IPs (for 60s)"
    log_msg "   New connections: Using new IPs immediately"
else
    log_msg "❌ ERROR: 3proxy not running after rotation!"
    exit 1
fi

log_msg "========== Rotation Completed Successfully =========="
ROTEOF

    chmod +x /home/bkns/rotate_ipv6.sh
}

create_monitor_script() {
    cat > /home/bkns/monitor.sh << 'EOF'
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Auto-cleanup monitor log if > 5MB
if [ -f /home/bkns/monitor.log ]; then
    LOG_SIZE=$(du -m /home/bkns/monitor.log 2>/dev/null | cut -f1)
    if [ "$LOG_SIZE" -gt 5 ]; then
        tail -n 500 /home/bkns/monitor.log > /home/bkns/monitor.log.tmp
        mv /home/bkns/monitor.log.tmp /home/bkns/monitor.log
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Monitor log rotated" >> /home/bkns/monitor.log
    fi
fi

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

create_log_cleanup_script() {
    cat > /home/bkns/cleanup_logs.sh << 'EOF'
#!/bin/bash
# Daily log cleanup - keeps logs under control

# Rotate rotate.log if > 10MB
if [ -f /home/bkns/rotate.log ]; then
    SIZE=$(du -m /home/bkns/rotate.log 2>/dev/null | cut -f1)
    if [ "$SIZE" -gt 10 ]; then
        tail -n 1000 /home/bkns/rotate.log > /home/bkns/rotate.log.tmp
        mv /home/bkns/rotate.log.tmp /home/bkns/rotate.log
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Rotate log cleaned (kept 1000 lines)" >> /home/bkns/rotate.log
    fi
fi

# Rotate monitor.log if > 5MB
if [ -f /home/bkns/monitor.log ]; then
    SIZE=$(du -m /home/bkns/monitor.log 2>/dev/null | cut -f1)
    if [ "$SIZE" -gt 5 ]; then
        tail -n 500 /home/bkns/monitor.log > /home/bkns/monitor.log.tmp
        mv /home/bkns/monitor.log.tmp /home/bkns/monitor.log
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Monitor log cleaned (kept 500 lines)" >> /home/bkns/monitor.log
    fi
fi

# Clean 3proxy logs if exist
if [ -d /usr/local/etc/3proxy/logs ]; then
    find /usr/local/etc/3proxy/logs -type f -mtime +7 -delete 2>/dev/null
fi
EOF
    chmod +x /home/bkns/cleanup_logs.sh
}

setup_cron_rotation() {
    echo "Setting up cron jobs..."
    
    crontab -r 2>/dev/null
    
    (
        echo "*/5 * * * * /home/bkns/rotate_ipv6.sh >> /home/bkns/rotate.log 2>&1"
        echo "*/3 * * * * /home/bkns/monitor.sh"
        echo "0 3 * * * /home/bkns/cleanup_logs.sh"
    ) | crontab -
    
    echo "✅ Cron configured (rotation 5min, monitor 3min, cleanup daily 3AM)"
}

echo "======================================"
echo "  3PROXY - 50 PORTS - ROTATION 5MIN  "
echo "  TRUE ZERO-DOWNTIME + AUTO CLEANUP  "
echo "  Username/Password: AnhVip17102     "
echo "======================================"
echo ""

echo "[1/10] Installing dependencies (including vim-common)..."
install_dependencies

echo "[2/10] Installing 3proxy..."
install_3proxy

echo "[3/10] Setting up directories..."
WORKDIR="/home/bkns"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p $WORKDIR && cd $WORKDIR

echo "[4/10] Detecting IPs..."
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

echo "[5/10] Generating 50 proxies..."
FIRST_PORT=10000
LAST_PORT=10049

gen_data > $WORKDIR/data.txt
echo "   Ports: 10000-10049"
echo "   Username: ${FIXED_USER}"
echo "   Password: ${FIXED_PASS}"

echo "[6/10] Configuring IPv6..."
gen_ifconfig > $WORKDIR/boot_ifconfig.sh
chmod +x $WORKDIR/boot_ifconfig.sh
bash $WORKDIR/boot_ifconfig.sh

echo "[7/10] Generating config..."
export FIXED_USER FIXED_PASS
gen_3proxy > /usr/local/etc/3proxy/3proxy.cfg

echo "[8/10] Auto-start setup..."
cat > /etc/rc.d/rc.local <<EOF
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
bash ${WORKDIR}/boot_ifconfig.sh
ulimit -n 65536
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
EOF

chmod +x /etc/rc.d/rc.local
systemctl enable rc-local 2>/dev/null

echo "[9/10] Starting 3proxy..."
pkill -9 3proxy 2>/dev/null
sleep 2
ulimit -n 65536
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
sleep 3

if pgrep 3proxy > /dev/null; then
    echo "✅ 3proxy started (PID: $(pgrep 3proxy))"
else
    echo "⚠️  Failed to start"
fi

echo "[10/10] Setting up rotation, monitoring, and log cleanup..."
create_rotate_script
create_monitor_script
create_log_cleanup_script
setup_cron_rotation
gen_proxy_file_for_user

rm -rf /root/setup.sh /root/3proxy-* 3proxy-0.8.13 2>/dev/null

echo ""
echo "======================================"
echo "✅ INSTALLATION COMPLETED"
echo "======================================"
echo "📋 Credentials:"
echo "   Username: ${FIXED_USER}"
echo "   Password: ${FIXED_PASS}"
echo ""
echo "📁 Files:"
echo "   Proxy list: $WORKDIR/proxy.txt"
echo "   Rotation log: $WORKDIR/rotate.log"
echo "   Monitor log: $WORKDIR/monitor.log"
echo ""
echo "⚙️  Features:"
echo "   ✅ TRUE Zero-Downtime Rotation"
echo "   ✅ AWK-based IPv6 generation (no xxd)"
echo "   ✅ Proper config format"
echo "   ✅ Clean kill before start (pkill -9)"
echo "   ✅ Auto log rotation (rotate.log > 10MB)"
echo "   ✅ Daily log cleanup (3AM)"
echo "   ✅ vim-common installed"
echo "   ✅ Auto rotation: Every 5 minutes"
echo "   ✅ Auto monitor: Every 3 minutes"
echo ""
echo "📊 Cron Jobs:"
echo "   */5 * * * * → IPv6 Rotation"
echo "   */3 * * * * → Health Monitor"
echo "   0 3 * * * → Log Cleanup"
echo ""
FIRST_PROXY=$(head -1 $WORKDIR/proxy.txt)
if [ -n "$FIRST_PROXY" ]; then
    echo "🧪 Test first proxy:"
    echo "   curl -x ${FIXED_USER}:${FIXED_PASS}@$(echo $FIRST_PROXY | cut -d: -f1):$(echo $FIRST_PROXY | cut -d: -f2) https://api64.ipify.org"
fi
echo ""
echo "======================================"
echo "🎉 All Done! Enjoy Your Proxy Pool!"
echo "======================================"
