# 铠侠 BG4 NVMe SSD（KBG40ZNS256G）故障定性诊断与数据抢救方案

## Summary

**目标**：判定 `KBG40ZNS256G`（KIOXIA BG4 256GB M.2 2230，SN `11UPG6WAQL42`，FW `10410106`）是否被正确识别并正常工作；在**优先抢救盘上数据**的前提下，穷尽可行的恢复路径，最后给出「盘坏还是主机问题」的定性结论与后续处置（含 RMA）。

**范围**：只读诊断 → 只读深度取证 → USB 桥接抢救 → 跨机交叉验证 → 定性结论。不涉及系统重装、数据迁移、性能压测、固件刷写。

**用户已确认的两条约束**（共同成立，靠「严格顺序 + 危险动作闸门」同时满足）：
1. 盘上有数据，必须尽量抢救 → 全流程以**只读、不 reset、不自检、不写盘**为默认。
2. 覆盖面要完整（诊断 + 恢复尝试 + 跨机验证）→ 但任何带写入/复位语义的步骤都放在**闸门之后**，需显式放行。

**关键设计决策**：
- **D1 — 不做任何"复活式"尝试优先。** 控制器复位 / rescan / 自检一律推迟到镜像窗口之后。理由：驱动转述的是控制器**内部错误**，反复复位濒死控制器有把它彻底锁死的风险，而当前收益为零。
- **D2 — 桥接测试同时是"抢救手段"和"定性手段"。** RTL9210 桥走完全不同的主机内存/DMA 路径且不经过 VT-d，HMB 若因 IOMMU 交互而失败，在桥上可能成功。这是当前**最有希望**的路径，一次动作同时满足两项目标。
- **D3 — 只读 SMART 取证优先于装包。** udisks2 已通过 D-Bus 暴露完整 NVMe SMART，**无需安装任何软件**即可拿到关键数据（已完成，见 §1）。装包只为后续 `nvme-cli`/`gddrescue` 便利，属可选。
- **D4 — 目标机空间与线缆拓扑必须先解决。** 镜像目标不能和被测盘共用同一个 USB 桥接盒/线缆（会掉速并放大风险），必须提前腾挪。

**已完成的判定结论**：**识别到了，但不正常工作；故障在 SSD 本体，证据来自设备自身。** 详见 §2。

---

## 1. 已完成的只读诊断证据（无需重做）

诊断环境：Dell Inspiron 14 5410 2-in-1 / Intel Core i3-1125G4 / BIOS 2.38.0 / Ubuntu 26.04.1 / 内核 `7.0.0-38-generic`。

### 1.1 PCIe 链路层 —— 完好

| 项 | 值 | 判定 |
|---|---|---|
| PCI ID | `1e0f:0001` KIOXIA NVMe SSD Controller BG4 (DRAM-less) | 型号匹配 |
| 链路速率/宽度 | `8.0 GT/s PCIe` / `x4`（= `max_link_speed`/`max_link_width`） | 满速，Gen3 x4 |
| 上游 Root Port | `00:1c.0`，同样 Gen3 x4 满速 | 链路无降速 |
| AER 正确/致命/非致命 | 端点与 Root Port **全部计数 = 0** | 无 PCIe 传输错误 |
| 电源状态 | `D0`，`runtime_status: active` | 供电正常 |
| IOMMU group 14 | 仅含该 SSD 一个设备 | 无共享冲突 |

### 1.2 控制器身份 —— 可读

`/sys/class/nvme/nvme0/`：`model = KBG40ZNS256G NVMe KIOXIA 256GB`、`serial = 11UPG6WAQL42`、`firmware_rev = 10410106`、`transport = pcie`、`state = live`、`subsysnqn = nqn.2018-06.com.toshiba-memory:...`。

> `10410106` 是 BG4 的正常量产固件版本（同型号在售盘的固件一致），**不是**明显的异常/砖化版本。

### 1.3 致命项 —— IO 队列与命名空间不存在

`lsblk` 与 `/sys/block` 中**没有任何 nvme 块设备**，`/sys/class/nvme/nvme0/namespace/` 目录不存在。即：控制器被认出来了，但**没有暴露任何 namespace**，盘上数据当前完全不可访问。

三次启动（boot `-2` / `-1` / `0`）日志**逐字相同**，说明是稳定复现，不是偶发：

```
nvme 0000:2b:00.0: platform quirk: setting simple suspend
nvme nvme0: pci function 0000:2b:00.0
nvme nvme0: failed to set APST feature (16390)
nvme nvme0: could not set timestamp (16390)
nvme nvme0: allocated 61 MiB host memory buffer (1 segment).
nvme nvme0: failed to set host mem (err 16390, flags 0x1).
nvme nvme0: Could not set queue count (16390)
nvme nvme0: IO queues not created
nvme nvme0: using unchecked data buffer        ← 良性，见下
```

**`16390` = `0x4006`** = NVMe Status：SCT=1（Command-specific）→ Status Code `0x06` = **Internal Error**。这是**控制器自己返回的状态码**，不是驱动侧报错，也不是 PCIe 超时/重试。`flags 0x1` 表示 `nvme_init_hmb()` 走了 Controller Memory Buffer 路径。

`using unchecked data buffer` 来自 `nvme_map_user_request()`（`drivers/nvme/host/block.c`）的 `dev_warn_once`：用户态发了 passthrough 命令、而设备不支持 SGL DMA。**与本次故障无关**，忽略。

### 1.4 设备自报 SMART（经 udisks2 D-Bus 读取，未装任何软件）

对象路径：`/org/freedesktop/UDisks2/drives/KBG40ZNS256G_NVMe_KIOXIA_256GB_11UPG6WAQL42`，接口 `org.freedesktop.UDisks2.NVMe.Controller`。

| SMART 字段 | 值 | 解读 |
|---|---|---|
| **`SmartCriticalWarning`** | **`["degraded"]`** | **可靠性降级告警被置位** |
| `percent_used` | 32% | 耐久余量充足，不是磨损耗尽 |
| `avail_spare` / `spare_thresh` | 100% / 50% | 备用空间正常 |
| `media_errors` | 0 | **NAND 介质本身零错误** |
| `total_data_written` | 53,879,467,520,000 B ≈ **53.88 TB** | 使用强度很高 |
| `total_data_read` | ≈ 52.997 TB | — |
| `power_on_hours` | 8,075 h | — |
| `power_cycles` / `unsafe_shutdowns` | 4,330 / **3,870** | 89% 的上电是非正常断电 |
| `ctrl_busy_time` | 9,974 min ≈ 166 h | 绝大部分时间闲置 |
| `temp` / `wctemp` / `cctemp` | 317 K (43.85°C) / 356 K / 360 K | 温度正常，从未越过告警阈值 |
| `warning_temp_time` / `critical_temp_time` | 0 / 0 | 从未温度告警 |
| `num_err_log_entries` | 1 | 仅 1 条错误日志项 |
| `SmartSelftestStatus` | `""`（percent_remaining `-1`） | **从未跑过任何自检** |
| `UnallocatedCapacity` | 0 | 与"无 namespace"一致 |

`SmartCriticalWarning` 的字符串映射（udisks2：`spare`/`temperature`/`degraded`/`readonly`/`volatile_mem`/`pmr_readonly` ↔ NVMe critical warning bit 0–5）确认：`degraded` = **bit 2 = Reliability Degraded**。按 NVMe 规范，该位含义为「NVM 子系统可靠性因**显著的介质相关错误或任何损害可靠性的内部错误**而降级」。本次**只有这一位**被置位。

### 1.5 目标机现状（影响救援操作）

| 设备 | 型号 | 桥接盒 | 挂载 | 可用空间 |
|---|---|---|---|---|
| sda | WDC WD10EZEX 931.5G | **ACASIS EC-7351 (RTL9210, 0bda:9201)** | `/` (sda7)、`/boot/efi`、`/run/media/wayyet/Windows` (sda3)、`/run/media/wayyet/DATA1` (sda4) | DATA1 **524G** |
| sdb | WDC WD10SPZX 931.5G | JMicron JMS561U **双口** SATA 桥 | `/run/media/wayyet/health` | 105G |
| nvme0 | KBG40ZNS256G | 笔记本 M.2 插槽 | **无块设备** | — |

要点：
- 当前系统的 `/` 在 **USB 硬盘**上，内置存储实际只有这块 SSD。SSD 已不可用，故现在没有可用的内部启动盘。
- `/etc/fstab` **不含任何 `nvme0n1` 引用**，说明当前系统并非装在这块 SSD 上；无 `/etc/crypttab`，无 LUKS。盘上原有内容未知。
- apt 索引存在（115 条），`archive.ubuntu.com` / `security.ubuntu.com` 均可达（HTTP 200）→ 装包可行（可能需先 `apt update`）。
- 现成工具：仅 `ntfsfix`、`hdparm`、`gnome-disks`、`udisksctl`。缺 `nvme-cli`、`smartmontools`、`gddrescue`、`testdisk`。

---

## 2. 定性结论

**故障在 SSD 本体（控制器内部失效），不是主机、插槽、驱动或系统配置问题。** 证据闭环：

1. **链路层完全干净** —— Gen3 x4 满速，AER 全 0，温度正常，供电 D0。排除接触不良、供电不足、信号降速、过热。
2. **故障是稳定复现的** —— 三次独立启动同一组报错，排除偶发/时序竞态。
3. **报错来自控制器本身** —— `0x4006` 是 NVMe 状态码里控制器主动返回的 Internal Error，不是驱动侧 DMA 映射失败（那会是 `-ENOMEM`/`-EFAULT` 之类），也不是 PCIe 链路错误。
4. **设备自证** —— SSD 自己把 Reliability Degraded 告警位置 1，而 NVMe 规范对该位的定义就是「介质错误**或任何损害可靠性的内部错误**」。这是 SSD 本体的自述。
5. **不是 NAND 磨损** —— `media_errors = 0`、`avail_spare = 100%`、`percent_used = 32%`。介质数据大概率完好，但控制器已无法建立 HMB 与 IO 队列，因此**连 namespace 都暴露不出来**。
6. **同类症状的行业先例** —— Thomas-Krenn 记录的同类案例（`Could not set queue count (16390)` → 无 namespace 设备）最终同样无法救活，故障定位于 SSD 控制器。

**对数据抢救的含义**：介质看起来是好的（0 media errors），所以**数据很可能还在盘上**，只是控制器拒绝建立访问路径。当前不可访问 ≠ 已丢失。这正是 D2（换桥接路径）值得优先尝试的理由，也是全流程必须克制、不做 reset 的理由。

**风险提示**：这是一块累计写入 53.88 TB、通电 8075 小时、4330 次上电中 3870 次非正常断电的盘（约为 Dell P/N 0FWJTG 的 OEM 盘，官方保修几乎必然已过）。控制器随时可能彻底停止响应，**每多一次带写入或复位语义的交互都在消耗它最后的余量**。

---

## 3. 范围与非目标

**范围内**
- 只读取证与日志固化。
- 通过 USB 桥接/异机原生插槽尝试让控制器建立访问路径，一旦成功立即做只读全盘镜像。
- 镜像内的文件级恢复。
- 「盘 vs 主机」的交叉验证与最终定性。
- RMA / 报废 / 数据已不可救的收尾判断。

**明确不做**
- 不重装系统、不迁移用户数据、不动 `/` 与 DATA1 上的现有数据。
- 不做性能基准测试（fio 等）—— 濒死盘上无意义且消耗寿命。
- 不刷固件、不 `nvme format` / `sanitize` / `smartctl -t` / `nvme selftest` / 分区或写任何数据。
- 不在完成镜像前做任何控制器 `reset` / `rescan`。

---

## 4. 执行流程（阶段严格顺序，闸门不可跳过）

### Phase 0 — 冻结现场与证据固化（无风险）
1. 存证：把本文档 §1 的内核日志、`lspci -vv`、`lsblk -o ...`、D-Bus SMART 输出落盘成一份报告，供 RMA/售后举证。
2. 记录基线：`lsblk`、`df -h`、`lsusb -t` 输出留档。
3. **不要**在此阶段拔插任何设备、不要重启。

**闸门 G0**：确认数据抢救目标（哪块盘、哪个分区）后再进入 Phase 1。

### Phase 1 — 原地只读深度诊断（不改变盘状态）
目的：在不动盘的前提下榨干最后的只读信息。

1. 装包（可选但推荐，便于后续复核）：
   `sudo apt update && sudo apt install -y nvme-cli smartmontools gddrescue testdisk`
2. 只读命令（全部无写入语义）：
   - `nvme list-subsys`、`nvme list` → 确认 namespace 仍为 0。
   - `nvme id-ctrl /dev/nvme0` → 与 §1.2 对照，看 `oacs`/`mdts`/`nn`/`cmic`/`hmpre`/`hmmin` 是否异常。
   - `nvme smart-log /dev/nvme0` → 取原始 `critical_warning` 字节，**确认 `degraded` 确实对应 bit 2**（把 §1.4 的推断坐实）。
   - `nvme error-log /dev/nvme0 -e 1` → 解出那 1 条错误日志项的内容（这是唯一一条错误记录，很可能是本故障的直接线索）。
   - `smartctl -x /dev/nvme0` → 与 D-Bus 数据交叉验证。
3. 若上述任一命令**返回错误而不是数据**，立即停止并记录，不要重试刷。

**此阶段禁止**：`nvme reset`、`nvme rescan`、`/sys/class/nvme/nvme0/reset_controller`、`rescan_controller`、PCI `remove`+`rescan`、`smartctl -t`、`nvme selftest`。

**闸门 G1**：错误日志内容与原始 critical_warning 已取到 → 才能进入 Phase 2。

### Phase 2 — USB 桥接抢救（主路径，D2）
目标：换一条主机内存/DMA 路径（无 VT-d），让 HMB 与 IO 队列有机会建立成功。

**前置的物理与空间准备（必须先解决，见 D4）**：

- 当前 **ACASIS EC-7351 上插着系统盘 sda**（`/` + DATA1 + Windows）。要把 SSD 放进这个桥，就必须把 sda 挪走，否则运行中的系统会当场掉盘。
- 推荐拓扑：**JMicron JMS561U 是双口 SATA 桥**，把 sda 与 sdb 都插到 JMicron 上并从 JMicron 启动；ACASIS 空出来专插 SSD。这样源与目标物理分离、各走一条线。
- 镜像目标选 **DATA1（sda4，NTFS，524 GiB 空闲）**，容量足够（镜像约 238 GiB）。
- 若不愿动线缆，则改为**整机拆到另一台有原生 M.2 插槽的台式机**上做（见 Phase 3），这条路径同样要一并准备好 ≥256 GiB 的空闲空间。

**操作顺序**：
1. 关机（不是重启）→ 拆下 M.2 中的 SSD → 装入 ACASIS EC-7351 → 重新开机。
2. 开机后**先只观察，不挂载、不运行任何磁盘工具的写入类操作**：
   - `lsblk` / `nvme list` 看是否出现 `/dev/nvme0n1`（桥可能暴露为 `sdX` 或 `sdX1`）。
   - 出现块设备时，第一时间 `nvme smart-log` 复核告警。
3. **一旦块设备出现，立刻开始三遍 ddrescue 镜像**（目标 = DATA1）：
   - 第 1 遍（大块，抓主体、跨过坏区）：
     `ddrescue -d -f -n /dev/<src> /run/media/wayyet/DATA1/nvme_img.dd /run/media/wayyet/DATA1/nvme_img.map`
   - 第 2 遍（4 KiB 中块）：
     `ddrescue -d -f -n -b 4096 /dev/<src> ...同一组输出...`
   - 第 3 遍（512 B 小块，重试超时区）：
     `ddrescue -d -f -n -b 512 -t 30 /dev/<src> ...同一组输出...`
   - `-d` 直读不经过页缓存；`-f` **只**作用于输出文件，绝不可加在源设备上；`-n` 首遍不刮取。
4. 镜像过程中**不要**对源盘做任何其它命令；`ddrescue` 跑完前不拔线。
5. 镜像完成后校验：比较 `map` 文件中的失败字节数；>0 则对失败区额外跑 `ddrescue -d -r 3` 重试。

**若桥上仍然出不来块设备**：不要反复插拔试运气。把 SSD 留在桥上，转 Phase 3。

**闸门 G2（硬性）**：`nvme_img.dd` + `.map` 完整生成且错误区已尽力重试 → 才允许进入任何"复活"尝试。

### Phase 3 — 跨机原生插槽交叉验证
目的：排除"只有这台笔记本的平台问题"这一残余可能（可能性低但需闭环）。

1. 优先：在**另一台有原生 M.2 2280/2230 插槽的台式机**上测试同一块 SSD。
2. 若条件不具备，退而求其次：桥接盒换到另一台主机 / 另一条线缆 / 另一个 USB 口（当前 ACASIS 与 JMicron 都挂在 Bus 004 的同一 root hub 上，换口意义有限，应优先换主机）。
3. 判定矩阵：
   - 桥上成功 + 原生槽失败 → 平台相关（VT-d / 内核），但盘内数据已在桥上救出，处置结论转向"该盘与该本机不兼容"。
   - 桥上与异机原生槽**都失败** → 盘坏确认（预期结果）。

### Phase 4 — 镜像内的文件级恢复
仅在 Phase 2 已产出镜像后进行（全部作用于镜像文件，不碰源盘）：
1. `testdisk` 分析分区表 → 找出分区边界。
2. 按文件系统类型只读挂载（未知类型时先看 superblock）：ext4 用 `debugfs` / `mount -o ro,norecover,loop`；NTFS 用 `ntfsfix -n` + `ntfs-3g -o ro,recover`；其他用 `photorec` carving。
3. 先把 `PhotoRec.txt`/目录树导出到 DATA1，再挑重要文件。
4. 恢复完成后给出完整性报告（恢复了多少、损失了什么）。

### Phase 5 — 定性与收尾
1. 三方一致即定性：**盘自报 degraded + 控制器回 0x4006 + 跨机均失败** → SSD 本体故障，确认送修/报废。
2. RMA / 售后路径：凭 §1 的型号、SN、FW、SMART 报告与内核日志走 OEM（Dell P/N 0FWJTG）或 KIOXIA 渠道。注意：通电 8075h / 写入 53.88TB，保修大概率已失效，按报废 + 数据已尝试抢救完毕来规划预期。
3. 机器侧的连带处置（本方案不实施，仅记录）：若未来换新盘，注意当前 BIOS 2.38.0 与 M.2 插槽规格；本机 `/` 在 USB 硬盘上这件事本身建议尽快迁回内置存储。

---

## 5. 危险动作闸门（Hard Gates）

以下动作在对应闸门放行前**一律禁止**：

| 动作 | 最早允许阶段 | 风险 |
|---|---|---|
| 控制器 `reset` / `reset_controller` / PCI `remove`+`rescan` | G2 之后（镜像已拿到） | 濒死控制器可能被彻底锁死 |
| `nvme format` / `nvme sanitize` / `smartctl -t` / `nvme selftest` | 永不（本盘无备份前） | 写入型，破坏数据 |
| 固件刷写 | 不在本方案内 | 高危 |
| 写分区 / 格式化 / 任何写入源盘的操作 | 永不（除非用户另有明确新指令） | 不可逆 |
| 在 GNOME「磁盘」里点格式化 / 修复文件系统 | 永不 | 误操作即毁数据 |

**明确告知用户的操作禁区**：不要用 GNOME「磁盘」工具对该盘做任何写操作；不要让任何自动化（快照、备份工具、磁盘守护服务）尝试往该盘写。

---

## 6. 失败与恢复语义

- **Phase 1 命令报错**：视为"该信息不可得"，跳过并记录，不重试、不换工具反复戳。数据已足够支撑定性。
- **Phase 2 桥接仍失败**：不视为异常，按设计预期进入 Phase 3；Phase 3 也失败即确认盘坏，转 Phase 5。
- **镜像出现读错误**：ddrescue 三遍递进 + `-r 3` 重试；残留坏区用 `photorec` carving 抢救可识别的文件碎片。坏区本身也写入 map 文件，作为盘体损伤的直接证据。
- **系统盘被误拔导致掉机**：本方案的拓扑调整在 Phase 2 开始**之前**一次性完成并验证可开机；若调整后无法启动，回退到「拆到台式机做」这条等效路径，而不是反复试。
- **任何阶段出现盘完全无响应**（`lsusb` 掉设备 / SMART 读取超时）：立即停止所有交互，判定为彻底损坏，转 Phase 5。

---

## 7. 验收标准

**阶段级**
- Phase 1：`nvme id-ctrl`、`nvme smart-log`、`nvme error-log` 三项输出落盘；原始 `critical_warning` 字节值被记录并与 `degraded` 对应关系坐实。
- Phase 2（成功时）：`/run/media/wayyet/DATA1/nvme_img.dd` 大小 ≈ 256060514304 字节；`.map` 文件存在；失败字节数已记录；重试已执行。
- Phase 2（失败时）：已确认"在无 VT-d 的独立 USB 桥路径下同样无法初始化"这一事实，并有 `lsblk`/`lsusb -t` 输出佐证。
- Phase 3：至少一个异机环境的结果被记录。
- Phase 4（成功时）：导出的目录树清单 + 目标文件抽样哈希校验。

**总体验收（满足任一即视为方案完成）**
- **A（数据优先达成）**：镜像产出且文件级恢复完成，并出具恢复/损失清单。
- **B（定性完成）**：证据链闭合，输出"SSD 本体故障 / 盘已死"的结论 + RMA 或报废建议。
- **C（穷尽性）**：A 或 B 有一个达成，且 §5 中所有被跳过的路径都有明确记录（为什么不做、何时做）。

---

## 8. 风险与未决事项

**已知风险**
1. **控制器随时可能彻底失效** —— 每次通电交互都在消耗余量。3870 次非正常断电的历史提示供电/断电管理可能一直有问题。
2. **桥接盒兼容性未知** —— RTL9210 对某些故障态 NVMe 控制器会一并无法枚举；这条路径不是必然成功。
3. **介质好 ≠ 数据好** —— `media_errors = 0` 只说明介质无新增错误，不能保证盘上逻辑结构完整；也可能是盘本来就是空盘/已清空的。这一点要等镜像出来才知道。
4. **物理操作风险** —— 拆机、走线、2230 螺丝极小易丢。
5. **保修失效** —— 8075h / 53.88TB，二手/OEM 盘属性明显。

**未决事项（留给执行时确认，本次未阻塞）**
1. 盘上**原本**装的是什么、期望恢复哪些数据 —— 影响 Phase 4 的恢复策略优先级（分区表恢复 vs. carving）。
2. 是否愿意拆机走线调整 USB 拓扑，还是直接整机拆到台式机 —— 影响 Phase 2 的具体形态。
3. DATA1 上现存数据能否承受新增一个 238 GiB 镜像文件（当前 524 GiB 空闲，空间上没问题）。
4. 是否需要为 Phase 3 另借一台主机。
5. 镜像完成后是否需要清理 DATA1 上的镜像文件（会占用 238 GiB）。

**已知的取证局限**
- `dmesg` 需要 root，本轮改用 `journalctl -k`（用户在 `adm` 组）达成等价取证，未提权。
- 未安装 `nvme-cli`，因此本轮的 SMART 数据来自 udisks2/libnvme 的 D-Bus 导出；`nvme error-log` 的详细条目内容本轮**尚未取到**，需在 Phase 1 补齐。
- 未跨机验证，本轮所有结论均来自这一台主机 + 设备自身上报。
