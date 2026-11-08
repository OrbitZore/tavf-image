#!/bin/bash
# build-rootfs-ubuntu.sh <amd64|arm64> <out.ext4> [sizeMiB]
# Ubuntu 24.04 minimal + tavfd + 静态网络配置（CI/本地通用）
# CI: GitHub runner 自带 qemu-user-static + binfmt（arm64 全 bootstrap 免注册）
# 本地 arm64: 需 binfmt（用 --foreign + QEMU 第二阶段亦可，见 README）
set -euo pipefail
ARCH=${1:-amd64}
OUT=${2:-rootfs.ext4}
SIZE=${3:-1400}
SUITE=noble
DEB_ARCH=$([[ $ARCH == x86_64 ]] && echo amd64 || echo arm64)
MIRROR=$([[ $ARCH == x86_64 ]] && echo http://archive.ubuntu.com/ubuntu || echo http://ports.ubuntu.com/ubuntu-ports)
MNT=$(mktemp -d)
trap 'umount -R "$MNT" 2>/dev/null || true; rm -rf "$MNT"' EXIT

rm -f "$OUT"; truncate -s "${SIZE}M" "$OUT"
mkfs.ext4 -q -F -E nodiscard -L tavf-root "$OUT"
sudo mount -o loop "$OUT" "$MNT"

sudo debootstrap --variant=minbase --components=main,universe \
  --include=systemd,systemd-sysv,iproute2,kmod,udev,tzdata,locales,socat,openssl,lrzsz \
  --arch="$DEB_ARCH" "$SUITE" "$MNT" "$MIRROR"

# tavfd：双传输（有网 TCP / 无网 vsock）
sudo tee "$MNT/usr/local/bin/tavfd" >/dev/null <<'EOF'
#!/bin/sh
i=0; IP=""
while [ $i -lt 10 ]; do
  IP=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
  [ -n "$IP" ] && break
  sleep 2; i=$((i+1))
done
if [ -n "$IP" ] && [ -d /sys/class/net/enp0s6 -o -d /sys/class/net/eth0 ]; then
  echo "TAVF_IP=$IP" > /dev/hvc0 2>/dev/null || true
  exec /usr/bin/socat TCP-LISTEN:7300,reuseaddr,fork EXEC:'/sbin/agetty --autologin root --noissue -',pty,setsid,ctty,stderr
fi
exec /usr/bin/socat VSOCK-LISTEN:7300,reuseaddr,fork EXEC:'/sbin/agetty --autologin root --noissue -',pty,setsid,ctty,stderr
EOF
sudo chmod +x "$MNT/usr/local/bin/tavfd"
sudo tee "$MNT/etc/systemd/system/tavfd.service" >/dev/null <<'EOF'
[Unit]
Description=termux-avf pty relay
[Service]
ExecStart=/usr/local/bin/tavfd
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF
sudo mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants"
sudo ln -sf /etc/systemd/system/tavfd.service "$MNT/etc/systemd/system/multi-user.target.wants/tavfd.service"

# hvc0 autologin
sudo mkdir -p "$MNT/etc/systemd/system/getty@hvc0.service.d"
sudo tee "$MNT/etc/systemd/system/getty@hvc0.service.d/autologin.conf" >/dev/null <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear hvc0 115200 $TERM
EOF
sudo mkdir -p "$MNT/etc/systemd/system/getty.target.wants"
sudo ln -sf /lib/systemd/system/getty@.service "$MNT/etc/systemd/system/getty.target.wants/getty@hvc0.service"

# 静态网络（AVF 固定网段）+ udevd（networkd 依赖 udev 初始化链路）
sudo mkdir -p "$MNT/etc/systemd/network"
sudo tee "$MNT/etc/systemd/network/10-eth.network" >/dev/null <<'EOF'
[Match]
Name=en* eth*
[Network]
Address=10.20.195.50/24
Gateway=10.20.195.248
DNS=10.20.195.248
EOF
for u in systemd-networkd.service systemd-udevd.service systemd-udev-trigger.service systemd-networkd.socket systemd-resolved.service; do
  sudo ln -sf /lib/systemd/system/$u "$MNT/etc/systemd/system/sysinit.target.wants/$u"
done
sudo ln -sf ../run/systemd/resolve/stub-resolv.conf "$MNT/etc/resolv.conf"
sudo tee "$MNT/etc/hostname" >/dev/null <<< tavf
# Truncate machine-id so each guest generates its own on first boot.
# The old `sudo : > "$MNT/..."` redirected as the *unprivileged* caller, and the
# `|| sudo sh -c ': > "$MNT/..."'` fallback never expanded $MNT inside single
# quotes, so it wrote a literal `$MNT/etc/machine-id` instead.
printf '' | sudo tee "$MNT/etc/machine-id" >/dev/null

sudo umount -R "$MNT"
echo "built: $OUT ($(du -h "$OUT" | cut -f1))"
