
# BaseOS RG353PS 安装与升级指南

[简体中文](#简体中文) | [English](#english)

> **适用设备：Anbernic RG353PS（Rockchip RK3566）。** 本指南只适用于 RG353PS。不要在 RG353PS 上使用 Miyoo Flip（my355）的 Preloader、NAND、mtd5 或右侧卡槽安装步骤。

## 简体中文

### 准备工作

需要 RG353PS、一张用于 TF1 的 microSD 卡、电脑和读卡器、磁盘镜像写入工具，以及稳定电源。建议提前备份 TF1 卡和其他重要数据。**写入完整镜像会清除目标卡上的全部内容。**

BaseOS 是系统底座，不包含游戏前端。没有发现可用前端时，系统会进入内置诊断界面。

### 全新安装

1. 从 [BaseOS RG353PS Releases](https://github.com/dengzhan007/BaseOS-RG353PS/releases) 下载正式版完整镜像文件 baseos-rg353ps-<version>.img.gz 和 .sha256 校验文件。
2. 校验下载文件。使用支持 gzip 镜像的写卡工具，或先解压 .img.gz，再将得到的 .img 作为整盘镜像写入 TF1 卡。
3. 确认写入目标是 TF1 卡。写入会覆盖目标卡的分区表和原有内容。
4. 将 TF1 卡插入 RG353PS 的 TF1 卡槽并开机。
5. 首次启动时，BaseOS 会初始化用户数据分区，并将其扩展到 TF 卡末尾。等待初始化完成，不要拔卡或断电。
6. 按需安装游戏前端，见下文。

RG353PS 直接从 TF1 上的 BaseOS 镜像启动。此流程不修改设备内部 NAND 或 Preloader，也不使用 Miyoo Flip 的启动卡槽流程。

### 安装前端

BaseOS 负责启动、硬件服务、存储挂载、前端发现和系统更新；游戏扫描、ROM 识别、列表展示及游戏启动由前端负责。

将前端安装到 TF1 或 TF2 的用户数据分区根目录，不要放到小容量的 BASEOS_BOOT 启动分区。通用适配器目录如下：

    <用户数据分区>/
    └── .baseos/
        └── frontends/
            └── <adapter-id>/
                ├── manifest.conf
                └── launch.sh

旧版兼容前端可能只提供 launch.sh；新适配器应同时提供 manifest.conf 和 launch.sh。详细格式见 [前端适配规范](platforms/rg353ps/FRONTENDS.md)。

BaseOS 启动时优先检查 TF2；TF2 没有可用适配器时再检查 TF1。BaseOS 不统一规定 ROM 目录，也不强制游戏和前端必须放在同一张卡上，具体布局由前端适配器决定。

### USB 文件传输

MTP、USB Mass Storage 和 USB SSH 使用 RG353PS 机身 **DC 接口**；OTG 接口不能用于本指南所述功能。

- **MTP：** 正式 Release 默认采用 MTP-only。连接 DC 数据线后，电脑可以访问用户数据分区。
- **USB Mass Storage：** 可从内置诊断界面进入；也可以开机时按住 Function，再按 Power 进入。此模式会独占导出用户数据卷，期间设备本地程序不得访问该卷。
- **读卡器：** 也可以关机取出 TF 卡，通过电脑读卡器复制文件。

使用 Mass Storage 时，建议先连接 DC 数据线，再按住 Function 并按 Power 开机。完成操作后，在电脑上安全弹出设备，再拔线。

### USB SSH 与 Wi-Fi 服务配置

编辑用户数据分区根目录的 baseos.conf。首次初始化会创建示例文件；卡上的配置优先于镜像内默认配置。只需写入需要覆盖默认值的项目：

    ssh_debug=no
    wifi_sftp=yes
    usb_mtp=yes
    usb_diagnostics=no

- **ssh_debug=yes** 同时启用 USB Dropbear SSH（192.168.42.1:22）和 Wi-Fi Dropbear SSH（设备当前 Wi-Fi 地址的 TCP 2222）；no 关闭两个交互式 shell。
- **wifi_sftp=yes** 独立启用 Wi-Fi SFTP（设备当前 Wi-Fi 地址的 TCP 22），不受 ssh_debug 控制；no 可关闭 SFTP。
- **usb_mtp=yes** 启用 USB MTP；Release 默认开启。
- **usb_diagnostics=yes** 只启用持久化 USB 故障报告，不会启用 SSH。正常使用保持 no。

当前镜像默认 root 密码为 root。启用 SSH 会在 USB 或 Wi-Fi 局域网开放 root shell；SFTP 也使用设备账户凭据。仅在可信网络中启用，并在对外分发前处理默认凭据。

Windows 因 USB RNDIS 网卡出现普通网络访问异常时，可将其 IPv4 接口跃点设为 9999 并关闭自动跃点。步骤见 [USB 架构文档](platforms/rg353ps/USB.md)。

### 系统升级

1.2.9 的 A/B 原地升级包只适用于**已经全新安装官方 1.2.8** 的设备：

1. 从 [GitHub Releases](https://github.com/dengzhan007/BaseOS-RG353PS/releases) 下载 baseos-rg353ps-1.2.9.bosupd。
2. 将 .bosupd 复制到设备可访问的用户数据分区根目录。
3. 重启并等待更新完成。期间保持供电稳定，不要拔卡或强制关机。

升级路径限制：

- 官方 1.2.8 → 1.2.9：可以使用 1.2.9 .bosupd。
- 1.2.7 或更早版本 → 1.2.9：必须备份数据后使用完整镜像重新写入 TF1，不能直接使用 1.2.9 .bosupd；1.2.8 调整了持久化 SSH 设置名称。
- .bosupd 更新 A/B 系统 BOOT 和 ROOTFS 区域，不包含 Rockchip U-Boot，也不覆盖独立的用户数据分区。需要更新 U-Boot 或恢复完整分区布局时，按对应版本说明使用完整镜像。

升级前请核对 SHA-256，并以目标版本的 Release Notes 为准。

### 已知限制与验证范围

- 1.2.9 是正式发布版本。CI 构建成功不代表所有硬件功能都已完成实机验收。
- RG353PS 实机 HDMI 输出尚未完成验证。
- 冷启动时可能仍听到轻微扬声器爆音；1.2.9 保留 1.2.8 音频初始化逻辑，没有声称解决此问题。
- Wi-Fi association、DHCP、路由可达性、深度休眠电流与唤醒恢复、Wi-Fi SSH/SFTP 传输及 USB/Wi-Fi 并发仍由 [Issue #21](https://github.com/dengzhan007/BaseOS-RG353PS/issues/21) 跟踪。真机测试完成前不得视为已验收。

### 更多文档

- [RG353PS 平台说明](platforms/rg353ps/README.md)
- [USB 架构与验证](platforms/rg353ps/USB.md)
- [前端适配规范](platforms/rg353ps/FRONTENDS.md)
- [电源管理](platforms/rg353ps/POWER.md)
- [启动画面规范](platforms/rg353ps/BOOTLOGO.md)
- [Wi-Fi SFTP / SSH](docs/rg353ps-network-access.md)
- [1.2.9 正式版说明](docs/RG353PS-RELEASE-1.2.9.md)

---

## English

### Scope and requirements

This guide applies only to the **Anbernic RG353PS (Rockchip RK3566)**. Do not use Miyoo Flip (my355) Preloader, NAND, mtd5 or card-slot procedures on an RG353PS.

You need an RG353PS, a microSD card for TF1, a computer and card reader, a disk-image writer, and stable power. Back up important data first. **Writing a full image erases the target card.**

BaseOS is the system layer and does not bundle a game frontend. The built-in diagnostic interface starts when no usable frontend is found.

### Fresh installation

1. Download the official full image baseos-rg353ps-<version>.img.gz and .sha256 file from [GitHub Releases](https://github.com/dengzhan007/BaseOS-RG353PS/releases).
2. Verify the download. Use an imaging utility that supports gzip images, or decompress the file and write the resulting .img as a whole-disk image.
3. Select the TF1 card as the target. The operation replaces its partition table and all existing contents.
4. Insert the card into TF1 and power on the RG353PS.
5. On first boot, BaseOS initializes the user-data partition and expands it to the end of the card. Do not remove the card or interrupt power during initialization.
6. Install a compatible frontend separately.

RG353PS boots directly from the BaseOS image on TF1. This process does not patch internal NAND or the Preloader and does not use the Miyoo Flip installation path.

### Install a frontend

Install the frontend on the root of a card's user-data volume, not on the small BASEOS_BOOT partition. A generic adapter uses:

    <userdata-volume>/
    └── .baseos/
        └── frontends/
            └── <adapter-id>/
                ├── manifest.conf
                └── launch.sh

Older compatible adapters may provide only launch.sh; new adapters should provide both files. See the [frontend adapter contract](platforms/rg353ps/FRONTENDS.md).

BaseOS checks TF2 first, then TF1 if TF2 has no usable adapter. BaseOS does not impose one universal ROM directory or require frontend and games to be on the same card; the selected adapter defines that layout.

### USB file transfer

MTP, USB Mass Storage and USB SSH use the RG353PS **DC port**, not the OTG port.

- **MTP:** Official Release builds default to MTP-only. Connect the DC cable to access the user-data volume.
- **USB Mass Storage:** Enter from the built-in diagnostic interface, or hold Function and press Power while booting. The user-data volume is exported exclusively and must not be accessed locally by the device at the same time.
- **Card reader:** Alternatively, power off, remove the card and copy files with a computer card reader.

For Mass Storage, connect the DC cable before powering on with Function held. Safely eject the device on the computer before unplugging it.

### SSH and Wi-Fi settings

Edit baseos.conf at the root of the user-data volume. The first-boot initializer creates an example file. Card-side values override image defaults:

    ssh_debug=no
    wifi_sftp=yes
    usb_mtp=yes
    usb_diagnostics=no

- **ssh_debug=yes** enables USB Dropbear SSH (192.168.42.1:22) and Wi-Fi Dropbear SSH (the current Wi-Fi address on TCP 2222). no disables both interactive shells.
- **wifi_sftp=yes** independently enables Wi-Fi SFTP on TCP 22; it is not controlled by ssh_debug. Set it to no to disable SFTP.
- **usb_mtp=yes** enables MTP; Release builds enable it by default.
- **usb_diagnostics=yes** only enables persistent USB fault reports. It does not enable SSH. Leave it at no for normal use.

The current image's default root password is root. Enabling SSH exposes a root shell over USB or the Wi-Fi LAN; SFTP also uses device credentials. Use these services only on trusted networks and address the default credentials before distributing a build.

If a Windows RNDIS adapter disrupts ordinary network access, set its IPv4 interface metric to 9999 and disable Automatic metric. See the [USB architecture guide](platforms/rg353ps/USB.md).

### System updates

The 1.2.9 A/B update package is for devices **freshly installed with the official 1.2.8 release**:

1. Download baseos-rg353ps-1.2.9.bosupd from [GitHub Releases](https://github.com/dengzhan007/BaseOS-RG353PS/releases).
2. Copy it to the root of an accessible user-data volume.
3. Reboot and allow the update to finish. Keep the device powered; do not remove the card or force shutdown during the update.

Upgrade compatibility:

- Official 1.2.8 to 1.2.9: use the 1.2.9 .bosupd.
- 1.2.7 or earlier: back up data and install the 1.2.9 full image to TF1. Do not apply the 1.2.9 .bosupd directly; 1.2.8 changed the persisted SSH setting name.
- .bosupd updates the A/B system BOOT and ROOTFS regions. It does not contain Rockchip U-Boot or overwrite the separate user-data partition. Use a full image when U-Boot or the complete partition layout must be updated.

Verify the SHA-256 checksum and follow the compatibility statement in the target release notes.

### Known limitations and validation

- Version 1.2.9 is an official release. A successful CI build does not mean every hardware feature has passed physical-device acceptance.
- HDMI output has not yet been verified on RG353PS hardware.
- A faint speaker pop may still occur during cold boot. Version 1.2.9 retains the 1.2.8 audio initialization path and does not claim to fix it.
- Wi-Fi association, DHCP, route reachability, deep-suspend current and wake/resume, Wi-Fi SSH/SFTP transfers, and concurrent USB/Wi-Fi sessions remain tracked in [Issue #21](https://github.com/dengzhan007/BaseOS-RG353PS/issues/21). They are not accepted until tested on hardware.

### More documentation

- [RG353PS platform guide](platforms/rg353ps/README.md)
- [USB architecture and validation](platforms/rg353ps/USB.md)
- [Frontend adapter contract](platforms/rg353ps/FRONTENDS.md)
- [Power management](platforms/rg353ps/POWER.md)
- [Boot-logo contract](platforms/rg353ps/BOOTLOGO.md)
- [Wi-Fi SFTP / SSH access](docs/rg353ps-network-access.md)
- [Version 1.2.9 release notes](docs/RG353PS-RELEASE-1.2.9.md)
