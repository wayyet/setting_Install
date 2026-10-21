# C 盘扩容方案：只扩 NTFS 文件系统，不动分区表、不动数据

## Summary

**目标**：让 C 盘可用容量从 200 GB 变成 777.86 GB，用掉之前那段 577.86 GB 空闲空间。

**关键发现（与用户截图已不同）**：截图时 C 盘分区是 200 GB、后面有 577.86 GB 未分配空间。**现在分区表已经改过了**——C 盘分区条目（分区 #3）已经是 835,225,387,008 字节 / 777.86 GiB，正好顶到 Linux 的 EXT4 分区（#6）起点，中间已无未分配空间。但 **NTFS 文件系统本身仍只有 200 GB**（总扇区 419,430,400 / 总簇数 52,428,799）。

**所以本轮要做的不是"扩分区"，而是"把 NTFS 撑满它自己的分区"**——这恰好是用户"不修改任何数据和分区"约束下的最优解：**分区表一个字节都不用改**，只更新 NTFS 自身的元数据（引导扇区、$Bitmap、$MFT 镜像），用户数据一个字节都不动、不搬移。

**核心设计决策**：
1. **主方案 = Windows 自带 `diskpart` 的 `extend filesystem` 子命令**。微软官方文档明确写着该子命令"仅适用于文件系统未随卷扩展的磁盘"——正是本机情形；且"如果分区以前是用 NTFS 文件系统格式化的，则文件系统会自动扩展以填充更大的分区，并且不会发生数据丢失"。
2. **明确禁用分区级 `extend`**。本机分区外已无未分配空间，`extend`（不带参数）必然报 "There is not enough usable free space"。不要因此误判为失败而回头去找分区工具。
3. **不使用 DiskGenius**（用户明确禁止），全程只用 Windows 内置 diskpart / fsutil / chkdsk。
4. **执行者 = 用户本人**（用户已选择）。我不碰这台机器的磁盘，只交付可复制粘贴的命令清单 + 验收标准。
5. **备选路线 = 原生"临时收缩再扩回"**（用户已批准）。仅在主方案报错时启用，分区最终大小与现在完全一致。

**不涉及任何仓库文件**。这是系统级操作，工作区内不新增/修改任何文件。

## 目标与范围

**做**：
- 把 NTFS 卷从 200 GB 撑到 777.86 GB（填满分区 #3 已有空间）
- 全程不改分区表条目、不移动/删除任何分区、不格式化、不丢数据
- 给出可量化的验收标准，让用户自己判断成功与否

**不做（明确排除）**：
- 不删分区 #4/#5/#6（WinRE_DRV、DELLSUPPORT、Linux EXT4）
- 不动分区 #1（ESP 260 MB）、#2（MSR 16 MB）
- 不装 DiskGenius 或任何第三方分区软件（备选路线是纯原生）
- 不改磁盘分区表风格（保持 GPT）、不改磁盘签名
- 不做整盘备份镜像（本机只有一块物理盘，无处可备，见「风险」）

## 用户约束（实现时必须遵守）

| 约束 | 内容 |
|---|---|
| 工具 | 只用 Windows 内置：diskpart / fsutil / chkdsk / Get-Partition。**禁止 DiskGenius** |
| 数据 | 不修改任何用户数据；不移动数据；不格式化 |
| 分区 | 不修改任何分区条目（主方案）。备选方案允许"临时缩小 1GB 再扩回"，终态与现状一致 |
| 执行 | **用户自己执行**，需要管理员权限的终端。我只提供命令 |
| 网络 | 本方案无需联网（已完成的资料核实除外） |
| 测试 | 用只读验证命令 + `chkdsk /scan` 做验收，不跑写入型测试 |
| 委派 | 不需要委派子任务 |
| 写入 | 唯一允许写的文件是本 plan.md；执行阶段不写任何脚本/文件到用户磁盘，命令清单以聊天文本交付 |

## 现状（2026-10-21 只读实测）

**磁盘**：Disk 0 = `ACASIS EC-7351`，GPT，1,953,525,168 扇区 = 931.513 GiB，`BusType=USB`，`IsBoot=True`，`IsSystem=True`，Online，非只读。全机只有这一块物理盘。

**分区表基线**（`Get-Partition -DiskNumber 0` 实测，执行后需逐行比对）：

| # | 类型 | StartLBA | Size（字节） | EndLBA | 说明 |
|---|---|---|---|---|---|
| 1 | System (ESP) | 2,048 | 272,629,760 | 534,527 | 引导分区 |
| 2 | Reserved (MSR) | 534,528 | 16,777,216 | 567,295 | 微软保留 |
| 3 | **Basic (C:)** | **567,296** | **835,225,387,008** | **1,631,866,879** | **777.86 GiB（已扩容过）** |
| 6 | Unknown (Linux EXT4) | 1,631,866,880 | 161,061,273,600 | 1,946,439,679 | 150 GiB，紧贴 C: 末尾 |
| 4 | Recovery (WinRE_DRV) | 1,946,439,680 | 2,097,152,000 | 1,950,535,679 | 2 GiB |
| 5 | Recovery (DELLSUPPORT) | 1,950,535,680 | 1,518,338,048 | 1,953,501,183 | 1.41 GiB |

**C: 卷现状**（`Get-Volume` / `Win32_Volume` 两路一致）：NTFS，Size = 214,748,360,704 B（200 GiB），SizeRemaining = 59,200,266,240 B（55.13 GiB），AllocationUnitSize = 4096，HealthStatus = Healthy，OperationalStatus = OK，卷标 `Windows`。

**其他事实**：
- 分区 #3 末尾（LBA 1,631,866,879）与分区 #6 起点（LBA 1,631,866,880）相邻 → **分区层面零未分配空间**
- `Get-BitLockerVolume` 报"没有关联的 BitLocker 卷" → **BitLocker 未启用**，无需恢复密钥
- 当前 MCode 终端非管理员（`IsInRole(Administrator)` = False），`diskpart` 报"请求的操作需要提升" → **必须用管理员终端**
- 磁盘被 USB 桥接器识别为 MediaType=HDD（实为 NVMe），不影响本操作

**根因推断**：分区条目已扩到 777.86 GiB，NTFS 未同步扩容。常见于 Linux 下用 sgdisk/parted 改了分区表后没跑 ntfsresize，或用分区工具只改了分区条目。本方案不用去查这个历史——修掉文件系统即可。

## 方案：端到端流程

> 全部命令在**管理员 PowerShell / 管理员 CMD** 中执行。
> 阶段 0、1、2 的输出请贴回对话，我来判断是否达标。

### 阶段 0 — 提权确认 + 记录基线（只读，约 30 秒）

```powershell
# 0.1 必须是 True，否则后面全部无效
([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# 0.2 分区表基线（和上文表格逐行比对）
Get-Partition -DiskNumber 0 | Select-Object PartitionNumber,DriveLetter,Type,@{n='StartLBA';e={[int64]($_.Offset/512)}},@{n='SizeBytes';e={[int64]$_.Size}},@{n='EndLBA';e={[int64]([math]::Floor(($_.Offset+$_.Size)/512)-1)}} | Format-Table -AutoSize

# 0.3 卷与文件系统基线
Get-Volume -DriveLetter C | Format-List Size,SizeRemaining,HealthStatus,FileSystem,AllocationUnitSize
fsutil fsinfo ntfsinfo C:
fsutil fsinfo volumeinfo C:
fsutil dirty query C:
```

**阶段 0 期望值**：分区表与上表 6 行完全一致；`Size` = 214748360704；`fsutil ntfsinfo` 的 `Total Sectors in File System` = 419,430,400；`fsutil volumeinfo` 的 `Total Cluster Count` ≈ 52,428,799；`fsutil dirty query` 返回 `Volume C: is not Dirty`。

**如果阶段 0 的分区表和上表不一致** → 说明期间状态又变了，**停止**，把输出贴回来重新判断。

### 阶段 1 — 主方案：diskpart `extend filesystem`（唯一写操作）

先开管理员终端（开始菜单搜 `powershell` → 右键"以管理员身份运行"），执行：

```powershell
diskpart
```

进入 `DISKPART>` 提示符后，**逐条**输入：

```
list volume
select volume C
detail volume
extend filesystem
exit
```

**每条的解释**：
- `list volume` — 确认 C: 的卷号和当前大小（应显示 200 GB），防止选错卷
- `select volume C` — 选中 C: 卷（在基本磁盘上会同时把分区 #3 设为焦点）
- `detail volume` — **执行前的最后确认**：应显示卷标 `Windows`、文件系统 `NTFS`、大小 200 GB、位于磁盘 0 的分区 3。若不符 → `exit` 退出，贴输出回来
- `extend filesystem` — **核心动作**：只把 NTFS 元数据撑到分区 #3 的末尾（777.86 GiB）。不碰分区表、不动数据
- `exit` — 退出 diskpart

**期望输出**：`DiskPart successfully extended the file system.`（或中文"磁盘分区成功扩展了文件系统。"）

**耗时**：通常 10–60 秒（USB 桥接的 NVMe 可能偏慢）。**过程中不要关窗口、不要拔线、不要断电、不要重启。**

**如果报 "There is not enough usable free space on disk(s) to complete this operation"** → 不是操作错误，是该场景下的预期表现（分区外已无未分配空间，`extend filesystem` 的可用空间识别在个别构建上会失败）。直接进入**阶段 3 备选**。

### 阶段 2 — 验收（只读）

```powershell
# 2.1 卷与文件系统
Get-Volume -DriveLetter C | Format-List Size,SizeRemaining,HealthStatus,FileSystem,AllocationUnitSize
fsutil fsinfo ntfsinfo C:
fsutil fsinfo volumeinfo C:
fsutil dirty query C:

# 2.2 文件系统完整性（在线扫描，不改数据）
chkdsk C: /scan

# 2.3 分区表比对（除 #3 外，其余 5 行必须与基线逐字节一致；#3 也应完全不变）
Get-Partition -DiskNumber 0 | Select-Object PartitionNumber,DriveLetter,Type,@{n='StartLBA';e={[int64]($_.Offset/512)}},@{n='SizeBytes';e={[int64]$_.Size}},@{n='EndLBA';e={[int64]([math]::Floor(($_.Offset+$_.Size)/512)-1)}} | Format-Table -AutoSize
```

### 阶段 3 — 备选（仅当阶段 1 报错时启用，用户已批准）

原理：先从尾部缩 1 GB，把空间"挤"到分区之外，形成真正的未分配空间；再用标准 `extend` 把分区和文件系统一起扩回原尺寸。**终态分区大小与现在完全相同**，只有 NTFS 元数据被更新。

```powershell
diskpart
```

`DISKPART>` 内逐条输入：

```
list volume
select volume C
detail volume
shrink desired=1024
list partition
select volume C
extend
detail volume
exit
```

**分支判断（看 `shrink` 之后 `list partition` 的输出）**：
- **分支 A**：`list partition` 显示分区 #3 变成约 776.86 GiB，且分区 #3 与 #6 之间出现 1 GB 未分配空间 → 执行 `select volume C` + `extend`，分区和 NTFS 会一起扩回 777.86 GiB。**这是预期路径。**
- **分支 B**：`list partition` 显示分区 #3 仍是 777.86 GiB（只缩了文件系统，没缩分区） → 分区外仍无未分配空间，此时改执行 `select volume C` + `extend filesystem`（可能这次会成功），而不是 `extend`。

**注意事项**：
- `shrink desired=1024` 单位是 **MB**（1024 MB = 1 GB）
- 若 `shrink` 报无法缩小到该大小（尾部有不可移动文件）→ 改小：`shrink desired=512`，再不行 `shrink desired=256`
- 收缩从 NTFS 尾部空闲区削，**不搬移用户数据**，且当前尾部有 55 GB 空闲，收缩 1 GB 是安全的
- 若在 `shrink` 之后、`extend` 之前中断：C: 只是比分区小 1 GB，**无任何损坏**，重跑 `select volume C` + `extend` 即可复原

## 失败模式与恢复语义

| 场景 | 现象 | 处理 |
|---|---|---|
| `extend filesystem` 报无可用空间 | 分区外无未分配空间（正常现象） | 进入阶段 3 备选 |
| `extend filesystem` 中途被中断（断电/拔线/强关窗口） | NTFS `$Bitmap` 与引导扇区可能不一致 | `chkdsk C: /scan`（在线扫描）；提示需修复时 `chkdsk C: /f`（占用卷则需重启进 WinRE） |
| 阶段 3 在 shrink 与 extend 之间中断 | C: 比分区小 1 GB，无损坏 | 重跑 `select volume C` + `extend` |
| `chkdsk /scan` 报发现错误 | 文件系统有隐患 | `chkdsk C: /f`；若因占用无法执行 → 重启后自动运行 |
| C: 无法启动（概率极低，本次不触碰引导结构） | 系统起不来 | 同盘存在 WinRE_DRV（分区 #4，2 GiB）可用 WinRE 修复；**USB 硬盘必须保持连接** |
| 操作后空间没变但提示成功 | 元数据缓存未刷新 | 重启一次，再跑阶段 2 验证 |

**并发/占用语义**：`extend filesystem` 属在线操作，C: 处于使用中（当前系统就跑在上面）也能执行，不需要关闭程序。执行期间**禁止**：拔 USB 线、关机/重启、运行 DiskGenius 或其他分区工具、磁盘休眠。

## 验收标准（全部满足才算成功）

| # | 检查项 | 期望值 |
|---|---|---|
| 1 | `Get-Volume C` → `Size` | ≈ 835,215,383,808 B（777.86 GiB），与 `Get-Partition C` 的 `Size` 835,225,387,008 差值 < 64 KB |
| 2 | `Get-Volume C` → `SizeRemaining` | ≈ 633 GiB（原 55.13 GiB + 577.86 GiB） |
| 3 | `fsutil fsinfo ntfsinfo C:` → `Total Sectors in File System` | ≈ 1,631,299,584 |
| 4 | `fsutil fsinfo volumeinfo C:` → `Total Cluster Count` | ≈ 203,912,448（允许 ±1） |
| 5 | `fsutil dirty query C:` | `Volume C: is not Dirty` |
| 6 | `chkdsk C: /scan` | 无错误、无需修复 |
| 7 | `Get-Partition -DiskNumber 0` | 6 个分区的 StartLBA / SizeBytes / EndLBA 与「现状」表格**逐字节一致**（含 #3 未变） |
| 8 | 资源管理器 / `Get-Volume` 显示 | C: 777.8 GB |
| 9 | 用户抽查 | `C:\Windows`、`C:\Users\wayyet` 下文件可正常读写，程序可正常启动 |

**反向验收（证明"没改分区"）**：验收项 7 全部一致 = 分区表一个字节没动；验收项 9 = 用户数据完好。

## 风险

1. **无备份介质**：本机只有一块物理盘（`Get-Disk` 只有 Disk 0），无法做整盘镜像。`extend filesystem` 官方语义是"不发生数据丢失"，但它会重写 NTFS 引导扇区 / `$Bitmap` / `$MFT` 镜像这几十 MB 元数据。**建议在执行前，把 C: 上不可再生的数据（文档、照片、项目文件）手动复制一份到外置存储**——这是唯一能降低残余风险的动作。
2. **系统盘 + USB 启动盘**：Disk 0 既是系统盘又通过 USB 连接。执行期间任何线材松动/断电都可能导致 NTFS 元数据不一致（可恢复，见上表）。执行前确认 USB 插口牢固、电源稳定。
3. **`extend`（分区级）会失败**：这是预期现象，不是操作错误。若照着网上教程跑 `extend` 看到报错，不要据此改用分区工具。
4. **Windows 磁盘管理 GUI 的"扩展卷"按钮可能仍是灰的**：因为分区外没有未分配空间。该 GUI 只认"分区外未分配空间"，不认"分区内文件系统没跟上"。**不要被 GUI 误导**，用 diskpart。
5. **磁盘被识别为 HDD**：USB 桥接器 MediaType 误报，实际是 NVMe。不影响本操作。

## 未决事项

- **无阻塞项**。两个关键决策已由用户确认：①执行方式 = 用户自己跑命令清单；②失败备选 = 原生临时收缩再扩回（不装第三方工具）。
- **待用户回传**：阶段 0 的基线输出 + 阶段 2 的验收输出。收到后我判定是否达标；若阶段 1 报错，直接进阶段 3，我再协助判读 `shrink` 后的分支 A / B。

## 交付物

阶段 1 执行完成后，我在对话里交付**可整段复制粘贴的命令清单**（阶段 0 → 阶段 1 → 阶段 2 → 阶段 3 备选），外加验收对照表。不在你磁盘上生成任何脚本或文件。
