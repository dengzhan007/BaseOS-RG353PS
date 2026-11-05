# USB 重连诊断脚本健壮性修订审查

## 1. 基线与范围

- 目标分支 `usb-reconnect-diag`，修订前 HEAD `bd0e2be`；`main` 为 `507004e`，本次未动。
- 基线是本轮开始前从该分支取得的 v1.1 版本；`DIAG_VERSION` 仍为 `1.1`，版本号未变。
- 范围：只处理诊断脚本自身的健壮性。未改 USB 驱动、内核、Supervisor、DHCP、MTP、RNDIS 或任何 USB 功能逻辑。
- 最小改动：脚本中只有 `enable_rules()` 与 `write_header()` 的函数体变化，另新增 `rule_is_enabled()` / `enable_one_rule()` 两个小函数；`disable_rules()`、`list_rules()`、`start_kmsg()`、`start_sampling()`、`write_footer()`、`cleanup()`、`enforce_limit()`、`irq_snapshot()` 的函数体逐字节未变。

## 2. 修改文件清单

| 文件 | 变更 |
|---|---|
| `platforms/rg353ps/tools/usb-reconnect-diag.sh` | 主流程顺序、5 条规则逐条写入+回读校验、头部失败字段、`enforce_limit()` 注释 |
| `platforms/rg353ps/tools/usb-reconnect-diag.README.md` | 头部字段说明、最终文件行数限制语义、规则启用/清理说明、本轮验证表与未覆盖风险 |
| `platforms/rg353ps/USB.md` | 诊断章节同步上限语义/校验说明/验证状态；原文前 11482 字节逐字节未改 |
| `platforms/rg353ps/tools/test-usb-reconnect-diag-awk.sh` | **未修改**，仅重新运行 |
| `docs/usb-reconnect-diag-robustness.diff` | 新增，本轮完整 diff（204 行 / 10 个 hunk） |
| `docs/usb-reconnect-diag-robustness-review.md` | 本文件 |

## 3. 关键 diff

以下三段为本轮核心改动，完整 diff 见 `docs/usb-reconnect-diag-robustness.diff`。

```diff
@@ -133,12 +135,40 @@
 # disable_rules() are mirror images; do not add one without the other.
 # Format strings were read back from the running kernel's
 # /sys/kernel/debug/dynamic_debug/control, not guessed from docs.
+# A write to control can succeed while matching no callsite at all (for
+# example a format string that no longer exists in this kernel), so check both
+# the write result and the flags read back from control.
+rule_is_enabled() {
+    case "$1" in
+        'file '*)   key=${1#file } ;;
+        'format '*) key=${1#format } ;;
+        *) return 1 ;;
+    esac
+    key=${key% +p}
+    key=$(printf '%s' "$key" | tr -d '"')
+    grep -F "$key" "$CONTROL" 2>/dev/null | grep -q '=p '
+}
+
+# RULES_ON is set by the caller BEFORE the first selector is written, so an
+# early exit or signal still makes cleanup() turn off all five selectors even
+# when only some of them were enabled successfully.
+enable_one_rule() {
+    one_rule=$1
+    if printf '%s\n' "$one_rule" >"$CONTROL" 2>/dev/null && rule_is_enabled "$one_rule"; then
+        RULE_OK=$((RULE_OK + 1))
+    else
+        RULE_FAILURES="${RULE_FAILURES}${RULE_FAILURES:+|}$one_rule"
+    fi
+}
+
 enable_rules() {
-    printf '%s\n' 'file phy-rockchip-inno-usb2.c +p' >"$CONTROL"
-    printf '%s\n' 'format "RG353PS DWC3 device DISCONNECT event" +p' >"$CONTROL"
-    printf '%s\n' 'format "RG353PS DWC3 device RESET event" +p' >"$CONTROL"
-    printf '%s\n' 'format "RG353PS DWC3 device-event raw" +p' >"$CONTROL"
-    printf '%s\n' 'format "RG353PS EP0 SETUP" +p' >"$CONTROL"
+    RULE_OK=0
+    RULE_FAILURES=
+    enable_one_rule 'file phy-rockchip-inno-usb2.c +p'
+    enable_one_rule 'format "RG353PS DWC3 device DISCONNECT event" +p'
+    enable_one_rule 'format "RG353PS DWC3 device RESET event" +p'
+    enable_one_rule 'format "RG353PS DWC3 device-event raw" +p'
+    enable_one_rule 'format "RG353PS EP0 SETUP" +p'
 }
 
 disable_rules() {

@@ -228,6 +258,12 @@
         echo "--- dynamic debug selectors enabled by this script ---"
     } >>"$LOG"
     list_rules
+    # Name every selector that failed to take effect, so a partial capture is
+    # never mistaken for a complete one. enabled_rule_ok= counts successes.
+    if [ -n "$RULE_FAILURES" ]; then
+        printf '%s\n' "$RULE_FAILURES" | tr '|' '\n' | sed 's/^/rule_enable_failed=/' >>"$LOG"
+    fi
+    echo "enabled_rule_ok=$RULE_OK/5" >>"$LOG"
     if [ -r "$CONTROL" ]; then
         n=$(grep 'RG353PS' "$CONTROL" 2>/dev/null | grep -c '=p ')
         echo "enabled_rule_count=$n" >>"$LOG"

@@ -355,11 +394,25 @@
 # A long "sleep 60" would delay signal handling until it finished, leaving the
 # debug rules on for a minute after Ctrl+C. One-second slices bound that delay
 # to 1 s; the signal handler only sets a flag, and EXIT runs the real cleanup.
-enable_rules
+# RULES_ON goes high BEFORE the first selector is written: if only some rules
+# enable, cleanup() must still attempt to disable all five of them.
 RULES_ON=1
+enable_rules
+# Resolve the stream name before the header is written, so kernel_stream=
+# describes the stream that will actually be started below.
+if [ -r /proc/kmsg ]; then
+    KMSG_METHOD=/proc/kmsg
+else
+    KMSG_METHOD=N/A
+fi
+# Write the complete header first. The two background producers only append,
+# so their lines can never be interleaved ahead of the header.
+write_header
 start_kmsg
 start_sampling
-write_header
+if [ -n "$RULE_FAILURES" ]; then
+    echo "warning: some dynamic-debug rules did not enable; see rule_enable_failed= in the log" >&2
+fi
 
 echo ""
 echo "=== USB reconnect diagnostic (v$DIAG_VERSION, ${DIAG_SECONDS}s) ==="
```

## 4. 验证结果

### 静态验证（本地）

| 检查 | 结果 |
|---|---|
| `sh -n` / `dash -n`（产品脚本、部分失败测试副本） | 全部通过 |
| `test-usb-reconnect-diag-awk.sh` | PASS=24 FAIL=0；9 类内核日志、4 CPU IRQ 累计与完整描述字段、`max=3` 上限 |
| 5 条启用规则 ↔ 5 条关闭规则 | 一一对应，selector 集合与基线完全一致 |
| 新增日志字段 | `enabled_rule_ok=N/5`；`rule_enable_failed=` 仅在失败时出现 |
| 高频 / 危险操作 | 无 `file gadget.c +p`、无 EP2 高频 `+p`、无 unbind / soft_connect / power-control / reprobe / DHCP 等写操作 |
| 机制保留 | 提前 trap、`DEBUGFS_OWNED`、`RULES_ON`、`CONFLICT` 冲突预检查、`STOP` 信号处理、`enforce_limit()` 全在 |
| 启动顺序 | 主流程中 `write_header` 位于 `start_kmsg` / `start_sampling` 之前；`RULES_ON=1` 位于 `enable_rules` 之前 |
| 换行 | 全部 LF，无 CRLF |

### 设备干跑（RG353PS 1.2.4 / 7.2.7-baseos-rg353ps，BusyBox 1.37.0，**无拔插**）

| 场景 | 结果 |
|---|---|
| **A** 正常结束 4 s | 标题在第 1 行；`enabled_rule_ok=5/5`、`enabled_rule_count=18`、`kernel_stream=/proc/kmsg`；`--- capture start ---` 第 42 行、首个 `[kmsg]` 第 43 行、首个 `[sample]` 第 54 行（头部竞态消除）；`[kmsg]` 16 行含 12 行通用 USB/warning，EP2/bulk-out 0 行；规则 0、debugfs 卸载、无残留 |
| **B** SIGTERM（2 s 后） | 规则 0、debugfs 卸载、无残留；日志头部完整 |
| **C** `DIAG_MAX_LOG_LINES=20` | 最终日志恰好 20 行，末行 `[diag] log truncated to 20 lines (limit)` |
| **D** 自挂 debugfs + 规则冲突 | `exit 1`；debugfs 已卸载；外部那条 `=p` 规则仍开启；无残留 |
| **E** debugfs 原本已挂载 | 运行后仍 `MOUNTED`，日志记 `debugfs_mounted_by_script=0` |
| **F** OUTDIR 检查失败 | `exit 1`；debugfs 未挂载、规则 0、无残留、未写日志 |
| **G** 部分规则启用失败 | 日志记 `rule_enable_failed=format "RG353PS NO SUCH FORMAT" +p`、`enabled_rule_ok=4/5`、`enabled_rule_count=17`，终端有 warning；**退出后规则 0**（成功的 4 条也被关闭）、debugfs 卸载、无残留 |
| **H** 非重叠外部规则 | 外部 `func dwc3_vbus_draw_work +p` before=1 / after=1 未被误关；脚本自身规则 after=0 |

G 用的是本地注入的测试副本（把一条 selector 换成当前内核不存在的格式串），设备内核本身不缺规则。

**测试后设备状态**：日志 0、debugfs 未挂载、`=p` 规则 0、残留进程 0、临时脚本 0、UDC 仍 `configured`。

## 5. 第三项的判断：不实现实时行数限制

`enforce_limit()` 只在退出时截断，两个后台进程运行期间的瞬时总行数可能短暂超过上限（各自最多写 `DIAG_MAX_LOG_LINES` 行，合计最多约 2 倍）。评估结论是**保留现状**，理由：

- 截断需要 `head -n > tmp; mv` 替换文件；两个后台进程用 `>>` 持有旧 inode 的 fd，替换后它们的后续写入会落到已被替换掉的旧文件，造成日志丢失。
- 两个进程若各自截断，会互相覆盖；要无竞态必须引入单一写入者或文件锁，这与"不要引入复杂日志锁或不稳定机制"冲突，且属于重构整个采集结构，超出最小改动范围。
- 现有 cleanup 顺序已是「先 kill + wait 两个后台进程 → 再 `write_footer` → 最后 `enforce_limit()`」，截断发生在没有并发写的时刻，本身是安全的。

因此 `DIAG_MAX_LOG_LINES` 明确定义为**最终文件行数上限，不是实时磁盘占用上限**；README 与 `USB.md` 都已写明，并给出缩短 `DIAG_SECONDS` / 调低上限作为控制磁盘占用的替代手段。

## 6. 安全边界核对

- 只读采集：不执行 recovery / unbind / bind / DWC3 reprobe / PHY reset / soft_connect / Runtime PM / 电源 / VBUS 控制，不改 Supervisor 恢复策略。
- 5 条 dynamic_debug 规则及其镜像关闭规则保持原样；冲突预检查保留；关闭动作只作用于这 5 条 selector。
- 未启用 `file gadget.c +p`，未增加 EP2 / bulk-out 高频规则；通用 USB 事件过滤、IRQ 多 CPU 累加、完整 IRQ 描述输出均未改动。
- 日志路径、文件命名规则、既有诊断字段（`enabled_rule_count`、`kernel_stream`、`[kmsg]`、`[sample]` 等）均未改；本轮只**新增**字段。
- 设备验证全程无拔插，未产生真实重连事件。

## 7. Git 操作与构建触发

- 只在 `usb-reconnect-diag` 分支提交；未合并 `main`，未在 `main` 上做任何改动。
- 不触发构建的依据：三个工作流的 `on.push.branches` 分别为 `[main]`（bring-up）与 `[main, "feature/**"]`（release、storage-mode-check），而本分支名为 `usb-reconnect-diag`，不匹配；release 的 `workflow_dispatch` 需手工触发；`pull_request` 限定目标分支 `main`，本次没有开 PR。新增的 `docs/` 文件也不在这些工作流的 paths 列表里。推送后按 `?branch=usb-reconnect-diag` 复查 Actions runs 的结果在交付回复中给出。
- 本地工作区未产生 git commit；改动经验证后才通过 Git Data API 推送。

## 8. 仍未覆盖的风险

1. **真实拔插的完整事件链仍未实测**；本轮所有干跑都没有产生真实重连，需要人工执行一次操作流程并回传日志。
2. `kill -9` 无法被 trap 捕获，仍可能残留动态调试规则和后台进程；README 的「关闭动态调试」一节提供手工兜底命令。
3. `/proc/kmsg` 不可读时的 `dmesg` 兜底分支本轮未验证（设备始终可读）。
4. 运行期间磁盘占用不受实时约束（见第 5 节的设计取舍）。
5. 逐条规则校验依赖 `control` 中 `=p ` 的显示格式；若未来内核改变 flags 呈现方式，需重新核对 `rule_is_enabled()`。
6. G 场景是注入式模拟，未在真实缺失格式串的内核上验证；但启用顺序、失败记录与清理路径与真实场景一致。
