
# BaseOS RG353PS 文档索引 / Documentation

[简体中文](#简体中文) | [English](#english)

## 简体中文

本仓库包含上游 BaseOS（Miyoo Flip / my355）的部分历史资料，以及独立的 RG353PS（RK3566）平台实现。**RG353PS 的安装、刷写、升级和硬件操作请以 RG353PS 文档为准，不要照搬 my355 的 Preloader、NAND、mtd5 或卡槽步骤。**

### RG353PS 用户文档

| 文档 | 内容 |
|---|---|
| [安装与升级](../INSTALL.md) | TF1 全新安装、前端安装、USB 文件传输和 1.2.9 升级 |
| [平台说明](../platforms/rg353ps/README.md) | 架构、构建、镜像布局和限制 |
| [USB 架构与验证](../platforms/rg353ps/USB.md) | MTP、Mass Storage、USB SSH、Wi-Fi SFTP、重连和验证 |
| [前端适配规范](../platforms/rg353ps/FRONTENDS.md) | manifest、启动接口、存储和休眠职责 |
| [电源管理](../platforms/rg353ps/POWER.md) | 深度休眠、唤醒和 Wi-Fi 生命周期 |
| [启动画面规范](../platforms/rg353ps/BOOTLOGO.md) | 自定义启动图、持久化和更新恢复 |
| [Wi-Fi SFTP / SSH](rg353ps-network-access.md) | 服务地址、端口和开关 |

### 发布、配置与验证

- [1.2.9 正式版说明](RG353PS-RELEASE-1.2.9.md)、[1.2.8](RG353PS-RELEASE-1.2.8.md)、[1.2.7](RG353PS-RELEASE-1.2.7.md)
- [历史发布基线](RG353PS-RELEASE-BASELINE-1.2.4.md)
- [贡献指南](../CONTRIBUTING.md)
- [待实机验收 Issue #21](https://github.com/dengzhan007/BaseOS-RG353PS/issues/21)
- [USB profile 首次启动继承问题](usb-profile-inheritance.md)：记录旧版缺陷和当前回归测试；usb_debug 是历史设置名，当前使用 ssh_debug。
- [修订后的 MTP-only 验收记录](mtp-only-release-fixed-20261106/README.md)
- [早期 MTP-only 验收记录](mtp-only-release-20261106/README.md)：如与修订记录冲突，以修订记录和当前 USB 文档为准。

### 上游 my355 参考资料（不是 RG353PS 操作指南）

以下文件来自上游 Miyoo Flip / my355 移植资料，仅用于理解原始 BaseOS 工程和上游实现，不代表 RG353PS 的硬件布局或操作步骤：

- [硬件笔记](hardware.md)、[启动链与 Preloader 研究](boot-chain.md)
- [卡片布局与 A/B 机制](card.md)、[rootfs 笔记](rootfs.md)
- [诊断笔记](diagnostics.md)、[恢复笔记](recovery.md)、[U-Boot 笔记](uboot.md)
- [设计决策](decisions.md)、[历史记录](history.md)

涉及 Preloader、NAND、mtd5、my355 板型和 Miyoo Flip 卡槽的操作不适用于 RG353PS。

## English

This repository contains historical upstream BaseOS material for the Miyoo Flip (my355) as well as a separate RG353PS (RK3566) platform implementation. **Use the RG353PS documentation for installation, flashing, updates and hardware operations. Do not apply my355 Preloader, NAND, mtd5 or card-slot procedures to an RG353PS.**

### RG353PS documentation

| Document | Contents |
|---|---|
| [Installation and updates](../INSTALL.md) | TF1 installation, frontend setup, USB transfer and the 1.2.9 upgrade path |
| [Platform guide](../platforms/rg353ps/README.md) | Architecture, build, image layout and known limitations |
| [USB architecture](../platforms/rg353ps/USB.md) | MTP, Mass Storage, USB SSH, Wi-Fi SFTP and validation |
| [Frontend adapter contract](../platforms/rg353ps/FRONTENDS.md) | Manifest, launch interface, storage and suspend ownership |
| [Power management](../platforms/rg353ps/POWER.md) | Deep suspend, wake and Wi-Fi lifecycle |
| [Boot-logo contract](../platforms/rg353ps/BOOTLOGO.md) | User logos, persistence and restoration after updates |
| [Wi-Fi SFTP / SSH](rg353ps-network-access.md) | Service addresses, ports and switches |

### Releases and validation

- [1.2.9 official release](RG353PS-RELEASE-1.2.9.md), [1.2.8](RG353PS-RELEASE-1.2.8.md), [1.2.7](RG353PS-RELEASE-1.2.7.md)
- [Historical release baseline](RG353PS-RELEASE-BASELINE-1.2.4.md)
- [Contributing guide](../CONTRIBUTING.md)
- [Hardware acceptance follow-up, Issue #21](https://github.com/dengzhan007/BaseOS-RG353PS/issues/21)
- [USB profile inheritance](usb-profile-inheritance.md) documents the earlier defect; usb_debug is historical terminology and current images use ssh_debug.
- [Revised MTP-only acceptance record](mtp-only-release-fixed-20261106/README.md)
- [Initial MTP-only acceptance record](mtp-only-release-20261106/README.md); prefer the revised record and current USB guide where conclusions differ.

### Upstream my355 reference material (not RG353PS instructions)

The following files are retained from the upstream Miyoo Flip / my355 port for historical context. They do not describe RG353PS hardware layout or operating procedures:

- [Hardware notes](hardware.md), [boot-chain and Preloader research](boot-chain.md)
- [Card layout and A/B notes](card.md), [rootfs notes](rootfs.md)
- [Diagnostics](diagnostics.md), [recovery](recovery.md), [U-Boot notes](uboot.md)
- [Design decisions](decisions.md), [history](history.md)

Procedures involving the Preloader, NAND, mtd5, the my355 board or Miyoo Flip card slots do not apply to RG353PS.
