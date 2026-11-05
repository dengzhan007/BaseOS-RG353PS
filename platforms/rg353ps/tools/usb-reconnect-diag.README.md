# USB 重连诊断脚本使用说明

`usb-reconnect-diag.sh` 只做采集，不做修复。它一次性记录
`VBUS → BVALID IRQ → OTG 状态机 → extcon USB → DWC3 device event → EP0 SETUP → UDC state`
这条链上的事件，并在退出时把**自己开启的**动态调试规则原样关掉。

## 在 RG353PS 上执行

通过 SSH（`root@192.168.42.1`）或从串口登录后：

```sh
sh /path/to/usb-reconnect-diag.sh
```

脚本会用 60 秒、每 0.5 秒采样一次。看到 `CAPTURE STARTED` 后按下面做：

1. **拔掉 OTG 数据线**
2. 等约 3 秒
3. **插回数据线**
4. 等恢复，或等脚本自己结束（也可按 Ctrl+C 提前停）

脚本不会动 USB、DHCP、Runtime PM、VBUS 或 supervisor，也不会执行任何 recovery / unbind / bind / PHY reset。

## 日志

```
/mnt/SDCARD/usb-reconnect-diag-YYYYMMDD-HHMMSS.log
```

文件名带时间戳，若重名会自动加后缀，**不会覆盖已有日志**。日志内容：

- 头部：脚本版本、开始时间、`/etc/baseos-release`、`uname`、UDC / extcon / IRQ 初始快照、路径存在性、实际启用的规则清单与条数
- `[kmsg]` 行：内核事件原始时间戳。保留 `RG353PS` 目标日志、`dwc3` / `usb2phy` / `extcon` 通用消息、内核 warning / error（`^<[1-4]>` 与 warn/error/fail/oops/panic/call trace 等关键字），以及**带明确 token 的通用 USB 子系统事件**（`usbcore`、`usb 1-1:`、`usb0`、`usb-phy`、`gadget`、`udc`、`xhci*`、`typec`、`ucsi`、`role-switch`、`rockchip_usb*`）。不用裸 `usb` 匹配，避免把 `my usb drive is slow` 这类普通文本收进来；EP2 / bulk-out 等数据面高频行仍然过滤
- `[sample]` 行：每 0.5 秒的 UDC `state/current_speed/maximum_speed`、extcon 全部状态、`/proc/interrupts` 中 USB2PHY / BVALID / OTG / DWC3 的**所有 CPU 累计**计数（附带 IRQ 编号、CPU 总计、CPU 计数之后的**完整描述字段**与 CPU 列数，例如 `20(total=10,desc=GICv3 167 Level rockchip_usb2phy)`）
- 尾部：结束时的同一组快照

`DIAG_MAX_LOG_LINES`（默认 20000）限制的是**实际写入日志文件的总行数**：实时流与采样各自在到达上限时停止写入，退出时再做一次总行数截断兜底。可用 `DIAG_MAX_LOG_LINES=20 DIAG_SECONDS=4 sh usb-reconnect-diag.sh` 验证上限行为。

## 可选参数

```sh
DIAG_SECONDS=90 sh usb-reconnect-diag.sh          # 采集 90 秒
DIAG_INTERVAL=0.25 sh usb-reconnect-diag.sh       # 每 250 ms 采样
DIAG_SECONDS=5 sh usb-reconnect-diag.sh           # 短时干跑，验证脚本本身
```

## 关闭动态调试

**正常结束、Ctrl+C、异常退出都会自动关闭**，无需手工操作。脚本在启用前会检查是否有重叠的、已经开启的规则；若有则直接拒绝运行，避免退出时误关别人的规则。

若确实需要手工兜底（例如脚本被 `kill -9`），逐条执行：

```sh
mount -t debugfs none /sys/kernel/debug 2>/dev/null || :
C=/sys/kernel/debug/dynamic_debug/control
echo 'file phy-rockchip-inno-usb2.c -p' > "$C"
echo 'format "RG353PS DWC3 device DISCONNECT event" -p' > "$C"
echo 'format "RG353PS DWC3 device RESET event" -p' > "$C"
echo 'format "RG353PS DWC3 device-event raw" -p' > "$C"
echo 'format "RG353PS EP0 SETUP" -p' > "$C"
```

不要使用 `file gadget.c +p`：那会打开 EP2 REQMAP / DEPCMD / bulk-out 等每包数条的高频日志。

## 格式串核对（基于设备实际内核）

设备 `1.2.4` / `7.2.7-baseos-rg353ps` 的 `dynamic_debug/control` 里，下列 9 条确实存在：

`RG353PS BVALID IRQ entry`、`RG353PS OTG state-machine entry`、`RG353PS USB PHY OTG sample`、
`RG353PS OTG VBUS decision`、`RG353PS extcon notify before`、
`RG353PS DWC3 device DISCONNECT event`、`RG353PS DWC3 device RESET event`、
`RG353PS DWC3 device-event raw`、`RG353PS EP0 SETUP`。

**`RG353PS extcon notify after` 不存在**（那是较早一版本地源码树的注入）。设备上的对应日志是
`RG353PS extcon charger result` 与 `RG353PS extcon data result`。脚本用
`file phy-rockchip-inno-usb2.c +p` 覆盖整个 PHY 文件，这三条都会被采集，因此不影响事件链完整性。

另有一条 `RG353PS DWC3 bulk-out event`（短版）是 `dev_info_ratelimited`，**不受动态调试控制、常开**；脚本在采集时把它过滤掉。

## 兼容性与验证状态

已在本机静态验证：`sh -n` / `dash -n`、selector 与设备格式串比对、启用/关闭规则一一对应、无修改 USB 状态的命令、无高频规则、缺 sysfs 节点时记 `N/A`。

设备上已验证过的环境能力（2026-11-05）：

- BusyBox v1.37.0，`dmesg` 只有 `-c/-r/-n/-s`，**没有 `-w`** → 脚本改用 `/proc/kmsg` 实时流
- debugfs 默认未挂载 → 脚本自行挂载，并在退出时卸载（仅当是自己挂的）
- `sleep 0.5`、awk `fflush()`、`id -u`、`/proc/interrupts` 计数、UDC / extcon sysfs 均可用
- 无 `klogd` / `syslogd` 抢占 `/proc/kmsg`

### 本地 awk 回归测试

新增 `test-usb-reconnect-diag-awk.sh`：运行时**从产品脚本里直接提取**两段 awk 程序，测试副本不会与设备实际执行的代码漂移。

```sh
cd platforms/rg353ps/tools
sh test-usb-reconnect-diag-awk.sh
```

样本覆盖 9 类内核日志（RG353PS PHY/DWC3、普通 USB 枚举、usbcore、gadget/UDC、xHCI、typec/role-switch、Rockchip USB、WARNING/ERROR、无关普通日志）与 EP2/bulk-out 高频日志；4 CPU 的 `/proc/interrupts` 样本验证累计值、IRQ 编号与完整描述字段；另验证 `max=3` 只写 3 行。共 24 项断言。

### 设备干跑验证（2026-11-05，无拔插）

修复版在设备上做过两次短时干跑（`DIAG_SECONDS=4` / `DIAG_SECONDS=6`），以及一次 SIGTERM 中途终止测试：

| 检查项 | 结果 |
|---|---|
| `enabled_rule_count` | 18（5 条 selector 命中的实际规则数） |
| `[kmsg]` 实时事件行 | 同时保留 `RG353PS EP0 SETUP` 与 `<4> dwc3_endpoint_interrupt: ... callbacks suppressed` 等通用 warning |
| 高频数据面日志 | EP2 / bulk-out 命中 0 行 |
| IRQ 计数 | `20(rockchip_usb2phy,total=189),21(...,total=0),31(dwc3,total=54122) cpus=4`，识别 4 个 CPU 列并保留编号与名称 |
| `[sample]` 采样行 | 每 0.5 秒一条，与设定一致 |
| **A** 正常结束（4 s） | 规则 0、debugfs 卸载、无残留进程 |
| **B** SIGTERM（2 s 后终止） | 规则 0、debugfs 卸载、无残留进程 |
| **C** `DIAG_MAX_LOG_LINES=20` | 日志恰好 20 行，末行为 `[diag] log truncated to 20 lines (limit)` |
| **D** 自挂 debugfs + 规则冲突 | `exit 1`；debugfs 已卸载；**外部那条 `=p` 规则未被关闭** |
| **E** debugfs 原本已挂载 | 运行后仍 `MOUNTED`，日志记 `debugfs_mounted_by_script=0` |
| **F** OUTDIR 检查失败 | `exit 1`；debugfs 未挂载、无残留、未写日志 |
| **G** 本地 awk 回归测试 | 24 项断言全通过：目标日志保留、无关文本与 EP2/bulk-out 过滤、4 CPU 累计与完整描述字段、`max=3` 上限 |

干跑日志与临时脚本已从设备删除，设备恢复到测试前状态。

### 1.1 的三项补充修复

- **早期退出清理**：退出 trap 现在安装在所有 preflight 之前。脚本自行挂载 debugfs 后，无论权限检查、规则冲突还是日志创建失败，都会卸载；原本已挂载的 debugfs 一律不动；规则未启用时不执行任何关闭动作。
- **IRQ 计数**：从只读 CPU0 改为累加所有 CPU 列，并保留 IRQ 编号与中断名；不改 IRQ affinity 或任何中断配置。
- **日志过滤与上限**：扩展保留范围但继续排除数据面高频日志；行数上限改为约束日志文件总行数。

`cleanup()` 里所有写日志的操作都先检查 `LOG` 是否存在，因此 preflight 早期失败时不会误写或报 `set -u` 错误。

脚本版本 1.1。**真实拔插场景下的完整事件链尚未实测**，需要人工执行一次上面的操作流程后回传日志。
