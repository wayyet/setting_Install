# Dell Inspiron 14 5410：Windows 11 + Ubuntu 26.04.1 LTS 安装方案审查与安全操作手册

> 审查日期：2026-10-11  
> 被审查文档：[在 Dell Inspiron 14 5410 上搭建 Windows 11 + Ubuntu 26.04.1 LTS 双系统](https://github.com/wayyet/setting_Install/blob/main/%E5%9C%A8%20Dell%20Inspiron%2014%205410%20%E4%B8%8A%E6%90%AD%E5%BB%BA%20Windows%2011%20%2B%20Ubuntu%2026.04.1%20LTS%20%E5%8F%8C%E7%B3%BB%E7%BB%9F.md)

## 0. 结论先行

**当前原文不能直接照做。请先不要运行原文的自动安装配置，也不要运行其提到的 U 盘制作脚本。** 本次检查发现了会影响分区位置、分区保护和数据安全的实质问题。

最低风险的建议路线：

1. 在 Windows 中确认目标盘和 D 盘身份，备份重要数据。
2. 使用 Windows“磁盘管理”压缩目标盘上的 D:，只腾出未分配空间；不要删除恢复分区，也不要在 Windows 中把未分配空间新建成 NTFS 卷。
3. 用**另一支空白 U 盘**制作 Ubuntu 安装介质。含有现有数据的 U 盘不参与制作，整个过程不对它执行格式化或写盘操作。
4. 安装时暂时拔掉机械硬盘 E:，从 Ubuntu 图形安装器进入“手动分区”，只在新腾出的未分配空间中创建 Ubuntu 分区。
5. 安装完成后，分别测试 Ubuntu 和 Windows，再重新接入 E:。

**数据安全边界：** 分区调整存在故障、断电和误选设备的风险。任何操作都不能对重要数据作绝对零风险承诺。开始前应将重要文件备份到另一块物理设备，并验证备份可读。

---

## 1. 原文方案核查结果

### 1.1 高风险问题

| 编号 | 原文内容或做法 | 核查结果 | 建议 |
|---|---|---|---|
| H1 | Autoinstall 存储配置使用 `offset`，但示例只写 `storage: config:`，没有显式声明 `storage.version: 2` | **配置与说明不一致。** Curtin 的分区配置 v1 与 v2 处理方式不同；分区 `offset` 只有在 v2 中才生效 | 不要使用当前 YAML。若坚持自动安装，必须由熟悉 Curtin 的人员重新设计并在可丢弃的测试盘上验证 |
| H2 | 原文声称 v2 下只要某个现有分区偏移量不符，安装就会安全报错 | **这个安全保证不成立。** Curtin 文档说明，v2 会把未在新配置中引用的现有分区进行 superblock wipe 并删除。偏移量写错或漏声明，可能导致真实分区未被匹配，而不只是安全中止 | 不要把 `preserve: true` 或偏移量检查当成防误抹盘保险。自动分区配置必须逐项验证 |
| H3 | P7/P8/P9 的分区偏移量 | **存在明确的数值错误。** P7 结束位置为 `836052713472`；原文 P8 起点却为 `836488713472`，中间留下 `436000000` 字节未解释空隙。P8 和 P9 起点对 512 取模均为 256，不是合法的 512 字节扇区边界 | 删除这组手写偏移量。采用图形安装器在未分配空间中创建新分区，不手算或手写 offset |
| H4 | `Get-PartitionSupportedSize` 的 `SizeMax` 被用于计算可压缩量 | **计算口径错误。** Windows 返回 `SizeMin`（可缩到的最小分区大小）和 `SizeMax`（可扩到的最大分区大小）。可压缩量应按“当前分区大小 − SizeMin”估算，而不是 `SizeMax − 当前大小` | 只把该命令用于只读预检；参考本文给出的公式，不运行原文未提供的脚本 |
| H5 | U 盘制作脚本计划创建/重排 `CIDATA` 与 `UBUNTU` 两个分区 | **不能满足“原有数据绝不受影响”。** 重建分区布局或写入混合 ISO 镜像可能覆盖原有分区表和文件 | 使用另一支空白 U 盘。若必须保留同一支 U 盘的数据，不要对它运行 Rufus、Etcher、`dd`、Ubuntu Disks 或原文所述脚本 |
| H6 | 原文引用多个 PowerShell 脚本、`autoinstall.yaml`、GUI 安装指南和修复文档 | 检查 GitHub 仓库 `main` 分支目录后，仓库目前只有原文这一个 Markdown 文件，没有这些配套文件 | 无法审核脚本的实际实现；不要因为原文声称“有校验和幂等保护”就假设这些保护已经存在 |

来源：Curtin [Storage 文档](https://curtin.readthedocs.io/en/latest/topics/storage.html) 对配置版本、`offset`、`preserve` 和未声明分区的行为有明确说明；Microsoft [Get-PartitionSupportedSize 文档](https://learn.microsoft.com/en-us/powershell/module/storage/get-partitionsupportedsize?view=windowsserver2025-ps) 说明其返回 `SizeMin` 与 `SizeMax`。

### 1.2 其他需要修正的地方

1. **Ubuntu ISO 文件名。** 原文写成 `ubuntu-26.04.1-desktop-amd64.iso`。Ubuntu 26.04.1 发布目录列出的桌面镜像名是 `ubuntu-26.04-desktop-amd64.iso`；发布目录中的 `SHA256SUMS` 也应按该官方文件名匹配。若本地自行改名，校验脚本必须仍然读取正确的官方哈希条目。官方目录：[Ubuntu 26.04.1](https://releases.ubuntu.com/26.04.1/)。
2. **试运行流程有矛盾。** 原文一处说 U 盘制作阶段已包含根目录 `autoinstall.yaml`，另一处又说 Try Ubuntu 之后才把它复制到 U 盘。自动安装配置的投放时间必须唯一、明确；否则可能在尚未检查磁盘身份时意外触发无人值守安装。
3. **磁盘匹配条件不能凭猜测。** `ACASIS EC-7351` 是硬盘盒型号；Linux 读取到的 `ID_MODEL` 可能由 USB 桥接芯片或内部 SSD 决定。`model: ACASIS*` 只有在试运行中确认它能唯一匹配目标设备后才有意义。不能只按“1 TB”区分两块同容量磁盘。
4. **关闭 Secure Boot 不是通用必需条件。** Ubuntu 官方安装介质通常支持 UEFI Secure Boot。不要仅因为原文要求就额外更改固件设置；保持电脑当前可正常启动 Windows 的模式，除非现场出现明确的兼容性错误。
5. **外置系统盘的额外风险。** 原文中的 Windows 系统盘通过 ACASIS USB 硬盘盒连接。安装后能否从固件菜单启动 Ubuntu，取决于 USB 桥接、端口、固件启动项等因素。安装和首次验证时不要使用 USB Hub，也不要在读写期间拔插硬盘盒。
6. **“脚本会回滚/幂等”目前无法验证。** 因为仓库没有这些脚本，不能确认其是否真的正确识别磁盘、是否有破坏性命令、是否对异常断电做了处理。

### 1.3 原文中可保留的思路

- 通过压缩 D: 腾出空间，而不是删除 WinRE 或 Dell 恢复分区，这个方向正确。
- 将 Ubuntu 安装在 ACASIS 目标盘的新分区中，并尽量让 E: 盘不参与安装，方向正确。
- 安装前通过 `lsblk`、`udevadm`、`parted` 等工具现场确认 Linux 看到的磁盘身份，方向正确。
- 下载 ISO 后比对官方 SHA-256 校验值，方向正确。

---

## 2. 操作前必须确认的磁盘关系

下文以原文记录的机器布局为参考，不代表当前现场一定仍然完全相同。任何磁盘编号、容量、偏移量只要与实测不一致，都应停止，不要套用旧值。

| 设备 | 原文记录 | 本次处理原则 |
|---|---|---|
| 磁盘 0：ACASIS EC-7351 | 约 1 TB；Windows 系统盘；GPT；P1 EFI、P2 MSR、P3 C:、P4 D:、P5 WinRE、P6 DELLSUPPORT | 唯一允许新增 Ubuntu 分区的磁盘。Windows 中只压缩 D:，安装器中只操作压缩后产生的未分配空间 |
| 磁盘 1：ST1000LM024 | 约 1 TB 机械硬盘；E: 数据盘 | 完全不参与。最好在 Ubuntu 安装前物理断开，待双系统测试完成再接回 |
| 安装 U 盘 | 原文计划至少 16 GB | 使用一支空白、专用于安装的 U 盘，不使用存有唯一副本或重要数据的 U 盘 |

两块硬盘都可能显示为约 1 TB，因此**不能只凭容量、`/dev/sda`/`/dev/sdb` 或磁盘编号来选择目标盘**。Linux 中的设备名会随 USB 枚举顺序变化。

---

## 3. Windows 下预检与压缩 D:

### 3.1 先做准备

1. 将 C:、D: 和 E: 中的重要资料备份到另一块物理磁盘或经过验证的网络存储。
2. 确认备份中的文件能打开，不要只确认“复制进度完成”。
3. 将笔记本连接电源。关闭正在大量读写 D: 的软件，不要在操作过程中拔掉 ACASIS 硬盘盒。
4. 确认 Windows 可以正常重启，并准备好 Windows 恢复方式。
5. 查看 BitLocker 状态和恢复密钥。即使原文称未启用，也必须以当前机器输出为准。
6. 记下目标盘的型号、序列号/UniqueId、容量和分区表，留存截图或文本。

### 3.2 以管理员身份打开 PowerShell，执行只读检查

先查看所有磁盘。此步骤不会更改磁盘：

```powershell
Get-Disk |
  Sort-Object Number |
  Format-Table Number, FriendlyName, SerialNumber, UniqueId, BusType, PartitionStyle, OperationalStatus, IsBoot, IsSystem, Size -AutoSize
```

查看 D: 实际位于哪块磁盘，以及分区大小：

```powershell
$d = Get-Partition -DriveLetter D
$d | Format-List DiskNumber, PartitionNumber, DriveLetter, Offset, Size, Type, GptType
Get-Volume -DriveLetter D | Format-List DriveLetter, FileSystem, FileSystemLabel, Size, SizeRemaining
```

查看 D: 当前能够压缩到的最小尺寸：

```powershell
$supported = Get-PartitionSupportedSize -DriveLetter D
$supported | Format-List SizeMin, SizeMax

$currentSize = (Get-Partition -DriveLetter D).Size
$maxShrinkBytes = $currentSize - $supported.SizeMin
[pscustomobject]@{
  CurrentGiB = [math]::Round($currentSize / 1GB, 2)
  MinimumGiB = [math]::Round($supported.SizeMin / 1GB, 2)
  MaxShrinkGiB = [math]::Round($maxShrinkBytes / 1GB, 2)
}
```

检查 BitLocker：

```powershell
manage-bde -status
```

**检查规则：**

- 确认 D: 与原文所述 ACASIS 目标盘对应，而不是机械硬盘 E:。
- 目标盘的 `PartitionStyle` 应为 `GPT`。
- 原文建议压缩 150 GiB。如果 `MaxShrinkGiB` 不足 150，不能强制按 150 操作；应选择更小值或先处理占用空间的问题。
- 原文提出“可用压缩量 = SizeMax 与当前大小之差”是错误的。正确的估算是 `当前大小 - SizeMin`。`SizeMax` 用于表示支持的最大分区大小，不能用于上述压缩量计算。
- 如果目标盘身份无法明确确认，停止，不要继续。

### 3.3 用 Windows“磁盘管理”压缩 D:

1. 按 `Win + X`，打开“磁盘管理”（Disk Management）。
2. 找到与 PowerShell 预检结果一致的 ACASIS 磁盘，确认 D: 位于该磁盘上。
3. 右键 D: 分区，选择“压缩卷”。
4. 在“输入压缩空间量（MB）”中输入 `153600`，表示 150 GiB（Windows 以 MiB 风格的 MB 数值进行该界面换算）。仅当界面报告的可压缩空间不少于该数值时才继续。
5. 单击“压缩”。等待操作结束，不要关机或拔盘。
6. 压缩完成后，D: 容量应减少约 150 GiB，D: 盘符和文件仍在。
7. 在磁盘管理中，D: 右侧应出现约 150 GiB 的黑色“未分配”空间，位置应在 D: 与原有恢复分区之间。
8. **保留这块空间为“未分配”。** 不要在 Windows 中把它新建为 NTFS 卷，不要格式化，不要删除 P5/WinRE 或 P6/DELLSUPPORT。
9. 再次确认 C:、D:、恢复分区依然可见，且 D: 中重要文件可以打开。
10. 重新启动一次 Windows，确认仍可正常进入，再关机。

如果“压缩卷”报告的可压缩空间明显少于预期，或者操作报错，不要改用删除恢复分区的方式“凑空间”。先停止、排查 NTFS 不可移动文件或选择更小的 Ubuntu 空间。

### 3.4 压缩后的目标布局

按原文记录、目标压缩 150 GiB 估算，布局大致如下：

```text
ACASIS EC-7351（GPT，约 1 TB）
├─ P1  Windows EFI System Partition（约 260 MiB）   不改动
├─ P2  Microsoft Reserved / MSR（16 MiB）           不改动
├─ P3  C: NTFS（约 200 GiB）                        不改动
├─ P4  D: NTFS（缩小约 150 GiB）                    只调整分区末端
├─     未分配空间（约 150 GiB）                     后续仅在这里安装 Ubuntu
├─ P5  Windows Recovery / WinRE（约 2 GiB）         不改动
└─ P6  DELLSUPPORT（约 1.41 GiB）                    不改动
```

不要使用原文中的硬编码 offset 作为现场判断依据。以 Windows“磁盘管理”和稍后的 Ubuntu `parted ... print free` 结果为准。

---

## 4. 制作 Ubuntu 安装 U 盘：保护现有数据的做法

### 4.1 先说明限制

Ubuntu 官方的标准 U 盘制作流程会覆盖安装介质的分区布局或写入镜像；Ubuntu 官方文档和 Rufus 都明确警告会破坏目标 U 盘上的现有数据。因此：

- **如果要求原有文件不受影响，推荐使用另一支空白 U 盘制作安装介质，并让原数据 U 盘全程不连接。** 这是本文采用的安全方案。
- 如果要求在同一支已有数据的 U 盘上直接制作启动盘，同时保证任何现有数据绝不改变，标准制作工具无法提供这种保证。不要把 Rufus、Etcher、Ventoy 安装或 `dd` 当作“保留原分区数据”的办法。
- 不要执行原文所述的 `03-make-usb.ps1`：该脚本没有出现在当前仓库中，无法审核它实际如何调整分区表。

这意味着，**本文不建议在唯一存有现有数据的 U 盘上直接制作启动盘**。如果手头只有一支存有数据的 U 盘，请先另备一支空白 U 盘；不要为了继续安装而赌数据风险。

### 4.2 下载 ISO 并校验

1. 在 Windows 中创建一个本地下载目录，例如 `C:\ISO\Ubuntu26.04.1`。
2. 打开 Ubuntu 官方 26.04.1 发布目录：<https://releases.ubuntu.com/26.04.1/>。
3. 下载官方桌面镜像 `ubuntu-26.04-desktop-amd64.iso`，以及同目录的 `SHA256SUMS`。不要把 ISO 直接下载到准备制作启动盘的 U 盘。
4. 将两个文件放在同一目录。以管理员或普通 PowerShell 执行以下校验命令（不写入 U 盘）：

```powershell
Set-Location 'C:\ISO\Ubuntu26.04.1'

$line = Select-String -Path '.\SHA256SUMS' -Pattern 'ubuntu-26\.04-desktop-amd64\.iso$' |
  Select-Object -First 1 -ExpandProperty Line
if (-not $line) {
  throw 'SHA256SUMS 中找不到 ubuntu-26.04-desktop-amd64.iso 条目。'
}

$expected = ($line -split '\s+')[0].ToLowerInvariant()
$actual = (Get-FileHash '.\ubuntu-26.04-desktop-amd64.iso' -Algorithm SHA256).Hash.ToLowerInvariant()

[pscustomobject]@{
  ExpectedSHA256 = $expected
  ActualSHA256   = $actual
  Match          = ($actual -eq $expected)
}

if ($actual -ne $expected) {
  throw 'ISO 的 SHA-256 与官方值不一致，请删除文件并重新下载。'
}
```

只有 `Match = True` 才继续。

### 4.3 用 Rufus 制作启动盘（只操作空白 U 盘）

1. 从 <https://rufus.ie/> 下载 Rufus。尽量使用官网提供的版本。
2. **拔下所有存有重要数据的 U 盘**，包括需要保持原样的数据 U 盘。只连接准备专门作为安装盘的空白 U 盘。
3. 打开 Rufus，确认 `Device` 显示的是这支空白 U 盘。按容量、型号和 Windows 磁盘管理中的设备再次核对。
4. `Boot selection` 选择 `ubuntu-26.04-desktop-amd64.iso`。
5. 对本机 UEFI 安装，选择 `GPT` 分区方案和 `UEFI (non CSM)` 目标系统（如果 Rufus 根据 ISO 自动设置了对应值，也应核对）。
6. 单击 `START`。Rufus 会警告目标设备上的数据将被删除；再次确认目标是空白安装 U 盘后才确认。
7. 如果出现 ISOHybrid 提示，按 Ubuntu 官方说明优先选择 `Write in ISO Image mode`。
8. 等待状态变为 `READY`，关闭 Rufus，再安全弹出 U 盘。
9. 重新插入 U 盘，检查文件和分区能正常读取。不要把它和数据 U 盘混淆。
10. 本方案先不放入 `autoinstall.yaml`，避免在验明目标磁盘前误触发无人值守安装。

> **数据保护的验证方式：** 制作过程中，存有原始数据的 U 盘一直处于拔出状态，因此 Rufus 不可能写到它。不要为了省一支 U 盘而更改这条原则。

---

## 5. 安装前现场验证：确认未分配空间在正确磁盘上

### 5.1 连接顺序

1. 完全关机。
2. 连接 ACASIS EC-7351 目标盘和刚制作好的 Ubuntu 安装 U 盘。
3. **暂时断开 E: 对应的 ST1000LM024 机械硬盘**，从物理上减少误选磁盘的机会。
4. 安装过程中不接入其他外置硬盘或 U 盘。
5. 通过 Dell 的 F12 一次性启动菜单启动 USB。Dell Inspiron 14 5410 系列文档说明，开机时按 F12 可以进入 One Time Boot Menu。参考：[Dell F12 启动菜单说明](https://www.dell.com/support/manuals/en-hk/inspiron-14-5410-2-in-1-laptop/inspiron-5410-2-in-1-service-manual/f12-one-time-boot-menu?guid=guid-71da763a-3f2f-4021-8ef7-3e50da009c74&lang=en-us)。

### 5.2 进入 Try Ubuntu，不启动安装

启动安装介质后，先选择 `Try Ubuntu` / 试用 Ubuntu。不要点击安装，不要打开分区编辑器后尝试写入更改。

打开终端执行只读检查：

```bash
lsblk -o NAME,PATH,SIZE,MODEL,SERIAL,TRAN,FSTYPE,LABEL,MOUNTPOINTS
```

根据上一步输出，人工确认 ACASIS 对应的设备路径，例如 `/dev/sdX`。这里的 `sdX` 是占位符，**必须换成现场确定的真实设备路径，不能照抄**。然后检查设备身份：

```bash
sudo udevadm info --query=property --name=/dev/sdX | grep -E 'ID_MODEL=|ID_SERIAL=|ID_VENDOR='
sudo parted /dev/sdX unit MiB print free
```

`parted ... print free` 是查看分区及空闲区的打印命令，不是在分区；不要输入 `mkpart`、`rm`、`mkfs` 等写操作。

**必须同时满足以下条件，才进入安装器：**

- 目标盘容量、型号/序列号与 Windows 预检记录一致。
- 目标盘显示 GPT 分区表。
- 可以看到 D: 对应分区之后、Windows 恢复分区之前的约 150 GiB 未分配区域。
- E: 机械硬盘没有连接、不会出现在 `lsblk` 输出中。
- 安装 U 盘能与目标盘明确区分。

任一条件不满足，立即退出试用环境并关机；不要凭设备名猜测。

---

## 6. Ubuntu 图形安装器手动分区步骤

### 6.1 选择安装方式

1. 从 Try Ubuntu 桌面启动安装器。
2. 选择正常安装流程。
3. 到达磁盘/安装类型页面时，选择 `Manual partitioning`、`Manual installation` 或等价的手动分区选项。不同 Ubuntu 安装器版本的文字可能略有不同。
4. **不要选择 `Erase disk and install Ubuntu`（清除磁盘并安装 Ubuntu）。** 不要选择自动安装到最大磁盘，不要使用原文中的 `autoinstall.yaml`。

### 6.2 只在约 150 GiB 的未分配区域创建分区

原文计划创建 512 MiB EFI、8 GiB swap 和剩余空间的 ext4 根分区，但原文偏移量有错误。手动安装无需指定这些绝对 offset。推荐采用更简单的方案：一个新的 Ubuntu EFI 分区，加一个根分区；让 Ubuntu 在根文件系统中使用默认 swapfile（交换文件）。这避免了不必要的 8 GiB 固定 swap 分区。

| 新分区 | 大小 | 文件系统/类型 | 挂载点 | 重要注意事项 |
|---|---:|---|---|---|
| Ubuntu EFI（ESP） | 512 MiB | FAT32，类型为 EFI System Partition | `/boot/efi`（如果界面要求填写挂载点） | 必须是未分配空间中新建的 ESP；不要格式化 Windows 原有 P1 EFI 分区 |
| Ubuntu 根分区 | 未分配空间的其余部分（约 149.5 GiB） | ext4 | `/` | 只格式化这个新建的根分区 |

如果界面明确要求单独 swap 分区，才考虑创建约 8 GiB 的 swap，根分区使用剩余空间。普通桌面使用可以先采用默认 swapfile；如果计划使用休眠功能，swap 容量和配置需要另行规划，不要直接套用 8 GiB。

具体操作：

1. 在分区列表中确认目标设备是 ACASIS 盘，而不是安装 U 盘。
2. 选中约 150 GiB 的 `free space` / 未分配空间，单击新增分区。
3. 创建 512 MiB 分区，格式为 FAT32，并将分区类型设为 `EFI System Partition`。如果安装器要求挂载点，设置为 `/boot/efi`。
4. 再选中剩余未分配空间，创建 ext4 分区，挂载点为 `/`。
5. 检查格式化标记：新 Ubuntu 根分区需要格式化；新 Ubuntu EFI 分区可以由安装器初始化。Windows 原有分区都必须保持不格式化。
6. 对照分区列表，确认 C:、D:、Windows EFI、MSR、WinRE、DELLSUPPORT 都仍存在，且没有被勾选格式化或删除。
7. 如果安装器提供单独的引导安装设备选项，选择整块 ACASIS 目标盘，而不是安装 U 盘或不存在的分区。若界面没有这个选项，不要臆造设置；重点是新 Ubuntu ESP 已正确创建并挂载。
8. 在最终摘要页再次检查：只有新建的 Ubuntu 分区会被格式化，没有任何 Windows 分区或 E: 数据盘被标为删除/格式化。
9. 只在上述检查全部通过后，才确认安装。

### 6.3 为什么建议使用单独的 Ubuntu ESP

目标盘上原本已有 Windows EFI 分区。很多双系统安装会复用原 EFI 分区，但本方案的优先目标是尽量不改动 Windows 启动文件。因此，若安装器支持在新腾出的空间内创建独立 ESP，就将 Ubuntu 启动文件放到这个新 ESP；绝不能把 Windows ESP 选成需要格式化的分区。

这仍然会写入新分区和固件启动项，也无法消除所有启动风险，但可以减少对现有 Windows EFI 文件的直接修改。安装完成后必须实际验证 Windows 仍可从 F12 菜单启动。

---

## 7. 安装后的验证

### 7.1 第一次启动

1. 安装完成后关机。
2. 拔掉 Ubuntu 安装 U 盘。
3. 保持 E: 机械硬盘仍然断开。
4. 开机按 F12，选择 `ubuntu` 或对应的 ACASIS UEFI 启动项。
5. 进入 Ubuntu 后，打开终端检查：

```bash
lsblk -f
findmnt -no SOURCE,FSTYPE,TARGET /
sudo efibootmgr -v
```

确认：

- 根目录 `/` 来自 ACASIS 盘中新建的 ext4 分区。
- 新 Ubuntu EFI 分区存在，且挂载关系符合安装时的选择。
- 固件启动项中存在 Ubuntu 项（名称可能因固件而异）。

### 7.2 验证 Windows 与旧数据

1. 重启按 F12，选择 `Windows Boot Manager`，确认 Windows 11 能正常启动。
2. 进入 Windows 后确认 C:、D: 正常，D: 容量按预期减少约 150 GiB，文件可读取。
3. 打开磁盘管理，确认 P1 Windows EFI、P2 MSR、C:、压缩后的 D:、P5 WinRE、P6 DELLSUPPORT 均仍存在。
4. 关机后重新接回 E: 机械硬盘。启动 Windows，确认 E: 盘符和文件正常。
5. 再次重启，分别测试 Ubuntu 和 Windows 的启动入口。

如果 GRUB 菜单没有列出 Windows，不要立刻执行网上找到的修复命令；先用 F12 的 `Windows Boot Manager` 测试 Windows 是否仍能启动。能够从 F12 独立启动 Windows，说明至少 Windows 的启动路径仍然可用，可以再分析 GRUB 菜单问题。

---

## 8. 安全停止条件与禁止操作

出现以下任何一种情况都应停止，不要继续安装：

- Windows 预检中无法唯一识别 ACASIS 目标盘。
- D: 不在预期磁盘上，或者可压缩空间不足。
- 压缩后未分配空间没有出现在 D: 与恢复分区之间。
- Try Ubuntu 环境中目标盘型号/序列号与 Windows 记录不一致。
- 看到的未分配空间大小明显不符，或者 E: 机械盘仍连接且无法确定目标设备。
- 安装器的最终摘要准备删除整块磁盘、格式化 C:/D:、Windows EFI、WinRE 或 DELLSUPPORT。
- 安装器要求更改分区表，而操作结果无法解释清楚。

严禁在本方案中执行以下操作：

- 对 ACASIS 盘或任何数据盘运行 `diskpart clean`。
- 使用 `dd`、`wipefs`、`mkfs` 等命令写入或格式化未能唯一确认的设备。
- 删除 P5/WinRE 或 P6/DELLSUPPORT 来腾空间。
- 在包含唯一数据副本的 U 盘上使用 Rufus、Etcher、Ventoy 安装或镜像写入工具。
- 使用原文未提供、未审核的 `03-make-usb.ps1`、`render-autoinstall.ps1` 或 `autoinstall.yaml`。
- 把固定的 `/dev/sda`、`/dev/sdb`、Windows Disk 0 或分区编号当作跨重启不变的设备标识。

---

## 9. 原文涉及内容的推荐修正

| 原文位置/主张 | 建议修正 |
|---|---|
| `SizeMax` 用于计算可压缩量 | 改为根据当前大小和 `SizeMin` 计算可压缩量，并以 Windows“压缩卷”界面实际显示值为准 |
| 手写 P7/P8/P9 的 offset | 删除硬编码偏移量。采用图形安装器在未分配空间内创建分区；如要保留自动安装，则先重新校验完整 Curtin v2 配置，在测试盘验证后才可使用 |
| “偏移量不匹配即安全中止” | 删除该安全承诺。Curtin v2 对未引用分区的处理可能是删除；配置错配不能视为无害 |
| U 盘根目录和 CIDATA 双路投递 | 当前没有脚本，不能确认实际文件格式、投放顺序和触发行为；先移除无人值守方案，改用普通图形安装器 |
| 通过重新分区同一 U 盘保留旧文件 | 不承诺同盘无损。改用空白安装 U 盘，并将数据 U 盘物理拔出 |
| ISO 目标文件名 `ubuntu-26.04.1-desktop-amd64.iso` | 按官方 26.04.1 发布目录下载并校验 `ubuntu-26.04-desktop-amd64.iso` |
| Secure Boot 必须关闭 | 不将其作为默认要求。保留当前固件设置，只有遇到可复现的兼容性错误时再单独判断 |

---

## 10. 参考资料

1. [被审查的 GitHub 文档](https://github.com/wayyet/setting_Install/blob/main/%E5%9C%A8%20Dell%20Inspiron%2014%205410%20%E4%B8%8A%E6%90%AD%E5%BB%BA%20Windows%2011%20%2B%20Ubuntu%2026.04.1%20LTS%20%E5%8F%8C%E7%B3%BB%E7%BB%9F.md)
2. [Ubuntu 26.04.1 官方发布目录与 SHA256SUMS](https://releases.ubuntu.com/26.04.1/)
3. [Ubuntu 26.04：制作启动 U 盘](https://ubuntu.com/desktop/docs/en/26.04/how-to/create-a-bootable-usb-stick/)
4. [Ubuntu Desktop 安装说明](https://ubuntu.com/desktop/docs/en/latest/tutorial/install-ubuntu-desktop/)
5. [Subiquity Autoinstall 配置参考](https://canonical-subiquity.readthedocs-hosted.com/en/latest/reference/autoinstall-reference.html)
6. [如何向安装器提供 Autoinstall 配置](https://canonical-subiquity.readthedocs-hosted.com/en/latest/tutorial/providing-autoinstall.html)
7. [Curtin Storage 配置说明](https://curtin.readthedocs.io/en/latest/topics/storage.html)
8. [Microsoft：Get-PartitionSupportedSize](https://learn.microsoft.com/en-us/powershell/module/storage/get-partitionsupportedsize?view=windowsserver2025-ps)
9. [Microsoft：Windows SHRINK 命令](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/shrink)
10. [Dell Inspiron 14 5410：F12 一次性启动菜单](https://www.dell.com/support/manuals/en-hk/inspiron-14-5410-2-in-1-laptop/inspiron-5410-2-in-1-service-manual/f12-one-time-boot-menu?guid=guid-71da763a-3f2f-4021-8ef7-3e50da009c74&lang=en-us)
11. [Rufus 官方网站](https://rufus.ie/)

> 本文是对原文及公开官方技术文档的审查和操作建议，不等于对某台实际机器、某块 SSD 或某支 U 盘的现场检测。实际设备信息与本文假设不一致时，以现场只读检查结果为准，并停止套用旧的磁盘编号或偏移量。
