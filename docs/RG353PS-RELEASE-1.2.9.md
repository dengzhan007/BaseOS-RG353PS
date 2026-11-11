# BaseOS for RG353PS 1.2.9

## 简体中文

1.2.9 基于 1.2.8 发布分支，重点修正 RG353PS 首次 ALSA PCM 初始化时的扬声器爆音，同时恢复从 1.2.8 原地升级的 A/B 更新包。

### 音频初始化调整

- 每次启动/唤醒都先将 `Internal Speakers Switch` 关闭，再检查/创建 softvol，确保第一次 PCM 打开时扬声器端点不接通。
- softvol 可用后先将 `BaseOS Master` 设为最低增益（-48 dB），再恢复扬声器通路；等待 100 ms 后按原逻辑恢复用户保存音量或首次启动默认音量。
- 后续启动或唤醒时，如果 softvol 已存在，不重复关闭/开启扬声器，避免无意义的音频通路切换。
- 保留原有延迟 ALSA 状态恢复、硬件增益固定和用户音量恢复逻辑；不调整 RK817 codec 驱动、功放 GPIO 极性、硬件增益或音量曲线。
- **仅本测试候选增加功放时序实验**：内核构建将 `simple-audio-amplifier` 的 RG353PS 节点切换为 `PRE_PMU`，使能 GPIO 后等待 250 ms，再继续 DAPM 上电。该延时只作用于 RG353PS 的外置扬声器功放节点，不改变其他 simple-amplifier 设备。功放 IC 型号尚未由板级资料确认，不能把 SGM4865 当成已证实型号；实验结果需要真机听音确认，未验收前不得合入正式发行。
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

- On every boot/resume, `Internal Speakers Switch` is turned off before the softvol check and any first PCM open.
- Once softvol is available, `BaseOS Master` is set to its minimum gain (-48 dB) before reconnecting the speaker path. The code waits 100 ms, then restores the saved or first-boot default user volume.
- On later boots or resume, an already-registered softvol control is not toggled off and on again.
- The existing deferred ALSA state restore, hardware-gain pinning, and user-volume restore remain enabled. No RK817 codec driver, amplifier GPIO polarity, hardware gain, or volume-curve changes are included.
- **This test candidate alone includes an amplifier timing experiment**: the RG353PS `simple-audio-amplifier` node uses `PRE_PMU`, asserts the enable GPIO, waits 250 ms, then lets DAPM continue powering up. The delay applies only to this RG353PS external speaker-amp node. The physical amplifier IC has not been confirmed from board-level evidence; SGM4865 remains a hypothesis, not a verified part number. Device listening is required, and this test-only change must not enter a formal release before validation.
- This candidate tests whether minimum digital gain during speaker-path reconnection attenuates the startup transient. The final behavior—normal audio with no startup pop—still requires hardware validation with this candidate. The extremely faint idle noise audible only close to the speaker is not addressed at the hardware level.

### Installation and updates

- `baseos-rg353ps-1.2.9.img.gz`: complete TF1 image for fresh installs or full reflashing.
- `baseos-rg353ps-1.2.9.bosupd`: A/B in-place update package for systems already running 1.2.8; it is not supported on 1.2.7 or earlier.
- `baseos-rg353ps-1.2.9.sha256`: checksums for the selected release artifacts.
- `baseos-rg353ps-1.2.9.build.txt`: exact source commit, kernel version, and build timestamp.

Version 1.2.8 renamed the persisted SSH setting to `ssh_debug`. Migration from 1.2.7 or earlier therefore still requires a complete 1.2.8 or 1.2.9 image flash. Back up important data and keep the device powered throughout an update.

### Validation boundary

Update progress now retains the left-to-right BaseOS wordmark illumination and overlays the bottom status/progress pill. CI verifies the complete image partition layout and the A/B update manifest/region hashes. A successful CI build is not a substitute for hardware acceptance. The key device checks for this release are audible output during startup, no startup pop, and normal audio when entering the frontend and playing games/music.
