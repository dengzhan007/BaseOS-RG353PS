# PC-B 剩余 20 轮复测 — 交接文档

本机（PC-A）已完成 round 1–20（结果见 `RESULT-PCA-20round.md`，数据见 `cycles.csv` 第 1–20 行）。
本文件用于在**另一台电脑 PC-B** 完成 round 21–40（线1×10 + 线3×10）。

---

## 0. 设备当前状态

- 内核 `7.2.7-baseos-rg353ps` / `BASEOS_BUILD=aa3536b-dirty-20261106013813`，UDC `configured` / `high-speed`。
- 诊断脚本已在设备：`/mnt/SDCARD/usb-reconnect-diag.sh`（v1.1，sha256 `c254496d…d4ae1cc`）。
- 当前**无**诊断进程在跑（PC-A 采集已停止、规则已关闭、debugfs 已卸载）。
- 设备可通过 USB RNDIS 访问：主机地址 `192.168.42.x`，设备 `192.168.42.1`（SSH 密码 `root`）。

---

## 1. 关键修正：必须提高日志上限（否则会再次截断）

PC-A 运行时，第 7 轮触发 DWC3 `gadget.c:2076` WARN 风暴（约 2500 次、~1.8 万行/5s），把 `DIAG_MAX_LOG_LINES=20000` 打满，导致 kmsg 从第 7 轮后停止、round 8–20 内核细节丢失。

**PC-B 本轮必须用 `DIAG_MAX_LOG_LINES=500000`**（SD 卡剩余 11.6G，足够）。其余参数不变。

---

## 2. 操作步骤

### 2.1 把设备接到 PC-B
- RG353PS 用**线1**接到 PC-B 的**固定 USB 口**，直连（不经 HUB/扩展坞），确认 RNDIS 网卡出现、能 `ssh root@192.168.42.1`（或 `ping 192.168.42.1`）。
- 记录 PC-B 型号/OS/构建、USB 口位置（写进 `RESULT` 与 CSV 备注）。

### 2.2 启动采集（在 PC-B 上，经 SSH/plink）

```sh
# 1) 先确认无残留进程
plink -pw root root@192.168.42.1 "ps | grep '[u]sb-reconnect-diag' || echo none"

# 2) 启动 1500 秒采集，上限提高到 500000
plink -pw root root@192.168.42.1 'nohup env DIAG_SECONDS=1500 DIAG_INTERVAL=0.5 DIAG_MAX_LOG_LINES=500000 sh /mnt/SDCARD/usb-reconnect-diag.sh </dev/null >/mnt/SDCARD/usb-reconnect-20round-PCB-runner.log 2>&1 & echo PID=$!'

# 3) 确认头部 9/9、单实例、规则 27
plink -pw root root@192.168.42.1 'L=$(ls -t /mnt/SDCARD/usb-reconnect-diag-*.log | head -1); echo LOG=$L; grep -E "enabled_rule_ok|enabled_rule_count|capture start" "$L"; ps | grep "[u]sb-reconnect-diag"'
```

看到 `enabled_rule_ok=9/9` 才继续；否则停止排查。

### 2.3 PC-B 主机侧监控（可选但强烈建议）

在 PC-B 上开一个逐秒记录 RNDIS/DHCP/MTP 的循环（PowerShell 示例，按 PC-B 实际网卡名调整）：

```powershell
$out="C:\usb-monitor-PCB.log"
"ts_utc,rndis_present,rndis_name,ipv4,dhcp_ok,mtp_present,mtp_status" | Out-File $out -Encoding utf8
$end=(Get-Date).AddMinutes(15)
while((Get-Date) -lt $end){
  $now=(Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss")
  $a=Get-NetAdapter -ErrorAction SilentlyContinue | ?{ $_.InterfaceDescription -match 'Remote NDIS|RNDIS' } | select -First 1
  $ip=""; $dhcp=$false
  if($a){ $x=Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | select -First 1; if($x){$ip=$x.IPAddress}; if($ip -and $ip -notmatch '^169\.254\.'){$dhcp=$true} }
  $w=Get-PnpDevice -Class WPD -ErrorAction SilentlyContinue | ?{ $_.FriendlyName -eq 'RG353PS' } | select -First 1
  "$now,$([bool]$a),$($a.Name),$ip,$dhcp,$([bool]$w),$($w.Status)" | Add-Content $out
  Start-Sleep -Milliseconds 1000
}
```

### 2.4 20 轮节奏（round 21–40）

- **每 30 秒一轮**：整 `:00` / `:30` 拔线 → 约 3 秒插回 → 等 ≤20 秒观察 → 到下一个 `:00`/`:30` 再拔。
- 20 轮约 10 分钟，采集窗口 1500s 有余量。

**⚠️ 强烈建议反序：PC-B 先测线3（21–30），再测线1（31–40）。**
原因：PC-A 两次运行都是"线1 先、线3 后"，结果线1 re-probe 75%、线3 仅 10%，但**线材与顺序没有分离**。PC-B 反序（先线3 后线1）可区分"线材因素"与"顺序/热身因素"：
- 若 PC-B 也是线3 少、线1 多 → 确认是**线材**；
- 若 PC-B 变成先测的少、后测的多 → 是**顺序/热身**。
> 反序时请把 `cycles.csv` 第 21–30 行的 `cable` 改成 `线3`、第 31–40 行改成 `线1`；换线在第 30 轮后做（不计轮，备注标 swap）。

若坚持固定顺序（线1 先、线3 后）也可以，但请在 RESULT 备注该混淆。

### 2.5 严禁操作
- 手动 `soft_connect` / UDC unbind·bind / 重启 gadget / 触发 Supervisor recovery / 重启设备。
- 改 DHCP、VBUS、USB Runtime PM、内核、Supervisor、USB profile；进 Mass Storage。

### 2.6 结束后立即保全（在设备重启前！）

```sh
# 停采集（TERM 触发清理，写 footer）
plink -pw root root@192.168.42.1 "pkill -TERM -f usb-reconnect-diag; sleep 4; ps | grep '[u]sb-reconnect-diag' || echo stopped"
# 立即复制 Supervisor 日志（/run 易失）
plink -pw root root@192.168.42.1 "cat /run/baseos-usb-debug.log" > baseos-usb-debug-PCB-20round.log
# 复制诊断日志
plink -pw root root@192.168.42.1 'cat $(ls -t /mnt/SDCARD/usb-reconnect-diag-*.log | head -1)' > usb-reconnect-diag-PCB.log
# 系统快照
plink -pw root root@192.168.42.1 'cat /etc/baseos-release; uname -a; cat /sys/class/udc/fcc00000.usb/state; grep -iE "usb2phy|dwc3" /proc/interrupts' > system-snapshot-PCB.txt
```

把上述 4 个文件 + `usb-monitor-PCB.log` 一起交回。

---

## 3. 需要回填的 CSV（`cycles.csv` 第 21–40 行）

每轮记录：`disconnect_time_utc`、`reconnect_time_utc`、`udc_state`（插入时）、`current_speed`、
`extcon_usb`、`bvalid_irq`、`otg_state`、`configured_time_utc`、`recovery_path`（A/B/B-self）、
`supervisor_reprobe`、`rndis_detected`、`host_ipv4`、`dhcp_success`（区分 APIPA `169.254.x.x`）、
`mtp_detected`、`result`、`notes`。

- 设备侧（UDC/extcon/BVALID/OTG/路径）由诊断日志回填；
- `supervisor_reprobe` 由 `baseos-usb-debug-PCB-20round.log` 的 `launching asynchronous recovery` / `re-probe done` 判定；
- 主机侧（RNDIS/IP/DHCP/MTP）由 `usb-monitor-PCB.log` 回填。
- **换线那一次**（第 30 轮后）不要计入 20 轮，备注标 `swap`。

---

## 4. 完成后我会做

1. 合并 40 轮：总体统计、四组分项（PC-A/线1、PC-A/线3、PC-B/线1、PC-B/线3）。
2. 生成最终 `RESULT.md`：总体 / 分项 / 故障分层（PHY-BVALID-IRQ / OTG / EXTCON / DWC3 / UDC / RNDIS-DHCP / MTP）/ 与旧版 19/40 对比 / 结论（是否降低 re-probe、主机/线材依赖、下一步改动点）。
3. 生成 `SHA256SUMS`。
4. 特别复核 `gadget.c:2076` WARN 风暴是否在 PC-B 复现（若复现，将是下一阶段首要修复点：`dwc3_ep0_interrupt` → `dwc3_gadget_ep_queue` 的 WARN_ON 分支）。

---

## 5. 待确认事项

- 若 PC-B 的 WARN 风暴同样把 500000 行打满（极端情况），说明该 WARN 是持续型而非瞬时，需要改为"按调用点聚合/过滤 WARN 栈"的采集策略，再重跑。
- 本机 round 8–20 的内核细节缺失，已用 Supervisor+主机数据覆盖主要指标；如要补齐内核细节，可在提高上限后补跑本机 20 轮。
