# BaseOS for RG353PS 1.2.9

## 简体中文

1.2.9 基于正式版 1.2.8，恢复从 1.2.8 原地升级的 A/B 更新包，并改进系统更新时的进度显示。USB、Wi-Fi、前端接口及音频初始化均沿用 1.2.8 的实现。

### 主要变化

- **恢复 A/B 原地升级**：已全新安装正式版 1.2.8 的设备可以使用 1.2.9 的 `.bosupd` 更新包，不需要重新刷写 TF 卡，也不会主动清除用户数据。
- **更新进度显示**：更新过程中继续显示 BaseOS 字标进度，并叠加底部状态/进度提示；进度仍根据实际写入和校验的数据量计算。
- **保持 1.2.8 的系统功能**：保留 USB MTP / Mass Storage、USB 与 Wi-Fi SSH 管理、Wi-Fi SFTP、启动画面持久化、前端 manifest / adapter 和现有电源管理行为。
- **音频逻辑不变**：音频初始化脚本和内核音频路径恢复为 1.2.8 的实现。本版本不包含扬声器 DAPM 延后启用、功放 250 ms 延时或提前拉高功放 EN 等实验改动。
- **已知音频限制**：RG353PS 冷启动时可能仍听到轻微扬声器爆音。1.2.9 不声称解决此问题；复测未发现音频候选方案相对 1.2.8 有明显改善，因此正式版保持 1.2.8 的音频行为。

### 安装与升级

- `baseos-rg353ps-1.2.9.img.gz`：完整 TF1 镜像，用于新装或需要完整重刷的情况。
- `baseos-rg353ps-1.2.9.bosupd`：A/B 原地升级包，适用于已经运行正式版 1.2.8 的设备。
- `baseos-rg353ps-1.2.9.sha256`：本次发布产物校验值。
- `baseos-rg353ps-1.2.9.build.txt`：精确源码提交、内核版本和构建时间。

1.2.8 将持久化 SSH 设置名调整为 `ssh_debug`。因此，从 1.2.7 或更早版本迁移仍须先使用完整镜像全新刷写 1.2.8 或 1.2.9；不能直接使用 1.2.9 的 `.bosupd`。升级前请备份重要数据，升级期间保持供电稳定。

### 验证范围与限制

CI 会构建 U-Boot、Linux 内核、DTB、rootfs、完整镜像和 A/B 更新包，并检查镜像分区布局及更新包 manifest / 区域哈希。构建成功不等于所有硬件功能均已实机验收。HDMI 输出仍未完成 RG353PS 实机验证；轻微开机音频爆音仍是已知限制。

---

## English

BaseOS RG353PS 1.2.9 is based on the 1.2.8 release. It restores A/B in-place update packages for 1.2.8 installations and improves system-update progress display. USB, Wi-Fi, frontend interfaces, and audio initialization retain the 1.2.8 implementation.

### Highlights

- **A/B in-place updates restored:** Devices freshly installed with the official 1.2.8 release can use the 1.2.9 `.bosupd` package without reflashing the TF card. User data is not intentionally erased.
- **Update progress display:** The BaseOS wordmark progress remains visible with a bottom status/progress overlay. Progress continues to be calculated from bytes actually written and verified.
- **1.2.8 system behavior retained:** USB MTP / Mass Storage, USB and Wi-Fi SSH management, Wi-Fi SFTP, persistent boot-logo handling, frontend manifest / adapter interfaces, and existing power-management behavior are retained.
- **Audio behavior unchanged:** The audio initialization script and kernel audio path are restored to the 1.2.8 implementation. This release does not include the experimental DAPM speaker gating, 250 ms amplifier delay, or early amplifier-EN assertion.
- **Known audio limitation:** A faint speaker pop may still be audible during a cold boot on RG353PS. Version 1.2.9 does not claim to fix it. Repeated testing found no meaningful audio improvement from the candidate sequence compared with 1.2.8, so the official release keeps the 1.2.8 audio behavior.

### Installation and updates

- `baseos-rg353ps-1.2.9.img.gz`: complete TF1 image for fresh installations or full reflashing.
- `baseos-rg353ps-1.2.9.bosupd`: A/B in-place update package for devices already running the official 1.2.8 release.
- `baseos-rg353ps-1.2.9.sha256`: checksums for the release artifacts.
- `baseos-rg353ps-1.2.9.build.txt`: exact source commit, kernel version, and build timestamp.

Version 1.2.8 renamed the persisted SSH setting to `ssh_debug`. Migration from 1.2.7 or earlier still requires a fresh flash of the complete 1.2.8 or 1.2.9 image; the 1.2.9 `.bosupd` package must not be applied directly to those older versions. Back up important data and keep the device powered throughout an update.

### Validation scope and limitations

CI builds U-Boot, the Linux kernel, DTB, rootfs, complete image, and A/B update package, and checks the image partition layout and update manifest / region hashes. A successful build does not mean every hardware feature has been accepted on a physical device. HDMI output remains unverified on RG353PS hardware, and the faint startup audio pop remains a known limitation.