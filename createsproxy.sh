# 1. Tạo proxy.txt
awk -F "/" '{print $3":"$4":AnhVip17102:AnhVip17102"}' /home/bkns/data.txt > /home/bkns/proxy.txt

echo "Created proxy.txt: $(wc -l < /home/bkns/proxy.txt) lines"

# 2. Tạo 3proxy config
cat > /usr/local/etc/3proxy/3proxy.cfg << 'EOFCFG'
daemon
maxconn 2000
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

users AnhVip17102:CL:AnhVip17102

EOFCFG

awk -F "/" '{print "auth strong\nallow AnhVip17102\nproxy -6 -n -a -p" $4 " -i" $3 " -e" $5 "\nflush"}' /home/bkns/data.txt >> /usr/local/etc/3proxy/3proxy.cfg

echo "Created 3proxy config"

# 3. Start 3proxy
pkill -9 3proxy 2>/dev/null
sleep 2
ulimit -n 65536
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
sleep 3

# 4. Verify
echo ""
echo "=== FINAL STATUS ==="
echo "Proxies: $(wc -l < /home/bkns/data.txt)"
echo "IPs: $(ip -6 addr show eth0 | grep -c 'inet6.*scope global')"
echo "3proxy PID: $(pgrep 3proxy || echo 'FAILED TO START')"
echo "Proxy file: $(wc -l < /home/bkns/proxy.txt 2>/dev/null || echo '0') lines"

# 5. Test proxy
echo ""
echo "=== TESTING FIRST PROXY ==="
FIRST=$(head -1 /home/bkns/proxy.txt)
IP=$(echo $FIRST | cut -d: -f1)
PORT=$(echo $FIRST | cut -d: -f2)
echo "Proxy: $IP:$PORT"
echo "Result:"
curl -x AnhVip17102:AnhVip17102@${IP}:${PORT} https://api64.ipify.org
echo ""

# 6. Enable cron
crontab -r 2>/dev/null
(
    echo "*/10 * * * * /home/bkns/rotate_ipv6.sh >> /home/bkns/rotate.log 2>&1"
    echo "*/3 * * * * /home/bkns/monitor.sh"
    echo "0 3 * * * /home/bkns/cleanup_logs.sh"
    echo "0 */6 * * * /home/bkns/emergency_cleanup.sh >> /home/bkns/emergency_cleanup.log 2>&1"
) | crontab -

echo ""
echo "✅ SETUP COMPLETED!"
echo ""
echo "View proxy list:"
echo "  cat /home/bkns/proxy.txt"
echo ""
echo "Monitor rotation:"
echo "  tail -f /home/bkns/rotate.log"
```

---

## ✅ KẾT QUẢ MONG ĐỢI:
```
Created proxy.txt: 50 lines
Created 3proxy config

=== FINAL STATUS ===
Proxies: 50
IPs: 50
3proxy PID: 12345
Proxy file: 50 lines

=== TESTING FIRST PROXY ===
Proxy: 42.96.12.130:10000
Result:
2403:6a40:0:12:xxxx:xxxx:xxxx:xxxx

✅ SETUP COMPLETED!
