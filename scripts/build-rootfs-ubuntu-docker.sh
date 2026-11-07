#!/bin/bash
# build-rootfs-ubuntu-docker.sh <amd64|arm64> <out.ext4>
# Docker --platform 方式构建 Ubuntu rootfs（CI runner 原生支持，免 debootstrap/binfmt）
set -euo pipefail
DEB_ARCH=${1:-amd64}
OUT=${2:-rootfs.ext4}
SIZE=${SIZE:-${3:-1400}}
QARCH=$([[ $DEB_ARCH == amd64 ]] && echo amd64 || echo arm64)

echo "pulling ubuntu:24.04 for $QARCH..."
docker pull --platform "linux/$QARCH" ubuntu:24.04 >/dev/null

docker rm -f tavf-rfs >/dev/null 2>&1 || true
docker run -d --name tavf-rfs --platform "linux/$QARCH" ubuntu:24.04 sleep infinity >/dev/null

echo "installing systemd + tools..."
docker exec tavf-rfs bash -c '
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    systemd systemd-sysv iproute2 kmod udev tzdata locales \
    socat openssl lrzsz systemd-resolved >/dev/null
  echo tavf > /etc/hostname
  mkdir -p /etc/systemd/system/sockets.target.wants /etc/systemd/system/multi-user.target.wants
  printf 'nameserver 10.1.4.1\n' > /etc/resolv.conf
  mkdir -p /etc/systemd/system/getty@hvc0.service.d
  printf "[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin root --noclear hvc0 115200 \$TERM\n" \
    > /etc/systemd/system/getty@hvc0.service.d/autologin.conf
  mkdir -p /etc/systemd/system/getty.target.wants
  ln -sf /lib/systemd/system/getty@.service /etc/systemd/system/getty.target.wants/getty@hvc0.service
  ln -sf /lib/systemd/system/systemd-networkd.service /etc/systemd/system/multi-user.target.wants/systemd-networkd.service
  ln -sf /lib/systemd/system/systemd-udevd.service /etc/systemd/system/multi-user.target.wants/systemd-udevd.service
  ln -sf /lib/systemd/system/systemd-networkd.socket /etc/systemd/system/sockets.target.wants/systemd-networkd.socket
  # ---- tavfd: pty 中继（框架必需；guest 在 console 公告 TAVF_IP）----
  mkdir -p /usr/local/bin
  cat > /usr/local/bin/tavfd <<"EOF"
#!/bin/bash
i=0; IP=""
while [ $i -lt 20 ]; do
  IP=$(ip -4 -o addr show scope global 2>/dev/null | awk "{print \$4}" | cut -d/ -f1 | grep -v "^169\.254\." | head -1)
  [ -n "$IP" ] && break; sleep 2; i=$((i+1))
done
echo "TAVF_IP=${IP:-none}" > /dev/hvc0 2>/dev/null
exec /usr/bin/socat TCP-LISTEN:7300,reuseaddr,fork EXEC:"/sbin/agetty --autologin root --noissue -",pty,setsid,ctty,stderr
EOF
  chmod +x /usr/local/bin/tavfd
  cat > /etc/systemd/system/tavfd.service <<"EOF"
[Unit]
Description=termux-avf pty relay
After=network.target
[Service]
ExecStart=/usr/local/bin/tavfd
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF
  mkdir -p /etc/systemd/system/multi-user.target.wants
  ln -sf /etc/systemd/system/tavfd.service /etc/systemd/system/multi-user.target.wants/tavfd.service
'

echo "exporting rootfs tar..."
docker export tavf-rfs -o /tmp/tavf-rootfs.tar
docker rm -f tavf-rfs >/dev/null

echo "populating ext4 ($SIZE MiB)..."
rm -f "$OUT"; truncate -s "${SIZE}M" "$OUT"
EXTRACT=$(mktemp -d)
tar -xf /tmp/tavf-rootfs.tar -C "$EXTRACT"
mkfs.ext4 -q -F -E nodiscard -d "$EXTRACT" -L tavf-root "$OUT"
rm -rf "$EXTRACT" /tmp/tavf-rootfs.tar
echo "built: $OUT ($(du -h "$OUT" | cut -f1))"
