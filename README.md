# tavf-image

**termux-avf 的镜像构建仓库**：CI 自动构建 AVF guest 可用的内核与发行版 rootfs，
产物发布于 GitHub Releases，供 [tavf CLI](https://github.com/OrbitZore/termux-avf) 直接拉取。

## 镜像矩阵

| 镜像 | 发行版 | 架构 | 包管理 | 用途 |
|---|---|---|---|---|
| ubuntu-x86_64 | Ubuntu 24.04 | x86_64 | apt | emulator-AVF 设备 |
| ubuntu-arm64 | Ubuntu 24.04 | arm64 | apt | 真机 AVF（Pixel 等） |
| archlinux-arm64 | Arch Linux ARM | arm64 | pacman | 真机 AVF（滚动更新党） |
| kernel-x86_64 / kernel-arm64 | vanilla stable 6.6 | — | — | AVF guest 通用内核 |

镜像特征：systemd 最小化 + tavfd pty 中继（vsock/TCP 双传输）+ 网络静态配置
（AVF 固定网段）+ 上游包管理完全兼容（apt/pacman 直接用）。

## CI

push 或手动触发自动构建；打 `v*` tag 自动发布 Release。
产物结构：

```
kernel-x86_64            # bzImage
kernel-arm64             # Image
ubuntu-x86_64-rootfs.ext4
ubuntu-arm64-rootfs.ext4
archarm-rootfs.ext4
catalog.json
```

## tavf 使用

```bash
# 默认镜像源即本仓库 catalog.json
tavf image list
tavf image pull ubuntu-arm64
```

## 与上游兼容性承诺

镜像只做**最小化定制**（tavfd 中继 + 网络配置），不魔改包管理器与系统组件；
apt/pacman 与上游仓库 100% 兼容，系统更新（含全量升级）在 VM 内正常执行。
