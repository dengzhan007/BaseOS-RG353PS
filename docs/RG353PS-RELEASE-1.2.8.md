# BaseOS for RG353PS 1.2.8

## 简体中文

1.2.8 是 RG353PS 的整合测试版本，包含 Wi-Fi SFTP、独立的 Wi-Fi SSH 通道和启动画面默认行为调整。

### 重要安装要求

**本版本必须使用完整镜像对 TF 卡全新刷写，不支持从 1.2.7 或更早版本通过 `.bosupd` 原地升级。**

本次将 SSH 总开关统一命名为 `ssh_debug`，不提供旧配置名兼容逻辑。旧卡上的 `baseos.conf` 不会自动迁移；请先备份游戏、存档和其他文件，再使用完整镜像重新刷写 TF1。首次启动会按正常流程初始化并扩展用户数据分区。

本版本只生成完整刷写镜像 `baseos-rg353ps-1.2.8.img.gz`，不生成 `.bosupd` 升级包。请勿将其他版本的升级包用于本版本迁移。

### 网络访问设置

- `ssh_debug=yes/no`：同时控制 USB SSH 和 Wi-Fi SSH。USB SSH 使用 DC 接口的 `192.168.42.1:22`；Wi-Fi SSH 使用设备 `wlan0` 地址的 TCP `2222`。
- `wifi_sftp=yes/no`：独立控制 Wi-Fi SFTP，监听 TCP `22`，并将会话限制在 `/mnt/SDCARD`。
- `usb_mtp=yes/no`：独立控制 MTP。
- Release 构建默认关闭交互式 SSH；开发构建默认开启。交互式 SSH 提供 root shell，只应在可信网络中启用。

### 其他变化

- 汇总 Wi-Fi SFTP 与 USB/Wi-Fi SSH 的端口、服务边界和配置方式。
- 保留 Wi-Fi SFTP 与 USB Mass Storage 的互斥处理：导出用户数据分区前停止 SFTP 会话，完成本地挂载恢复后再启动服务。
- U-Boot 保持黑屏；没有持久化自定义启动图选择时，Linux 启动画面使用 BaseOS 生成的默认字标。
- Windows RNDIS 路由异常的处理方法仍为将 RNDIS IPv4 接口跃点设为 `9999`，并关闭自动跃点。

### 下载

- `baseos-rg353ps-1.2.8.img.gz`：完整 TF1 刷写镜像，仅用于全新安装。
- `baseos-rg353ps-1.2.8.sha256`：完整镜像的 SHA-256 校验值。

---

## English

Version 1.2.8 is an integrated RG353PS test build. It includes Wi-Fi SFTP, an independent Wi-Fi interactive SSH endpoint, and the generated default boot-splash behavior.

### Important installation requirement

**Version 1.2.8 must be installed by freshly flashing the complete image to the TF card. In-place `.bosupd` upgrades from version 1.2.7 or earlier are not supported.**

This release renames the shared interactive-SSH setting to `ssh_debug` and intentionally provides no compatibility alias for the previous setting name. Existing card-side `baseos.conf` files are not migrated automatically. Back up games, saves, and other files, then flash the complete image to TF1. The first boot initializes and expands the user-data partition through the normal process.

This version produces only the complete image, `baseos-rg353ps-1.2.8.img.gz`; no `.bosupd` update package is generated. Do not use an update package from another version for this migration.

### Network access settings

- `ssh_debug=yes/no`: controls both USB SSH and Wi-Fi SSH. USB SSH uses `192.168.42.1:22` through the DC port; Wi-Fi SSH uses the device's `wlan0` address on TCP `2222`.
- `wifi_sftp=yes/no`: independently controls Wi-Fi SFTP on TCP `22`, with sessions confined to `/mnt/SDCARD`.
- `usb_mtp=yes/no`: independently controls MTP.
- Release builds disable interactive SSH by default; development builds enable it. Interactive SSH provides a root shell and should only be enabled on a trusted network.

### Other changes

- Documents the Wi-Fi SFTP and USB/Wi-Fi SSH ports, service boundaries, and configuration.
- Preserves mutual exclusion between Wi-Fi SFTP and USB Mass Storage: SFTP sessions stop before the user-data partition is exported and restart after the local mount is restored.
- U-Boot remains black. Without a persistent custom boot-logo selection, Linux displays the generated BaseOS default wordmark.
- The Windows RNDIS route workaround remains setting the RNDIS IPv4 interface metric to `9999` and disabling Automatic metric.

### Downloads

- `baseos-rg353ps-1.2.8.img.gz`: complete TF1 image for fresh installation only.
- `baseos-rg353ps-1.2.8.sha256`: SHA-256 checksum for the complete image.
