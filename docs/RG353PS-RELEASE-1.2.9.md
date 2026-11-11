# BaseOS for RG353PS 1.2.9

## 简体中文

1.2.9 基于 1.2.8 发布分支，重点修正 RG353PS 首次 ALSA PCM 初始化时的扬声器爆音，同时恢复从 1.2.8 原地升级的 A/B 更新包。

### 音频初始化调整

- 首次创建 `BaseOS Master` softvol 控件时，先将 RK817 的 `Internal Speakers Switch` 设为关闭，再打开第一次 ALSA PCM，避免在扬声器通路开启时执行首次 PCM 初始化。
- PCM/softvol 初始化步骤结束后立即恢复 `Internal Speakers Switch`，正常声音输出仍然开启。
- 后续启动或唤醒时，如果 softvol 已存在，不重复关闭/开启扬声器，避免无意义的音频通路切换。
- 保留原有延迟 ALSA 状态恢复、硬件增益固定和用户音量恢复逻辑；不调整 RK817 驱动、功放 GPIO、功放延时或音量曲线。
- 该改动来自 RG353PS 实机的启动爆音隔离测试。最终“恢复扬声器后仍无爆音且声音正常”的结果仍需使用本候选包完成实机确认。极低电平、贴近扬声器才能听到的待机底噪未作硬件级处理。

### 安装与升级

- `baseos-rg353ps-1.2.9.img.gz`：完整 TF1 镜像，用于新装或完整重刷。
- `baseos-rg353ps-1.2.9.bosupd`：A/B 原地升级包，适用于已经运行 1.2.8 的系统；不适用于 1.2.7 或更早版本。
- `baseos-rg353ps-1.2.9.sha256`：本次发布产物校验值。
- `baseos-rg353ps-1.2.9.build.txt`：精确源码提交、内核版本和构建时间。

1.2.8 将持久化 SSH 设置名调整为 `ssh_debug`，因此从 1.2.7 或更早版本迁移仍须先完整刷写 1.2.8 或 1.2.9 镜像。升级前请备份重要数据，升级期间保持供电稳定。

### 验证边界

CI 会分别校验完整镜像分区布局和 A/B 更新包 manifest/区域哈希。CI 构建成功不等于设备实机验收；本版本的关键实机验收项目是首次开机有正常声音、启动爆音消失、进入前端及播放游戏/音乐均正常。

---

## English

BaseOS RG353PS 1.2.9 is based on the 1.2.8 release branch. It adjusts the first ALSA PCM initialization sequence to address the RG353PS startup pop and restores A/B update packages for in-place upgrades from 1.2.8.

### Audio initialization

- When the `BaseOS Master` softvol control is first created, the RK817 `Internal Speakers Switch` is turned off before the first ALSA PCM is opened.
- Normal speaker output is restored immediately after PCM/softvol initialization completes.
- On later boots or resume, an already-registered softvol control is not toggled off and on again.
- The existing deferred ALSA state restore, hardware-gain pinning, and user-volume restore remain enabled. No RK817 driver, amplifier GPIO, amplifier delay, or volume-curve changes are included.
- This change follows the RG353PS startup-pop isolation test. The final behavior—normal audio with no startup pop after speaker output is restored—still requires hardware validation with this candidate. The extremely faint idle noise audible only close to the speaker is not addressed at the hardware level.

### Installation and updates

- `baseos-rg353ps-1.2.9.img.gz`: complete TF1 image for fresh installs or full reflashing.
- `baseos-rg353ps-1.2.9.bosupd`: A/B in-place update package for systems already running 1.2.8; it is not supported on 1.2.7 or earlier.
- `baseos-rg353ps-1.2.9.sha256`: checksums for the selected release artifacts.
- `baseos-rg353ps-1.2.9.build.txt`: exact source commit, kernel version, and build timestamp.

Version 1.2.8 renamed the persisted SSH setting to `ssh_debug`. Migration from 1.2.7 or earlier therefore still requires a complete 1.2.8 or 1.2.9 image flash. Back up important data and keep the device powered throughout an update.

### Validation boundary

CI verifies the complete image partition layout and the A/B update manifest/region hashes. A successful CI build is not a substitute for hardware acceptance. The key device checks for this release are audible output during startup, no startup pop, and normal audio when entering the frontend and playing games/music.
