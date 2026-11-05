# DWC3 重连路径打点：注入与验证记录

**状态：本轮只完成源码打点、脚本扩展与静态/干跑验证。第二次真实拔插测试尚未执行**（需先构建包含新诊断内核的镜像）。本文件不是实机拔插结果。

## 1. 目标与基线

- 工作分支 `usb-reconnect-diag`，本轮修改前 HEAD `b74ad9fae5cc5191ba04f3b7a706758fd9f93532`。
- 依据：`docs/usb-reconnect-tests/USB-OTG-RECONNECT-TEST-20261105.md` 的真实日志结论——PHY/IRQ/OTG/excon 均正常，`EXTCON_USB` 在 14:37:08 置 1 但 DWC3 未自发重连，靠 supervisor 在 14:37:10 发起 re-probe 后于 14:37:15 恢复；DHCP/枚举正常。
- 本轮目标是把「extcon=1 之后 DWC3 没有动作」进一步定位到具体调用路径，**不修复任何尚未证实的故障**。没有重新推测 PHY 或 DHCP 为故障源。

## 2. 修改文件清单

| 文件 | 变更 |
|---|---|
| `platforms/rg353ps/kernel/tools/inject-reconnect-diag.py` | **新增**：幂等注入 9 条 `dev_dbg`（8 条 gadget.c、1 条 udc/core.c） |
| `platforms/rg353ps/build-kernel.sh` | 末尾新增一行 `python3 /inputs/tools/inject-reconnect-diag.py "$SRC"`；其余 2553 行未动 |
| `platforms/rg353ps/tools/usb-reconnect-diag.sh` | 5 条 selector 扩到 9 条（启用/关闭/头部清单/冲突检查/`enabled_rule_ok=N/9`） |
| `platforms/rg353ps/tools/usb-reconnect-diag.README.md` | 新增字段、事件顺序、四种情形的分析方法；修正旧版「真实拔插未实测」表述 |
| `platforms/rg353ps/USB.md` | 诊断章节同步（原文前 11482 字节未改） |
| `docs/usb-reconnect-tests/instrumentation-20261105.diff` | 本轮完整 diff（403 行 / 17 个 hunk） |
| 本文件 | 验证记录 |

内核源码改写放在独立文件而不是嵌入式 heredoc，原因是所有既有改写块都位于 `docker run ... sh -euc '...'` 的**单引号字符串**内，块内不能出现单引号；独立脚本通过 `/inputs`（`platforms/rg353ps/kernel` 的容器内挂载点）访问。`INPUT_KEY` 含 `build-kernel.sh` 的 SHA256，本轮改动会使缓存的源码树重新展开，注入得以执行。

## 3. 新增日志对应的函数与判断分支

| 格式串子前缀 | 文件 / 函数 | 判断分支与记录内容 |
|---|---|---|
| `DISCONNECT entry` | gadget.c `dwc3_gadget_disconnect_interrupt()` | 函数入口，记录断开瞬间的 `connected` / `pullups` / `softconnect` / `state` / `speed`（此时 `connected` 尚未被清零） |
| `PULLUP entry` | gadget.c `dwc3_gadget_pullup()` | `is_on = !!is_on` 之后，记录请求的 `is_on`、当前 `pullups_connected` / `connected` / `state` |
| `PULLUP pm` | gadget.c `dwc3_gadget_pullup()` | `pm_runtime_get_sync()` 返回后，记录 `ret` 与 `branch=error / no_resume / proceed`，对应 `if (!ret || ret < 0)` 短路 |
| `PULLUP short` | gadget.c `dwc3_gadget_pullup()` | `dwc->pullups_connected == is_on` 分支内，记录 `reason=same_state` |
| `PULLUP soft` | gadget.c `dwc3_gadget_pullup()` | `dwc3_gadget_soft_connect/disconnect()` 返回后，记录 `is_on` / `ret` / `pullups` |
| `UDC connect out` | udc/core.c `usb_gadget_connect_locked()` | `out:` 出口（调用者持有 `connect_lock`），记录 `connected` / `deactivated` / `allow_connect` / `started` / `has_pullup` / `ret`，可判断 `gadget->connected`、UDC 未 started、deactivated 或 allow_connect 造成的提前返回 |
| `SOFTCONNECT enter` | gadget.c `dwc3_gadget_soft_connect()` | 函数入口，记录 `pullups` / `connected` / `state`——**是否真正进入 soft-connect** |
| `SOFTCONNECT reset` | gadget.c `dwc3_gadget_soft_connect()` | `dwc3_core_soft_reset()` 返回后记录 `ret` |
| `SOFTCONNECT done` | gadget.c `dwc3_gadget_soft_connect()` | `dwc3_gadget_run_stop(dwc, true)` 返回后记录 `ret` / `pullups`。仅把原 `return f(...)` 拆成 `ret = f(...)` + 日志 + `return ret`，返回值与调用顺序不变 |

共 9 条，均使用 `dev_dbg`，前缀 `RG353PS DWC3 RECONNECT `，格式串全部唯一。占位符数量与参数数量逐条核对一致。

## 4. 新增 dynamic_debug selector

```
format "RG353PS DWC3 RECONNECT DISCONNECT" +p
format "RG353PS DWC3 RECONNECT PULLUP" +p
format "RG353PS DWC3 RECONNECT UDC" +p
format "RG353PS DWC3 RECONNECT SOFTCONNECT" +p
```

四条均有镜像 `-p` 关闭规则；分别命中源码中 1 / 4 / 1 / 3 条日志，合计覆盖全部 9 条。原有 5 条 selector 内容不变。冲突预检查的正则已加入 `"RG353PS DWC3 RECONNECT`，外部已开启的同前缀规则会导致脚本拒绝运行。没有启用 `file gadget.c +p`，没有增加 EP2 / DEPCMD / bulk-out 规则。

## 5. 验证结果

**静态**

| 检查 | 结果 |
|---|---|
| `sh -n` / `dash -n`（诊断脚本、awk 测试脚本） | 全通过 |
| `bash -n build-kernel.sh` | 通过（曾因 `Path.write_text()` 写成 CRLF 与 heredoc 单引号冲突两次失败，均已定位并改用字节写入 + 独立脚本） |
| `python3 -m py_compile inject-reconnect-diag.py` | 通过 |
| 现有 `test-usb-reconnect-diag-awk.sh` | `PASS=24 FAIL=0` |
| 21 个既有源码改写块重放（pristine 7.2.7 副本） | 20 成功；唯一失败的是 Hantro 摄像头块（依赖先应用的 patch，与 USB 无关） |
| 新注入块重放 | 9 条注入成功；重跑注入 0 条（幂等） |
| 格式串唯一性 / 占位符-参数匹配 | 9 条全唯一、全部匹配 |
| selector 对应性 | 9 启用 / 9 关闭一一对应；头部清单 9 条（对齐空格规范化后一致）；4 条新 selector 覆盖 9 条日志 |
| 无功能逻辑变化 | **两个内核文件在「去掉新增 dev_dbg 行 + 还原 `return` 拆分」后，与重放基线逐字节相同** |
| 无 USB 功能控制 | 脚本非注释行无 unbind / bind / soft_connect / power-control / reprobe / DHCP / VBUS 写操作；`file gadget.c +p` 只出现在「禁止使用」注释里 |
| 既有字段 / 路径 / 采样 | `OUTDIR`、时间戳命名、0.5 s 采样、20000 行上限、`[kmsg]` / `[sample]` / IRQ 多 CPU 累计与完整描述字段均未改 |
| LF 换行 | 全部文件无 CRLF |

**设备干跑（1.2.4 / 67f86b1 旧内核，4 秒，无拔插）**

- 头部完整：`script_version=1.1`、`--- capture start ---` / `--- capture end ---` 齐全。
- 旧内核没有新增 callsite，4 条新 selector 如实记为 `rule_enable_failed=...`，`enabled_rule_ok=5/9`、`enabled_rule_count=18`，终端给出 warning。**这是预期行为**，验证了逐条回读与部分失败记录。
- 退出后 `RG353PS_enabled=0`、`conflict_enabled=0`、debugfs 恢复未挂载、残留进程 0、UDC `configured`；无日志截断。
- 干跑日志与临时文件已删除；设备 `/tmp/usb-reconnect-diag.sh` 更新为 9 条规则版本（SHA256 `c254496d…a1cc`）；2026-11-05 的真实拔插日志保留。

**未做**：完整内核编译（会触发正式构建，且需交叉工具链），只做了源码重放与结构静态验证；第二次真实拔插待新诊断内核构建后执行。

## 6. 未覆盖风险与注意事项

- 新诊断内核尚未构建、尚未刷机；本轮 9 条日志**没有在任何真机内核里产生过**。
- 独立注入脚本本身的内容变化时，`INPUT_KEY`（只含 `build-kernel.sh` 等哈希）不会变，缓存复用可能跳过注入；后续若修改该脚本，需同时触碰 `build-kernel.sh` 或清理 `work/rg353ps/kernel/src`。
- `udc/core.c` 不在既有 `dev_info → dev_dbg` 降级列表里，因此该文件的日志必须直接写成 `dev_dbg`（本轮已如此）。
- 内核 printk 时间轴与 `/proc/uptime` 在该平台分叉约 2 万秒，分析时仍应以 `[sample]` 墙钟为主轴。
- 单次拔插样本不能代表统计特性；此前 40 次矩阵测试的 19/40 re-probe 比例仍有效。

## 7. 第二次实机拔插的分析口径

以 `extcon data result usb=1` 或 `[sample]` 的 `EXTCON_USB=1` 为时间零点，先确认头部 `enabled_rule_ok=9/9` 且无 `rule_enable_failed=`，再按下列四种情形区分（详见 `tools/usb-reconnect-diag.README.md`）：

1. **pullup 未调用**：零点后无 `PULLUP entry`；用 `UDC connect out` 的 `started` / `allow_connect` / `deactivated` / `has_pullup` 定位前置条件。
2. **pullup 被短路**：有 `PULLUP entry` 无 `SOFTCONNECT enter`；看 `PULLUP pm` 的 `branch` 或 `PULLUP short(reason=same_state)`。
3. **soft-connect 未执行或失败**：有 `SOFTCONNECT enter`，但缺 `done` 或 `reset/done ret!=0`，`pullups` 仍为 0。
4. **DWC3 已执行但枚举失败**：`done ret=0 pullups=1` 之后没有 EP0 SETUP 突发、UDC 未到 `configured`。

关键行缺失一律记为「未见该调用」，不推断为已执行；也不要据此提前修改驱动或恢复策略。
