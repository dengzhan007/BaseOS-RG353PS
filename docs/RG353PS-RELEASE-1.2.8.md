# BaseOS for RG353PS 1.2.8

## 简体中文

1.2.8 是 RG353PS 的网络访问、USB 管理、启动体验与前端适配维护版本。它基于 1.2.7，重点是把 USB SSH、Wi-Fi SSH、Wi-Fi SFTP 和 MTP 拆分为边界清晰、可独立配置的服务，并完善电源状态切换与启动画面管理。

### 重要安装要求

**1.2.8 必须使用完整镜像全新刷写 TF1，不支持从 1.2.7 或更早版本通过 `.bosupd` 原地升级。**

本版本将 USB 与 Wi-Fi 交互式 SSH 的统一开关命名为 `ssh_debug`，不提供旧配置名兼容迁移。旧卡上的 `baseos.conf` 不会自动转换。请先备份游戏、存档和其他用户数据，再刷写完整镜像；首次启动会按正常流程初始化并扩展用户数据分区。

本次正式发布只提供完整镜像，不提供 `.bosupd` 升级包。

### 主要变化

- **USB 与 Wi-Fi SSH 统一管理**：`ssh_debug=yes/no` 同时控制 USB SSH 与 Wi-Fi 交互式 SSH。USB SSH 通过 DC 接口使用 `192.168.42.1:22`；Wi-Fi SSH 通过设备的 wlan0 地址使用 TCP `2222`。Release 默认关闭交互式 SSH，避免正常使用时暴露 root shell。
- **独立 Wi-Fi SFTP**：新增 `wifi_sftp=yes/no`，在 Wi-Fi TCP `22` 提供文件传输服务，会话限制在 `/mnt/SDCARD`，与交互式 SSH 使用不同端口和服务配置。
- **USB MTP 独立开关**：`usb_mtp=yes/no` 独立控制 MTP，不再与 SSH 调试开关混为一谈。
- **USB 存储与 SFTP 协调**：进入 USB Mass Storage 前停止 SFTP 会话并释放数据分区；退出后恢复本地挂载，再按配置恢复 SFTP，避免主机导出期间本机继续访问同一文件系统。
- **关闭默认 USB 诊断输出**：USB 调试探测与诊断日志默认关闭，正常使用不会持续生成 USB 调试文本文件；需要排查问题时再显式开启。
- **电源与无线网络状态管理**：完善睡眠、唤醒和关机路径中的 Wi-Fi 关闭/恢复处理，避免设备休眠后无线服务状态与实际网卡状态不一致。
- **启动画面管理**：保持 U-Boot 阶段黑屏；Linux 阶段使用 BaseOS 默认生成字标作为回退画面，并保留用户自定义启动图的管理方式，避免普通系统更新无故覆盖持久化选择。
- **前端适配器与网络脚本**：保留 manifest 前端适配接口；RG353PS Slot 适配器通过卡侧网络脚本管理连接，BaseOS 负责底层无线模块初始化。
- **Windows RNDIS 路由说明**：补充 USB SSH 网卡影响 Windows 默认路由时的解决办法，将 RNDIS IPv4 接口跃点设置为 `9999` 并关闭自动跃点。

### 网络端口速查

| 功能 | 开关 | 接口 / 端口 |
|---|---|---|
| USB 交互式 SSH | `ssh_debug` | DC 接口，`192.168.42.1:22` |
| Wi-Fi 交互式 SSH | `ssh_debug` | wlan0 地址，TCP `2222` |
| Wi-Fi SFTP | `wifi_sftp` | wlan0 地址，TCP `22` |
| USB MTP | `usb_mtp` | USB gadget / MTP |

交互式 SSH 提供 root shell，只应在可信网络中按需开启。SFTP 用于日常文件传输。

### 下载

- `baseos-rg353ps-1.2.8.img.gz`：完整 TF1 刷写镜像，用于全新安装。
- `baseos-rg353ps-1.2.8.sha256`：完整镜像的 SHA-256 校验值。
- `baseos-rg353ps-1.2.8.build.txt`：记录精确源码提交、内核版本和构建时间。

请先备份用户数据。完整镜像刷写会覆盖目标 TF 卡；首次启动完成扩容后再恢复游戏和存档。不要使用其他版本的升级包代替完整刷写。

---

## English

BaseOS RG353PS 1.2.8 is a maintenance release covering network access, USB management, startup behavior, power-state handling, and frontend integration. Based on 1.2.7, it separates USB SSH, Wi-Fi SSH, Wi-Fi SFTP, and MTP into clearly scoped, independently configurable services.

### Important installation requirement

**Version 1.2.8 must be installed by freshly flashing the complete image to TF1. In-place `.bosupd` upgrades from 1.2.7 or earlier are not supported.**

The shared switch for USB and Wi-Fi interactive SSH is now named `ssh_debug`. No migration alias is provided for the previous setting name, and an existing card-side `baseos.conf` is not automatically converted. Back up games, saves, and other user data, flash the complete image, and allow the first boot to initialize and expand the user-data partition.

This release provides the complete image only; no `.bosupd` update package is published.

### Highlights

- **Unified USB and Wi-Fi interactive SSH control:** `ssh_debug=yes/no` controls both endpoints. USB SSH uses `192.168.42.1:22` through the DC port; Wi-Fi SSH listens on TCP `2222` at the device's wlan0 address. Interactive SSH is disabled by default in release builds to avoid exposing a root shell during normal use.
- **Independent Wi-Fi SFTP:** `wifi_sftp=yes/no` enables file transfer on TCP `22`, confined to `/mnt/SDCARD`. It is separate from interactive SSH and uses a different port.
- **Independent USB MTP control:** `usb_mtp=yes/no` controls MTP without coupling it to the SSH debugging switch.
- **SFTP / USB Mass Storage coordination:** SFTP sessions are stopped and the data partition is released before USB Mass Storage exports it. After export ends, the local mount is restored before SFTP is started again.
- **USB diagnostics disabled by default:** USB probe and diagnostic text logging no longer run during ordinary use. Enable diagnostics explicitly when troubleshooting.
- **Power and wireless state handling:** improves Wi-Fi shutdown and restoration across suspend, wake, and power-off paths.
- **Boot splash management:** U-Boot remains black. Linux uses a generated BaseOS wordmark as the fallback splash while retaining the persistent custom boot-logo workflow.
- **Frontend integration:** keeps the manifest-based frontend adapter contract and uses card-side networking scripts for the RG353PS Slot frontend while BaseOS initializes the wireless hardware.
- **Windows RNDIS routing guidance:** documents setting the RNDIS IPv4 interface metric to `9999` and disabling Automatic metric when the USB SSH link interferes with the Windows default route.

### Network port reference

| Service | Setting | Interface / port |
|---|---|---|
| USB interactive SSH | `ssh_debug` | DC port, `192.168.42.1:22` |
| Wi-Fi interactive SSH | `ssh_debug` | wlan0 address, TCP `2222` |
| Wi-Fi SFTP | `wifi_sftp` | wlan0 address, TCP `22` |
| USB MTP | `usb_mtp` | USB gadget / MTP |

Interactive SSH provides a root shell and should only be enabled on trusted networks when needed. SFTP is the recommended option for routine file transfers.

### Downloads

- `baseos-rg353ps-1.2.8.img.gz`: complete TF1 image for fresh installation.
- `baseos-rg353ps-1.2.8.sha256`: SHA-256 checksum for the complete image.
- `baseos-rg353ps-1.2.8.build.txt`: exact source commit, kernel version, and build timestamp.

Back up user data before flashing. A complete-image flash overwrites the target TF card. Restore games and saves only after the first boot has completed data-partition expansion. Do not substitute an update package from another version.
