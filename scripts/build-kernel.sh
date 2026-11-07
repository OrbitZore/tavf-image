#!/bin/bash
# build-kernel.sh <x86_64|arm64> <out-file> — vanilla stable 6.6 + AVF guest fragment
# CI 友好：defconfig 基座（已知可用），无 GKI/CFI/LTO 约束（AVF 非 protected VM
# 可引导任意内核；vendor 模块兼容仅真机 GKI 场景需要，此处不适用）
set -euo pipefail
ARCH=${1:-x86_64}
OUT=${2:-kernel}
VER=${LINUX_VERSION:-6.6.74}
FRAG=$(dirname "$0")/kernel-avf-guest.fragment
DL=${KERNEL_DIR:-$(mktemp -d)}

cd "$DL"
if [ ! -f linux-$VER.tar.xz ]; then
  echo "downloading linux-$VER..."
  curl -fL --retry 3 -o linux-$VER.tar.xz "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$VER.tar.xz"
fi
[ -d linux-$VER ] || tar xJf linux-$VER.tar.xz
cd linux-$VER

if [ "$ARCH" = x86_64 ]; then
  make defconfig
  KOUT=bzImage
else
  make ARCH=arm64 defconfig
  KOUT=arch/arm64/boot/Image
fi
./scripts/kconfig/merge_config.sh -m .config "$FRAG"
make ARCH=$ARCH olddefconfig
make ARCH=$ARCH -j"$(nproc)" $KOUT

case $ARCH in
  x86_64) cp arch/x86_64/boot/bzImage "$OUT" 2>/dev/null || cp arch/x86/boot/bzImage "$OUT" ;;
  arm64)  cp arch/arm64/boot/Image "$OUT" ;;
esac
echo "built: $OUT ($(du -h "$OUT" | cut -f1))"
