# BaseOS for RG353PS 1.2.7

## 简体中文

1.2.7 是在 1.2.6 硬件验证基线之上的维护版本，重点是将 RG353PS 前端接口正式收敛为通用适配器契约，并补齐相关回归验证与文档。

### 主要变化

- **通用前端适配器发现**：通过普通文本 `manifest.conf` 声明 `adapter_api=1`、优先级、音量键和电源键所有权。BaseOS 优先检查 TF2，再检查 TF1；支持隐藏目录和可见别名、一级包装目录、`frontend_id` 固定选择，以及按适配器目录/文件时间戳失效的快速缓存。
- **向后兼容**：没有 manifest 的旧式 `launch.sh` 适配器仍可按默认能力启动；不支持的 API 或非法字段会被跳过。manifest 仅作为数据解析，不会被 source 或 eval。
- **适配器测试**：将通用发现测试纳入发布工作流，覆盖 manifest 默认值、优先级、所有权、固定选择、旧包兼容、路径别名及缓存失效。
- **Windows USB 调试说明**：补充 RNDIS/SSH 导致 Windows 默认路由异常时的处理方式：将 RNDIS IPv4 接口跃点设为 `9999` 并关闭自动跃点。
- **MTP 复测记录**：2026-11-09 重插数据线后 Windows WPD 恢复显示 27 项；64 KiB 设备到主机下载和主机到设备上传均完成 SHA-256 对照，临时测试目录已清理。对应的 `Read Error (-1)` 与物理拔线同秒发生，不作为 uMTP 自发故障证据。

### USB 默认行为与验证边界

- Release 默认仍为 **MTP-only**；持久化 USB 故障日志默认关闭（`usb_diagnostics=no`）。
- 本版本没有因上述 MTP 断连记录修改 DWC3、PHY、Gadget、uMTP、DHCP 或 RNDIS 运行时代码。
- 主机到设备的 64 KiB 上传哈希通过设备端 SSH 计算，并非 Windows WPD 回读验证。
- MTP 128 MiB 长时/重复断连、MTP-only 长会话、WPD 重命名/删除，以及 MTP 与 Mass Storage 互斥压力测试仍未完成。
- RG353PS HDMI 输出仍未完成实机验证。

### 下载

- `baseos-rg353ps-1.2.7.img.gz`：完整 TF1 刷写镜像，用于新装；刷写会覆盖目标卡。
- `baseos-rg353ps-1.2.7.bosupd`：A/B 系统升级包，不包含 U-Boot，也不覆盖持久化用户数据分区。
- `baseos-rg353ps-1.2.7.sha256`：本次发布二进制文件的 SHA-256 校验值。

完整镜像与升级包可以独立下载；升级前请备份重要数据并保持设备供电。

---

## English

Version 1.2.7 is a maintenance release based on the 1.2.6 hardware-validated baseline. Its main goal is to formalize the RG353PS generic frontend adapter contract and include its regression tests and documentation in the release workflow.

### Highlights

- **Generic frontend adapter discovery:** a plain-text `manifest.conf` declares `adapter_api=1`, priority, volume-key ownership, and power-key ownership. BaseOS checks TF2 before TF1 and supports hidden/visible adapter paths, one wrapper-directory level, `frontend_id` pinning, and a metadata-based fast cache with adapter-tree invalidation.
- **Backward compatibility:** legacy adapters with `launch.sh` but no manifest continue to use default capabilities. Unsupported API versions and invalid values are skipped. The manifest is parsed as data and is never sourced or evaluated.
- **Adapter regression tests:** the release workflow now runs the generic discovery test, covering defaults, priority, ownership, pinned selection, legacy compatibility, path aliases, and cache invalidation.
- **Windows USB debugging guidance:** documents how to resolve Windows default-route interference caused by the RNDIS/SSH link by setting the RNDIS IPv4 interface metric to `9999` and disabling Automatic metric.
- **MTP recheck record:** after a cable reseat on 2026-11-09, Windows WPD again exposed 27 storage items. A 64 KiB device-to-host download and host-to-device upload passed SHA-256 comparison, and the temporary test directory was removed. The associated `Read Error (-1)` occurred in the same second as physical cable removal and is not evidence of a spontaneous uMTP fault.

### USB defaults and validation boundaries

- Release remains **MTP-only**; persistent USB diagnostic reports remain disabled by default (`usb_diagnostics=no`).
- The MTP reconnect observation did not require changes to DWC3, PHY, Gadget, uMTP, DHCP, or RNDIS runtime code.
- The host-to-device 64 KiB upload hash was computed on the device over SSH; this was not a Windows WPD read-back test.
- MTP 128 MiB long-duration/repeated-disconnect testing, long MTP-only sessions, WPD rename/delete operations, and MTP/Mass Storage mutual-exclusion stress remain untested.
- HDMI output has not been validated on RG353PS hardware.

### Downloads

- `baseos-rg353ps-1.2.7.img.gz`: complete TF1 image for a fresh installation; flashing erases the target card.
- `baseos-rg353ps-1.2.7.bosupd`: A/B system update; it does not include U-Boot or overwrite the persistent user-data partition.
- `baseos-rg353ps-1.2.7.sha256`: SHA-256 checksums for the published binaries.

The complete image and update package can be downloaded independently. Back up important data before upgrading and keep the device powered throughout the update.
