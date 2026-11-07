#!/bin/bash
# build-rootfs-ubuntu-docker.sh <amd64|arm64> <out.ext4> [sizeMiB]
# Ubuntu 基础系统 rootfs（CI/本地通用）：容器里装基础包 + 注入 tavfd，导出为 ext4
set -euo pipefail
DEB_ARCH=${1:-amd64}
OUT=${2:-rootfs.ext4}
SIZE=${SIZE:-${3:-1400}}
QARCH=$([[ $DEB_ARCH == amd64 ]] && echo amd64 || echo arm64)
HERE=$(cd "$(dirname "$0")" && pwd)

echo "pulling ubuntu:24.04 for $QARCH..."
docker pull --platform "linux/$QARCH" ubuntu:24.04 >/dev/null

docker rm -f tavf-rfs >/dev/null 2>&1 || true
docker run -d --name tavf-rfs --platform "linux/$QARCH" ubuntu:24.04 sleep infinity >/dev/null

echo "installing base system..."
docker exec tavf-rfs bash -c '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends \
    systemd systemd-sysv iproute2 kmod udev tzdata locales \
    socat openssl lrzsz systemd-resolved >/dev/null
  echo tavf > /etc/hostname
  printf "nameserver 10.1.4.1\n" > /etc/resolv.conf
  mkdir -p /etc/systemd/system/getty@hvc0.service.d /etc/systemd/system/getty.target.wants
  printf "[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin root --noclear hvc0 115200 \$TERM\n" \
    > /etc/systemd/system/getty@hvc0.service.d/autologin.conf
  ln -sf /lib/systemd/system/getty@.service /etc/systemd/system/getty.target.wants/getty@hvc0.service
  mkdir -p /etc/systemd/system/multi-user.target.wants /etc/systemd/system/sockets.target.wants \
           /etc/systemd/system/sysinit.target.wants
  ln -sf /lib/systemd/system/systemd-networkd.service /etc/systemd/system/multi-user.target.wants/systemd-networkd.service
  ln -sf /lib/systemd/system/systemd-udevd.service     /etc/systemd/system/sysinit.target.wants/systemd-udevd.service
  ln -sf /lib/systemd/system/systemd-networkd.socket   /etc/systemd/system/sockets.target.wants/systemd-networkd.socket
  mkdir -p /etc/systemd/network
  printf "[Match]\nName=en* eth*\n[Network]\nDHCP=yes\n" > /etc/systemd/network/10-eth.network
'

echo "installing tavfd (pty relay)..."
docker cp "$HERE/tavfd.sh" tavf-rfs:/usr/local/bin/tavfd
docker cp "$HERE/tavfd.service" tavf-rfs:/etc/systemd/system/tavfd.service
docker exec tavf-rfs bash -c '
  chmod +x /usr/local/bin/tavfd
  mkdir -p /etc/systemd/system/multi-user.target.wants
  ln -sf /etc/systemd/system/tavfd.service /etc/systemd/system/multi-user.target.wants/tavfd.service
  ls -l /usr/local/bin/tavfd /etc/systemd/system/multi-user.target.wants/tavfd.service
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
