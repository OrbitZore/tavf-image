#!/bin/bash
# build-rootfs-archarm.sh <out.ext4> [sizeMiB]
# Arch Linux ARM minimal + tavfd（pacman 与上游 archlinuxarm.org 兼容）
set -euo pipefail
OUT=${1:-archarm-rootfs.ext4}
SIZE=${2:-1400}
TARBALL_URL=${ALARM_URL:-http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz}
MNT=$(mktemp -d)
DL=$(mktemp -d)
trap 'umount -R "$MNT" 2>/dev/null || true; rm -rf "$MNT" "$DL"' EXIT

rm -f "$OUT"; truncate -s "${SIZE}M" "$OUT"
mkfs.ext4 -q -F -E nodiscard -L tavf-root "$OUT"
sudo mount -o loop "$OUT" "$MNT"

echo "downloading ALA rootfs..."
curl -fL --retry 3 -o "$DL/ala.tar.gz" "$TARBALL_URL"
# bsdtar 保留设备节点/special files；ALA tarball 自带已初始化的 pacman keyring
sudo bsdtar -xpf "$DL/ala.tar.gz" -C "$MNT"

# 网络：systemd-networkd 静态（AVF 固定网段）+ DHCP 兜底关闭
sudo tee "$MNT/etc/systemd/network/10-eth.network" >/dev/null <<'EOF'
[Match]
Name=en* eth*
[Network]
Address=10.20.195.50/24
Gateway=10.20.195.248
DNS=10.20.195.248
EOF
sudo mkdir -p "$MNT/etc/systemd/system/sysinit.target.wants"
for u in systemd-networkd.service systemd-networkd.socket systemd-resolved.service; do
  sudo ln -sf /usr/lib/systemd/system/$u "$MNT/etc/systemd/system/sysinit.target.wants/$u"
done
sudo ln -sf ../run/systemd/resolve/stub-resolv.conf "$MNT/etc/resolv.conf"

# socat（tavfd 依赖）：chroot + qemu binfmt（CI runner 预配置）
if command -v qemu-aarch64-static >/dev/null 2>&1; then
  sudo cp /usr/bin/qemu-aarch64-static "$MNT/usr/bin/" 2>/dev/null || true
  sudo systemctl start systemd-binfmt 2>/dev/null || true
  sudo chroot "$MNT" /usr/bin/pacman -Sy --noconfirm --needed socat 2>&1 | tail -2 || true
  sudo rm -f "$MNT/usr/bin/qemu-aarch64-static"
else
  echo "WARN: no qemu-aarch64-static — socat 需首次 boot 后 pacman 安装"
fi

# tavfd：vsock + TCP 双监听（有网 TCP / 无网 vsock）
sudo tee "$MNT/usr/local/bin/tavfd" >/dev/null <<'EOF'
#!/bin/bash
i=0; IP=""
while [ $i -lt 10 ]; do
  IP=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
  [ -n "$IP" ] && break
  sleep 2; i=$((i+1))
done
[ -n "$IP" ] && echo "TAVF_IP=$IP" > /dev/hvc0 2>/dev/null
if [ -d /sys/class/net/enp0s6 ] || [ -d /sys/class/net/eth0 ]; then
  /usr/bin/socat TCP-LISTEN:7300,reuseaddr,fork EXEC:'/sbin/agetty --autologin root --noissue -',pty,setsid,ctty,stderr &
else
  /usr/bin/socat VSOCK-LISTEN:7300,reuseaddr,fork EXEC:'/sbin/agetty --autologin root --noissue -',pty,setsid,ctty,stderr &
fi
wait
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
sudo ln -sf /etc/systemd/system/tavfd.service "$MNT/etc/systemd/system/multi-user.target.wants/tavfd.service"

# hvc0 autologin（ALA 默认未启用 getty@hvc0）
sudo mkdir -p "$MNT/etc/systemd/system/getty@hvc0.service.d"
sudo tee "$MNT/etc/systemd/system/getty@hvc0.service.d/autologin.conf" >/dev/null <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear hvc0 115200 $TERM
EOF
sudo ln -sf /usr/lib/systemd/system/getty@.service "$MNT/etc/systemd/system/getty.target.wants/getty@hvc0.service"
sudo tee "$MNT/etc/hostname" >/dev/null <<< tavf

sudo umount -R "$MNT"
echo "built: $OUT ($(du -h "$OUT" | cut -f1))"
