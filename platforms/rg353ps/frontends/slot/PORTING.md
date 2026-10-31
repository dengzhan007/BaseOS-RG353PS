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

> 经验值：**第 4、5 项是每个 fork 真正要写的东西**，其余都是复制粘贴。

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
- **不要写** `# baseos: power-owned`

### D. 数据分区的 `Config/slot.state`

`volume=` 和 `volume_hp=` 是 Slot **自己的软件音量**（0..100），和 ALSA mixer 是
**串联相乘**的两级衰减，不是同一个数字。系统侧怎么配合见 §5「音量键归属」。

### E. 不要做的事

- 不要给 fork 加 `power-owned`（除非它的短按真的能挂起整机）
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
- [ ] 存档 / 退出 / 休眠唤醒正常

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
- **Slot 不声明 power-owned**：Slot 的短按动作是 `doze()`——只关背光待机，不挂起系统，
  功耗仍然不低；而 hotkeyd 的短按是真 `mem` 挂起。实测接管后"按一下只关屏、不睡觉"，
  所以 Slot 把电源键完全交还给 hotkeyd，并且 `slot-rg353ps.patch` 里特意**不映射
  `KEY_POWER(116)`、也不放进 `WANTED`**，两边不会同时动作。移植别的 fork 时如果它
  的电源键行为能真正挂起系统（而不是只关屏），再把标记行加回 `launch.sh` 才有意义。
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

## 6. 资产清单（文件位置）

- 构建镜像定义：`platforms/rg353ps/frontends/slot/Dockerfile.slot-build`
- 暖缓存脚本：`diag/warm-slot-cache.sh`
- 构建+打包：`platforms/rg353ps/build-slot.sh`
- 显示后端：`platforms/rg353ps/frontends/slot/fbdev.rs`
- 运行环境：`platforms/rg353ps/frontends/slot/launch.sh`
- 按键映射 patch（只动 `evdev.rs`，与 DTS 相关）：`platforms/rg353ps/frontends/slot/slot-rg353ps.patch`
- 摇杆模拟轴 patch（跨 15 个文件，与 DTS 无关）：`platforms/rg353ps/frontends/slot/slot-analog.patch`
- 音量/电源归属实现：`platforms/rg353ps/rootfs/usr/sbin/baseos-frontend-session`
  （`claim_volume_for_frontend` / `release_power_owner`）与 `src/rg353ps-hotkeyd.c`
- 本指南：`platforms/rg353ps/frontends/slot/PORTING.md`

> 持久卷：`rg353ps-slot-cargo`（registry）、`rg353ps-slot-target`（编译产物缓存）。
> 镜像：`rg353ps-slot-build:latest`（arm64）。
