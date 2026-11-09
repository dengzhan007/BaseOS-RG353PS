# RG353PS 电源管理与深度休眠

## 简体中文

### 支持范围

RG353PS（RK3566）支持 Linux suspend-to-RAM 深度休眠模式。内核通过 /sys/power/state 暴露 mem，并通过 /sys/power/mem_sleep 提供 deep / s2idle。BaseOS 的运行时入口是：

~~~sh
/usr/sbin/rg353ps-sleep
~~~

这是**挂起到 RAM**，不是关机，也不是休眠到磁盘（hibernation）：系统内存状态保留，按机身 Power 键唤醒后继续当前启动会话。当前不能依赖 RTC 定时唤醒；需要用户按 Power 键唤醒。

### BaseOS 深度休眠流程

rg353ps-sleep 是产品运行时路径，执行以下步骤：

1. 记录 Wi-Fi 当前连接状态，并停止 DHCP / wpa_supplicant。
2. 解绑 Realtek SDIO Wi-Fi 功能驱动。该驱动会申请 MMC_PM_KEEP_POWER；休眠前解绑，MMC 才能在 deep suspend 窗口关闭 Wi-Fi 电源轨。
3. 选择 deep，同步文件系统、关闭背光，并向 /sys/power/state 写入 mem。
4. Power 键唤醒后恢复背光、重新绑定 Wi-Fi 驱动；若休眠前无线服务已运行或已连接，则重新启动 wpa_supplicant 和 DHCP。
5. 恢复休眠前的 mem_sleep 选择并写入休眠日志。

如果 deep suspend 请求失败且 Wi-Fi 已成功解绑，脚本会再尝试 s2idle，避免设备完全失去休眠能力。若解绑本身失败，脚本会保留错误记录，不会把这次尝试伪装成 deep suspend 成功。

### 前端适配约定

BaseOS 启动前端时导出：

~~~sh
BASEOS_SLEEP=/usr/sbin/rg353ps-sleep
~~~

前端应在用户明确触发休眠时启动该程序，而不是用“息屏 N 分钟后 poweroff”来模拟休眠。休眠前应先保存游戏状态；脚本会负责系统层的 Wi-Fi 关闭与恢复。由于 BASEOS_SLEEP 由适配器提供，其他平台或桌面开发环境没有该变量时，前端可以保留自身的备用电源策略。

Slot 的 RG353PS 适配已通过此接口进入 BaseOS 深度休眠；设置页显示“系统深度休眠”，并忽略旧卡上遗留的自动关机分钟数。长按关机仍是独立的真正关机路径。

### 手动检查与诊断

只读检查当前内核能力：

~~~sh
cat /sys/power/state
cat /sys/power/mem_sleep
~~~

应能看到 mem，并在 mem_sleep 中看到 deep。实际运行时由 rg353ps-sleep 选择 deep。

如需检查设备唤醒源而不触发休眠，可运行：

~~~sh
/usr/sbin/rg353ps-suspend-audit
~~~

该命令只读，不会改变电源状态。若需要一次性将报告写入 BASEOS_BOOT，在电脑上于该分区根目录创建空文件 BASEOS-SUSPEND-AUDIT，然后启动设备一次。

不要在 USB Mass Storage 模式或文件传输过程中测试休眠。长时间无响应时，长按 Power 可能触发 PMIC 硬件断电，会丢失尚未保存的数据；只应作为最后恢复手段。

---

## English

### Supported mode

The RG353PS (RK3566) supports Linux suspend-to-RAM deep suspend. The kernel exposes mem through /sys/power/state and offers deep / s2idle through /sys/power/mem_sleep. BaseOS provides this runtime entry point:

~~~sh
/usr/sbin/rg353ps-sleep
~~~

This is suspend-to-RAM, **not poweroff and not disk hibernation**. RAM remains powered so the current boot session can resume. Wake the device with its physical Power button. RTC-timed self-wakeup is not currently supported.

### Runtime sequence

The product helper performs the following steps:

1. Records whether Wi-Fi was connected, then stops DHCP and wpa_supplicant.
2. Unbinds the Realtek SDIO Wi-Fi function driver. The driver requests MMC_PM_KEEP_POWER; unbinding lets the MMC core cut the Wi-Fi rail during deep suspend.
3. Selects deep, syncs filesystems, turns off the backlight and writes mem to /sys/power/state.
4. After the Power key wakes the device, restores the backlight, rebinds Wi-Fi, and restarts wpa_supplicant / DHCP when Wi-Fi had been active.
5. Restores the prior mem_sleep selection and writes a sleep log.

If deep suspend fails after Wi-Fi was successfully unbound, the helper attempts s2idle as a fallback. An unbind failure is logged and is not reported as a successful deep-suspend transition.

### Frontend adapter contract

BaseOS exports this variable before launching a frontend:

~~~sh
BASEOS_SLEEP=/usr/sbin/rg353ps-sleep
~~~

A frontend should launch this helper when the user requests suspend, rather than approximating sleep with an idle timer that later calls poweroff. Save game state before entering suspend; the helper owns system-level Wi-Fi shutdown and recovery. Other platforms and desktop development environments may omit this variable, so a frontend may retain its platform-independent fallback policy.

The RG353PS Slot adapter now uses this hook, shows “Deep Suspend” in its settings page, and ignores legacy auto-poweroff minutes stored on older cards. Long-press poweroff remains a separate, explicit shutdown path.

### Inspection and diagnostics

Read the kernel's advertised capabilities without suspending:

~~~sh
cat /sys/power/state
cat /sys/power/mem_sleep
~~~

The output should include mem and deep. The runtime helper selects deep before requesting suspend.

For a read-only wake-source audit:

~~~sh
/usr/sbin/rg353ps-suspend-audit
~~~

To request a one-shot report on BASEOS_BOOT, create an empty BASEOS-SUSPEND-AUDIT file at the root of that partition from a PC and boot once.

Do not test suspend while USB Mass Storage mode is active or while files are transferring. A long Power-button hold may invoke the PMIC's hard power cut if the device is unresponsive; use it only as a last resort because unsaved data may be lost.
