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

### 6.7 还没做的

- **softvol 控件第一次真正打开 PCM 要 ~1.4 s**（aplay 刚关掉 PCM，控件赋值又要重开，
  触发 DAPM 上电）。这笔钱目前由 `audio-init` 先付、前端等它；理想做法是并进前端那次
  PCM 会话里，让这 1.4 s 和 Slot 自己的启动重叠。实测里 `session: audio ready` 这一步
  在 0.2~1.5 s 之间波动，就是它。
- **SD 卡初始化在 Linux 里要 0.7 s**，其中 0.53 s 是 SDR104 的调谐，而且第一次调谐
  会失败（`tuning execution failed: -5`）再整体重来一次。改 `sd-uhs-sdr50` 可以省掉
  调谐，代价是读速从 ~79 MB/s 掉到 ~40 MB/s —— 那 33 MB 的 `libgallium` 预读会慢
  0.35 s 左右（目前预取有 0.35 s 余量）。要不要换是个取舍，没量透之前不动。
- **开机前还剩 4.18 s**（§6.5），其中内核 `Image` 29 MB 从 FAT 读入是大头。

### 6.8 量启动时的注意事项

- **别用不同启动之间的小数互相减**：内核 dmesg 时间戳、`/proc/uptime`、`boot-clock`
  是三个基准，每次都略有不同。要比就比同一份 `baseos-boot-report` 里的行。
- `boot-clock` 是唯一能量"U-Boot + 内核加载"的手段，但它只给总数。要拆开就得在
  U-Boot 里埋点（`bootstage` 或往 FAT 写报告），这一层目前没做。
- `handoff: entered` 和 `frontend exec` 之间只应该差几十毫秒。如果差出上百毫秒，
  说明 `record_handoff` 里又混进了写卡操作。
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
- 音量/电源归属实现：`platforms/rg353ps/rootfs/usr/sbin/baseos-frontend-session`
  （`claim_volume_for_frontend` / `release_power_owner`）与 `src/rg353ps-hotkeyd.c`
- 启动测量：`src/boot-clock.c`、`platforms/rg353ps/rootfs/usr/sbin/baseos-boot-mark`、
  `platforms/rg353ps/rootfs/usr/sbin/baseos-boot-report`（用法见 §6）
- GL 后台预读：`platforms/rg353ps/rootfs/usr/sbin/baseos-prefetch-gl`（rcS 里与
  hotkeyd 采样窗口并行启动，不占关键路径）
- 本指南：`platforms/rg353ps/frontends/slot/PORTING.md`

> 持久卷：`rg353ps-slot-cargo`（registry）、`rg353ps-slot-target`（编译产物缓存）。
> 镜像：`rg353ps-slot-build:latest`（arm64）。
