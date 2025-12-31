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

# Logging function
log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $LOGFILE
}

array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
    ip64() {
        echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }
    echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

log_msg "========== Starting IPv6 Rotation =========="

# Get current IPv6 prefix with timeout
IP6=$(timeout 10 curl -6 -s icanhazip.com 2>/dev/null | cut -f1-4 -d':')
if [ -z "$IP6" ]; then
    log_msg "ERROR: Cannot get IPv6 prefix, aborting rotation"
    exit 1
fi

log_msg "IPv6 Prefix: $IP6"

# Backup current data
cp $WORKDATA ${WORKDATA}.backup
log_msg "Backup created: ${WORKDATA}.backup"

# Generate new data with rotated IPv6 (keep username/password/IP4/port)
awk -v ip6="$IP6" -F "/" '{
    # Generate random IPv6 suffix
    cmd = "export LC_ALL=C; array=(1 2 3 4 5 6 7 8 9 0 a b c d e f); printf \"%s:%s%s%s%s:%s%s%s%s:%s%s%s%s:%s%s%s%s\" \"" ip6 "\" \"${array[$RANDOM % 16]}\" \"${array[$RANDOM % 16]}\" \"${array[$RANDOM % 16]}\" \"${array[$RANDOM % 16]}\" \"${array[$RANDOM % 16]}\" \"${array[$RANDOM % 16]}\" \"${array[$RANDOM % 16]}\" \"${array[$RANDOM % 16]}\" \"${array[$RANDOM % 16]}\" \"${array[$RANDOM % 16]}\" \"${array[$RANDOM % 16]}\" \"${array[$RANDOM % 16]}\" \"${array[$RANDOM % 16]}\" \"${array[$RANDOM % 16]}\" \"${array[$RANDOM % 16]}\" \"${array[$RANDOM % 16]}\"";
    cmd | getline newipv6;
    close(cmd);
    print $1 "/" $2 "/" $3 "/" $4 "/" newipv6;
}' $WORKDATA > ${WORKDATA}.tmp

# Validate new data file
if [ ! -s ${WORKDATA}.tmp ]; then
    log_msg "ERROR: Failed to generate new data file!"
    rm -f ${WORKDATA}.tmp
    exit 1
fi

LINES=$(wc -l < ${WORKDATA}.tmp)
log_msg "Generated $LINES new proxy entries"

# Replace data file
mv ${WORKDATA}.tmp $WORKDATA

# Clear old IPv6 addresses (keep link-local)
log_msg "Removing old IPv6 addresses..."
ip -6 addr show eth0 | grep "inet6" | grep -v "fe80" | grep -v "::1/128" | awk '{print $2}' | while read addr; do
    ip -6 addr del $addr dev eth0 2>/dev/null
done

sleep 2

# Add new IPv6 addresses
log_msg "Adding new IPv6 addresses..."
IPV6_COUNT=0
awk -F "/" '{print $5}' ${WORKDATA} | while read ipv6; do
    if ip -6 addr add $ipv6/64 dev eth0 2>/dev/null; then
        IPV6_COUNT=$((IPV6_COUNT + 1))
    fi
done
log_msg "Added new IPv6 addresses to eth0"

# Regenerate 3proxy config
log_msg "Regenerating 3proxy configuration..."
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

# Stop 3proxy gracefully
log_msg "Stopping 3proxy..."
if pgrep 3proxy > /dev/null; then
    pkill 3proxy
    sleep 2
    # Force kill if still running
    if pgrep 3proxy > /dev/null; then
        pkill -9 3proxy
        sleep 1
    fi
fi

# Verify 3proxy stopped
if pgrep 3proxy > /dev/null; then
    log_msg "WARNING: 3proxy still running, force killing..."
    killall -9 3proxy 2>/dev/null
    sleep 2
fi

# Start 3proxy with increased limits
log_msg "Starting 3proxy..."
ulimit -n 65536
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
PROXY_PID=$!

sleep 3

# Verify 3proxy started successfully
if pgrep 3proxy > /dev/null; then
    PROXY_COUNT=$(wc -l < $WORKDATA)
    PORT_COUNT=$(netstat -tlnp 2>/dev/null | grep 3proxy | wc -l)
    log_msg "✅ SUCCESS: 3proxy started (PID: $(pgrep 3proxy))"
    log_msg "Total proxies: $PROXY_COUNT | Listening ports: $PORT_COUNT"
else
    log_msg "❌ ERROR: 3proxy failed to start!"
    log_msg "Attempting recovery with backup..."
    
    # Restore backup
    if [ -f ${WORKDATA}.backup ]; then
        cp ${WORKDATA}.backup $WORKDATA
        log_msg "Backup restored, restarting 3proxy..."
        
        # Regenerate config with backup
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
        
        ulimit -n 65536
        /usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
        sleep 3
        
        if pgrep 3proxy > /dev/null; then
            log_msg "✅ Recovery successful"
        else
            log_msg "❌ Recovery failed - manual intervention required"
            exit 1
        fi
    else
        log_msg "❌ No backup found - manual intervention required"
        exit 1
    fi
fi

log_msg "========== Rotation Completed =========="
echo ""
ROTEOF

    chmod +x /home/bkns/rotate_ipv6.sh
}

create_system_service() {
    cat > /etc/systemd/system/3proxy.service << 'EOF'
[Unit]
Description=3proxy Proxy Server
After=network.target

[Service]
Type=forking
PIDFile=/var/run/3proxy.pid
ExecStartPre=/bin/sleep 5
ExecStartPre=/bin/bash /home/bkns/boot_ifconfig.sh
ExecStart=/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
Restart=on-failure
RestartSec=10s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable 3proxy.service
}

setup_cron_rotation() {
    echo "Setting up auto-rotation every 10 minutes..."
    
    # Remove existing cron job if any
    crontab -l 2>/dev/null | grep -v "rotate_ipv6.sh" | crontab - 2>/dev/null
    
    # Add new cron job
    (crontab -l 2>/dev/null; echo "*/10 * * * * /home/bkns/rotate_ipv6.sh >> /home/bkns/rotate.log 2>&1") | crontab -
    
    echo "✅ Cron job added: IPv6 will rotate every 10 minutes"
}

create_monitor_script() {
    cat > /home/bkns/monitor.sh << 'EOF'
#!/bin/bash
# Monitor script to check if 3proxy is running

if ! pgrep 3proxy > /dev/null; then
    echo "[$(date)] WARNING: 3proxy not running, restarting..." >> /home/bkns/monitor.log
    ulimit -n 65536
    /usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
    sleep 3
    if pgrep 3proxy > /dev/null; then
        echo "[$(date)] 3proxy restarted successfully" >> /home/bkns/monitor.log
    else
        echo "[$(date)] Failed to restart 3proxy" >> /home/bkns/monitor.log
    fi
fi
EOF
    chmod +x /home/bkns/monitor.sh
    
    # Add monitor to cron (every 5 minutes)
    (crontab -l 2>/dev/null | grep -v "monitor.sh"; echo "*/5 * * * * /home/bkns/monitor.sh") | crontab -
}

echo "======================================"
echo "  3PROXY AUTO-ROTATE IPv6 INSTALLER  "
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
IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')

if [ -z "$IP4" ]; then
    echo "ERROR: Cannot detect IPv4 address"
    exit 1
fi

if [ -z "$IP6" ]; then
    echo "ERROR: Cannot detect IPv6 address"
    exit 1
fi

echo "   IPv4: ${IP4}"
echo "   IPv6 Prefix: ${IP6}"

echo "[4/8] Generating proxy data..."
FIRST_PORT=22001
LAST_PORT=22050
TOTAL_PROXIES=$((LAST_PORT - FIRST_PORT + 1))

gen_data > $WORKDIR/data.txt
echo "   Generated $TOTAL_PROXIES proxies (ports $FIRST_PORT-$LAST_PORT)"

echo "[5/8] Configuring IPv6 addresses..."
gen_ifconfig > $WORKDIR/boot_ifconfig.sh
chmod +x $WORKDIR/boot_ifconfig.sh
bash $WORKDIR/boot_ifconfig.sh

echo "[6/8] Generating 3proxy configuration..."
gen_3proxy > /usr/local/etc/3proxy/3proxy.cfg

echo "[7/8] Setting up auto-start..."
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
    echo "✅ 3proxy started successfully"
else
    echo "⚠️  Warning: 3proxy may not have started properly"
fi

echo ""
echo "Setting up rotation system..."
create_rotate_script
setup_cron_rotation
create_monitor_script

echo ""
echo "Generating proxy list..."
gen_proxy_file_for_user

# Cleanup
rm -rf /root/setup.sh 2>/dev/null
rm -rf /root/3proxy-3proxy-0.8.6 2>/dev/null
rm -rf 3proxy-0.8.13 2>/dev/null

echo ""
echo "======================================"
echo "✅ INSTALLATION COMPLETED SUCCESSFULLY"
echo "======================================"
echo ""
echo "📊 Configuration Summary:"
echo "   Total Proxies: $TOTAL_PROXIES"
echo "   Port Range: $FIRST_PORT - $LAST_PORT"
echo "   IPv4 Address: $IP4"
echo "   IPv6 Prefix: $IP6"
echo ""
echo "📁 Important Files:"
echo "   Proxy List: $WORKDIR/proxy.txt"
echo "   Data File: $WORKDIR/data.txt"
echo "   Rotation Log: $WORKDIR/rotate.log"
echo "   Monitor Log: $WORKDIR/monitor.log"
echo ""
echo "⚙️  Features:"
echo "   ✅ Auto-rotation: Every 10 minutes"
echo "   ✅ Auto-monitor: Every 5 minutes"
echo "   ✅ Auto-start on boot"
echo "   ✅ Backup & Recovery system"
echo ""
echo "🔧 Useful Commands:"
echo "   View proxy list: cat $WORKDIR/proxy.txt"
echo "   View rotation log: tail -f $WORKDIR/rotate.log"
echo "   Manual rotation: bash $WORKDIR/rotate_ipv6.sh"
echo "   Check status: ps aux | grep 3proxy"
echo "   View cron jobs: crontab -l"
echo ""
echo "🧪 Test your first proxy:"
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
