# RG353PS · Slot 系前端快速移植指南

适用：把任意 **Slot 家族 fork**（基于 https://github.com/BrandonKowalski/slot 的衍生前端）
移植到 RG353PS（RK3566，640×480，BaseOS A/B 布局）。

目标不是"把某一个 fork 编出来"，而是沉淀一套**换 fork 只改极少文件**的方法论。

---

## 0. 为什么能快速复用（先建立心智模型）

- **显示走 Option A：SDL2 KMSDRM + Mesa/Panfrost**，与上游的 Mali fbdev EGL ABI 解耦。
  上游 `fbdev.rs` 用 Mali 私有的 `FbdevWindow` 结构体建 EGL native window，Mesa/Panfrost 不支持；
  我们的 `fbdev.rs` 改用 SDL2 的 KMSDRM 后端 + GLES 上下文，运行时 `dlopen` libSDL2。
- **内核已就绪**：`CONFIG_DRM_PANFROST=m`（GPU 用开源 Panfrost），rootfs 已带
  SDL2(KMSDRM) + Mesa(GBM/EGL) + ALSA，无需塞闭源 libMali（那需要私有 `mali.ko`，
  与 Panfrost 互斥，还会搞挂依赖 Mesa 的其他前端）。
- **音频走 ALSA 直连**，无 pulse / 无 dbus 依赖 —— 正好契合我们无 dbus 的 rootfs。
- **结论**：fork 之间真正会变的是「源码仓库 + 按键映射 + 可能多几个 Rust 依赖」；
  显示后端、运行环境、构建/打包、模拟核心都是可复用的，换 fork 不用重做。

---

## 1. 已沉淀的可复用资产（换 fork 不重做）

| 资产 | 路径 | 作用 |
|---|---|---|
| 构建镜像定义 | `platforms/rg353ps/frontends/slot/Dockerfile.slot-build` | 生成 `rg353ps-slot-build:latest`（arm64，预装 git/build-base/cmake/SDL2/Mesa 等依赖） |
| 暖缓存脚本 | `diag/warm-slot-cache.sh` | 把 slot 依赖 + crates.io registry 固化进持久卷，避免每次全量编译 |
| 构建+打包主脚本 | `platforms/rg353ps/build-slot.sh` | pin 版本、覆盖 fbdev.rs、打 patch、编 slot+cores、出 `baseos-rg353ps-slot.zip` |
| **显示后端替换** | `platforms/rg353ps/frontends/slot/fbdev.rs` | SDL2 KMSDRM+GLES 版 `fbdev.rs`，**fork 间基本直接复用** |
| **运行环境** | `platforms/rg353ps/frontends/slot/launch.sh` | `SDL_VIDEODRIVER=kmsdrm` / `SDL_AUDIODRIVER=alsa` / 暂存二进制到 tmpfs / `--init-root` |
| 示例按键 patch | `platforms/rg353ps/frontends/slot/slot-rg353ps.patch` | 本 fork 专用按键/摇杆映射（**换 fork 要重做**） |
| **摇杆补丁** | `platforms/rg353ps/frontends/slot/slot-analog.patch` | 让摇杆真的成为模拟轴送到 libretro 核心，并把摇杆按压变成可绑定的 L3/R3（**通用，换 fork 一般直接可用**） |
| **电源键补丁** | `platforms/rg353ps/frontends/slot/slot-power.patch` | KEY_POWER 交给前端，并让 `doze()` 通过 `BASEOS_SLEEP` 真正挂起整机（**改法固定，但要按 fork 的 `Btn` 枚举与 `doze` 名字对一遍**，见 §2.1 E） |
| **boot logo 补丁** | `platforms/rg353ps/frontends/slot/slot-bootlogo.patch` | 让前端认 `BASEOS_BOOT` 这个分区名，并复用 `rcS` 已建立的挂载点（**换机型只改一个常量**，见 §2.1 F） |
| 模拟核心 | mGBA / gpSP 的 `.so`（aarch64 musl） | 与前端 fork 无关，通常直接复用 |

---

## 2. 移植一个新 fork 时要动的东西（按改动量升序）

| # | 改动点 | 触及文件 | 是否 fork 相关 | 做法 |
|---|---|---|---|---|
| 1 | 显示后端 | 覆盖 `crates/slot-gfx/src/fbdev.rs` 为我们版 | **否**（只要该 fork 的 `slot-gfx` 的 `Surface` trait 接口没变） | 直接 `cp frontends/slot/fbdev.rs` 覆盖 |
| 2 | 运行环境 | `launch.sh` | 否 | 直接复用，无需改 |
| 3 | 模拟核心 | mGBA/gpSP `.so` | 否 | 直接复用（除非 fork 指定不同 core 版本） |
| 4 | 构建 pin | `build-slot.sh` 顶部 `SLOT_REV`/`SLOT_REPO`（或环境变量） | **是** | 指向目标 fork 的 commit / repo，如 `SLOT_REPO=owner/fork SLOT_REV=abc123 ./build-slot.sh` |
| 5 | **按键映射** | 新 patch，如 `slot-<fork>-ab.patch` | **是（每个 fork 必做）** | 对该 fork 的 `crates/slot/src/input/evdev.rs` 重写 `code_to_btn`、`WANTED` 与摇杆轴 |
| 6 | 设备脚本 | `led.sh`/`lid.sh` + `AGS_*` 环境变量 | 否（设备相关） | 提供 RK817 / 无 hall 传感器的版本或 stub |
| 7 | 分辨率 | `fbdev.rs` 读 `fb0`，fallback 640×480 | 否 | 通常不动；若 fork 硬写分辨率再调 |
| 8 | **电源键归前端** | `slot-power.patch`（`evdev.rs` + `app.rs`）+ `launch.sh` | **是（每个 fork 必做）** | 三处改动，见 §2.1 E |
| 9 | **boot logo 写盘** | `slot-bootlogo.patch`（`bootlogo.rs`） | 否（前提是 fork 自带该模块） | 改分区名 + 复用挂载点，见 §2.1 F |

> 经验值：**第 4、5、8 项是每个 fork 真正要写的东西**，其余都是复制粘贴。

---

## 2.1 对上游源码的最小改动集（照清单逐条做，不要另行发明）

这一节是**已经验证过、缺一条就有一个功能不对**的清单。换 fork 时按顺序过一遍，
每条都写了「不改会怎样」，方便判断某个 fork 是否已经自带。

### A. `crates/slot-gfx/src/fbdev.rs` —— 整体替换，不是改几行

**为什么必须换**：上游用 Mali 私有的 `FbdevWindow` 结构体建 EGL native window，
Mesa/Panfrost 根本不认这个 ABI，结果就是黑屏或 `EGL not initialized`。

**做法**：`cp platforms/rg353ps/frontends/slot/fbdev.rs` 覆盖同名文件。
只要目标 fork 的 `Surface` trait 签名没变就直接生效；变了才需要按新签名微调。

### B. `crates/slot/src/input/evdev.rs` —— 十处，漏一处坏一个功能

| # | 改动 | 不改的后果 |
|---|---|---|
| 1 | `code_to_btn`：`0x130→B`、`0x131→A`、`0x133→X`、`0x134→Y` | ABXY 全错位（按 A 出 B）。Anbernic 用的是任天堂印字，DTS 的位置名和印字是对上的，别按 Xbox 布局映射 |
| 2 | 肩键：`0x136→L1`、`0x137→R1`、`0x138→L2`、`0x139→R2` | 肩键错位，或者 L2/R2 完全没反应 |
| 3 | `0x13a→Select`、`0x13b→Start`、`0x13c→Menu`(Function) | 打不开菜单，等于进不去设置 |
| 4 | 十字键 `0x220~0x223`，并保留 `103/108/105/106`(KEY_↑↓←→) 兜底 | 十字键没反应；不同内核把 D-pad 建成 gpio-keys 数组或 adc-keys，两种编码都要接 |
| 5 | **删掉 `116`(KEY_POWER) 的映射，并从 `WANTED` 里删掉** | 一次短按被两边同时处理：屏幕只关不睡，唤醒还要再按一次 |
| 6 | 摇杆：接 `ABS_X(0x00)`/`ABS_Y(0x01)`（左）与 `ABS_RX(0x03)`/`ABS_RY(0x04)`（右），`ADC_CENTRE=519`、`ADC_DEADZONE=140`，**X 保持原号、Y 取负**（见下面的方位表） | 摇杆完全没反应（上游死区 2048 会把 0..1023 的采样全部吞掉），或者上下颠倒、左右相反 |
| 7 | `wanted_node()` 用 **ABS 能力位**判定摇杆设备，要求四轴齐全 | 摇杆设备是 `adc-joystick`，**一个按键都不报**，只按 `WANTED` 选设备会直接漏掉它 |
| 8 | `LEFT_STICK_TARGETS` 里加 `"rg353ps"` | `has_left_stick()` 返回 false，摇杆输入被丢弃 |
| 9 | 摇杆按压：`0x13d→Btn::L3`、`0x13e→Btn::R3` | 两个摇杆按下去完全没反应，也绑不到任何功能上 |
| 10 | 只有 `is_stick_node()`（四轴齐全）的那一个节点发布模拟轴（`slot-analog.patch`） | 按键节点也在写共享轴，一按按键就把摇杆清零，右摇杆表现为「时有时无」 |

**方位约定（踩过三次，务必照抄）**：Slot 的方向约定是「正值 = 右/下」（就是 Linux 惯例：
`ends[usize::from(v > 0)]`，axis0 是 `[Left, Right]`、axis1 是 `[Up, Down]`）。

真机实测的结论（不要从 DTS 的 `abs-range` 反推，会推错）：**X 上报值越大越靠右，
Y 上报值越大越靠上**。所以 X 保持原号、Y 取负。而且**数字方向与模拟轴共用同一个符号**，
不可能出现「摇杆方向对了、模拟轴反了」这种半对半错的状态。符号放在 `AxisSigns` 里：

| 物理轴 | 上报值增大方向 | Slot 数字（正 = 右/下） | libretro 模拟（正 X = 右、正 Y = 下） |
|---|---|---|---|
| 左 X `ABS_X` | 右 | 不取负 `+1` | 不取负 |
| 左 Y `ABS_Y` | 上 | 取负 `-1` | 取负 |
| 右 X `ABS_RX` | 右（同一分压） | — | 不取负 |
| 右 Y `ABS_RY` | 上（同一分压） | — | 取负 |

内置表 `left [1, -1]`、`right [1, -1]`。**右摇杆的实测无法离线做**，所以做成了运行时配置：
数据分区 `Config/sticks.txt`，写 `rx=-1` 就是把右摇杆 X 反过来，改完重进前端即可生效，
**不用重新编译**。文件缺失、键名写错、值为 0 都会退回内置值，不会把摇杆搞死。
启动日志里会打印 `slot: input sticks: left [1, -1], right [1, -1]`，一眼能看出实际生效的值。

**多设备共用轴的两个坑（都踩过）**：
1. `pick_devices()` 在 RG353PS 上会选出**两个**节点 —— `gpio-keys`（有 key、无 ABS）和
   `adc-joystick`（有 ABS、无 key）。每个节点一个读线程，如果两个线程都往共享轴里写，
   按一下任意按键就会把摇杆值清零，表现就是「右摇杆在游戏里时有时无、按着键就完全没反应」。
   **只有 `is_stick_node()` 判定为真的节点才允许发布轴值。**
2. 摇杆在**按键映射设置界面里本来就不会有反应** —— 那个界面绑定的是 `RawEvent::Down/Up`
   数字事件，模拟轴走的是「读线程 → 4 个原子 → 每帧喂核心」的旁路，不相交。验证摇杆要去
   支持模拟的核心（街机 / PS1）里试，或者看 `SLOT_TRACE_INPUT=1` 的日志。

`is_stick_node()` 要求四轴齐全，这是给双摇杆机做的最严判据。**移植到只有左摇杆的机型时**
（RG35XX Plus / RG28XX 之类），把它改成只要 `ABS_X` + `ABS_Y` 就返回真，否则模拟轴永远不发布。

同一组常量还负责模拟轴归一化：`ADC_TRAVEL=504`（519→1023 与 519→15 都是 504），
采样减去中心后按 ±504 缩放到 i16，模拟死区比数字倾斜死区小得多（`ADC_ANALOG_DEADZONE=40`），
否则摇杆要走完四分之一行程才开始有输出，手感是坏的。

关于第 7 条的判据：要求 `ABS_X` + `ABS_Y` + `ABS_RX` + `ABS_RY` 同时存在，
这样鼠标和触摸屏不会混进来。**注意 `ABS_RX` 的编号就是 0x03**，H700 机型把左摇杆
Y 轴叫 `ABS_LSY` 也是 0x03 —— RG353PS 上 0x03 属于右摇杆，别照 H700 的写法抄。

补丁本体见 `slot-rg353ps.patch`，是上面**第 1～9 条**（全部落在 `evdev.rs` 一个文件里）的可执行版本 ——
新 fork 直接改文件名后 `git apply` 大概率能过；如果它的 `evdev.rs` 已经重构过，就照着表逐条手工改。
**第 10 条不在这个补丁里**，它跨 `device.rs`，放在 B2 的 `slot-analog.patch`。

### B2. `slot-analog.patch` —— 摇杆真正变成模拟轴（通用，与 DTS 无关）

**为什么必须加**：上游 Slot **完全没有模拟输入**。全仓 `grep -i analog` 零命中，
libretro 回调里 `device != RETRO_DEVICE_JOYPAD` 直接返回 0，开场还
`set_controller_port_device(0, RETRO_DEVICE_JOYPAD)`。所以哪怕官方支持机型里就有
双摇杆机器（RG35XX H、RG34XXSP），它们的右摇杆在上游也是**纯摆设**。
上游唯一和摇杆有关的功能是 CHANGELOG #106/#107 那条「左摇杆当十字键」。

**参考实现**：NextUI（`LoveRetro/NextUI`，支持街机，右摇杆能用）的
`workspace/all/minarch/ma_input.c`：

```c
if (port==0 && device==RETRO_DEVICE_ANALOG) {
    if (index==RETRO_DEVICE_INDEX_ANALOG_LEFT)  { X -> pad.laxis.x; Y -> pad.laxis.y; }
    else if (index==RETRO_DEVICE_INDEX_ANALOG_RIGHT) { X -> pad.raxis.x; Y -> pad.raxis.y; }
}
```

三个可照搬的结论：
1. **端口仍然声明成 JOYPAD**（`Core_load()` 里 `set_controller_port_device(0, RETRO_DEVICE_JOYPAD)`），
   只在 `input_state` 里回答 ANALOG 查询。想要摇杆的核心照样会问，不想要的核心完全无感。
2. 模拟轴**只挂 port 0**，左右摇杆用 `index` 区分，值是完整的 i16 量程（±32767）。
3. 死区不在 libretro 回调里做，放在读设备那一层 —— 我们的 `ADC_ANALOG_DEADZONE` 就在 `Hat::analog()`。

**补丁改了这些文件**（一次改完，换 fork 通常不用动）。分两组，**A 组漏了编译不过，
B 组漏了编译能过但摇杆仍然没反应** —— 后者更容易悄悄漏掉，所以每行都写了「漏了会怎样」：

| 文件 | 改动 | 漏了会怎样 |
|---|---|---|
| **A 组：摇杆按压 L3 / R3** | | |
| `crates/slot-input/src/raw.rs` | `Btn` 增加 `L3`/`R3` | 整组编译不过 |
| `crates/slot-store/src/bindings.rs` | `Device` 增加 `L3`/`R3`（`ALL` 从 14 变 16），`key()`/`label()` 补上 `l3`/`r3` | `Device::ALL` 与 `Btn` 数量对不上，编译不过 |
| `crates/slot/src/input/bind.rs` | `PAIRS` 补 `(Device::L3, Btn::L3)`、`(Device::R3, Btn::R3)` | 按键设置里按摇杆不会被捕获成 L3/R3 |
| `crates/slot/src/input/keys.rs` | `KeyE → L3`、`KeyR → R3` | 桌面用键盘调试时没有 L3/R3 |
| `crates/slot/src/input/pad.rs` | `LeftThumb → L3`、`RightThumb → R3` | 接 SDL 手柄调试时没有 L3/R3 |
| `crates/slot/src/input/trace.rs` | 轴名改成 `ABS_X/ABS_Y/ABS_RX/ABS_RY`，输出 `lx/ly/rx/ry` | `SLOT_TRACE_INPUT=1` 的日志里看不到摇杆 |
| **B 组：模拟轴通路（读设备 → 原子 → 核心）** | | |
| `crates/slot-retro/src/core.rs` | 新增 `Axes { left, right }`，`RetroCore::set_analog()`（默认空实现，不碰任何核心） | 没有往核心送值的入口 |
| `crates/slot-retro/src/lib.rs` | 导出 `Axes` | 上层 `use` 不到 |
| `crates/slot-retro/src/ffi.rs` | `DEVICE_ANALOG=5`、`DEVICE_INDEX_ANALOG_LEFT/RIGHT`、`DEVICE_ID_ANALOG_X/Y` | 只能手写魔数，易错 |
| `crates/slot-retro/src/libretro.rs` | `Host` 存 `Axes`；`input_state` 增加 ANALOG 分支；实现 `set_analog` | 核心来问了也拿不到值，右摇杆照旧无效 |
| `crates/slot/src/emu.rs` | `Shared` 增加 4 个 `AtomicI32`；`EmuHandle::set_analog()`；帧循环里每帧喂给核心 | 事件到不了核心所在线程 |
| `crates/slot/src/input/device.rs` | 读设备的线程把 `Hat::analog()` 写进共享原子（**只有 `is_stick_node()` 节点允许**）；`DeviceInput::analog()` | 轴恒为 0，或者按一下按键就清零 |
| `crates/slot/src/frontend.rs` | 转发 `set_analog()` | 上层调用无处落地 |
| `crates/slot/src/session.rs` | 新增 `set_analog()` | 同上 |
| `crates/slot/src/device_app.rs` | 每帧 `frontend.set_analog(input.analog())` | 链路最后一步没接上，前面全白做 |

**设计要点**：模拟量**不进 `RawEvent` 流**。`RawEvent` 只有 `Down/Up` 两个变体，
再加一个变体要动 app/session/gesture 里所有 `match`，收益为零。摇杆走的是
「读线程 → 原子量 → 每帧给核心」的旁路，UI 侧一行都不用改。

**没做的事**：`ButtonMask` 仍然是 16 位数字位图（bit14/15 对应 libretro 的 L3/R3），
但 GBA 核心用不到，所以没有把 L3/R3 塞进 `GameButton`，按键设置界面也不会多出两行空项。
要让 L3/R3 成为「游戏按键」而不是「快捷键」，才需要改 `GameButton` + 快捷菜单 UI。

### C. `launch.sh`

- `SDL_VIDEODRIVER=kmsdrm`、`SDL_AUDIODRIVER=alsa`
- 二进制 `cp` 到 `/tmp` 再 `exec`（TF/exFAT 不保 exec 位）
- **写** `# baseos: power-owned`，并 `export BASEOS_SLEEP=/usr/sbin/rg353ps-sleep`
  —— 前端接管电源键，长按走 Slot 自己的关机画面，短按的 `doze()` 通过这个变量
  真正挂起整机（见 §5「电源键归属」，逐条改法见 §2.1 E）

### D. 数据分区的 `Config/slot.state`

`volume=` 和 `volume_hp=` 是 Slot **自己的软件音量**（0..100），和 ALSA mixer 是
**串联相乘**的两级衰减，不是同一个数字。系统侧怎么配合见 §5「音量键归属」。

### E. 电源键交给前端（`slot-power.patch`）—— 三处，缺一处就有一半不工作

**前提**：前端必须已经有一条「短按真的挂起整机」的路。Slot 的 `doze()` 原本只关背光、
CPU 照跑，所以早期版本把电源键整个交给 `rg353ps-hotkeyd`。现在反过来由前端负责，
但因为补上了挂起钩子，短按仍然是真 `s2idle`。**先确认能挂起，再声明归属**，否则
一次触碰就变成"屏幕黑了但机器在烧电"。

1. `crates/slot/src/input/evdev.rs` —— **两处**
   - `code_to_btn()` 里加 `116 => Btn::Power`（`KEY_POWER`）。早期 patch 曾把它注释掉
     并 `return None`，现在必须恢复。把全部 patch 打完后，最终源码里**不该**再出现
     那段 "deliberately left unmapped" 的注释；还留着就是 `slot-power.patch` 没打上，
     或排到了 `slot-rg353ps.patch` 前面（它必须在之后）。
   - `WANTED` 数组加 `116` 并把常量长度 `+1`（`[u16; 24]` → `[u16; 25]`）。
     **只改映射不改 `WANTED` 是无效的**：`WANTED` 决定该节点被 `EVIOCGBIT` 保留哪些
     码，不在里面的码根本不会被读上来，表现就是"完全没反应"，且不报错。
2. `crates/slot/src/app.rs` `doze()` 末尾 —— 挂起钩子
   ```rust
   if let Some(program) = std::env::var_os("BASEOS_SLEEP") {
       let _ = std::process::Command::new(program).status();
   }
   ```
   放在 `power.on_close()` 之后：先把存档/状态落盘，再睡。这个调用**阻塞到按键唤醒**，
   正是 `doze()` 期望的语义；不设该变量时行为与上游完全一致。
3. `launch.sh` —— 两行
   ```sh
   # baseos: power-owned
   export BASEOS_SLEEP=/usr/sbin/rg353ps-sleep
   ```
   标记行必须**独占一行**且匹配 `^\s*#\s*baseos:\s*power-owned\s*$`，
   前面多写一个词就不算。

**符号替换到别的 fork**：`Btn::Power` 要在该 fork 的 `Btn` 枚举里存在；枚举里叫别的名字
（如 `Btn::PowerOff`）就换名字。`doze()` 也可能叫 `sleep()` / `on_idle()`，找那个
「关背光 + 停音频 + 落盘」的函数，把钩子放它尾巴上。

**验证**（三项都过才算成）：
```sh
cat /run/baseos-power-frontend          # 前端运行期间有 pid，退出/暂停后消失
dmesg | grep 'power key'                # frontend slot owns the power key while it runs
tail -5 /mnt/SDCARD/.baseos/state/rg353ps-sleep.log
#   应看到 entering suspend -> suspend returned rc=0
```
实机确认的形态是**两个进程同时打开同一个节点**：电源键是 `rk805 pwrkey`（`event1`），
`rg353ps-hotkeyd` 和前端都读它，谁都没做 `EVIOCGRAB`，所以两边都收得到事件，
hotkeyd 靠 marker 决定要不要动作。**别指望前端"独占设备"，也别为了独占去加 grab** ——
那会让 hotkeyd 在前端崩溃、marker 来不及清理时彻底失去电源键，只能拔电。
验证时可以顺带看 `ls -l /proc/$(cat /run/baseos-power-frontend)/fd` 里有没有 `event1`。
hotkeyd 让位后不再打动作日志，但它的 `KEY_EVENT` 行里仍会出现该键，这不代表失败。

### F. boot logo 写回启动分区（`slot-bootlogo.patch`）

上游的契约是：logo 文件在**启动分区**根目录（`bootlogo.bmp`），用户想换图就把图放进
数据分区的 `Config/bootlogo.bmp`，前端启动时把它写进启动分区，原图另存为
`bootlogo.baseos.bmp`。Slot 自带这套逻辑，但在本移植上**两处都会失败**：

1. **分区名不对**：它找的是 `boot-resource`，这个移植的 FAT 分区叫 `BASEOS_BOOT`，
   于是 `partition()` 返回 `None`，直接静默放弃（只有 stderr 一行）。
   → 加一个回退常量，`partition(PARTITION).or_else(|| partition(PORT_PARTITION))`。
   **换机型只改这一行常量。**
2. **二次挂载 `EBUSY`**：它无条件 `mount -t vfat` 到 `/tmp/slot-boot-resource`，
   而 `rcS` 从开机起就把这个分区挂在 `/mnt/boot`。vfat 不允许同一设备挂两次，
   照上游写的代码到这里必然失败。
   → `mounted_at()` 读 `/proc/mounts` 找该设备已有的挂载点；找到就直接在里面操作，
   并且**跳过 remount rw 和 umount**（那两个动作作用在别人的挂载点上，会把 `rcS`
   的挂载改成 rw 或直接摘掉）。找不到才走原来的 mount/remount/umount 三步。

**底座侧的对应契约**（改前端时不用动，但要知道）：`rcS` 在挂上 `BASEOS_BOOT` 之后
立刻用 `BASEOS_CUSTOM_SPLASH_ONLY=1 fbsplash 0` 画一次 `/mnt/boot/bootlogo.bmp`，
整个启动只画这一次，不存在"用户分区挂上后再重绘"的第二遍。所以前端写盘要到
**下一次开机**才看得到，这与上游一致。U-Boot 在本移植不驱动 VOP2，不读这个文件。

**状态：写盘路径尚未上机验证。** 已验的是：补丁能干净应用到目标 commit、整条 patch
链顺序无冲突、`rcS` 正常画出该文件、开机后 `vcsa1` 无残留文字。**未验的是**
"Slot 把 `Config/bootlogo.bmp` 真的写进 `BASEOS_BOOT`" 这一步——当前这个 Slot 版本
没有更换 logo 的 UI 入口，触发不到 `refresh()`。换到带入口的 fork 时补测，检查点：
```sh
ls -l /mnt/boot/bootlogo.bmp /mnt/boot/bootlogo.baseos.bmp
cat /mnt/SDCARD/Logs/slot.log | grep bootlogo     # 期望 "installed"
```
若出现 `could not mount` / `EBUSY`，说明 `mounted_at()` 没命中——先确认
`/proc/mounts` 里该设备名与 `/sys/class/block/*/uevent` 的 `DEVNAME` 一致。

### G. 不要做的事

- 前端要接管电源键，就必须给它一个真能挂起的 `doze()`（见 §2.1 E），否则一次触碰只关屏
- 不要靠调低 mixer 来"修音量"——硬件前提是 0 dB，调低就破坏了 0..100 的整条曲线
- 不要让前端直接打开 `hw:CARD`，那会绕开 softvol 层

---

## 3. 标准流程（适配 10 分钟 + 构建时间）

1. **定目标**：fork 仓库 URL + 一个已知能跑的 commit（`SLOT_REV`）。
2. **构建镜像**（首次/换 Rust 版本时）：
   `docker build --platform linux/arm64 -t rg353ps-slot-build:latest -f platforms/rg353ps/frontends/slot/Dockerfile.slot-build platforms/rg353ps/frontends/slot`
3. **暖缓存**（首次/换 fork 导致依赖树变化时）：`bash diag/warm-slot-cache.sh`
   （取码已在宿主完成，容器无需联网；cargo registry/依赖产物固化进命名卷）。
4. **改 `build-slot.sh`**：把 `SLOT_REV`（仓库不同则也改 clone URL）指向新 fork；
   把要 `git apply` 的 patch 文件名换成新的。
5. **为新 fork 生成按键 patch**：基于该 fork 的 `evdev.rs`，按 RG353PS 的 DTS
   （`rk3566-anbernic-rg353x.dtsi` + `rk3566-anbernic-rg353ps.dts`）映射：

   | 物理键 | Linux 码 | Slot 按钮 |
   |---|---|---|
   | A（右） | `BTN_EAST` 0x131 | `A` |
   | B（下） | `BTN_SOUTH` 0x130 | `B` |
   | X（上） | `BTN_NORTH` 0x133 | `X` |
   | Y（左） | `BTN_WEST` 0x134 | `Y` |
   | L1 / R1 | `BTN_TL` 0x136 / `BTN_TR` 0x137 | `L1` / `R1` |
   | L2 / R2 | `BTN_TL2` 0x138 / `BTN_TR2` 0x139 | `L2` / `R2` |
   | Select / Start | `BTN_SELECT` 0x13a / `BTN_START` 0x13b | `Select` / `Start` |
   | Function | `BTN_MODE` 0x13c | `Menu` |
   | 十字键 | `BTN_DPAD_*` 0x220~0x223（兜底 `KEY_UP/DOWN/LEFT/RIGHT`） | 方向 |
   | 左摇杆 | `ABS_X`/`ABS_Y`（0..1023，静止 519） | 模拟轴 + 方向（方向需 `left_stick_dpad` 打开） |
   | 右摇杆 | `ABS_RX`/`ABS_RY` | 模拟轴（靠 `slot-analog.patch`） |
   | 摇杆按压 | `BTN_THUMBL`/`BTN_THUMBR` 0x13d/0x13e | `L3`/`R3`（可绑快捷键；靠 `slot-analog.patch` 的 `Btn`/`Device` 扩展） |

   两个易错点，写 patch 时务必照做：
   - **摇杆是 `adc-joystick`**：报送 `ABS_X/ABS_Y`（左）与 `ABS_RX/ABS_RY`（右），
     量程 0..1023、静止约 519，上游的 `STICK_DEADZONE = 2048` 会把所有采样吞掉；
     四个轴的方向约定见 §2.1 的方位表（X 不取负，Y 取负）。
   - **摇杆设备没有任何按键**：只靠 `WANTED`（按键位图）选设备会漏掉它，必须在
     `wanted_node()` 里用 `ABS` 能力位判定（同时要求左右摇杆都在，避免误收鼠标/触摸屏）。
6. **构建**：`SLOT_BUILD_IMAGE=rg353ps-slot-build:latest ./build-slot.sh`
   → 产出 `baseos-rg353ps-slot.zip`（含 `System/slot` + `launch.sh` + cores + 源码留证）。
7. **上机验证**（见 §4）。

---

## 4. 上机验证清单（每次必过）

- [ ] SDL2 KMSDRM 在 640×480 屏初始化成功（无黑屏、无 "EGL not initialized"）
- [ ] 输入：方向键 / ABXY / LR / Start / Select 按**物理位置**正确
- [ ] 左摇杆：推上下左右**方向正确**（上下、左右都不能反），按键设置里能被捕获成方向
- [ ] 摇杆按压：按下去能在按键设置里捕获成 `L3`/`R3`
- [ ] 右摇杆：在支持模拟核心的游戏里（街机 / PS1）推右摇杆有反应；GBA 核心本来就不用右摇杆。
      **注意右摇杆在按键映射设置里永远不会亮** —— 那里只认数字事件，别用它判断右摇杆好坏
- [ ] 音频：RK817 声卡出声（`SDL_AUDIODRIVER=alsa` 生效，日志里有 `audio plug:default at 48000 Hz`）
- [ ] 音量：按音量键，**前端自己的条**在动，且响度跟着变；`amixer -c <n> cget name='BaseOS Master'` 保持 90 不动
- [ ] 音量：一次开机到下一次开机，同一格的响度一致（不漂移）
- [ ] 模拟核心能加载并运行（mGBA / gpSP）
- [ ] 电池/背光脚本不报错（无 AXP 设备时安全跳过）
- [ ] 存档 / 退出正常
- [ ] **短按电源键**：熄屏后**真的挂起**，不是只关背光。
      `tail -5 /mnt/SDCARD/.baseos/state/rg353ps-sleep.log` 要有
      `entering suspend` 与 `suspend returned rc=0`；再按一次能唤醒、音频回来
- [ ] **长按 2 秒电源键**：出现**前端自己的**关机画面再关机，不是黑底 tty1 残留文字。
      只看到黑屏直接断电，说明电源键仍在 hotkeyd 手里（`/run/baseos-power-frontend`
      不存在或 `launch.sh` 少了标记行）
- [ ] 电源键归属可回收：退出前端后 `/run/baseos-power-frontend` 消失，电源键回到
      hotkeyd；`dmesg | grep 'power key'` 里有前端接管/交还的记录
- [ ] 启动耗时：`/usr/sbin/baseos-boot-report` 的 `Linux to menu` 不超过 9 s（拔掉数据线再测一次，
      插线时 USB 调试 gadget 会让整机变慢）；`handoff: entered` 到 `frontend exec` 应在几十毫秒内
- [ ] 音量在 audio 走上后台之后仍然正确：开机后 `amixer -c <n> sget 'BaseOS Master'` 是 90，
      硬件 `Master Playback Volume` 是 0 dB（这两条靠后台补救，别只验"能出声"）

### 摇杆不对时先分层，别一上来就改代码

硬件、前端映射、核心三段可以各自单独验，从上往下走，很快能定位问题落在哪一段：

```sh
# ① 哪个节点是摇杆 —— 节点号在不同机型/内核上不固定，别硬编码
for f in /sys/class/input/event*/device/name; do echo "$f: $(cat $f)"; done

# ② 硬件层：推摇杆，看四个轴的原始值（evtest 在 rootfs 里已装）
evtest /dev/input/event4 | awk -F', ' '$2 ~ /EV_ABS/ {c=$3; v=$4; sub(/.*\(/,"",c); sub(/\).*/,"",c); sub(/value /,"",v); printf "%-6s %5s\n", c, v; fflush()}'

# ③ 前端层：实际生效的极性，以及哪个节点在供轴
grep -iE 'input|sticks' /mnt/SDCARD/Logs/slot.log | tail
```

判读：

| 现象 | 结论 |
|---|---|
| ② 里某个轴完全不动 | 硬件或 DTS 问题，跟前端无关，先查 `adc-joystick` 的 `ABS` 能力位 |
| ② 有值，但方向和预期相反 | 改数据分区 `Config/sticks.txt` 的 `lx/ly/rx/ry=±1`，重进前端生效，**不用重新编译** |
| ③ 里没有 `[sticks]` 标记 | `is_stick_node()` 没认到设备 —— 单摇杆机型要放宽判据，见 §2.1 B 第 7、10 条 |
| ②③ 都对，游戏里仍没反应 | 该核心不查 `RETRO_DEVICE_ANALOG`（GBA/GB/GBC 天生如此），不是前端的问题 |
| ② 能读到值，但插了别的前端就读不到 | 那个前端 `EVIOCGRAB` 了设备；Slot **没有** grab，可以和 `evtest` 同时跑 |

RG353PS 实测参考值：`adc-joystick` 是 **event4**（`event1` 是电源键），静止 `ABS_X≈539`、
其余≈511，行程 15..1023。**不要用 `hexdump -e` 或 `od` 读**，原因见 §5「验轴工具」。

---

## 5. 已知坑（写进方法论，免得每次重踩）

- **容器里绝对取不到源码（已踩坑两次）**：WSL 下容器内 `git clone`/`curl` 全量拉 GitHub
  会 TLS 断流（`OpenSSL/3.x: error:0A000126:SSL routines::unexpected eof while reading`），
  **即使加 `--network host` 也不行**（小请求如 `ls-remote` 能过、全量 `clone` 仍被重置）。
  **正确做法：所有源码在宿主（WSL）取好，只读挂载进容器，容器内复制可写副本再打补丁/编译。**
  `build-slot.sh` 与 `warm-slot-cache.sh` 已把取码移到宿主侧（STEP 0），换 fork 只改
  脚本顶部的 `SLOT_REPO` / `SLOT_REV`（或环境变量）即可，容器无需联网。
- **musl 动态链接**：slot 用 `libloading::Library::new` 运行时 dlopen libSDL2，
  静态链接的 musl 二进制会报 "Dynamic loading not supported" 并退出。
  必须 `RUSTFLAGS="-C target-feature=-crt-static"`（脚本已带）。
  **cargo 指纹含 RUSTFLAGS** —— 暖缓存时用的 RUSTFLAGS 必须与生产完全一致，否则缓存不命中。
- **fat LTO 很慢**：`[profile.device]` 开 `lto="fat"` + `codegen-units=1`，干净编译在 QEMU arm64
  模拟下极慢；靠 `warm-slot-cache.sh` 把依赖固化进命名卷，之后只重编 slot 自身一个 crate。
- **exec 位**：TF/exFAT 不保 Unix exec 位，`launch.sh` 把二进制 `cp` 到 `/tmp` 再 `exec`；
  ROM/存档/core 留在用户分区。
- **无 dbus**：rootfs 无 `dbus-daemon`，依赖系统总线的前端特性（如某些 audiomon）起不来；
  Slot 走 ALSA 直连，不受影响。
- **内核驱动**：坚持 Panfrost，**不要**试图塞闭源 libMali（需私有 `mali.ko`，与 Panfrost 互斥）。
- **验轴工具（实测踩过，别再抄网上的命令）**：BusyBox 环境下两条最常见的读 evdev 命令**都跑不了**：
  - `hexdump -e '24/1 "%u " "\n"'` —— BusyBox 1.37 的 `-e` 不支持 `N/M` 迭代前缀，
    直接报 `Invalid argument`；
  - `od -An -tu1 -w24` —— 读字符设备报 `read error`。
  还有一个更隐蔽的坑：`struct input_event` 在 **aarch64 上是 24 字节**（timeval 16 + type 2 +
  code 2 + value 4），而网上大量按 16 字节（32 位）写的字段偏移式 awk 抄过来会**全部筛空**——
  正确偏移是 `type` 在 `$17/$18`、`code` 在 `$19/$20`、`value` 在 `$21..$24`。
  **正解是 rootfs 自带的 `evtest`**：输出本身就是可读文本，`grep EV_ABS` 就能用，命令见 §4。
  另外节点号**不是固定的**，`event1` 在这台机器上是电源键、摇杆在 `event4`，换机型必然要重查。
- **电源键归属**：系统里有两个角色能处理电源键——常驻的 `rg353ps-hotkeyd`（短按
  `echo mem` 真挂起、长按 2 秒关机）和前端自己。两者同时响应会让一次短按休眠两次、
  唤醒还要再按一次。约定是**前台优先**：前端在 `launch.sh` 里写一行
  `# baseos: power-owned`，`baseos-frontend-session` 就会在前端运行期间把 pid 写进
  `/run/baseos-power-frontend`，hotkeyd 据此让位；前端退出/暂停/崩溃时该文件被清掉，
  电源键自动回到 hotkeyd。不写这一行的前端，始终由 hotkeyd 负责。
- **Slot 声明 power-owned**：电源键归前端，长按由 Slot 画关机画面、落盘再退出，
  这是用户能看懂的关机；交给 hotkeyd 直接 `poweroff`，屏幕上只剩 tty1 的残留
  （实测就是开机 logo 上那几行 EROFS 报错），没有前端收尾。代价原本是短按变成
  「只关屏不睡觉」，所以给 Slot 加了 `BASEOS_SLEEP` 钩子：`doze()` 在关背光、落盘
  之后执行该变量指向的程序并阻塞到唤醒，`launch.sh` 把它指向 `rg353ps-sleep`，
  短按因此仍是真 `mem` 挂起。`slot-power.patch`（必须排在 `slot-rg353ps.patch` 之后）恢复
  `KEY_POWER(116)` 的映射、把它加进 `WANTED`，并给 `doze()` 补那段钩子 ——
  早期 `slot-rg353ps.patch` 是把这个码注释掉、交给 hotkeyd 的，两版方向相反，
  所以顺序不能换。逐条改法见 §2.1 E。hotkeyd 看到
  `/run/baseos-power-frontend` 就让位，前端退出/暂停/崩溃时电源键自动回到 hotkeyd。
  移植别的 fork 时，同样要先有「doze 能挂起整机」这条路，再声明 power-owned。
- **bootlogo 放在启动分区**：和上游 BaseOS 一致，开机画面是启动分区上的一个文件，
  数据分区里既没有这个目录、也没有改它的入口。上游由 U-Boot 直接读 p2 的
  `bootlogo.bmp`；这个移植的 U-Boot 不驱动 VOP2（屏幕全黑），改由 `rcS` 在挂载
  `BASEOS_BOOT` 之后画一次 `fbsplash 0`，整个启动只画这一次。换图有两条路：卡根目录放
  `Config/bootlogo.bmp`，Slot 启动时把它写进 `BASEOS_BOOT`（原图留作
  `bootlogo.baseos.bmp`）；或在 PC 上把 640×480、24 位、未压缩的 BMP 直接写进该分区
  根目录。`slot-bootlogo.patch` 让 Slot 认 `BASEOS_BOOT` 这个分区名，并在分区已经被
  `rcS` 挂载时复用挂载点——vfat 不允许同一设备挂两次，照上游那样再 mount 一次只会
  拿到 EBUSY。逐条改法见 §2.1 F。
  **这一条只验到"补丁能应用、rcS 能画出 logo"，写盘那一步还没上机验证**：当前
  Slot 版本没有更换 logo 的 UI 入口，`refresh()` 触发不到。换到带入口的 fork 再补测。
- **音频**：不要指望前端自己设混音器。`baseos-audio-init` 在开机时、前端之前把
  `rk817_ext` 声卡的 ALSA `default`、DAC 音量和 Speaker Amp 开关都设好并存进
  `alsactl`；Slot 只会打开 ALSA 播放，从不碰控件。排查用 `baseos-audio-check`。
- **音量模型（重要，移植时别重复踩）**：RK817 的 DAC 增益是 0..255 寄存器线性映射到
  -95.5 dB..0 dB，ALSA 的百分号是**寄存器百分比**，50% = -47 dB、20% = -76 dB，
  在这颗喇叭上等于没声。所以底座把**硬件音量钉死在 0 dB**，用户音量交给
  `/etc/asound.conf` 里的 `softvol` 控件 `BaseOS Master`（0..100 → -48 dB..0 dB）。
  也就是说 `default` 的链路是 `plug -> baseos_vol(softvol) -> baseos_hw`。
  任何直接对 `hw:CARD,0` 调的代码都会绕开这一层；任何把 `Playback Volume` 调低的
  代码都会破坏"拉满就是满"的前提。音量键（hotkeyd）调的就是 `BaseOS Master`，
  找不到时才回退到硬件控件并用 dB 步进（3 dB），绝不用寄存器百分比。
  Slot 自己还有一层 `v²` 软件音量（`Config/slot.state` 的 `volume=` / `volume_hp=`，
  默认 60），它和上面的 mixer 是**串联相乘**的两级衰减，两个数字互不相干 ——
  这就是「条显示 50% 却没声」的来源。处理方式见下一条。
  休眠唤醒和前端启动前都会重新执行初始化，防止 codec 复位后音量"又不一样了"。
- **音量键归属：前端优先（现行方案，别再按旧结论改）**。原则是**谁有音量条谁管**，
  这样换前端才能各自匹配皮肤。
  - `baseos-frontend-session` 在前端启动前把 `BaseOS Master` 钉到 **90/99**
    （-4.3 dB，满幅 0 dB 推小喇叭会削顶），并把前端 pid 写进
    `/run/baseos-volume-frontend`
  - `rg353ps-hotkeyd` 读到这个 marker 且 pid 还活着，就**完全不碰 mixer**
    （dmesg 里能看到 `volume keys belong to the running frontend; not touching the mixer`）
  - 前端退出时 mixer 恢复到启动前记在 `/run/baseos-volume-mixer-saved` 的值
  - `baseos-audio-init` 开机时如果看到 marker 存活，也直接钉 90，不读持久文件 ——
    否则后台的 restore 会盖掉 pin，出现"开机静音但条显示 30%"
  - 开关是卡上 `baseos.conf` 的 `volume_owner=auto|frontend|system`
  - **移植新 fork 必看**：`auto` 只对 `slot` 这个名字生效（`volume_owner=auto` 时
    只有 `SELECTED=slot` 才认领）。换别的 fork 名字，必须显式写
    `volume_owner=frontend`，否则音量键仍归 hotkeyd，前端那条 UI 不会动。
    如果该 fork 根本不处理音量键，就写 `volume_owner=system`。
  - 一个实测细节：`amixer` 的 `5+` 在这颗控件上不是 5 格而是 **10 格**（按量程百分比换算），
    而且到顶被 clamp 后回不到原点。所以 hotkeyd 走 `volume_owner=system` 时是
    "读原值 → 加 5 → 夹到 0..99 → 写绝对值"，不用相对步进。

---

## 6. 启动速度（怎么量、量出了什么、还剩什么）

原版 BaseOS 的 README 敢写"4 秒启动"，是因为它先建了测量设施再优化。移植版一开始
两样都没有：`/proc/uptime` 看不见引导器，而插着数据线时 dwc3 的调试打印每个 USB 包
写好几行，几秒内就把内核日志挤出 ring buffer。于是"开机前花了多少"和"内核里花了
多少"这两个问题都答不了。

### 6.1 三个工具（已在 rootfs 里，构建脚本会校验它们存在）

| 工具 | 作用 |
|---|---|
| `src/boot-clock.c` → `/usr/sbin/boot-clock` | 读 `CNTVCT_EL0`（内核不复位它）再减去 `CLOCK_MONOTONIC_RAW`，把总时长拆成「开机前」和「Linux 到现在」。这是唯一能看到 U-Boot 和内核解压的手段 |
| `baseos-boot-mark` / `baseos-boot-report` | 在 rcS / 前端会话里打 uptime 标记，汇总成一张分阶段表 |
| rcS 首行的 `dmesg > /run/dmesg-boot.txt` | 在 USB gadget 起来之前抓一份干净内核日志。**必须放在 rcS 最前面**，晚几秒就没用了 |

看结果：SSH 登录后 `/usr/sbin/baseos-boot-report`。每次启动还会往卡上
`Logs/boot.log` 追加一段（在后台写，不挡启动）。

### 6.2 实测时间线（uptime，单位秒）

> 这一节记的是第一轮（可写根）的状态，留作对照。**当前值是 §6.7 的 1.0.6 实测**：
> `4.18 s before Linux, 3.33 s Linux to menu, 7.51 s total`。

第一轮优化后（可写根，每次启动重放 ext4 日志）：

```
 4.17  rcS 开始
 4.94  hotkeyd ready          ← rcS 会一直等这个标记
 5.47  userdata ready
 5.81  GL 预取完成
 6.09  选中前端 slot
 6.12  开始等音频就绪
 7.75  音频就绪                ← 波动 0.2~1.6
 7.79  接棒记录
 8.05  exec 前端
 +2.06 Slot 进程内首帧
```

第二轮（只读根 + U-Boot 不再空等按键），刷成 1.0.4 之后的冷启动实测：

```
Startup: 4.184 s before Linux, 4.896 s Linux to menu, 9.080 s total
    1.21     +0.00  rcS: proc/sys/dev
    1.27     +0.06  rcS: mdev done
    1.99     +0.72  hotkeyd ready
    2.02     +0.03  storage mounted
    2.06     +0.04  modules: gpu ready
    2.53     +0.47  userdata ready
    2.89     +0.36  bg: gl prefetch done
    2.99     +0.10  rcS done
    3.00     +0.01  session entry
    3.03     +0.10  bg: wifi/bt/vpu ready
    3.13     +0.10  frontend selected: slot
    3.17     +0.04  session: audio wait begins
    4.70     +1.53  session: audio ready (waited 1500 ms)
    4.74     +0.04  session: prepped
    4.74     +0.00  handoff: entered
    4.89     +0.15  frontend exec
```

**通电到前端进程启动 14.2 s → 9.1 s**，三笔账分别是：

| 改动 | 省下 |
|---|---|
| ext4 不再重放日志（只读根） | 2.9 s（rcS 从 4.17 s 提到 1.21 s） |
| U-Boot 不再空等按键（`CONFIG_BOOTDELAY=0`） | 2.0 s（开机前 6.19 s → 4.18 s） |
| 第一轮的四项白等（hotkeyd / aplay / alsactl / 写日志） | 3.4 s |

现在开机前那 4.18 s 仍是最大的一块，占 44%。剩下的两块大头都在 SD 卡上：内核 `Image`
29 MB 要从 FAT 读进内存，还有 SD 卡初始化本身（§6.7）。

**这个数字现在不再依赖关机是否干净。** 只读根之前，每次拔卡断电都会让下次启动多花
2.9 s；现在拔卡和正常关机启动一样快。这是这一轮最实用的副产品。

### 6.3 量出来才发现的四个坑

都是"看起来合理、实际白等"，共同特征是**等待的东西早就在手上了**：

1. **`hotkeyd` 固定采样 1500 ms 才写 ready，而 rcS 整个启动都阻塞在这个标记上。**
   开机就按住的键，在 evdev 节点被打开时已经按下，`EVIOCGKEY` 快照当场就能读到 ——
   那 1500 ms 等不到任何快照漏掉的东西。改成 400 ms（仍然覆盖"开机时按住 Function"
   这个文档写明的操作）：**1.74 s → 0.61 s**。
2. **`audio-init` 为了注册 softvol 控件播了整整 1 秒静音**（`aplay -d 1`）。控件是在
   PCM **打开时**注册的，与放多久无关。改把 2 KB 管道给 aplay，同样效果 **1.02 s → 0.14 s**。
3. **`alsactl restore` 在真机启动时序里要 1.6 s，热态只要 0.02 s。** 它压在 ready 标记
   前面，是前端启动前最后一块大开销。移到 ready 之后的后台过程，并在里面重新钉硬件
   增益、重设 softvol —— 顺序照样成立，前端不再等：**1.84 s → 0.2~0.3 s**。
4. **启动日志是写在启动路径上的。** `write_boot_log` 往 SD 卡 exFAT 追加一段，加上
   `baseos-boot-report` 的一次 fork，实测 0.3~1.4 s，而没有任何东西需要等这个文件。
   改后台写：**1.35 s → 0.26 s**。

另外两项：`libgallium` 有 33 MB，原本是前端启动时冷读（`surface` 那 2.2 s 主要是它），
改成在 hotkeyd 采样窗口旁边后台预读，Slot 首帧 **4.21 s → 2.06 s**；Mesa 着色器缓存
本来就落在 `/.cache`（`HOME=/`），确认已生效即不动。

### 6.4 第二轮：根分区只读，干掉每次启动 2.9 s 的日志重放

内核日志里那三行就是全部证据：

```
[ 1.137309] EXT4-fs (mmcblk0p3): INFO: recovery required on readonly filesystem
[ 3.405310] EXT4-fs (mmcblk0p3): recovery complete
[ 3.877031] EXT4-fs (mmcblk0p3): mounted filesystem ... ro
```

**为什么每次都是脏的**：BusyBox 的 `reboot` 直接调 `reboot(2)`，不会通知 init 去跑
`::shutdown:/bin/umount -a -r`；手动 `mount -o remount,ro /` 会 `EBUSY`（真有写句柄
拿着，换 `/dev/mmcblk0p3` 也一样）。掌机长按断电更是必然脏。

**为什么一个几乎空的日志要 2.8 s**：JBD2 恢复是整个日志顺序扫一遍，4 KiB 一块地读，
4096 块就是 4096 次单块 I/O。日志本身没几条事务，时间全花在"扫完它"上。

**解法**：根分区只用只读挂载（`ro`），可写的东西全进 RAM。改动只有四处：

| 位置 | 改动 |
|---|---|
| `build-image.sh` extlinux `APPEND` | `rootwait rw` → `rootwait ro` |
| `build-image.sh` `mkfs.ext4` | `-J size=4`，把日志压到 4 MiB（真脏时的代价上限） |
| `rcS` 开头 | `/var`、`/root`、`/etc/wpa_supplicant` 挂 tmpfs |
| `build-rootfs.sh` | `/etc/asound.conf` → 指向 `/run/asound.conf` 的符号链接 |

只读根一旦成立，文件系统**永远不会脏**，也就没有东西可重放；顺带把"断电损坏根分区"
这个复古掌机最经典的故障一起去掉了。日志恢复仍在（内核会在只读挂载时照样重放），
所以真有特殊情况也不会带着坏账跑。

**刷成 1.0.4 之后的实测**：`grep EXT4-fs /run/dmesg-boot.txt` 只有一行

```
[    1.147590] EXT4-fs (mmcblk0p3): mounted filesystem c295601d-... ro with ordered data mode.
```

没有 `recovery required`，没有 `recovery complete`。rcS 开始时间从 4.17 s 降到 1.21 s，
省下的 2.9 s 与日志重放的实测耗时一致。

三个坑，都在"可写目录"这件事上：

1. **`/etc/asound.conf` 是 audio-init 每次都重写的**（softvol 定义里要写声卡序号）。
   只读根会让它静默失败 → 没声音。用符号链接指到 `/run/asound.conf`：写穿链接落在
   tmpfs 上，ALSA 读 `/etc/asound.conf` 的路径一个字没变；链接悬空时 alsa-lib 当
   "没有配置文件"处理，正是镜像出厂的状态。
2. **`/etc/wpa_supplicant` 不能只做文件级链接**：`update_config=1` 时 wpa_supplicant
   用"写临时文件再 rename"落盘，rename 会把符号链接换成普通文件，在只读目录里直接
   EROFS。所以挂整个目录 tmpfs，持久副本仍在用户分区的 `.baseos/wifi.conf`。
3. **`/root` 也要 tmpfs**：dropbear 的 `authorized_keys` 是由 `baseos-usb-debug`
   从镜像或用户分区拷进去的，`/root` 里没有任何需要跨启动保留的东西。

**代价：状态必须搬家。** 只读根让所有 `/var` 下的东西随启动消失，包括音量记忆和
Mesa 着色器缓存（后者值 2 s）。所以这两个连同 ALSA mixer 状态一起搬到了用户卷的
`/mnt/SDCARD/.baseos/` 下：`state/`（音量 + mixer state）和 `cache/`（Mesa 缓存）。
设备上没有卡时自动退回 tmpfs，只是丢记忆不影响使用。

实测确认：`baseos-volume` 里是 99，`baseos-alsa-state` 更新于本次启动，
`cache/mesa_shader_cache_db` 里 52 条还在，音量跨重启保留。

排查时先看这两条，能省一小时：`grep EXT4-fs /run/dmesg-boot.txt` 应该只有一行
`mounted ... ro`；`grep -c EROFS /run/dmesg-boot.txt` 应该是 0（真出错时去看是谁在写，
而不是去把根分区改回 rw）。

### 6.5 第二轮：开机前 6.19 s → 4.18 s

`boot-clock` 说 6.19 s，而 `bootflow`/U-Boot 的串口没人接，所以这一层只能靠"改一项、
量一次"来逼近。第一刀是最便宜的：**`CONFIG_BOOTDELAY` 板级默认是 2**，每次启动白等
两秒按键——这台机器没有串口，U-Boot 也不轮询手柄。`platforms/rg353ps/uboot.config`
把它设成 0（构建脚本用 `merge_config.sh` 合进去，并 grep 校验真的生效）。

刷进卡里实测：开机前 6.186 s → 4.184 s，正好省掉 2 s。

剩下的大头是内核本身：`Image` 有 29 MB，U-Boot 要把每一字节从 FAT 读进内存。可选方向
（都需要重刷验证）：U-Boot 里把 SD 时钟提到 UHS、内核存成压缩的 FIT 让 U-Boot 解压、
砍内建驱动。别在没量的情况下动，这一层的"看起来合理"通常不准。

### 6.6 dwc3 的调试打印：从淹没日志到按需打开

`build-kernel.sh` 里注入了一整套 USB bring-up 探针（dwc3 请求映射、PHY 状态机、
FSG 生命周期），原本全是 `dev_info`/`pr_info`。插着数据线时每个 USB 包 3~5 行，
1 MB 的 ring buffer 几秒就满了 —— 所以才有 §6.1 那个"必须在 rcS 首行抓 dmesg"的技巧。
那本质上是拿快照绕过一个自己制造的噪声源。

现在这些探针统一收进动态调试（`CONFIG_DYNAMIC_DEBUG` + `CONFIG_JUMP_LABEL` 都在，
关掉时是 nop 跳转，零成本），源码和格式串原样保留：

```sh
mount -t debugfs none /sys/kernel/debug
echo "file gadget.c +p" > /sys/kernel/debug/dynamic_debug/control
echo "file ep0.c +p"    > /sys/kernel/debug/dynamic_debug/control
```

实现是 `build-kernel.sh` 末尾一段"往回找到调用它的括号、再改函数名"的改写，而不是
在十处注入点各改一遍：格式串统一以 `RG353PS` 开头，所以锚点稳定，且改写是幂等的
（源码树有缓存，同一棵树会被处理两次）。

刷进卡里的实测：`grep -c REQMAP /run/dmesg-boot.txt` 从 635（全是它）变成 **0**，
快照现在 552 行，全是正常的内核消息。mass-storage 那批 `baseos-msdiag:` 前缀的
`pr_info` 故意留在 info 级——它们只在用户主动按 Function 进 USB 存储模式时才跑，
不在启动路径上。

### 6.7 还能压的地方（1.1.2 复核，按"收益 ÷ 难度"排）

1.1.2 冷启动实测（USB 未插，同一张卡连测三次，取最后一次的时间线）：

```
Startup: 4.184 s before Linux, 2.92 s Linux to menu, 7.104 s total
    1.24  rcS: proc/sys/dev          1.30  mdev done        +0.06
    1.34  storage mounted            +0.04
    1.38  modules: gpu ready         +0.04
    1.99  hotkeyd ready              +0.61   ← 采样窗口，下面几项已排进来
    2.05  bg: gl prefetch done       +0.06   （后台，不挡路）
    2.29  bg: wifi/bt/vpu ready      +0.24   （后台，不挡路）
    2.40  userdata ready             +0.11
    2.51  rcS done                   +0.11
    2.52  session entry              +0.01
    2.75  frontend selected: slot    +0.23
    2.90  session: audio wait begins +0.15   ← 这段就是等 audio 的 0.44 s
    2.90  session: audio ready       +0.00
    2.94  session: prepped           +0.04
    2.94  handoff: entered           +0.00
    2.94  frontend exec              +0.00
```

三次 `Linux to menu`：3.03 / 2.94 / 2.92，`total`：7.213 / 7.124 / 7.104。

#### 已做

| # | 压缩点 | 版本 | 原值 | 现值 | 实收益 |
|---|---|---|---|---|---|
| 1 | `boot-clock` 冷读拦在 exec 前 | 1.0.6 | `handoff`→`exec` 差 0.00–1.34 s | 0.00–0.01 s | **−1.56 s**（9.08 → 7.51） |
| 2 | `hotkeyd ready` 的阻塞等待 | 1.0.8 | `rcS done` 2.66 | `rcS done` 2.48 | **−0.18 s**（7.51 → 7.25），改法见 §6.7b |
| 3 | `audio-init` 提前启动 | 1.1.2 | 只占位没收益 | 已回退，只留并发修复 | **≈0**（7.25 → 7.15，噪声内）。**假设被证伪，见 §6.7e** |

#### 还没做

| # | 压缩点 | 现状 | 做法 | 难度 | 目标收益 |
|---|---|---|---|---|---|
| 3 | **前端选择结果缓存** | +0.13–0.29 s，每次扫 `.baseos/frontends/*` | 把选中的名字写进 `/run` 或 `baseos.conf` 缓存，失效再扫 | 低 | **~0.2 s** |
| 4 | **内核压缩成 FIT** | `Image` 27.8 MB，U-Boot 侧约 2.9 s | `Image.gz` + `kernel.itb` + `bootm`；`CONFIG_FIT=y` 已开 | 中–高（要同步改更新包与 A/B 布局） | **~1.3 s**（读 9.5 MB 省 1.85，内核自解压付 0.55；按下面那个 A/B 实测修正） |
| 5 | **裁内核体积** | 27.8 MB 偏大（同芯片常见 18–22 MB） | 关掉不用的子系统/驱动（**要先列清砍掉什么、影响什么**） | 中 | 每减 5 MB ≈ **0.5 s** |
| 6 | **SD 调谐（Linux 侧）** | 0.585→1.165 = 0.58 s，含一次 `tuning failed -5` 重来 | DTS 改 `sd-uhs-sdr50` | 低（但要复核 `libgallium` 预读仍赶得上首帧） | **~0.5 s**；若同时做 #4，U-Boot 读盘不受影响 |
| 7 | **`mdev -s` 改用 devtmpfs** | `mdev done` 0.07 s + init 到首 mark 的 0.21 s | 内核已自动填充 `/dev`，只需处理热插拔 | 低 | 0.05–0.15 s |
| 8 | **userdata 初始化精简** | 稳定态只有 0.11 s（见 6.7d），已无油水 | — | — | 接近 0 |
| — | **Slot 首帧**（不属于底座） | 2.07 s（前端进程内） | 前端自己的资源/皮肤加载 | 中 | 0.3–1.0 s。**改前端，已列为可选，见 §6.7c** |

**唯一还没量准的数字是"U-Boot 读 27.8 MB `Image` 花了多久"。** `before Linux` 4.183 s
里含 bootrom/SPL/BL31/U-Boot 自身（同芯片上游约 0.94 s）、FAT 读 `Image`、内核早期到
timekeeping。按 4.18 − 0.94 − 0.2 倒推，读盘约 **2.9 s，即 ~9.5 MB/s** —— 这是
U-Boot 的 PIO/FAT 路径，不是 Linux 侧那个 150 MHz SDR104。**先把这个假设验掉再动内核**：
往启动分区放一个明显更小的可启动 `Image`，看 `before Linux` 掉多少，一次 A/B 就能得出
实际读速，不用重编 U-Boot。

**不要做的**：把 Linux 侧 SD 降到 SDR50 之后，如果同时还想靠"提高 SD 时钟"来加速
U-Boot 读内核，两者方向相反 —— 先定 #4 还是"提速"，别一起上。

**不减时间但很值的一项**：通电到有画面现在是 **5.5 s**（`rcS` 画 logo 在
`hotkeyd ready` 之后），这之前全是黑屏。U-Boot 在本移植不驱动 VOP2，所以修 U-Boot
显示（或让内核挂内建 splash）能把黑屏砍到 ~1.5 s。这是**感知收益**，不影响总时间。

**推荐顺序**：#3（前端选择缓存，~0.2 s）之后再往下去，剩下的都是要动内核或设备树的
项 —— 先用 A/B 验掉 #4 的读速假设，决定要不要把内核压成 FIT。

### 6.7a #1 的改法：把不随时刻变化的量挪到前面去采

`boot-clock` 输出的四个字段里，只有 **"before Linux" 与采样时刻无关**：它是
`CNTVCT_EL0`（自由运行，含 bootloader）减去 `CLOCK_MONOTONIC_RAW`，两个钟同速前进，
差值是常量。所以这个字段什么时候采都一样，而"Linux to handoff"永远等于当下的 uptime。

于是 `rcS` 在 `mark "rcS: proc/sys/dev"` 之后、I/O 还空着的时候采一次，把整行存进
`/run/boot-clock-boot`：

```sh
bc_try=0
while [ "$bc_try" -lt 3 ]; do
  if /usr/sbin/boot-clock > /run/boot-clock-boot 2>/dev/null; then break; fi
  bc_try=$((bc_try + 1))
done
```

`record_handoff` 之后只做三件便宜事：读 `/proc/uptime`（已在 page cache）、从
`/run/boot-clock-boot` 取 `before`、`awk` 相加得 `total = before + uptime`。它仍然把结果
写成 `/run/boot-clock-handoff` 的同一个四字段格式，所以 `baseos-boot-report` 一行都不用改。
`boot-clock` 在 handoff 处仍是回退路径：早期采样失败（内核禁止用户态读计数器，或三次采样
都跨了调度）时，它的行为和以前完全一样。

实测早期采样只花 **约 10 ms**（`rcS: proc/sys/dev` 记 1.21，采样写下的 uptime 是 1.22），
对比 exec 前那次 0.03–1.34 s。失败重试最多三次，每次都是一次 fork，最坏情况可忽略。

**顺带解释 §6.7a 旧结论的来历**：1.0.5 里那 1.34 s 一直被读成"口径差"或"record_handoff
里又写卡了"，实际是 `boot-clock` 这个 66 KB 静态二进制自己没被读进来 —— 那一刻 27.8 MB
内核刚由 bootloader 读完、`libgallium` 33 MB 正在预读、exFAT 才接手第一次写，队列排满。

### 6.7b #2 的改法：把不依赖按键采样的步骤排进采样窗口

`hotkeyd` 启动后要先采 400 ms 按键（`CONFIG` 里的采样窗口），采完才写
`/run/rg353ps-hotkeyd.ready`。rcS 原来就堵在 `while [ ! -e ...ready ]` 上，把整段
0.61 s 空等掉，然后才去挂载卷、加载 GPU、初始化 userdata —— 而这三件事一件都不需要
采样结果。

现在的顺序是：`hotkeyd` 启动 → `baseos-mount-storage` → GPU 模块 → userdata →
**等 ready** → 画 logo → 剩下的。`rcS done` 从 2.66 s 降到 2.48 s。

三件必须记住的事：

1. **logo 不能跟着往前挪。** 它必须等采样结果，因为采样决定这一轮是不是
   Function 触发的 USB 存储会话，而那种会话由 USB helper 独占屏幕，logo 会盖掉它的
   操作提示。
2. **userdata 只在"已初始化过的卡"上提前。** 首次启动它要画 `EXPANDING STORAGE`
   状态条，同样会和 USB helper 抢屏，所以首启路径仍然留在 wait 之后
   （`USERDATA_DONE` 标记区分）。两条路径都调同一个 `init_user_storage()` 函数。
3. **`prefetch-gl` 必须排在 userdata 之后。** 第一版把它放在前面，两个 I/O 密集型
   任务抢同一张卡：exFAT 挂载 + 建目录从 0.48 s 涨到 1.15 s，把这项的收益整个吃掉。
   现在的顺序是 userdata 先跑完，预读再起，仍然赶在 session 之前读完。

**为什么实收益只有 0.18 s，而不是预估的 0.6–0.7 s**：预估用的是 1.0.6 时间线里
`userdata ready` 的 +0.48 s，但那是一次带迁移的启动。稳定态下这三项分别是
0.04 / 0.04 / 0.11 s，加起来 0.19 s —— 就是能填进采样窗口的全部工作量，剩下 0.4 s
是净等，除非缩短 hotkeyd 自己的 400 ms 采样窗口（那会改变"按住 Function 开机"的
手感，属于产品取舍，不在这次范围内）。

### 6.7c 前端侧的可选项（不在底座范围内，换 fork 时再看）

这几项只能在前端进程里做，底座改不动，因此**只记录，不在本移植实施**：

- **首帧 2.07 s**：`slot.log` 的 `first frame at 2074 ms`（1.0.8）。Slot 在首帧前加载皮肤、
  字体与封面缓存；换成带增量加载或预热资源的 fork 才有意义。
- **资源预读**：底座已经把 `libgallium` 提前 33 MB 读进 cache（`bg: gl prefetch done`），
  前端若自己也做资源预读，两条路径会抢 I/O；真要改，让前端在首帧后再预读。
- **启动时的 `sync`/写盘**：前端若在首帧前落盘（存档扫描、日志 flush），会直接顶到首帧时间上。

### 6.7d 同一个阶段在"首次"和"稳定态"能差三倍

这一轮差点被自己的基线骗了：1.0.6 的 `userdata ready` 是 +0.48 s，1.0.8 稳定态是
+0.11 s，而 1.0.7/1.0.8 的第一次启动又是 +1.06 s。三个数都对，但量的是三件事：

- **+1.06 s**：刚刷完新版本后的第一次，`.baseos` 下要重建目录、迁移旧布局；
- **+0.48 s**：1.0.6 的那次测量恰好也是一次带迁移的启动；
- **+0.11 s**：之后的每一次，只剩挂载 exFAT 和几个 `mkdir`。

结论：**比较启动时间只能用稳定态，而且至少要三次取同一段**。这也是为什么 §6.7 的
数字都写成"连测三次"而不用单次值；1.0.7 第一次测出 `rcS done` 2.62 时差点被当成
"这项没有收益"而放弃。

### 6.7e #3 证伪：audio 的等待不是"启动太晚"，是 codec 本身的节奏

原计划是"把 `baseos-audio-init` 从 rcS 末尾挪到采样窗口里并行，省掉 session 里
0–400 ms 的等待"。改了四版，全部量过，结论是这条路上没有收益。

**第一步**：把 audio-init 从 rcS 373 行挪到 userdata 之后（约 1.5 s）。等待仍是 400 ms。
看 `/run/baseos-audio.log` 的时间戳，第一条 `rk817 codec is card1` 是 **2.40 s**——
也就是说它 1.5 s 启动，但直到 2.4 s 才跑到第一行。

**第二步**：查 dmesg，codec 早在 **1.13 s** 就 probe 完了，不是它等 codec。那 0.9 s
是 audio-init 这个 shell 脚本自己没被读进来 —— 同一时刻 `prefetch-gl` 正在读 33 MB。

**第三步**：把 `prefetch-gl` 和 Wi-Fi/BT/VPU 的模块加载都推到 audio-init 之后，让它
独占 I/O。**仍然 2.40 s。** 至此可以确定：与 I/O 顺序无关，是内核那边 codec 节点
可用的时刻就摆在那里（1.13 s 是 dmesg 的首条，而 `find_card` 轮到它时已经 2.4 s ——
中间被 bg 模块和 exFAT 初始化占满，换谁先跑都躲不开）。

**第四步**：量总账。因为把两个后台 I/O 任务推后，`frontend selected` 从 0.23 s 涨到
**0.56 s**（exFAT 目录扫描被拖慢），total 反而从 7.25 回到 7.40。回退。

**顺带修掉一个真 bug**：`baseos-frontend-session` 里有一段兜底——查不到
`BaseOS Master` 就再跑一次 audio-init。rcS 里那次还没跑完时，这个判断会误以为音量层
缺失，于是起了**第二个** audio-init，两个抢 default PCM，后一个在
`/run/baseos-audio.log` 里留下 `could not open default PCM to create the softvol control`。
现在先等 `/run/baseos-audio-ready` 再判断（那个 flag 在"没找到 codec"的分支里也会写，
所以真的坏了仍然会重试）。

**结论**：`session` 与 audio ready 的相对位置决定了这 0.4 s 一定要等 —— audio 在
2.9 s 完成，session 在 2.5 s 就开始找前端。提前启动 audio-init 只是让它更早开始等
同一个时刻。1.1.2 保留的只有并发修复和把等待挪到更早的位置（现在记在
`frontend selected` 之后的那一段，标记更诚实），净收益在噪声内。

### 6.8 量启动时的注意事项

- **别用不同启动之间的小数互相减**：内核 dmesg 时间戳、`/proc/uptime`、`boot-clock`
  是三个基准，每次都略有不同。要比就比同一份 `baseos-boot-report` 里的行。
- `boot-clock` 是唯一能量"U-Boot + 内核加载"的手段，但它只给总数。要拆开就得在
  U-Boot 里埋点（`bootstage` 或往 FAT 写报告），这一层目前没做。
- `handoff: entered` 和 `frontend exec` 之间的差值，1.0.6 起应当稳定在 0.00–0.01 s，因为
  两侧都只剩读 `/proc/uptime`。它若又跳到几十毫秒以上，说明 §6.7a 的早期采样没成功、
  `record_handoff` 退回了 exec 前跑 `boot-clock` 的老路径 —— 先看 `/run/boot-clock-boot`
  是否存在。
- 插着数据线调试时机器会明显更慢（USB 调试 gadget 在跑），优化的真实收益要在
  `usb_debug=no` 下复核一次。
- rcS 首行的 dmesg 快照现在不再是"救命"的（探针已收进动态调试），但它便宜到没有理由
  去掉：它同时是只读根是否生效的第一手证据。

### 6.9 这一轮在构建里踩的三个坑（都不是设备的坑，是仓库的）

1. **注释里的撇号会关掉 docker 的单引号块。** `build-image.sh` 把容器脚本写成
   `docker run ... sh -euc '...'`，所以那一段里的任何 `'` 都会提前闭合字符串。
   注释里的 `ext4's journal replay` 就这么把后半段脚本甩到了宿主 shell 上，
   报错是 `BOOTFS: parameter not set` —— 指向变量，完全不指向真正的原因。
   **写这类脚本时，注释里别用撇号。**（`build-rootfs.sh` / `build-kernel.sh` /
   `build-uboot.sh` 同理。）
2. **校验要放在它检查的东西被创建之后。** 只读根那三个符号链接的检查一度写在了
   创建它们的代码前面两百里，于是构建永远失败在一个马上就要变对的文件系统上。
3. **版本号要跟着设备走。** 卡上跑的是 1.0.3（上一轮交付脚本里手工打的号，从未进
   仓库），仓库 `VERSION` 还写着 1.0.2。更新器拒绝不比运行中新的包，所以 1.0.2 的包
   会在卡上被静默挡掉。**每次交付都要把 `VERSION` 一起提上去。**
   另外 `VERSION` 已加进 `.gitattributes` 的 `eol=lf`：`core.autocrlf=true` 会在文件里
   塞一个 CR，设备读到 `1.0.4\r` 就再也对不上任何版本了。

---

## 7. 资产清单（文件位置）

- 构建镜像定义：`platforms/rg353ps/frontends/slot/Dockerfile.slot-build`
- 暖缓存脚本：`diag/warm-slot-cache.sh`
- 构建+打包：`platforms/rg353ps/build-slot.sh`
- 显示后端：`platforms/rg353ps/frontends/slot/fbdev.rs`
- 运行环境：`platforms/rg353ps/frontends/slot/launch.sh`
- 按键映射 patch（只动 `evdev.rs`，与 DTS 相关）：`platforms/rg353ps/frontends/slot/slot-rg353ps.patch`
- 摇杆模拟轴 patch（跨 15 个文件，与 DTS 无关）：`platforms/rg353ps/frontends/slot/slot-analog.patch`
- 电源键归前端 patch（`evdev.rs` + `app.rs`，与 fork 的 `Btn` 枚举有关）：
  `platforms/rg353ps/frontends/slot/slot-power.patch`
- boot logo 写回启动分区 patch（`bootlogo.rs`，只改分区名与挂载复用）：
  `platforms/rg353ps/frontends/slot/slot-bootlogo.patch`
- 音量/电源归属实现：`platforms/rg353ps/rootfs/usr/sbin/baseos-frontend-session`
  （`claim_volume_for_frontend` / `release_power_owner`）与 `src/rg353ps-hotkeyd.c`
- 启动测量：`src/boot-clock.c`、`platforms/rg353ps/rootfs/usr/sbin/baseos-boot-mark`、
  `platforms/rg353ps/rootfs/usr/sbin/baseos-boot-report`（用法见 §6）
- GL 后台预读：`platforms/rg353ps/rootfs/usr/sbin/baseos-prefetch-gl`（rcS 里与
  hotkeyd 采样窗口并行启动，不占关键路径）
- 本指南：`platforms/rg353ps/frontends/slot/PORTING.md`

> 持久卷：`rg353ps-slot-cargo`（registry）、`rg353ps-slot-target`（编译产物缓存）。
> 镜像：`rg353ps-slot-build:latest`（arm64）。

---

## 8. 上游 v1.5.3 与日志写卡审计

这一节记两件事：上游 1.5.3 的更新对我们到底有没有用（结论是没有可直接搬的东西，但照着它的思路查了一遍 HDMI），以及"每次开机到底往卡上写了什么"（结论是三处例行写，改掉了其中最贵的两处）。

### 8.1 上游 v1.5.3 的两条更新

v1.5.3 的版本提交（`ddae623`）只改 `VERSION` 一行，内容都在 v1.5.2 之后的几条提交里，release note 归纳成两条：

1. **HDMI 输出恢复。** 1.5.1/1.5.2 的 fast loader 在交给 Linux 的 DTB 里把 HDMI 标成 `late`。内核的 `of_device_is_available()` 只认 `okay`/`ok`，`late` 等同于没启用；而发布版里没有任何东西事后再去打开它，所以插着电视也毫无反应。现在 loader 保留原厂设置，并加了断言要求这一项（`54910e7`）。
2. **fast loader 交给内核的东西与原始 loader 完全一致**，包括 boot logo 的交接。他们用模拟器把 11 个机型跑了一遍，逐字节比对 FDT、命令行、入口寄存器、kernel 与 initrd（`64a3bac` 起的一组提交）。

**为什么不能直接受益。** 上游这套 fast loader 面向 Allwinner H700 那一票（rg28xx/34xx/35xx/rg40xx），自己构造 DTB 再交给内核；RG353PS 是 RK3566，走原厂 U-Boot + 内核自编译的主线 DTB（`rk3566-anbernic-rg353ps.dts`），没有这层 DTB 生成器。那个 `late` 的形态我们不生产，也就踩不到；代码同样搬不过来。**这一条不是"我们落后了"，是两条不同的引导路线。**

**按它的思路自查的结果（1.2.0 真机）：**

| 检查项 | 结果 |
|---|---|
| `dmesg` | `Detected HDMI TX controller v2.11a with HDCP`、`display-subsystem: bound fe0a0000.hdmi` |
| `/sys/class/drm` | `card0-HDMI-A-1` 存在，`status=disconnected`（当时没插线） |
| 内核配置 | `DRM_DW_HDMI`、`DRM_DW_HDMI_I2S_AUDIO`、`ROCKCHIP_DW_HDMI`、`PHY_ROCKCHIP_INNO_HDMI`、`SND_SOC_HDMI_CODEC` 全 `=y` |
| 音频 | `#0: HDMI` 声卡已注册（README 里"声卡编号不固定"就是它） |

也就是说 HDMI 通路本身是完好的，**唯一没验的是插线后的实际画面**，因为手上没有 HDMI 线。这条留在"待验证"里，不要因为"启动数字正常"就默认显示正常——1.1.7 的黑屏事故已经证明启动计时不会替显示把关。

上游第二条对我们只有参考价值：现在我们是 U-Boot 交黑屏、rcS 再把 logo 画回来；上游证明了"loader 直接把 logo 交给内核"可行，但那是他们自己写的 loader，不具备可移植性。

### 8.2 每次开机往卡上写了什么（1.2.0 真机实测）

审计方法：把 1.2.0 的 `.bosupd` 解开，`debugfs` 提取 rootfs 里的全部脚本逐一统计写点，再用真机（SSH）核对文件时间戳与大小。结论如下：

| 文件 | 分区 | 频率 | 单次量 | 判断 |
|---|---|---|---|---|
| `Logs/boot.log` | SDCARD（exFAT） | 每次启动 | ~20 行 / 0.9 KB | 启动计时，明细可压 |
| `rg353ps-usb-probe.txt` | SDCARD | 每次启动 2 次 | 每次重写 17 KB + `sync` | 例行写，不必要 |
| `rg353ps-usb-debug.txt` | SDCARD | 每次启动 1–4 次 | 1.1 KB + `sync` | 例行写，不必要 |
| `baseos.log` | boot（vfat） | 仅更新事件 | 167 B | 必要 |
| `baseos-userdata-init.txt` | boot | 仅初始化失败 | — | 必要 |
| `baseos-frontend-detection.txt` | boot | 仅 debug 或前端扫描失败 | — | 必要 |
| `Logs/slot*.log`、`ags-shutdown-trace.log` | SDCARD | 每会话 | 96 + 12 + 7 KB | 前端 Slot 自带，不属底座 |

真机时间戳就是判据：`usb-probe.txt` 与 `usb-debug.txt` 的 mtime 每次都等于当次开机时刻，而 `baseos.log` 只在应用更新那一轮写过三行。

根因是 `usb_debug=yes` 这个 bring-up 默认值：它每次开机起 RNDIS + dropbear + 一个 supervisor，而 supervisor 一启动就 `probe_dump "boot"`，把 17 KB 探测报告重写一遍再 `sync`；通道起来之后再写一次 `"after start"`。这份报告是为"通道起不来"准备的，通道起来了就没有读者。

### 8.3 本版改了什么（1.2.1）

只动 `baseos-usb-debug`，不动 `usb_debug` 的默认值，也不动失败诊断的能力：

- 探测报告与通道日志先在 `/run`（RAM）里攒，**不再每次开机落卡**。
- 只有两种情况才落卡：一是 `USB_TROUBLE=1`（supervisor 真的开始走重试阶梯：reprobe / rebind / 重建 PHY），二是 `debug=yes`（人工要求全量留痕）。
- 启动失败的三条路径（等不到 UDC、gadget 构建失败、绑不上 UDC）与显式 `stop` 仍然强制落卡。
- 首次落卡时会把 RAM 里攒的 `boot` / `after start` 快照一起带出去，所以故障现场仍然完整；阶梯每走一步重置一次已落卡标记，多次尝试的过程仍然逐步可见。

正常开机与正常插拔线的结果：**卡上不新增任何字节，也不再有这两次 `sync`**。故障时的卡上内容与原来一致。

**实测（1.2.1，同一张卡）：** 升级前后各记录一次 `stat`，升级那次开机（含应用更新与随后的一次重启）与再之后一次干净重启，两个文件都没有变化：

| 文件 | 升级前 | 升级后 |
|---|---|---|
| `rg353ps-usb-probe.txt` | 17243 B / mtime 1793529892 | 17243 B / mtime 1793529892 |
| `rg353ps-usb-debug.txt` | 1118 B / mtime 1793529893 | 1118 B / mtime 1793529893 |

`baseos.log` 只多了 `update to 1.2.1 confirmed` 那三行（更新本身的事件，应当写）；`Logs/boot.log` 每次开机仍加 19 行。启动时间没有变化：`before Linux 2.548 s`、`total 5.068 s`，与 1.2.0 同一档。`baseos-usb-debug status` 在新脚本下正常返回（`udc state: configured`），SSH 通道自始至终可用。

### 8.4 前端侧可选项（不在底座范围内）

Slot 的 `System/launch_frontend.sh` 第 101 行无条件把前端输出重定向到卡：

```sh
exec /lib/ld-linux-aarch64.so.1 "$SYS/slot" > "$LOGS/slot.log" 2>&1
```

`slot.log` 每个会话几十 KB，`launch_frontend.sh` 自己还有 64 KB 的会话轮转。想让卡上的写入再少一截，把这一行改成 `>/dev/null 2>&1`（崩溃现场就没了），或者只在需要排障时保留。这是前端包里的文件，改它不属于底座，所以只记在这里。

### 8.5 一条教训：`/proc/config.gz` 要当资产存

1.2.0 的内核配置（A/B 两组裁剪后的那份）当时只存在于构建产物里，仓库里的 `linux.aarch64.conf` 还停在未裁剪版本。这一版是用设备上的 `/proc/config.gz` 恢复回来的，差异除了裁剪项，还有一批编译器探测项（`CONFIG_CC_VERSION_TEXT`、`CONFIG_RUSTC_*` 等）会由 `olddefconfig` 重算，不影响结果。

以后每次改了内核配置就提交它，别只留在 `work/` 里——否则下一次构建会悄悄退回未裁剪状态，Image 从 21.6 MB 涨回 29 MB，启动时间也跟着回去，而且不会有任何报错。
