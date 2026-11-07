#!/bin/bash
# extract-distro-kernel.sh <ubuntu|archarm> <outdir> [arch]
# 从**官方发行版内核包**剥离 kernel + initramfs（本项目不编译任何内核）
#
# ubuntu : 在 ubuntu:24.04 容器里安装 linux-image-virtual，取 /boot/vmlinuz-* + initrd.img-*
#          （Ubuntu 的 initrd 由 update-initramfs 在包安装时生成，只能装包后取）
# archarm: 从 ALA 官方 rootfs/包取 /boot/Image + /boot/initramfs-linux.img
set -euo pipefail
DISTRO=${1:?usage: extract-distro-kernel.sh <ubuntu|archarm> <outdir> [arch]}
OUT=${2:?}
ARCH=${3:-amd64}
mkdir -p "$OUT"

case "$DISTRO" in
  ubuntu)
    QARCH=$([[ $ARCH == amd64 ]] && echo amd64 || echo arm64)
    CT=tavf-kern-$$
    echo "== ubuntu linux-image-virtual ($QARCH) =="
    docker run -d --name "$CT" --platform "linux/$QARCH" ubuntu:24.04 sleep infinity >/dev/null
    docker exec "$CT" bash -c '
      apt-get update -qq
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        linux-image-virtual initramfs-tools 2>&1 | tail -3
      ls -la /boot/
    '
    VMLINUZ=$(docker exec "$CT" sh -c 'ls /boot/vmlinuz-* | head -1')
    INITRD=$(docker exec "$CT" sh -c 'ls /boot/initrd.img-* | head -1')
    docker cp "$CT:$VMLINUZ" "$OUT/kernel"
    docker cp "$CT:$INITRD" "$OUT/initrd"
    docker exec "$CT" sh -c 'dpkg-query -W -f="${Package} ${Version}\n" linux-image-virtual' > "$OUT/kernel-source.txt" 2>/dev/null || true
    docker rm -f "$CT" >/dev/null
    ;;
  archarm)
    SRC=${ALA_TARBALL:-}
    BOOTDIR=${ALA_BOOT:-}
    echo "== Arch Linux ARM linux-aarch64 =="
    if [ -n "$BOOTDIR" ] && [ -d "$BOOTDIR" ]; then
      cp "$BOOTDIR/Image" "$OUT/kernel"
      cp "$BOOTDIR/initramfs-linux.img" "$OUT/initrd" 2>/dev/null || true
    elif [ -n "$SRC" ] && [ -f "$SRC" ]; then
      T=$(mktemp -d); bsdtar -xpf "$SRC" -C "$T" boot/ 2>/dev/null || true
      cp "$T/boot/Image" "$OUT/kernel"
      cp "$T/boot/initramfs-linux.img" "$OUT/initrd" 2>/dev/null || true
      rm -rf "$T"
    else
      echo "需要 ALA_TARBALL=<tarball> 或 ALA_BOOT=<含 Image/initramfs-linux.img 的目录>" >&2
      exit 2
    fi
    echo "linux-aarch64 (ArchLinuxARM official)" > "$OUT/kernel-source.txt"
    ;;
  *) echo "unknown distro: $DISTRO" >&2; exit 2 ;;
esac

ls -la "$OUT"
echo "kernel=$(du -h "$OUT/kernel" | cut -f1) initrd=$(du -h "$OUT/initrd" 2>/dev/null | cut -f1)"
