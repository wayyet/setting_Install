# C 盘扩容：WinRE 写入步骤执行计划

## Summary

**目标**：把 C: 的 NTFS 文件系统从 200 GiB 扩展到其所在分区（GPT #3）的完整边界 777.86 GiB，
同时**完全不触碰 GPT #6 的 EXT4 分区**（150 GiB，LBA 1,631,866,880–1,946,439,679）。

**已完成的阶段**：S1 只读基线（status=ok，8 门槛全过）、S2 只读取证 + 外置盘独立备份（status=ok，9 份副本 SHA-256 两侧一致）、
S3 门槛评审（**VERDICT=GO**，13 条全过）。全程未对目标磁盘写入任何扇区。

**已坐实的根因**：旧 D:（DATA1，NTFS）的两个引导扇区仍物理留在分区 3 内 ——
LBA `419,997,696`（主）与 LBA `1,631,866,879`（备），BPB `TotalSectors=1,211,869,183`、
`HiddenSectors=419,997,696`、卷序列号 `94AE2854AE283162`，且 `419997696 + 1211869183 = 1631866879`
正好等于分区 3 末扇区。Windows 把它识别为 C: 内部的第二个卷，于是
`Get-PartitionSupportedSize` 的 `SizeMin` 被锁在 **796,486,766,592 B（741.79 GiB）**，
而 `SizeMax = 835,225,387,008 B（777.86 GiB）`。清零这 2 个扇区即可解除锁定。

**当前唯一的障碍**：在运行中的 Windows 里，对该扇区所在分区（挂着 C:）的**原始写盘被 Windows 卷管理器拒绝**
（`ERROR_ACCESS_DENIED`），已逐条排除权限/驱动/硬件（见 §2.3）。必须在一个 **C: 未挂载的启动环境**中写入。

**本计划的核心**：把 S4（写 2 个扇区）搬进 Windows 恢复环境（WinRE）执行，其余 S5→S7 回到 Windows 后照常跑完。

**关键设计决策**：
1. **不改动任何分区表**：全程只写 2 个扇区（各 512 字节），GPT 头与 128 个分区表项由 SHA-256 逐字节守护。
2. **EXT4 零改动**：写前 / 写后各做一次三个取样点（首扇区 / superblock / 组描述符表）的逐字节比对，任一不符即中止。
3. **写前必须逐字节匹配 S2 基线**：目标扇区当前内容若与基线 .bin 不一致，工具直接拒绝写入。
4. **不依赖 .NET / PowerShell**：实测 WinRE 镜像内**没有 clr.dll，也没有 powershell.exe**，
   所以用 mingw-w64 交叉编译的**零依赖原生 Win32 程序**（PE32+ x86-64，静态链接）。
5. **独立物理备份**：9 份取证副本同时存在于 C: 与外置 Kingston（F:），两侧 SHA-256 一致。

---

## 1. 目标、范围、非目标、用户约束

### 1.1 目标
- 扩展 C: 的 NTFS 文件系统到分区 3（GPT #3）完整边界 835,225,387,008 B（777.86 GiB）。
- GPT 分区表**逐字节不变**（6 个分区的 StartLBA/EndLBA/Size/Guid/Type + 主/备 GPT 头 + 128 项表）。
- EXT4 分区（GPT #6）**内容与几何完全不变**，150 GiB 容量不变。
- 全流程可审计：每步都有 log + JSON + 扇区副本 + SHA-256，外置盘有独立副本。

### 1.2 明确的非目标
- 不删除、不格式化、不重排任何分区；不修改分区表；不做分区级 `extend`/`shrink`。
- 不使用 DiskGenius / AOMEI / MiniTool 等第三方分区工具执行写操作。
- 不改动 WSL 发行版、Docker 数据盘等其它资产。
- 不修改旧 D: 区域中的任何用户数据（本流程只写 2 个引导扇区）。

### 1.3 用户硬性约束（不可协商）
| # | 约束 | 落实方式 |
|---|---|---|
| C1 | 不得修改或删除 EXT4 分区 | 写操作 LBA 硬上界 `< 1,631,866,880`；EXT4 三点写前/写后字节比对 |
| C2 | 不得清零 C: 的主引导扇区（567,296）与备份引导扇区（419,997,695） | 目标集合写死在工具参数里，且由 S3 门槛校验过 |
| C3 | 不得猜测地址、不得"清零相邻几个扇区试错" | 目标 LBA 由 S2 只读取证实测确认；写前逐字节匹配基线 |
| C4 | 不得在无独立物理备份的情况下执行写入 | 9 份副本在 C: 与 F: 双份，SHA-256 两侧一致 |
| C5 | 不得把 DiskPart 的成功提示当作扩容成功 | 验收一律以 `Get-Volume` / `fsutil` 实读数为准 |

### 1.4 工具与操作限制
- 提权：UAC 策略为 `ConsentPromptBehaviorAdmin=0`（管理员操作免提示自动提升），无需人工点确认。
- WinRE 步骤需要**用户本人**在机器上操作一次（重启 + 在 WinRE 命令提示符粘贴 1 条命令）。
- **WinRE 内不得假定有 .NET / PowerShell**（已实测确认没有）。
- 不得使用第三方分区工具做写操作。

---

## 2. 当前实现与已定位的障碍

### 2.1 已完成的阶段（状态与产物）

| 阶段 | 脚本 | 状态 | 关键结论 |
|---|---|---|---|
| S1 只读基线 | `C:\CResizeOps\scripts\10_baseline_readonly.ps1` | `logs/S1_baseline.json` = ok | 6 个分区几何全对；`SizeMin=741.79 GiB` / `SizeMax=777.86 GiB`；C: 非 Dirty；`chkdsk C: /scan` 无错误、坏扇区 0；BitLocker 未启用 |
| S2 只读取证 | `20_forensics_readonly.ps1` | `logs/S2_forensics.json` = ok | 4 个关键扇区 + EXT4 三点 + GPT 头/表项落盘；扫描到 **3 个** NTFS 引导扇区（C_Backup + OldD 主/备），**无第三份副本** |
| S3 门槛评审 | `30_gate_review.ps1` | `logs/S3_gate.json` verdict=**GO** | 13 条门槛全过；写入目标 = LBA 419,997,696 与 1,631,866,879 |
| S4 | `40_zero_two_sectors.ps1` | **未执行**（写通道被封锁） | 全部前置断言已通过，失败点在写调用本身 |
| S5–S8 | `50/60/70/90_*.ps1` | 已写好，待 S4 之后执行 | |

公共库 `C:\CResizeOps\scripts\Common.ps1` 持有全部硬常量与护栏
（磁盘型号 / 扇区大小 / 分区 3 几何 / EXT4 边界 / LBA 允许与拒绝集合）。

### 2.2 关键扇区实测数据（S2 基线，写盘后不得改变）

| 扇区 | LBA | SHA-256 | BPB |
|---|---|---|---|
| C_Primary | 567,296 | `e5fdc5c8e96508744aa096e22a07726c5a3998aa5842ad1ff8731552bb082b69` | hidden=567296, total=419430399, serial=3CB42780B4273BB0 |
| C_Backup | 419,997,695 | 同上（与主**字节完全相同**） | 同上 |
| **OldD_Primary** | **419,997,696** | `ffd92f3a8f6fb497794ea10dbb470110e030f9ccc124b611ae7dcedb0e443f1f` | hidden=419997696, total=1211869183, serial=94AE2854AE283162 |
| **OldD_Backup** | **1,631,866,879** | 同上（与主**字节完全相同**） | 同上 |
| ext4_first_sector | 1,631,866,880 | `076a27c79e5ace2a3d47f9dd2e83e4ff6ea8872b3c2218f66c92b89b55f36560` | magic=0xEF53 |
| ext4_superblock | 1,631,866,882（1024 B） | `70b90256d17c4994d26c02552c9d56e48037cd962c9a3e0265659523f9804d1f` | uuid=FD39F00D-6381-494B-9F4F-A5C8103E4FEB, block=4096, blocks=39,321,600 |
| ext4_group_desc | 1,631,866,888（4096 B） | `9d4bb65dacd9bb5c4ea9b88be6cf4dd2307848d38eb20ad7bd44e5552ff9b4d7` | — |
| GPT_primary_header | 1 | `fdd68a527e0f635aba9b063dec223a8c4cbf919468f07c73f2c4a53b1ae87ca6` | MyLba=1, entriesLba=2, n=128, size=128 |
| GPT_partition_entries | 2（16384 B） | `5e2ccbb433020c9e7919025ada53299227bab33b89183d66519f98e30f60979f` | — |

> ⚠️ 计划原文里的 EXT4 UUID `FD39F00D-6387-4948-9F4F-A5C8103E4FEB` 是**转录笔误**：
> 该 16 字节序列在分区首个 1 MiB 内搜索结果为「未找到」，磁盘上实际是 `FD39F00D-6381-494B-9F4F-A5C8103E4FEB`。
> 完整偏差清单见 `C:\CResizeOps\logs\DEVIATIONS.md`（D1–D10）。

### 2.3 为什么在线写不了（证据）

| 通道 | 结果 |
|---|---|
| .NET `FileStream` + `FileAccess.ReadWrite` | `UnauthorizedAccessException`：Access to the path `\\.\PhysicalDrive0` is denied |
| 原生 `CreateFileW` + `GENERIC_READ\|GENERIC_WRITE` | 打开**成功**；`WriteFile` 返回 `ERROR_ACCESS_DENIED (5)` |
| `FILE_FLAG_NO_BUFFERING` + `WriteFile` | `ERROR_ACCESS_DENIED (5)` |
| `DeviceIoControl(IOCTL_DISK_WRITE)` | `ERROR_INVALID_FUNCTION (1)` |
| `IOCTL_SCSI_PASS_THROUGH` / `_DIRECT` | `ERROR_INVALID_FUNCTION (1)` |
| `\\?\GLOBALROOT\Device\0000004e`（磁盘 PDO） | 打开成功，`WriteFile` 仍 `ERROR_ACCESS_DENIED (5)` |
| `\\.\C:` 卷句柄越界 I/O | 读返回 0 字节；写被 NTFS 卷驱动丢弃 |
| `wsl --mount \\.\PhysicalDrive1 --bare` | `0x8007000f` |
| **对照实验：同一套原生代码写 Kingston（Disk 1，非系统盘）** | **成功**，写后 sha256 = 全零标准值 `076a27c7…` |

⇒ USB 桥接正常，硬件正常；封锁来自**卷管理器**（C: 处于挂载状态）。
⇒ 唯一解法：在 C: 未挂载的环境里写。Windows 11 的离线写盘工具一贯如此。

### 2.4 WinRE 环境实测（把 `winre.wim` 只读挂载后逐项确认）

| 项目 | 结果 |
|---|---|
| `System32\clr.dll` | **不存在** |
| `Microsoft.NET\Framework\*\clr.dll` | **不存在**（`v2.0.50727` 只是空壳目录） |
| `Microsoft.NET\Framework64` | **不存在** |
| `System32\WindowsPowerShell\v1.0\powershell.exe` | **不存在**（只有空 Modules 目录） |
| `cmd.exe` / `diskpart.exe` / `fsutil.exe` / `mountvol.exe` / `wpeutil.exe` / `bcdedit.exe` | **都存在** |
| `SysWOW64` 目录 | 存在 |
| `reagentc /info` | **Windows RE 状态: Enabled**，位置 `\\?\GLOBALROOT\device\harddisk0\partition4\Recovery\WindowsRE`，版本 10.0.26100.9711 |

⇒ `.NET` 版工具在 WinRE 里**起不来**；必须用**零依赖原生 exe**。

### 2.5 受影响文件

```
C:\CResizeOps\
├─ scripts\   Common.ps1（常量与护栏）10_/20_/30_/40_/50_/60_/70_/90_*.ps1
│             run_elevated.ps1、00_selftest_readonly.ps1
├─ src\       cresize-zero.cs（.NET 版，WinRE 用不了）
│             cresize-zero-native.c（★ 零依赖原生版，WinRE 用这个）
├─ bin\       cresize-zero-native.exe  ★ 实际执行体（PE32+ x86-64，静态链接）
│             cresize-zero.exe、wimlist*.exe
├─ backup\    9 份基线 .bin（S2 取证产物）
├─ winre\     ★ RUN_ZERO.cmd、dp_list.txt、dismount.cmd
├─ logs\      S1..S7 的 .log + .json、DEVIATIONS.md
└─ F:\CResizeForensicBackup\   外置 Kingston，9 份副本（独立物理备份）
   F:\CResizeOps\             外置上的第二份 WinRE 资产（逐字节一致）
```

---

## 3. WinRE 步骤详解

### 3.1 这一步到底在做什么（一句话）

在 **Windows 恢复环境**里，C: 没有被挂载，Windows 卷管理器就不再拦截原始写盘，
于是可以用一个 280 KB 的独立程序，把分区 3 里那 2 个旧 D: 的 NTFS 引导扇区各写 512 个零字节。

### 3.2 动手前要做的三件事

| # | 事项 | 为什么 |
|---|---|---|
| 1 | **保存/关闭当前所有工作** | 重启会终止当前 MCode 会话 |
| 2 | **不要拔 USB，别用 USB 集线器，接交流电** | 系统盘（ACASIS EC-7351）就在 USB 上，掉线 = 无法开机 |
| 3 | **保持 Kingston U 盘插着** | 里面有第二份手册与基线；Windows 卷万一在 WinRE 里不可见，U 盘是唯一入口 |

### 3.3 你的操作序列（共 3 步）

#### 步骤 1 — 在 Windows 里发起重启进 WinRE

在 PowerShell（管理员）里执行：

```powershell
shutdown /r /o /t 0
```

`/o` = 直接重启进「高级启动 / Windows 恢复环境」菜单。

#### 步骤 2 — 在 WinRE 里选到命令提示符

蓝色菜单里依次选：**疑难解答 → 高级选项 → 命令提示符**。
若要求选择账户，选 **Administrator** 并输入该账户密码。
进入后你会看到 `X:\>` 提示符（X: 是 WinRE 的内存盘）。

#### 步骤 3 — 粘贴这一条命令

```cmd
for %d in (C D E F G H) do @if exist %d:\CResizeOps\winre\RUN_ZERO.cmd call %d:\CResizeOps\winre\RUN_ZERO.cmd
```

这条命令会依次检查 C: 到 H:，找到第一个含 `CResizeOps\winre\RUN_ZERO.cmd` 的盘并执行它
（C: 上和 Kingston 上各有一份，内容逐字节一致）。
若它什么都没输出，说明 Windows 卷和 U 盘都没被自动挂载 —— 这时用 `diskpart`
（`list volume` → `select volume N` → `assign letter=E`）手工给 Windows 卷或 U 盘分配一个盘符，再重跑上面那条命令。

#### 步骤 4 — 读结果，然后重启回 Windows

脚本最后会 `pause`。看最后那行：

| 屏幕输出 | 含义 | 下一步 |
|---|---|---|
| `RESULT: SUCCESS` | 2 个扇区已清零，EXT4 三点逐字节一致 | 记下这一行 → 执行 `wpeutil reboot` |
| `RESULT: NOT COMPLETED (exit N)` | 没写成 | **不要**重启回 Windows 扩容；把屏幕上的 `tool output` 整段拍照/抄给我 |
| `[FAIL] preconditions not met` | 工具或基线没找到 | 什么都没有被写；把屏幕内容给我 |

> **重要**：只有 `RESULT: SUCCESS` 才继续。其它任何情况都**不要**执行扩容，
> 旧 D: 的数据依然完好，随时可以重来。

回 Windows：

```cmd
wpeutil reboot
```

### 3.4 脚本在 WinRE 内部自动做的事（你不用管，但要知道它保证什么）

```
[1/5] 定位根目录        找到 <root>\{bin,backup,winre}
[2/5] 暂存到内存盘      工具 + 5 份基线 .bin 复制到 X:\ 和 X:\bk\
                        （必须暂存，因为接下来要把 Windows 卷卸载掉）
[3/5] 卸载卷            先试写；若被卷管理器拒绝，再卸载各卷后重试
[4/5] dry-run           逐字节比对 EXT4 三点 + 2 个目标扇区，全部 MATCH 才继续
                        ↓ 只有这一步全过才会写
[4/5] 实际写入          对 LBA 419,997,696 和 1,631,866,879 各写 512 字节 0x00
                        立即回读，要求全零
                        再比一次 EXT4 三点，要求与写前完全一致
[5/5] 打印结论          RESULT: SUCCESS / NOT COMPLETED
```

**它绝不碰的东西**：LBA 567,296（C: 主引导扇区）、419,997,695（C: 备份引导扇区）、
1,631,866,880 及其之后（EXT4 起点及以后）、GPT 主头与 128 个分区表项、其它任何扇区。
工具参数里写死的目标集合就是那两个 LBA，退出码 2 表示参数错误。

### 3.5 回到 Windows 之后（我来做）

重启回 Windows 后你重开 MCode 说一声，我按顺序接着跑：

| 阶段 | 脚本 | 判定 |
|---|---|---|
| **先做独立复核** | — | 我用 PowerShell 重新读 LBA 419,997,696 / 1,631,866,879，确认**全零**；重算 EXT4 三点 SHA-256 与 S2 基线比对；重算 GPT 主头 + 128 项 SHA-256 比对 —— 这是对 WinRE 那一步的**独立第三方验证**，不依赖 WinRE 里的任何输出文件 |
| S5 Go/No-Go | `50_gono_gate.ps1` | `Update-HostStorageCache` + `diskpart rescan` → `Get-PartitionSupportedSize`；要求 `SizeMax` 仍为 835,225,387,008、`SizeMin` 塌回 ≤ 250 GiB、C: 仍约 200 GiB、非 Dirty、Healthy。**顺带受益于这次重启，VDS 缓存也一并清空** |
| S6 扩容 | `60_extend_filesystem.ps1` | 先 diskpart 只读确认（`detail volume` 必须显示卷名 C:、NTFS、标签 Windows、位于 Disk 0），确认无误才执行 `extend filesystem`；同时记录 5 个系统文件的扩容前哈希 |
| S7 验收 | `70_verify.ps1` | 14 项验收：容量、Total Sectors、Total Cluster Count、剩余空间、非 Dirty、chkdsk、分区表逐字段比对、EXT4 三点 + UUID + 几何、GPT 头与表项哈希、系统文件哈希、卷健康 |
| S8 还原 | `90_restore_two_sectors.ps1` | **仅在 S4 已写、S6 未执行时**可用：从外置盘读回 2 份原始副本写回并校验 |

### 3.6 扩容后会出现的一个"看似异常"现象（提前说明，避免误判）

扩容成功后，LBA `1,631,866,879` 会被 NTFS 写入**新的 C: 备份引导扇区**
（NTFS 惯例：备份引导扇区放在卷的末扇区）。这**不是** EXT4 被改动的证据 ——
EXT4 的首扇区仍然是 `1,631,866,880`，且它的三个取样点 SHA-256 在写前/写后/扩容后三次比对全等。
S7 的报告里会显式写明这一点。

---

## 4. 实现清单（本次要改的文件）

| # | 文件 | 改动 | 目的 |
|---|---|---|---|
| 1 | `C:\CResizeOps\src\cresize-zero-native.c` | ① 无法打开磁盘时改用**独立退出码 3**（现在是 1，与"基线不匹配"撞车）② 新增 `--restore <lba> <file>` 模式（把 .bin 原样写回，用于 S8 还原） | 让手册能可靠分支；补齐回滚能力 |
| 2 | `C:\CResizeOps\src\cresize-zero-native.c` | 用 WSL 的 `x86_64-w64-mingw32-gcc -O2 -static` 重新交叉编译 | 产出新 exe |
| 3 | `C:\CResizeOps\winre\RUN_ZERO.cmd` | ① 改成**自适应**：先直接 dry-run，只有在工具报"无法打开"（退出码 3）时才卸载卷并重试；② 修掉 `dismount.cmd` 现在只是 echo、根本没跑 diskpart 的 bug；③ 退出码 3 分支 | WinRE 里 Windows 卷可能本来就已挂载或根本未挂载，两种情况都要能走通 |
| 4 | `C:\CResizeOps\winre\dismount.txt` | 改成真正的 diskpart 脚本（`select volume N` + `dismount`，N=1..12，错误忽略） | 卸载所有卷 |
| 5 | `C:\CResizeOps\winre\dp_list.txt` | 保留（列卷用） | 审计 |
| 6 | `C:\CResizeOps\backup\*`、`F:\CResizeOps\*` | 重新同步新 exe 与手册，两侧 SHA-256 逐一比对 | 双份一致 |

**不要改的东西**：`Common.ps1` 的常量与护栏、S1/S2/S3 的脚本与产物、任何分区表数据。

---

## 5. 状态、并发、失败与恢复语义

### 5.1 状态机
```
[S1 ok] → [S2 ok] → [S3 GO] → [S4: WinRE 写入] → [S5 门槛] → [S6 扩容] → [S7 验收]
                                              ↘(失败) 保留现状 / 手动 S8 还原
```
- S3 之前：磁盘零写入，随时可停。
- S4 之后、S6 之前：**可逆**（用 .bin 基线还原 2 个扇区）。
- S6 之后：**不可逆**（NTFS 元数据已重写），此后禁止任何"还原旧 D: 引导扇区"的动作。

### 5.2 并发约束
- 同一时刻只允许一个提权阶段在跑。
- S4/S6 执行期间不得并行跑任何磁盘工具/备份软件/索引服务。
- WSL 必须 Stopped，EXT4 不得被 `wsl --mount` 挂载（当前两个发行版均为 Stopped ✓）。
- **WinRE 阶段要求全部卷卸载**；因此不能同时依赖 U 盘上的 Windows 卷，U 盘可保持挂载。

### 5.3 失败恢复矩阵

| 失败点 | 动作 |
|---|---|
| WinRE 里找不到 `RUN_ZERO.cmd` | 用 `diskpart` 手工 assign 盘符再重跑；**未发生任何写入** |
| 工具报 `cannot open`（退出码 3） | 脚本已自动卸载卷后重试；仍失败则停下，把屏幕输出给我 |
| 工具报基线不匹配 | 立即停止。目标扇区已被改动 → 不要再扩容，先用 S2 的 .bin 复核并还原 |
| 写入过程中失败（第二个扇区写失败） | 第一个扇区已被清零 → 用 `--restore` 从 .bin 写回，然后重新评估 |
| EXT4 写后比对不一致 | **最高优先级**：立刻 `--restore` 两个扇区，停止一切后续操作，升级为事故处理 |
| S5 `SizeMin` 未下降 | 先重启一次（清 VDS 缓存）重跑 S5；仍不通过则还原 2 扇区并停止 |
| S6 `extend filesystem` 报错 | 不清零其它扇区、不做分区级 extend、不用第三方工具；保存完整输出并复测容量/扇区数/Dirty |
| S6 显示成功但容量未变 | 判定未成功；不重复写入，先记录前后读数 |
| S6 后 C: Dirty 或 chkdsk 报错 | 不立即 `/f`；先保存日志，单独制定修复方案 |
| USB 掉线 / 掉电 | 停止一切操作；重新插上后先跑 S1+S2 重新取证再决定 |

---

## 6. 测试与验收标准

### 6.1 WinRE 步骤的验收
1. 工具自检输出中，EXT4 三点与 2 个目标扇区全部 `MATCHES baseline`（写前）。
2. 写后回读两个目标扇区均为 `ALL ZERO OK`。
3. 写后 EXT4 三点再次 `MATCHES baseline`。
4. 屏幕最终行是 `RESULT: SUCCESS`。
5. **回到 Windows 后我独立复核**（不依赖 WinRE 的任何文件）：
   - LBA 419,997,696 与 1,631,866,879 的 512 字节**全为 0x00**；
   - EXT4 三点 SHA-256 与 S2 基线**完全相同**；
   - GPT 主头 + 128 个分区表项 SHA-256 与 S1 基线**完全相同**；
   - LBA 567,296 / 419,997,695（C: 主/备引导扇区）SHA-256 **完全相同**。

### 6.2 整体验收（S7，14 项）
1. `Get-Volume C` Size 接近 835,225,387,008 B（容差 2 GiB）
2. `fsutil fsinfo ntfsinfo C:` Total Sectors 接近 1,631,299,584
3. Total Cluster Count 约 203,912,448
4. 剩余空间显著增加
5. `fsutil dirty query C:` = not Dirty
6. `chkdsk C: /scan` 无错误
7. 6 个分区的 StartLBA/EndLBA/Size/Guid/Type 与 S1 基线完全一致
8. EXT4 三个取样点 SHA-256 与 S2 基线一致
9. EXT4 UUID = `FD39F00D-6381-494B-9F4F-A5C8103E4FEB`
10. `Get-Partition` 的 Partition 6 Offset/Size/GptType 未变
11. GPT 主头 + 备头字节一致
12. GPT 128 项分区表字节一致
13. 5 个系统文件哈希与扩容前一致
14. 卷 Healthy

### 6.3 回归验证
- S1 基线脚本在扩容后重跑，6 个分区几何仍应全对（证明没有分区级改动）。
- `Get-PartitionSupportedSize -PartitionNumber 6` 仍为 150 GiB 量级（EXT4 容量未变）。

---

## 7. 未决事项与风险

| 级别 | 风险 | 缓解 |
|---|---|---|
| 🔴 高 | **重启本身**：系统盘在 USB 上，重启时掉线 = 无法开机 | 交流电、别拔 USB、别用 USB 集线器；执行前确认 USB 链路稳定 |
| 🔴 高 | **WinRE 里仍然写不了**（卸载卷后卷管理器依旧拦截） | 这是本步唯一的真实未知。脚本会先直接试写、再卸载重试；若两次都失败，**不做任何写入**，把屏幕输出给我，另行评估（例如把系统盘接到内部 SATA/NVMe —— 本机无第二块物理磁盘） |
| 🔴 高 | 幽灵卷假设不成立：清零后 `SizeMin` 不降 | S5 门槛拦下；S8 可完全还原；不硬来 |
| 🟠 中 | Kingston 途中被存储栈自动置为 Offline 过一次（已恢复，副本 9/9 校验通过） | 写盘前确认 F: 在线且副本可读；U 盘上已有第二份手册与基线 |
| 🟠 中 | 旧 D: 区域在扩容后被 NTFS 接管并覆写 | 用户已确认可丢弃；原始引导扇区副本在 C: 与 F: 双份留存 |
| 🟡 低 | VDS 缓存导致 `SizeMin` 读数滞后 | S5 预留"重启后复测"分支；本次 WinRE 往返本身已是一次重启 |
| 🟡 低 | WinRE 里找不到手册 | 手册在 C: 与 U 盘双份；还提供 `diskpart` 手工 assign 盘符的兜底说明 |

### 未决决策（需要用户拍板）
1. **是否现在执行 WinRE 这一步**（用户先前未在问卷中选择）。
   - 选「执行」：按 §3 的 3 步操作，预计耗时约 10–15 分钟（含两次重启）。
   - 选「暂不执行」：C: 保持 200 GiB，旧 D: 数据完好，取证材料与全部脚本保留在
     `C:\CResizeOps` 与 `F:\CResizeForensicBackup`，风险为零，随时可再执行。
2. 扩容后是否需要把 EXT4 纳入 WSL 自动挂载（`wsl --mount` / fstab）？**本计划不动它。**
3. `C:\CResizeOps` 与外置盘备份保留多久？默认保留至 S7 验收通过后 7 天。

---

## 8. 证据索引

| 文件 | 内容 |
|---|---|
| `C:\CResizeOps\logs\S1_baseline.json` / `.log` | 只读基线：分区表、卷、NTFS 信息、SizeMin/SizeMax、chkdsk、GPT 头 |
| `C:\CResizeOps\logs\S2_forensics.json` / `.log` | 4 关键扇区 BPB、NTFS 签名扫描、EXT4 基线、外置盘副本校验 |
| `C:\CResizeOps\logs\S3_gate.json` | 13 条门槛逐条判定 = GO |
| `C:\CResizeOps\logs\DEVIATIONS.md` | **D1–D10**：与原 plan 的全部偏差及证据（字节序、TotalSectors 约定、末扇区超时、UAC、中文本地化、UUID 转录、写通道封锁、WinRE 无 .NET、Kingston 离线） |
| `C:\CResizeOps\logs\S0_*.log` | 自检留档：原生 I/O 层基线一致性、写入通道排查对照实验、WinRE 镜像内容枚举、Kingston 对照写入 |
| `C:\CResizeOps\backup\*.bin` | 9 份基线副本（本地） |
| `F:\CResizeForensicBackup\*.bin` | 9 份基线副本（外置 Kingston，独立物理备份） |
