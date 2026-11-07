#!/bin/bash
# build-rootfs-ubuntu-docker.sh <amd64|arm64> <out.ext4>
# Docker --platform 方式构建 Ubuntu rootfs（CI runner 原生支持，免 debootstrap/binfmt）
set -euo pipefail
DEB_ARCH=${1:-amd64}
OUT=${2:-rootfs.ext4}
QARCH=$([[ $DEB_ARCH == amd64 ]] && echo amd64 || echo arm64)

echo "pulling ubuntu:24.04 for $QARCH..."
docker pull --platform "linux/$QARCH" ubuntu:24.04 >/dev/null

docker rm -f tavf-rfs >/dev/null 2>&1 || true
docker run -d --name tavf-rfs --platform "linux/$QARCH" ubuntu:24.04 sleep infinity >/dev/null

echo "installing systemd + tools..."
docker exec tavf-rfs bash -c '
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    systemd systemd-sysv iproute2 kmod lrzsz tzdata locales socat udev \
    iputils-ping openssl systemd-resolved >/dev/null
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
'

echo "exporting rootfs tar..."
docker export tavf-rfs -o /tmp/tavf-rootfs.tar
docker rm -f tavf-rfs >/dev/null

echo "populating ext4 ($SIZE MiB)..."
SIZE=${SIZE:-1400}
rm -f "$OUT"; truncate -s "${SIZE}M" "$OUT"
EXTRACT=$(mktemp -d)
tar -xf /tmp/tavf-rootfs.tar -C "$EXTRACT"
mkfs.ext4 -q -F -E nodiscard -d "$EXTRACT" -L tavf-root "$OUT"
rm -rf "$EXTRACT" /tmp/tavf-rootfs.tar
echo "built: $OUT ($(du -h "$OUT" | cut -f1))"
