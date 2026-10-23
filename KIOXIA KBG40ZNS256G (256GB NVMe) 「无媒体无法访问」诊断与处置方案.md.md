# KIOXIA KBG40ZNS256G (256GB NVMe) 「无媒体 / 无法访问」诊断与处置方案

## Summary

**目标**：定性 Dell Inspiron 14 5410 2-in-1 内置 M.2 NVMe 固态盘「256 GB Disk」在 GNOME Disks 中显示红色「无媒体」的原因，并在交叉验证后决定「尝试复活」还是「直接换盘」。

**已得结论（核心诊断）**：这不是分区表、文件系统、挂载或权限问题，而是 **SSD 自身控制器/固件层失效**。NVMe 控制器在 PCIe 总线上正常枚举、能应答 Identify Controller 与 SMART/Health Log，但凡是需要控制器内部资源的 Set Features（APST、时间戳、Host Memory Buffer、队列数）以及命名空间枚举，全部返回保留状态码 `0x3FFE`（16390），导致 IO 队列无法创建、**始终未能生成任何命名空间**（无 `/dev/nvme0n1`）。GNOME Disks 的「无媒体」在这里是字面含义：驱动手里只有一个控制器，没有介质（namespace）。SSD 自身 SMART 的 critical warning 已报 `degraded`，与该判断一致。

**范围**：本方案覆盖 (A) 现场只读取证、(B) 交叉验证定性、(C) 复活/换盘决策门、(D) 换盘与迁移。A、B 两阶段全部只读，不做任何写盘、格式化、sanitize、固件刷写。

**用户已确认的决策**：
1. 盘内数据不重要，无需抢救，可直接换盘。
2. 需要 sudo 的进阶诊断由**用户自行在终端执行**，我只提供命令清单（我无免密 sudo，不接触密码）。
3. 策略：先交叉验证确认坏因，再决定复活还是换盘。

**非目标（明确不做）**：不做数据恢复；不做专业送修/开盒显微分析；不刷固件（先排除，且 OEM 盘通常不支持）；不重装系统（当前系统根在外置 USB 盘，换盘与重装无关）。

---

## 一、现状与证据（已在只读检查中取得）

### 1.1 环境基线

| 项 | 值 | 来源 |
|---|---|---|
| 机型 | Dell Inspiron 14 5410 2-in-1（2 合 1，Chassis: convertible） | `/sys/class/dmi/id/product_name` |
| BIOS | 2.38.0（2026-05-27） | `/sys/class/dmi/id/bios_version` |
| 操作系统 | Ubuntu 26.04.1 LTS，kernel `7.0.0-38-generic` | `os-release`, `uname -r` |
| 系统根 | `/dev/sdb6`（外置 USB 盘 WDC WD10EZEX），**不在这块 NVMe 上** | `findmnt -n -o SOURCE /` |
| 截图对应 | 截图左侧「1.0 TB WDC WD10EZEX-08WN4A1」「1.0 TB WDC WD10SPZX-00Z10T0」与本机 `sdb`/`sda` 一致 → 截图即本机 | `lsblk` + 截图比对 |
| 插槽规格 | 1× M.2 2230/2280，PCIe Gen3 x4 NVMe，容量上限 1 TB | Dell 官方《Inspiron 14 5410 2-in-1 Setup and Specifications / Storage》 |

### 1.2 故障盘关键事实

| 采集项 | 值 | 来源 |
|---|---|---|
| PCIe 枚举 | `0000:2b:00.0`，`[1e0f:0001] KIOXIA Corporation NVMe SSD Controller BG4 (DRAM-less)`，NVMe 类型端点 | `lspci -nn` / `lspci -tv` |
| 控制器识别 | model `KBG40ZNS256G NVMe KIOXIA 256GB`，serial `11UPG6WAQL42`，fw `10410106`，`state=live`，`transport=pcie` | `/sys/class/nvme/nvme0/*` |
| 驱动绑定 | `nvme` 已绑定 `0000:2b:00.0`（`/sys/bus/pci/drivers/nvme/`），模块已加载 | `lsmod` / sysfs |
| **命名空间** | **完全没有**：`lsblk` 无 nvme 条目、`/dev/disk/by-id/` 无 nvme 条目、无 `nvme0n1` 设备节点 | `lsblk`, `/dev/disk/by-id` |
| SMART（udisks） | `SmartCriticalWarning: degraded`、`SmartPowerOnHours: 8074`（≈336 天通电）、`SmartTemperature: 320`（32.0 °C）、`UnallocatedCapacity: 0`、`SanitizeStatus: never_sanitized`、`FGUID` 为空 | `udisksctl dump` |
| 实时温度 | `hwmon2/temp1_input = 44850` → **44.85 °C**（正常，非过热、非热保护） | `/sys/class/nvme/nvme0/hwmon2/` |
| PCIe 链路 | BAR0 16 KB 已映射，IOMMU group 14，**无 AER / uncorrectable 错误**，link 正常 | `lspci -vvv`, `journalctl -k` |
| 历史一致性 | 2026-10-15 ~ 10-23 共 8 次开机，**每次都是同一串错误、从未出现过 `nvme0n1`**；`/etc/fstab`、`/var/log/dpkg.log` 无任何 `nvme0n1` 痕迹 | `journalctl --list-boots` + 逐 boot 查 |
| OEM 属性 | subsystem ID 也是 `1e0f:0001`，subsystem NQN `nqn.2018-06.com.toshiba-memory` → 厂商白牌 OEM 盘（KBG40Z = RC100 系列，BG4 DRAM-less 控制器） | `lspci -vvv`, `/sys/class/nvme/nvme0/subsysnqn` |

### 1.3 决定性内核证据（boot 0，2026-10-23 20:24:09）

```
pci 0000:2b:00.0: BAR 0 [mem 0x7e200000-0x7e203fff 64bit]
nvme 0000:2b:00.0: platform quirk: setting simple suspend
nvme nvme0: pci function 0000:2b:00.0
nvme nvme0: failed to set APST feature (16390)          ← ①
nvme nvme0: could not set timestamp (16390)             ← ②
nvme nvme0: allocated 61 MiB host memory buffer (1 segment).
nvme nvme0: failed to set host mem (err 16390, flags 0x1) ← ③
nvme nvme0: Could not set queue count (16390)            ← ④
nvme nvme0: IO queues not created                        ← ⑤
nvme nvme0: using unchecked data buffer                  ← ⑥（首次探测失败后约 34 秒的回退重试）
```

**链条解读**：控制器能回 Identify Controller（型号/序列号/固件都能读出）→ 说明控制器固件在跑、PCIe 链路通；但 ①②③④ 四条 Set Features 全部返回同一个 `16390`（= `0x3FFE`，Status Code Type `0x3F` 属保留/厂商区，Linux 驱动无对应名字故直接打印数字）→ ⑤ IO 队列无法创建 → 命名空间枚举无法进行 → 无块设备 → GNOME Disks 显示「无媒体」。⑥ 说明驱动还做过一次回退重试（放弃 HMB、改用 unchecked data buffer），但依旧没有命名空间。

**同类案例对照（症状完全一致）**：Thomas-Krenn 案例《Nvme nvme1: Could not set queue count (16390)》——同样是「控制器能识别 + 无命名空间 + 同一串 16390」，其结论为 **SSD 控制器故障，且未能复活**。ArchWiki NVMe 条目亦记载 KBG40ZN* 系列有控制器级失效史。

### 1.4 已排除的假设

| 假设 | 排除依据 |
|---|---|
| 分区表/文件系统损坏 | 根本没到那层：无命名空间，无 `nvme0n1` 可供 `fsck`；GNOME Disks 红条是「无媒体」不是「无法挂载」 |
| 掉盘 / 接触不良 / 插槽故障 | PCIe 端点稳定枚举、BAR 已映射、IOMMU 正常、无 AER 错误、8 次开机表现完全一致 |
| 温度过高/热保护 | 44.85 °C，属正常工作区间 |
| 驱动未装 / 内核不支持 | `nvme` 模块已加载并绑定，udisks 还能读到 SMART 数据 |
| 权限 / 挂载 / 磁盘已满 | 与「无设备节点」无关 |
| 那个著名的 APST 挂起 bug | APST 失败只是**症状之一**：本机是**每次冷启动即失败**（非仅 resume 后），且 4 条不同命令返回同一保留码。ArchWiki 那条 KBG40ZN* 的 `amd_iommu=fullflush` 建议针对的是 HP/AMD 平台的 "Device not ready" I/O 错误，与本机 Dell/Intel 的「探测期即失败」不是同一现象（可作低成本备选项，但优先级低） |
| 盘是新的/从未工作过 | 8 次开机日志一致失败 → 若曾工作过必有 `nvme0n1` 痕迹；但 journal 只回溯到 10-15，故「此前是否一直如此」未完全证实（见风险项） |

---

## 二、方案总流程

```
[A] 现场只读取证（用户执行，sudo）
        ↓ 产出：smart-log / id-ctrl / id-ns / error-log / fw-log / lspci -vvv
[B] 交叉验证定性（4 项并行/独立）
        B1 BIOS 可见性（绕过 Linux，最有说服力）
        B2 断电冷复位 / PCI function reset / nvme reset
        B3 换机换槽 + 已知良品盘插入本机（双向交叉）
        B4 Ubuntu Live USB（不同内核）
        ↓
[C] 决策门（矩阵见 §5）
        ├─ 盘侧死 → 走 D（换盘）★最可能
        └─ 环境侧问题 → 走 E（复活尝试）
[D] 换盘与迁移
[E] 复活尝试（按性价比排序，均为可回退操作）
```

---

## 三、阶段 A：现场只读取证（用户自行执行）

> 我无免密 sudo，因此以下命令**由用户在终端粘贴执行**，把输出贴回给我继续分析。
> 本阶段全部只读：不格式化、不 sanitize、不写盘、不刷固件。
> 主机当前系统跑在外置 USB 盘上，NVMe 未挂载，任何命令都不会影响现有系统。

```bash
# A0. 安装诊断工具
sudo apt update && sudo apt install -y nvme-cli smartmontools

# A1. 控制器与子系统总览（关键：看 nvme0 是否存在、有无 namespace）
sudo nvme list-subsys
sudo nvme list
sudo nvme id-ctrl /dev/nvme0
sudo nvme id-ns /dev/nvme0          # 预期：无命名空间时输出为空

# A2. SMART / 健康日志（原始 Critical Warning 位、Available Spare、Percentage Used、Media Errors）
sudo nvme smart-log /dev/nvme0
sudo smartctl -x /dev/nvme0

# A3. 命名空间列表原始日志（Identify Namespace List，log id 0x02）
sudo nvme get-log /dev/nvme0 --log=0x02 --len=4096

# A4. 错误信息日志（历史 I/O / 管理命令错误）
sudo nvme error-log /dev/nvme0

# A5. 固件槽信息与固件日志
sudo nvme get-log /dev/nvme0 --log=0x03 --len=1024
sudo nvme fw-log /dev/nvme0

# A6. 内核与 PCIe 完整细节（Capabilities 需 root 才可见）
sudo dmesg -T | grep -iE "nvme|2b:00|pcieport.*2b"
sudo lspci -vvv -s 2b:00.0
sudo cat /sys/bus/pci/devices/0000:2b:00.0/config_space | xxd | head -20
```

免 sudo 的快速自查（可先跑，确认与本文一致）：

```bash
cat /sys/class/nvme/nvme0/model /sys/class/nvme/nvme0/serial /sys/class/nvme/nvme0/state
cat /sys/class/nvme/nvme0/hwmon2/temp1_input     # 44850 = 44.85°C
ls /dev/disk/by-id/ | grep -i nvme                # 预期为空 → 无命名空间
```

**A 阶段验收标准**：
- `nvme smart-log` 成功返回，并给出 Critical Warning 原始位、Available Spare、Percentage Used、Media and Data Integrity Errors、Error Information Log Entries 数。
- `nvme id-ns` 输出为空 或明确报错。
- `nvme error-log` 的条目数与报错类型被记录（若有大量 `0x3FFE`/Internal Error 条目，直接支持「控制器内部失效」结论）。
- `nvme fw-log` 有输出（BG4 控制器的固件日志常能直接暴露 NAND 初始化失败原因）。

---

## 四、阶段 B：交叉验证定性

按信息量从高到低。B1 最有说服力——BIOS 直接对话控制器，完全绕过 Linux。

### B1. BIOS 可见性（关键判定）
1. 重启，在 Dell logo 出现时按 `F2` 进入 System Setup。
2. 找到 `Storage` / 系统信息，观察内置 NVMe 是否存在、容量是否显示 256 GB。
3. 另可按 `F12` 打开一次性启动菜单，看启动项里是否列出这块盘。

| BIOS 表现 | 结论 |
|---|---|
| 完全不出现 / 容量 0 / 报设备错误 | **盘已死**（控制器仅在 PCIe 层存活，固件无响应）→ 直接走 D |
| 正常显示 256 GB | 盘体可读，故障在软件层 → 优先走 B4/E |

### B2. 断电冷复位 / 控制器复位（清状态，非破坏性）
```bash
# 完全关机（非休眠）→ 拔掉充电器 → 长按电源键 30 秒放残电 → 装回 → 开机
# 若仍不出现，依次尝试（每次后重新 dmesg | grep -i nvme 观察）：
sudo sh -c 'echo 1 > /sys/bus/pci/devices/0000:2b:00.0/reset'   # PCI function 级复位
sudo nvme reset /dev/nvme0                                      # NVMe admin reset
```
> 说明：这类「控制器半死不活」的盘有时会被一次彻底断电唤醒；本机故障跨 8 次开机复现，因此 B2 成功概率不高，但成本极低，先做。

### B3. 换机换槽（双向交叉，判定力最强）
- **方向一（盘的问题）**：把 KIOXIA 装到另一台机器 / M.2 转 PCIe 卡的台式机 / NVMe-USB 硬盘盒。
- **方向二（本机的问题）**：把一块**已知良品**的 M.2 2280 NVMe 装进本机插槽，确认能否正常识别并分区。

| 方向一 | 方向二 | 结论 |
|---|---|---|
| 另一台机器同样「无媒体」/不识别 | 良品在本机正常 | **盘彻底坏**，本机无罪 → 走 D |
| 另一台机器正常识别 | — | 本机环境问题 → 走 E |
| 都不识别 | 良品在本机也不识别 | 本机插槽/BIOS 问题 → 需另查主板 |

### B4. 不同内核 + 干净环境
用 Ubuntu 官方 Live USB 启动（自带与本机不同的内核），登录后运行 `sudo nvme list-subsys` 与 `lsblk`。
- Live 环境同样无命名空间 → 排除本机发行版/配置问题，进一步坐实盘侧故障。

### B 阶段验收标准
- 至少完成 B1；B3 方向二若能便利则一并完成。
- 输出必须能唯一归因到「盘」或「本机环境」；若两者皆正常则转入 §5 的第三分支（罕见，需升级分析）。

---

## 五、阶段 C：决策门

| 判定条件 | 结论 | 去向 |
|---|---|---|
| BIOS 看不到盘 / 容量 0 **或** 换机后仍不识别 **或** SMART 显示 Available Spare=0%、Percentage Used=100% | **盘侧失效（控制器或介质报废）** | **走 D：换盘**（预期落点） |
| BIOS 正常显示 256 GB，但 Live USB 内核也不识别；或换机后识别正常 | 固件/配置层问题 | 走 E：复活尝试 |
| 换机正常 且 本机装良品也正常 | 环境变量（供电/BIOS/内核参数） | 走 E 的 F1/F2 分支 |
| 交叉验证结果矛盾或无法完成 | 证据不足 | 重做 A 阶段并升级分析（开盒/送修） |

---

## 六、阶段 D：换盘与迁移（预期路径）

**硬件选型**：M.2 2280，PCIe Gen3 x4 NVMe，容量上限 1 TB（Dell 官方规格）。本机为 Gen3 插槽，买 Gen3 或 Gen4 盘都可正常工作（向下兼容），建议 1 TB。注意这是 **PCIe NVMe**，不是 M.2 SATA（SATA 盘在该插槽不兼容）。

**迁移影响评估**：当前系统根在 `/dev/sdb6`（外置 USB WDC WD10EZEX），**不在这块内置 NVMe 上**，所以：
- 拔旧盘、装新盘**不影响现有系统启动**，无需重装。
- 系统盘数据、外接的两块 1 TB 盘均不受影响。

**执行步骤**：
1. 关机断电（注意：2 合 1 机型拆机需断开电池排线，建议先在 Dell 官网查该机型 Service Manual 的电池断开步骤；本阶段为建议，实际动手时再确认）。
2. 拆下旧 KIOXIA 盘，插入新盘。
3. 开机 → 新盘应出现在 `lsblk` 与 GNOME Disks 中（**这一步同时构成 B3 方向二的天然验证**）。
4. 决定用途：作为数据盘（新建 ext4 分区并挂载）或直接装 Ubuntu 26.04 迁回内置盘。
5. 若装系统：Ubuntu 安装器可正常识别内置 NVMe；装完记得调整 `/etc/fstab` 中 `/dev/sdb6` 相关条目为新盘 UUID，并拔掉外置盘验证可独立启动。

**旧盘处置**：数据已确认不重要 → 直接废弃或留作「故障件留档」；不送修亦无价值。

---

## 七、阶段 E：复活尝试（仅当 C 阶段判定为环境/固件层问题时启用）

按「成本低 → 成本高」排序，每步之后用 `sudo dmesg -T | grep -i nvme` 观察是否出现 `nvme0n1`：

1. **F1 换内核参数**：尝试 `iommu=soft`（或 `iommu=disable`）引导。依据：ArchWiki 记载 KBG40ZN* 系列有 IOMMU 相关异常史。注意本机为 Dell/Intel，ArchWiki 那条针对 HP/AMD，**优先级低，仅作低成本排除**。
2. **F2 `nvme_core.multipath=0` / `nvme_core.io_timeout=18000` 等参数**：仅调参，通常无效，除非 F1 命中。
3. **F3 Live USB 最新内核**：排除发行版内核补丁差异。
4. **F4 厂商固件更新**：KIOXIA SSD Utility（原 Toshiba SSD Utility）仅支持白名单零售型号，**本盘是 OEM 白牌盘（PCI subsystem `1e0f:0001`），支持与否存疑；且该工具需要盘能正常枚举出命名空间才可能工作**，因此优先级最低。
5. **F5 `nvme sanitize` / `nvme format`**：本盘数据不重要，若某天能枚举出命名空间又想要「彻底重置再试」，可以执行；但在当前无命名空间状态下**无法执行**，故不列入本方案的可执行路径。

> 若执行到 F4/F5 仍无命名空间，则应认定为盘体报废，回到阶段 D。

---

## 八、风险与未决事项

1. **无免密 sudo**：本方案 A 阶段的所有 SMART/日志细节在用户贴回输出前均属**未验证**。文中「degraded」的精确位归属依据的是 udisks2 文档取值词表（`spare` / `temperature` / `degraded` / `readonly` / `volatile_mem` / `pmr_readonly`），而本机 udisks2 2.10.91 的 `SmartCriticalWarning` 是单字符串属性、二进制中未找到细分位名表；**以 `nvme smart-log` 打印的 Critical Warning 原始位为最终准绳**。
2. **`0x3FFE` 的官方语义未查到权威定义**：该值不在 NVMe 规范的通用/命令专用状态码表内（SCT `0x3F` 属保留区），目前只能确定它是「控制器对需要内部资源的命令统一返回的保留/厂商码」。Thomas-Krenn 案例与本机症状一致，其结论为控制器故障且未能复活——这是**同类先例**，非本机的直接权威定论。
3. **「这块盘是否曾经正常工作过」未完全证实**：journal 仅回溯到 2026-10-15，8 次开机全部同样失败。若用户记得此盘此前可用，则更支持「渐进性介质/控制器劣化」；若从未可用，则更偏向「到货即坏 / 始终未正确装配」。此项可由用户在阶段 A 的 `nvme smart-log` 输出（`Power On Hours 8074`、Percentage Used、Media Errors）与购买时间交叉印证。
4. **该机型的电池断开流程未验证**：拆机换盘涉及断开电池排线，需查 Dell Service Manual 确认，不在本方案的已验证范围内。
5. **拆机操作的风险**：2 合 1 机型结构较紧，撬棒易损伤排线/外壳；建议由熟悉笔记本拆装的同事操作，或直接送修。
6. **BIOS 2.38.0 与该 OEM 盘的兼容性**：未核查是否存在已知 BIOS/固件交互问题；若 B1 显示 BIOS 异常且 B4 正常，可在此方向深挖。

---

## 九、执行顺序与交付

| 序 | 动作 | 执行者 | 交付物 |
|---|---|---|---|
| 1 | 运行 §三 的 A0–A6，贴回输出 | 用户（sudo） | 完整 SMART / id-ctrl / id-ns / error-log / fw-log |
| 2 | 我基于输出补全精确定性（关键位、错误日志计数） | 我 | 精确定性结论 |
| 3 | 执行 §四 的 B1（BIOS）+ B2（冷复位），条件允许再做 B3 方向二 | 用户 | 交叉验证结论 |
| 4 | 按 §五 决策门定性 | 我 + 用户 | 「盘坏」/「环境问题」定论 |
| 5 | 盘坏 → 执行 §六 换盘迁移；环境问题 → 执行 §七 复活尝试 | 用户 | 恢复可用或换盘完成 |
| 6 | 输出最终结案报告（含留档的故障特征数据，供日后同批次盘预警） | 我 | 结案报告 |

**当前状态**：阶段 A 已完成（本机只读检查，见 §1），阶段 B/C/D/E 待用户执行 A 阶段与交叉验证后推进。核心结论不因 A 阶段结果而改变——A 阶段的唯一作用是把「控制器/介质报废」从「高概率推断」升级为「有 SMART 原始位与错误日志支撑的定论」，并排除「BIOS/主板侧异常」这一少数可能。
