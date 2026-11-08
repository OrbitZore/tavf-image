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

## catalog.json 的字段

`catalog.src.json` 是**手写的**（只写“有哪些镜像、每个角色用哪个 asset”），
`catalog.json` 是**生成的**（由 `scripts/gen-catalog.sh` 从实际产物算出 size/sha256）。
**不要手改 `catalog.json` 的校验和**，改 `catalog.src.json` 后重新生成：

```bash
# 从本地已构建产物（CI release job 就是这么做的）
bash scripts/gen-catalog.sh --local dist

# 从已发布的 GitHub Release 读 digest（事后补录 / 本地校对）
bash scripts/gen-catalog.sh --release          # latest
bash scripts/gen-catalog.sh --release v1.3.1
```

每个镜像除角色字段外，还带（按角色前缀）：

| 字段 | 含义 | 来源 |
|---|---|---|
| `kernel_bytes` / `initrd_bytes` / `rootfs_bytes` | 下载字节数 | 产物实际大小 / Release API |
| `kernel_sha256` / `initrd_sha256` / `rootfs_sha256` | 下载校验和 | 本地 `sha256sum` / Release API 的 `digest` |
| `rootfs_uncompressed` | rootfs **解压后**字节数 | gzip ISIZE trailer |

顶层 `updated` 是生成日期（不是手填的）。

> **为什么需要 `rootfs_uncompressed`**：客户端导入时要解压 rootfs，
> 真正占磁盘的是解压后的 1.4 GB / 2.5 GB，不是下载的 90 MB。
> termux-avf 用这个值做**导入前的空间预检**，呰不到就直接报
> 「磁盘空间不足：约需 N MiB，当前可用 M MiB」，而不是写到一半 ENOSPC。
> GitHub 的 release CDN 不支持 `bytes=-4` 后缀范围（会回 501），
> 所以脚本用显式的 `bytes=<size-4>-<size-1>` 读尾部 4 字节。

消费端（termux-avf App 与 `tavf` CLI）会在**下载后校验 sha256**：
不匹配则删掉 `.part` 并以 exit 5 失败，不会把坏文件当成功。
校验和缺失时 CLI 会明说“catalog 未提供，跳过校验”（不默默信任）。

## tavf 使用

```bash
# 默认镜像源即本仓库 catalog.json
tavf image list
tavf image pull ubuntu-arm64
```

## 镜像内容（只有基础系统）

镜像**刻意保持最小**：只装「基础系统 + termux-avf 运行必需组件」，其余软件一律由你
在 VM 内自行安装（这样避免镜像膨胀、也避免版本锁死）。

| 已包含 | 说明 |
|---|---|
| systemd / systemd-sysv / udev | 基础 init 与设备管理 |
| iproute2 / kmod | 网络与模块工具 |
| socat + openssl | tavfd 的 pty 中继依赖（框架必需） |
| lrzsz | zmodem 文件传输（框架必需，`tavf` 传文件用） |
| systemd-resolved / tzdata / locales | 基础系统组件 |
| **无** | 无 git/curl/vim/nginx/docker/数据库/编译器… 全部自行安装 |

## 自行安装常用服务器软件

> 两个发行版都建议**先做一次系统更新**，再装软件。
> Ubuntu 用 `apt`，Arch Linux ARM 用 `pacman`（滚动更新，无固定版本号）。

### 0. 先更新系统

```bash
# Ubuntu Server
sudo apt update && sudo apt -y full-upgrade

# Arch Linux ARM（首次需初始化 keyring）
sudo pacman-key --init && sudo pacman-key --populate archlinuxarm
sudo pacman -Syu
```

### 1. 基础开发工具

```bash
# Ubuntu
sudo apt install -y build-essential git curl wget vim htop tmux unzip jq

# Arch
sudo pacman -S --needed base-devel git curl wget vim htop tmux unzip jq
```

### 2. Web 服务器 / 反向代理 / HTTPS

```bash
# Nginx
sudo apt install -y nginx            # Ubuntu
sudo pacman -S --needed nginx        # Arch

# Caddy（自动 HTTPS）
sudo apt install -y caddy            # Ubuntu
sudo pacman -S --needed caddy        # Arch

# 证书
sudo apt install -y certbot python3-certbot-nginx   # Ubuntu
sudo pacman -S --needed certbot                     # Arch
sudo systemctl enable --now nginx caddy 2>/dev/null
```

### 3. 数据库与缓存

```bash
# PostgreSQL
sudo apt install -y postgresql        # Ubuntu
sudo pacman -S --needed postgresql    # Arch

# MariaDB / MySQL
sudo apt install -y mariadb-server    # Ubuntu
sudo pacman -S --needed mariadb       # Arch

# Redis
sudo apt install -y redis-server      # Ubuntu
sudo pacman -S --needed redis         # Arch

# SQLite
sudo apt install -y sqlite3           # Ubuntu
sudo pacman -S --needed sqlite        # Arch

sudo systemctl enable --now postgresql mariadb redis 2>/dev/null
```

### 4. 语言运行时

```bash
# Python
sudo apt install -y python3 python3-pip python3-venv     # Ubuntu
sudo pacman -S --needed python python-pip                # Arch

# Node.js
sudo apt install -y nodejs npm                           # Ubuntu（版本较保守）
# 需要新版：curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt install -y nodejs
sudo pacman -S --needed nodejs npm                       # Arch

# Java
sudo apt install -y openjdk-21-jdk-headless              # Ubuntu
sudo pacman -S --needed jdk-openjdk                      # Arch

# Go / Rust / PHP
sudo apt install -y golang-go rustc cargo php-fpm        # Ubuntu
sudo pacman -S --needed go rust php                      # Arch
```

### 5. 容器

```bash
# Docker
sudo apt install -y docker.io docker-compose-v2          # Ubuntu
sudo pacman -S --needed docker docker-compose            # Arch
sudo systemctl enable --now docker
sudo usermod -aG docker $USER   # 重新登录生效

# Podman（无守护进程，适合 ARM 小机器）
sudo apt install -y podman                               # Ubuntu
sudo pacman -S --needed podman                           # Arch
```

### 6. 文件共享与同步

```bash
# rsync / rclone
sudo apt install -y rsync rclone                         # Ubuntu
sudo pacman -S --needed rsync rclone                     # Arch

# Samba / NFS / Syncthing
sudo apt install -y samba nfs-kernel-server syncthing    # Ubuntu
sudo pacman -S --needed samba nfs-utils syncthing        # Arch
sudo systemctl enable --now smbd syncthing@$USER 2>/dev/null
```

### 7. 远程访问 / 安全

```bash
# SSH 服务端
sudo apt install -y openssh-server                       # Ubuntu
sudo pacman -S --needed openssh                          # Arch
sudo systemctl enable --now sshd

# WireGuard
sudo apt install -y wireguard-tools                      # Ubuntu
sudo pacman -S --needed wireguard-tools                  # Arch

# 防火墙 / 防爆破
sudo apt install -y nftables fail2ban                    # Ubuntu
sudo pacman -S --needed nftables fail2ban                 # Arch
```

### 8. 媒体与其它常用服务

```bash
sudo apt install -y ffmpeg imagemagick mosquitto         # Ubuntu
sudo pacman -S --needed ffmpeg imagemagick mosquitto      # Arch

# Git 服务器（可选，轻量）
sudo apt install -y gitea 2>/dev/null || echo "gitea 在 Arch: pacman -S gitea"
```

### 9. Arch Linux ARM 的 AUR 说明

ALA 官方仓库不含 AUR。需要 AUR 包（如 `tailscale`、`yay`）时自己编译：

```bash
sudo pacman -S --needed base-devel git
git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si
```

> ARM 上部分 AUR 包无预编译产物，会本地编译（耗时长、需内存充足）。

### 10. 注意事项

- 镜像默认**无桌面环境**；需要图形界面自行安装（`ubuntu-desktop-minimal` /
  `xorg-server` + 轻量 WM），但注意 AVF VM 通常无 GPU 加速。
- 磁盘默认较小（Ubuntu 1.4G / Arch 5G）；装大软件前先扩容（edit ext4 + `resize2fs`）。
- 时区/语言：`timedatectl set-timezone Asia/Shanghai`、`locale-gen`。

## 与上游兼容性承诺

镜像只做**最小化定制**（tavfd 中继 + 网络配置），不魔改包管理器与系统组件；
apt/pacman 与上游仓库 100% 兼容，系统更新（含全量升级）在 VM 内正常执行。
