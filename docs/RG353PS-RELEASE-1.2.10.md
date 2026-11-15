# BaseOS for RG353PS 1.2.10

**Release date: 2026-11-15**

## 简体中文

1.2.10 是 RG353PS BaseOS 的前端管理与兼容性版本。在 1.2.9 的系统底座上，本版本加入托管前端包与配置档案、启动选择器、旧式前端自动兼容和更完整的路径映射，并修正诊断界面导航与中英文控制台文字显示。

### 主要变化

- **托管前端包与配置档案（Managed Frontend API v1）**：新增 Frontends/<package-id>/ 包结构，通过 profiles/<profile-id>.conf 为同一程序提供不同的独立配置。多个档案可以共用程序文件，同时拥有独立的 BaseOS 实例数据目录和用户数据目录。
- **启动时前端选择器**：开机时按住 L1 或 R1 可进入前端选择器；Function + Power 的 USB Mass Storage 入口保持更高优先级。A 临时启动所选前端，Start 保存默认前端并启动，B 继续启动已配置的默认项。选择器始终提供内置 BaseOS 诊断入口。
- **前端启用、停用与卸载**：SELECT 统一切换前端启用状态，停用项仍显示在列表中。Y 用于删除托管包中的单个配置档案，X 在二次确认后删除整个前端程序包。删除配置或程序目录不会清除 BaseOS 为该档案保存的实例数据、Games、共享存档或共享核心。
- **单档案默认配置**：随 BaseOS 适配的 LUCKLUCK-SLOT 包默认只提供 640-native 一个档案。用户可复制现有 profile 配置文件、使用新的文件名并修改 display_name，创建额外的独立配置；无需复制或修改共享程序 payload。
- **旧式前端自动兼容**：直接放在 Frontends/<name>/ 下、具有已识别启动入口的普通前端目录可以自动生成 BaseOS 兼容配置。历史 adapter 位置仍受支持。BaseOS 不会通过猜测任意 ELF 来启动程序。
- **旧前端安全管理**：自动兼容项和历史 adapter 可以通过 SELECT 停用；对于独立的 Frontends/<name>/ 程序包，X 经确认后可删除完整程序目录。位于卡根目录或共享容器中的 adapter 使用保守删除边界，避免误删其他文件。
- **路径映射与共享资源**：统一以 Games/ 作为规范游戏目录；兼容旧前端的 Roms/、ROMs/、roms/ 名称映射，并支持映射嵌套的 .system/、Tools/ 和共享核心目录。BaseOS 生成的路径配置保存在 .baseos/frontend-paths/，后续扫描保留用户手动修改。
- **Slot 数据隔离与迁移**：ROM 游戏本体和电池存档继续共享；用户偏好、收藏夹、核心选择及即时存档等档案数据按 profile 隔离。旧 Slot 包身份迁移使用显式 previous_package_id，首次迁移后保留旧实例目录作为回退副本。
- **诊断界面与显示修正**：诊断页面与前端选择器之间的返回流程复用现有选择器，不再重复打开第二个选择器或显示重复入口。修正紧凑 PSF2 控制台字体的中英文/CJK 显示，并在帮助页和按键测试页补充 L1/R1 肩键说明。
- **启动画面绘制**：启动/更新字标与进度提示在同一帧完成合成，减少页面切换时短暂显示中间画面的闪烁。
- **自动化回归检查**：扩展前端发现、包与档案生命周期、兼容目录、路径映射、诊断导航、USB 互斥失败路径、启动画面、Shell/C 语法和字体资源检查。

### 游戏与用户数据规则

| 数据 | 1.2.10 行为 |
|---|---|
| ROM 游戏本体 | 在前端和 profile 之间共享，规范目录为 Games/ |
| 电池存档（.sav） | 共享，位于 Saves/ |
| 模拟器核心 | 使用卡内共享核心或 BaseOS 共享核心目录 |
| 收藏夹、偏好和核心选择 | 按 profile 分开保存 |
| 即时存档/恢复状态 | 按 profile 分开保存 |
| 前端程序 payload | 同一 package 的多个 profile 共用 |

额外 profile 通过复制 profile 配置创建，不需要复制程序目录。前端包卸载不会删除每个 profile 的实例数据和共享游戏数据；重新安装相同 ID 的包/档案可以继续使用保留的数据。

### 安装与升级

- **baseos-rg353ps-1.2.10.img.gz**：完整 TF1 镜像，用于全新安装或完整重刷。
- **baseos-rg353ps-1.2.10.bosupd**：A/B 原地升级包，适用于已经运行官方 1.2.9 的设备。
- **baseos-rg353ps-1.2.10.sha256**：本次发布二进制产物的 SHA-256 校验值。
- **baseos-rg353ps-1.2.10.build.txt**：记录源码提交、内核版本和构建时间。

升级路径：
- 官方 1.2.9 → 1.2.10：可以使用 1.2.10 .bosupd。
- 官方 1.2.8：先按 1.2.9 发布说明应用 1.2.9 .bosupd，确认升级完成后再升级到 1.2.10。
- 1.2.7 或更早版本：需要备份数据并使用 1.2.10 完整镜像迁移；不要直接使用 1.2.10 .bosupd。1.2.8 调整了持久化 SSH 设置名，旧配置应按当前文档检查。

.bosupd 只更新 A/B 系统 BOOT 和 ROOTFS 区域，不包含 Rockchip U-Boot，也不会覆盖独立的用户数据分区。需要更新 U-Boot 或恢复完整分区布局时，应使用完整镜像。完整镜像写入会覆盖目标 TF1 卡，请先备份重要数据。

前端程序仍由用户单独安装。安装托管包时，将完整的 Frontends/<package-id>/ 顶层目录放在 TF1 或 TF2 用户数据分区的 Frontends/ 下，不要拆散包内文件；旧式 adapter 仍可使用历史目录结构。BaseOS 1.2.10 不内置 LUCKLUCK-SLOT 游戏前端或模拟器核心。托管包格式和 profile 创建方法见前端适配规范。

### 验证范围与已知限制

- 前端选择、profile 隔离、共享 ROM/电池存档、档案删除和整个程序包卸载流程，已经在 RG353PS 配合 Slot 测试包完成设备验证；这不代表所有模拟器、核心和游戏组合均已穷尽测试。
- 诊断界面中文/英文显示和修正后的选择器导航已在 RG353PS 实机核对。
- CI 已通过 1.2.10 的完整镜像与 A/B 更新构建，以及相关 USB、前端生命周期、路径、界面和语法回归检查。
- Hosted CI 无法验证需要特权挂载的 exFAT bind-mount 实际行为及完整 teardown；不同卡片布局下的路径映射仍应按前端规范实机验证。
- RG353PS 实机 HDMI 输出仍未完成验证。
- 冷启动时仍可能听到扬声器爆音；1.2.10 沿用既有音频初始化路径，不声称解决此问题。
- USB 文档中已明确标记的 MTP 长时间/反复插拔、Linux GVFS 真机、Windows WPD 覆盖/重命名/删除操作，以及 MTP 与 Mass Storage 负载互斥压力测试仍未全部完成。Mass Storage 的稳定性和写入完整性结果不能替代这些独立测试。
- Wi-Fi 关联、DHCP/路由、深度休眠电流与恢复、Wi-Fi SSH/SFTP 传输及 USB/Wi-Fi 并发等未完成项目继续以 Issue #21 的真实硬件记录为准。

---

## English

BaseOS RG353PS 1.2.10 is a frontend management and compatibility release. Building on the 1.2.9 system base, it introduces managed frontend packages and profiles, a boot-time selector, automatic compatibility for legacy frontend layouts, and more complete path mapping. It also corrects diagnostics navigation and bilingual console text rendering.

### Highlights

- **Managed frontend packages and profiles (Managed Frontend API v1):** adds the Frontends/<package-id>/ package layout and independent profiles/<profile-id>.conf configurations. Profiles can share one executable/resource payload while retaining separate BaseOS instance and user-data directories.
- **Boot-time frontend selector:** hold L1 or R1 while powering on to open the selector. Function + Power USB Mass Storage retains higher priority. A launches the highlighted frontend once; Start saves it as the default and launches it; B continues with the configured default. The built-in BaseOS diagnostics entry is always available.
- **Enable, disable and uninstall controls:** SELECT consistently toggles a frontend's enabled state, while disabled entries remain visible. Y removes one profile from a managed package. X removes the complete frontend package after confirmation. Neither profile nor package removal deletes retained BaseOS instance data, the shared Games library, shared saves or shared cores.
- **Single default Slot profile:** the bundled LUCKLUCK-SLOT package ships with one 640-native profile. Users can create another independent configuration by copying the profile file, assigning a new filename and changing display_name; the shared program payload does not need to be copied or modified.
- **Automatic legacy frontend compatibility:** ordinary folders directly under Frontends/<name>/ can receive a generated BaseOS compatibility entry when they contain a recognized launch entry point. Historical adapter locations remain supported. BaseOS never guesses by launching an arbitrary ELF.
- **Conservative legacy management:** generated compatibility entries and historical adapters can be disabled with SELECT. X can delete a complete, isolated Frontends/<name>/ bundle after confirmation. Adapters in the card root or shared containers use conservative deletion boundaries to avoid removing unrelated files.
- **Path mapping and shared resources:** Games/ is the canonical game directory. Legacy Roms/, ROMs/ and roms/ names can be mapped, as can nested .system/, Tools/ and shared core paths. BaseOS-generated path configuration lives under .baseos/frontend-paths/; later scans preserve user edits.
- **Slot data isolation and migration:** ROMs and battery saves remain shared. Preferences, favorites, core selections and save-state data are profile-private. An explicit previous_package_id supports migration from the previous Slot package identity; the old instance directory is retained as a rollback copy.
- **Diagnostics UI and display fixes:** diagnostics and the frontend selector now hand control back to the existing selector instead of opening a duplicate selector. The compact PSF2 console font's CJK/English rendering is corrected, and L1/R1 shoulder-button guidance is included on the help and controller-test screens.
- **Boot/update splash composition:** the wordmark and progress indicator are composed in one frame to reduce visible intermediate-frame flashes.
- **Automated regression coverage:** expands checks for frontend discovery, package/profile lifecycle, legacy compatibility, path mapping, diagnostics navigation, USB mutual-exclusion failure paths, splash rendering, shell/C syntax and font assets.

### Game and user-data behavior

| Data | Version 1.2.10 behavior |
|---|---|
| ROM files | Shared across frontends and profiles under Games/ |
| Battery saves (.sav) | Shared under Saves/ |
| Emulator cores | Shared card-side cores or the BaseOS shared-core directory |
| Favorites, preferences and core selections | Separate per profile |
| Save-state / resume snapshots | Separate per profile |
| Frontend program payload | Shared by profiles belonging to the same package |

Create additional profiles by copying a profile configuration; there is no need to duplicate the program directory. Uninstalling a frontend package does not remove its retained profile instance data or shared game data. Reinstalling the same package/profile IDs can reuse that data.

### Installation and updates

- **baseos-rg353ps-1.2.10.img.gz**: complete TF1 image for fresh installations or full reflashing.
- **baseos-rg353ps-1.2.10.bosupd**: A/B in-place update package for devices already running the official 1.2.9 release.
- **baseos-rg353ps-1.2.10.sha256**: SHA-256 checksums for the release binaries.
- **baseos-rg353ps-1.2.10.build.txt**: source commit, kernel version and build timestamp.

Upgrade compatibility:
- Official 1.2.9 to 1.2.10: apply the 1.2.10 .bosupd.
- Official 1.2.8: first apply the 1.2.9 update as described in its release notes, then update to 1.2.10.
- 1.2.7 or earlier: back up data and migrate with the 1.2.10 complete image; do not apply the 1.2.10 .bosupd directly. Version 1.2.8 changed the persisted SSH setting name, so review old card-side configuration against the current guide.

The .bosupd package updates only the A/B system BOOT and ROOTFS regions. It does not include Rockchip U-Boot or overwrite the separate user-data partition. Use the complete image when U-Boot or the full partition layout must be updated. Writing a complete image erases the target TF1 card; back up important data first.

The game frontend remains a separate user-installed package. For a managed package, place the intact top-level Frontends/<package-id>/ directory under Frontends/ on the TF1 or TF2 user-data volume; do not split the package files. Legacy adapters can continue using their historical directory layouts. BaseOS 1.2.10 does not bundle the LUCKLUCK-SLOT frontend or emulator cores. See the frontend adapter contract for the package layout and profile creation procedure.

### Validation scope and known limitations

- The frontend selector, profile isolation, shared ROM/battery-save behavior, profile removal and full-package uninstall have been device-tested on RG353PS with the Slot test package. This does not claim exhaustive testing of every emulator, core or game combination.
- The corrected diagnostics navigation and Chinese/English rendering have been checked on physical RG353PS hardware.
- CI passed the 1.2.10 complete-image and A/B update build, along with the related USB, frontend lifecycle, path, UI and syntax regression checks.
- Hosted CI cannot validate privileged exFAT bind-mount behavior and complete teardown. Verify path mapping on hardware for the card layout in use, following the frontend contract.
- HDMI output remains unverified on RG353PS hardware.
- A speaker pop may still be audible during cold boot. Version 1.2.10 retains the established audio initialization path and does not claim to fix it.
- USB items explicitly listed as incomplete in the USB guide remain separate acceptance tasks: long-duration/repeated-unplug MTP, real-hardware Linux GVFS, Windows WPD overwrite/rename/delete operations, and MTP/Mass Storage mutual-exclusion stress under load. Mass Storage stability and write-integrity results do not substitute for these tests.
- Wi-Fi association, DHCP/routing, deep-suspend current and recovery, Wi-Fi SSH/SFTP transfer, and concurrent USB/Wi-Fi testing remain governed by the real-hardware records in Issue #21.
