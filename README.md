# BaseOS for Anbernic RG353PS

[简体中文](#简体中文) | [English](#english)

---

## 简体中文

面向 **Anbernic RG353PS（Rockchip RK3566）** 的轻量级 Linux 系统底座。BaseOS 提供设备启动、硬件与系统服务、存储管理、前端发现和系统更新；游戏界面由独立前端提供。

当前平台版本：**1.2.6**

### 功能概览

- **独立的 RG353PS 系统镜像**：提供完整 SD 卡镜像（`.img.gz`）和 A/B 系统升级包（`.bosupd`），两种产物可以独立构建和发布。
- **首次启动自动扩容**：全新安装后，系统会自动将空白的 `BASEOS` 用户数据分区扩展到 TF 卡末尾，并格式化为 exFAT。
- **前端自动发现**：优先查找 TF2；TF2 没有可用前端时，再查找 TF1。没有找到可用前端时进入内置诊断界面。
- **持久化用户数据**：系统更新采用 A/B 机制，用户数据分区与系统槽分离，更新不会主动清除用户文件。
- **USB 文件传输与调试**：Release 默认启用 MTP；开发配置可启用 USB 虚拟网卡、SSH 和 MTP；另提供独占 USB Mass Storage 模式。
- **设备基础功能**：集成显示、按键输入、RK817 音频、Wi-Fi、蓝牙及电源管理相关适配。
- **启动画面持久化**：自定义启动图保存在用户数据分区，系统更新后会在启动阶段恢复。

### 底座与前端的职责

BaseOS 与游戏前端分层工作：

| BaseOS 负责 | 前端负责 |
|---|---|
| 识别并挂载 TF1、TF2 | 扫描游戏目录 |
| 自动发现并选择可用前端 | 识别 ROM 格式和游戏所属机种 |
| 启动前端并提供存储路径 | 游戏列表、封面和界面展示 |
| 提供系统服务、USB 模式和更新机制 | 游戏启动、模拟器及游戏相关数据管理 |

**游戏识别属于前端的工作，不是 BaseOS 的 ROM 扫描功能。** BaseOS 负责挂载存储设备并向前端提供路径；不同前端可以有不同的游戏目录规则和跨卡能力。

BaseOS 不规定统一的游戏目录或前端与游戏是否必须位于同一张卡。前端适配器负责配置自己的游戏根目录；支持多卡或多个游戏根目录的前端可以采用各自的存储布局。

### 安装与升级

1. 将完整系统镜像写入 TF1，并首次启动 RG353PS。首次启动时，BaseOS 会自动初始化并扩展 `BASEOS` 用户数据分区。
2. 系统启动后，再安装所需的游戏前端。可以通过 MTP、USB Mass Storage、读卡器或拔卡方式，将前端文件写入目标 TF 卡。
3. 前端应按其适配说明解压到对应卡的指定位置。不要将前端或游戏文件放进小容量的 `BASEOS_BOOT` 启动分区。
4. 前端及游戏目录的卡片布局由对应适配器决定，请遵循该前端的存储布局要求。

BaseOS 支持完整镜像全新安装和 `.bosupd` 原地升级。A/B 更新切换系统槽，不需要重新安装前端或清空用户数据；升级前仍建议备份重要文件。

详细步骤见 [RG353PS 平台说明](platforms/rg353ps/README.md) 和 [通用前端适配器规范](platforms/rg353ps/FRONTENDS.md)。

### USB 连接说明

RG353PS 的 USB 文件传输和调试功能使用机身 **DC 接口**。MTP、Mass Storage 和 USB 虚拟网卡 SSH 均应连接 DC 接口；连接 OTG 接口不能使用这里描述的这些功能。

- **Release 默认配置：** MTP-only，可通过电脑访问用户数据分区中的文件。
- **开发配置：** USB 虚拟网卡 + SSH + MTP，用于连接电脑进行远程调试和文件传输。SSH 默认用户名为 `root`，默认密码为 `root`。此默认凭据仅用于开发调试配置；请勿将该配置暴露到不可信网络，并建议在实际使用前修改密码。
- **USB 虚拟网卡：** 提供设备与电脑之间的点对点调试通道，**不是互联网共享或网络热点**。
- **Mass Storage：** 独占导出用户数据卷，设备在该模式下不会同时挂载和访问被导出的卷。

**Windows 网络异常处理：** 启用开发配置中的 USB RNDIS/SSH 通道时，Windows 可能把没有互联网出口的 USB 网卡选为默认路由，导致部分网站或网络服务访问异常。将 Windows RNDIS 网卡的 IPv4 接口跃点手动设为 `9999`，并关闭“自动跃点”；这只降低 RNDIS 的默认路由优先级，不影响通过 `192.168.42.1` 使用 USB SSH。具体 PowerShell 和图形界面步骤见 [USB 技术说明](platforms/rg353ps/USB.md#windows-host-routing-with-usb-rndisssh-enabled)。

进入 Mass Storage 时，建议先将数据线连接到 RG353PS 的 DC 接口，再按住 **Function 并按 Power 开机**。先插线通常更容易完成 USB 枚举；开机进入等待状态后再插线，可能需要较长时间才能连接。

更多技术细节和已完成的测试范围见 [USB 架构与验证记录](platforms/rg353ps/USB.md)。

### 诊断与已知限制

内置诊断界面提供按键测试、音频测试和 USB Mass Storage 入口。它不是通用系统恢复界面；用户数据初始化失败时出现的全屏重试提示属于启动初始化流程。

HDMI 相关代码和设备树支持仍在平台中，但 **RG353PS 实机 HDMI 输出尚未完成验证**，目前不作为已验证功能承诺。

### 文档

- [RG353PS 平台说明](platforms/rg353ps/README.md)
- [前端安装、发现与存储规则](platforms/rg353ps/FRONTENDS.md)
- [USB 架构与硬件验证](platforms/rg353ps/USB.md)
- [启动画面持久化规范](platforms/rg353ps/BOOTLOGO.md)
- [更新与发布工作流](.github/workflows/rg353ps-release.yml)
- [贡献指南](CONTRIBUTING.md)

### Contributors

- [dengzhan007](https://github.com/dengzhan007) — 项目维护与平台移植
- [ChatGPT](https://chatgpt.com/) — AI 辅助分析、开发与文档协作
- [DeepSeek](https://www.deepseek.com/) — AI 辅助分析与开发协作

### 致谢

本项目 Fork 自 [apommel/baseos-my355](https://github.com/apommel/baseos-my355)。感谢原作者及所有贡献者的开源工作，为本项目提供了重要的基础。

---

## English

A lightweight Linux system foundation for the **Anbernic RG353PS (Rockchip RK3566)**. BaseOS provides device boot, hardware and system services, storage management, frontend discovery, and system updates. The user interface and game library are provided by independent frontends.

Current platform version: **1.2.6**

### Features

- **Dedicated RG353PS system images:** a complete SD-card image (`.img.gz`) and an A/B system update package (`.bosupd`) are available as independently buildable and publishable artifacts.
- **Automatic first-boot expansion:** on a fresh installation, the blank `BASEOS` user-data partition is automatically expanded to the end of the TF card and formatted as exFAT.
- **Automatic frontend discovery:** BaseOS checks TF2 first, then TF1 if no usable frontend is found on TF2. The built-in diagnostic UI starts when neither card provides a usable frontend.
- **Persistent user data:** A/B system slots are separate from the user-data partition. System updates do not intentionally erase user files.
- **USB transfer and debugging:** Release builds default to MTP; development configuration can enable a USB virtual network interface, SSH, and MTP. An exclusive USB Mass Storage mode is also available.
- **Device integration:** display, button input, RK817 audio, Wi-Fi, Bluetooth, and power-management adaptations are integrated.
- **Persistent boot logo:** custom boot logos are stored in user data and restored during startup after system updates.

### BaseOS and frontend responsibilities

BaseOS and game frontends have separate responsibilities:

| BaseOS | Frontend |
|---|---|
| Detects and mounts TF1 and TF2 | Scans game directories |
| Discovers and selects an available frontend | Identifies ROM formats and systems |
| Launches the frontend and provides storage paths | Presents the game library, artwork, and UI |
| Provides system services, USB modes, and updates | Launches games and manages emulator/game data |

**Game discovery and ROM identification belong to the frontend, not to a BaseOS ROM-scanning service.** BaseOS mounts storage devices and exposes paths to the frontend. Directory layouts and multi-card support depend on each frontend.

BaseOS does not prescribe a universal game directory or require the frontend and game library to share one card. Each adapter configures its own game roots and may support one or multiple cards.

### Installation and updates

1. Write the complete system image to TF1 and boot the RG353PS. On first boot, BaseOS initializes and automatically expands the `BASEOS` user-data partition.
2. After the system starts, install the desired game frontend. Frontend files can be copied using MTP, USB Mass Storage, a card reader, or by removing the card.
3. Extract frontend files to the location specified by that frontend's installation instructions. Do not put frontend or game files on the small `BASEOS_BOOT` partition.
4. Frontend and game-library card layout is defined by the selected adapter; follow that frontend's storage instructions.

BaseOS supports fresh installation from a complete image and in-place upgrades using `.bosupd`. A/B updates switch the system slot without requiring frontend reinstallation or user-data erasure. Back up important files before upgrading.

See the [RG353PS platform guide](platforms/rg353ps/README.md) and [frontend installation and discovery guide](platforms/rg353ps/FRONTENDS.md).

### USB connection notes

The RG353PS USB transfer and debugging features use the device's **DC port**. MTP, Mass Storage, and USB virtual-network SSH must be connected through the DC port; the OTG port does not support the functions described here.

- **Release default:** MTP-only, allowing a computer to access files in the user-data partition.
- **Development configuration:** USB virtual network + SSH + MTP for remote debugging and file transfer. The default SSH username is `root` and the default password is `root`. These default credentials are for the development configuration only. Do not expose this configuration to untrusted networks; change the password before practical use.
- **USB virtual network:** a point-to-point debugging link between the handheld and the computer; **it does not provide internet sharing or a network hotspot**.
- **Mass Storage:** exclusively exports the user-data volume. The device does not mount or access that volume locally while it is exported.

**Windows network warning:** When the development USB RNDIS/SSH channel is enabled, Windows may prefer the USB adapter as a default route even though that point-to-point link has no internet gateway. Some websites or network services can then fail. Set the Windows RNDIS adapter IPv4 interface metric to `9999` and disable Automatic metric. This lowers its default-route priority without preventing SSH to `192.168.42.1`. See the [USB host-routing instructions](platforms/rg353ps/USB.md#windows-host-routing-with-usb-rndisssh-enabled).

To enter Mass Storage, connect the data cable to the RG353PS DC port first, then hold **Function and press Power** to boot. Connecting the cable first generally makes USB enumeration more reliable. If the device is already waiting for a connection before the cable is inserted, connection may take considerably longer.

See the [USB architecture and validation notes](platforms/rg353ps/USB.md) for details.

### Diagnostics and known limitations

The built-in diagnostic UI provides button testing, audio testing, and an entry to USB Mass Storage. It is not a general-purpose system recovery interface. The full-screen retry prompt shown after a user-data initialization failure belongs to the boot-time initialization flow.

HDMI-related code and device-tree support are present, but **HDMI output has not yet been verified on RG353PS hardware** and is not claimed as a validated feature.

### Documentation

- [RG353PS platform guide](platforms/rg353ps/README.md)
- [Generic frontend adapter contract](platforms/rg353ps/FRONTENDS.md)
- [USB architecture and hardware validation](platforms/rg353ps/USB.md)
- [Boot-logo persistence contract](platforms/rg353ps/BOOTLOGO.md)
- [Release workflow](.github/workflows/rg353ps-release.yml)
- [Contributing guide](CONTRIBUTING.md)

### Contributors

- [dengzhan007](https://github.com/dengzhan007) — project maintainer and platform port
- [ChatGPT](https://chatgpt.com/) — AI-assisted analysis, development, and documentation
- [DeepSeek](https://www.deepseek.com/) — AI-assisted analysis and development

### Acknowledgements

This project is forked from [apommel/baseos-my355](https://github.com/apommel/baseos-my355). Many thanks to the original author and all contributors for their open-source work and for providing the foundation for this project.
