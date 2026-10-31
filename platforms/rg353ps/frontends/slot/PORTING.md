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
| 示例按键 patch | `platforms/rg353ps/frontends/slot/slot-rg353ps.patch` | 本 fork 专用按键映射（**换 fork 要重做**） |
| 模拟核心 | mGBA / gpSP 的 `.so`（aarch64 musl） | 与前端 fork 无关，通常直接复用 |

---

## 2. 移植一个新 fork 时要动的东西（按改动量升序）

| # | 改动点 | 触及文件 | 是否 fork 相关 | 做法 |
|---|---|---|---|---|
| 1 | 显示后端 | 覆盖 `crates/slot-gfx/src/fbdev.rs` 为我们版 | **否**（只要该 fork 的 `slot-gfx` 的 `Surface` trait 接口没变） | 直接 `cp frontends/slot/fbdev.rs` 覆盖 |
| 2 | 运行环境 | `launch.sh` | 否 | 直接复用，无需改 |
| 3 | 模拟核心 | mGBA/gpSP `.so` | 否 | 直接复用（除非 fork 指定不同 core 版本） |
| 4 | 构建 pin | `build-slot.sh` 顶部 `SLOT_REV`/`SLOT_REPO`（或环境变量） | **是** | 指向目标 fork 的 commit / repo，如 `SLOT_REPO=owner/fork SLOT_REV=abc123 ./build-slot.sh` |
| 5 | **按键映射** | 新 patch，如 `slot-<fork>-ab.patch` | **是（每个 fork 必做）** | 对该 fork 的 `crates/slot/src/input/evdev.rs` 重写 `code_to_btn` 与 `WANTED` 数组 |
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

### B. `crates/slot/src/input/evdev.rs` —— 八处，漏一处坏一个功能

| # | 改动 | 不改的后果 |
|---|---|---|
| 1 | `code_to_btn`：`0x130→B`、`0x131→A`、`0x133→X`、`0x134→Y` | ABXY 全错位（按 A 出 B）。Anbernic 用的是任天堂印字，DTS 的位置名和印字是对上的，别按 Xbox 布局映射 |
| 2 | 肩键：`0x136→L1`、`0x137→R1`、`0x138→L2`、`0x139→R2` | 肩键错位，或者 L2/R2 完全没反应 |
| 3 | `0x13a→Select`、`0x13b→Start`、`0x13c→Menu`(Function) | 打不开菜单，等于进不去设置 |
| 4 | 十字键 `0x220~0x223`，并保留 `103/108/105/106`(KEY_↑↓←→) 兜底 | 十字键没反应；不同内核把 D-pad 建成 gpio-keys 数组或 adc-keys，两种编码都要接 |
| 5 | **删掉 `116`(KEY_POWER) 的映射，并从 `WANTED` 里删掉** | 一次短按被两边同时处理：屏幕只关不睡，唤醒还要再按一次 |
| 6 | 摇杆：加 `ABS_X(0x00)`/`ABS_Y(0x01)`，`ADC_CENTRE=519`、`ADC_DEADZONE=140`，**X 轴取负** | 摇杆完全没反应（上游死区 2048 会把 0..1023 的采样全部吞掉），或者左右相反 |
| 7 | `wanted_node()` 用 **ABS 能力位**判定摇杆设备 | 摇杆设备是 `adc-joystick`，**一个按键都不报**，只按 `WANTED` 选设备会直接漏掉它 |
| 8 | `LEFT_STICK_TARGETS` 里加 `"rg353ps"` | `has_left_stick()` 返回 false，摇杆输入被丢弃 |

关于第 7 条的判据：要求 `ABS_X` + `ABS_Y` + `ABS_LSY` 同时存在（右摇杆的 `ABS_RX`
和 `ABS_LSY` 是同号），这样鼠标和触摸屏不会混进来。

补丁本体见 `slot-rg353ps.patch`，是这八条的可执行版本 —— 新 fork 直接改文件名后
`git apply` 大概率能过；如果它的 `evdev.rs` 已经重构过，就照着表逐条手工改。

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
   | 左摇杆 | `ABS_X`/`ABS_Y`（0..1023，静止 519） | 方向（需 `left_stick_dpad` 打开） |
   | 右摇杆 | `ABS_RX`/`ABS_RY` | 无对应（Slot 无右摇杆功能） |
   | 摇杆按压 | `BTN_THUMBL`/`BTN_THUMBR` 0x13d/0x13e | 无对应（`Btn` 枚举没有 L3/R3） |

   两个易错点，写 patch 时务必照做：
   - **摇杆是 `adc-joystick`**：报送 `ABS_X/ABS_Y`，量程 0..1023、静止约 519，上游的
     `STICK_DEADZONE = 2048` 会把所有采样吞掉；且 X 轴方向反了（值大 = 左），要取负。
   - **摇杆设备没有任何按键**：只靠 `WANTED`（按键位图）选设备会漏掉它，必须在
     `wanted_node()` 里用 `ABS` 能力位判定（同时要求左右摇杆都在，避免误收鼠标/触摸屏）。
6. **构建**：`SLOT_BUILD_IMAGE=rg353ps-slot-build:latest ./build-slot.sh`
   → 产出 `baseos-rg353ps-slot.zip`（含 `System/slot` + `launch.sh` + cores + 源码留证）。
7. **上机验证**（见 §4）。

---

## 4. 上机验证清单（每次必过）

- [ ] SDL2 KMSDRM 在 640×480 屏初始化成功（无黑屏、无 "EGL not initialized"）
- [ ] 输入：方向键 / ABXY / LR / Start / Select 按**物理位置**正确
- [ ] 音频：RK817 声卡出声（`SDL_AUDIODRIVER=alsa` 生效，日志里有 `audio plug:default at 48000 Hz`）
- [ ] 音量：按音量键，**前端自己的条**在动，且响度跟着变；`amixer -c <n> cget name='BaseOS Master'` 保持 90 不动
- [ ] 音量：一次开机到下一次开机，同一格的响度一致（不漂移）
- [ ] 模拟核心能加载并运行（mGBA / gpSP）
- [ ] 电池/背光脚本不报错（无 AXP 设备时安全跳过）
- [ ] 存档 / 退出 / 休眠唤醒正常

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
- 示例按键 patch：`platforms/rg353ps/frontends/slot/slot-rg353ps.patch`
- 音量/电源归属实现：`platforms/rg353ps/rootfs/usr/sbin/baseos-frontend-session`
  （`claim_volume_for_frontend` / `release_power_owner`）与 `src/rg353ps-hotkeyd.c`
- 本指南：`platforms/rg353ps/frontends/slot/PORTING.md`

> 持久卷：`rg353ps-slot-cargo`（registry）、`rg353ps-slot-target`（编译产物缓存）。
> 镜像：`rg353ps-slot-build:latest`（arm64）。
