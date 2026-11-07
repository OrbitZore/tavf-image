#!/bin/bash
# termux-avf pty relay（框架必需）：在 console 公告本机 IP，然后在 7300 提供 pty
i=0; IP=""
while [ $i -lt 20 ]; do
  IP=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -v '^169\.254\.' | head -1)
  [ -n "$IP" ] && break
  sleep 2; i=$((i+1))
done
echo "TAVF_IP=${IP:-none}" > /dev/hvc0 2>/dev/null
exec /usr/bin/socat TCP-LISTEN:7300,reuseaddr,fork EXEC:'/sbin/agetty --autologin root --noissue -',pty,setsid,ctty,stderr
