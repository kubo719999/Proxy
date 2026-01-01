cat > /home/bkns/emergency_cleanup.sh << 'EOF'
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

LOGFILE="/home/bkns/emergency_cleanup.log"
CURRENT_IPS="/home/bkns/data.txt"

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $LOGFILE
}

log_msg "========== EMERGENCY CLEANUP =========="

[ ! -f "$CURRENT_IPS" ] && log_msg "ERROR: data.txt not found" && exit 1

awk -F "/" '{print $5}' $CURRENT_IPS | sort > /tmp/keep_current.txt

BEFORE=$(ip -6 addr show eth0 | grep -c 'inet6.*scope global')

if [ "$BEFORE" -lt 150 ]; then
    log_msg "IP count normal ($BEFORE)"
    rm -f /tmp/keep_current.txt
    exit 0
fi

log_msg "WARNING: $BEFORE IPs - cleanup needed"

ip -6 addr show eth0 | grep 'inet6.*scope global' | awk '{print $2}' | cut -d'/' -f1 | sort > /tmp/all_current.txt

DELETED=0
while IFS= read -r ip; do
    if ! grep -Fxq "$ip" /tmp/keep_current.txt; then
        ip -6 addr del ${ip}/64 dev eth0 2>/dev/null && DELETED=$((DELETED + 1))
    fi
done < /tmp/all_current.txt

rm -f /tmp/keep_current.txt /tmp/all_current.txt

AFTER=$(ip -6 addr show eth0 | grep -c 'inet6.*scope global')

log_msg "Done: Before=$BEFORE After=$AFTER Deleted=$DELETED"

if ! pgrep 3proxy > /dev/null; then
    ulimit -n 65536
    /usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
    sleep 3
    log_msg "3proxy restarted (PID: $(pgrep 3proxy))"
fi
EOF

chmod +x /home/bkns/emergency_cleanup.sh
