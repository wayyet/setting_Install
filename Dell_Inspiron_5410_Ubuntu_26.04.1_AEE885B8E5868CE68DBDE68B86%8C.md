# Dell Inspiron 14 5410：Windows 11 + Ubuntu 26.04.1 LTS 双系统安装与分区操作手册

> 文档核对日期：2026-10-14  
> 适用场景：保留现有 Windows 11，在 ACASIS EC-7351 系统盘的 D: 末端腾出未分配空间安装 Ubuntu；机械硬盘 E: 不参与安装。  
> **推荐流程：先备份 → 下载并校验 ISO → 用 Rufus 制作专用安装 U 盘 → 在 Windows 中压缩 D: → 从 U 盘试运行 Ubuntu → 使用图形安装器手动分区。**

## 0. 重要结论

**不要直接执行第一份文档的无人值守安装流程，也不要运行原文提到的 `03-make-usb.ps1`。** 第二份审查文档列出了自动分区配置与偏移量的高风险问题；仓库检索也未找到 `03-make-usb.ps1` 和 `01-shrink-D-drive.ps1` 的可审核实现。因此，不能声称这些脚本已验证有效。

本手册改用更易检查的做法：

1. Rufus 只把 Ubuntu ISO 写入一支专用空白 U 盘。
2. 在 Windows 中仅压缩 D:，不删除分区，也不在腾出的空间中新建 NTFS 卷。
3. 安装 Ubuntu 时选择手动分区，只在约 150 GiB 未分配空间中新建 Ubuntu EFI 分区和 ext4 根分区。
4. 安装前尽可能物理断开机械硬盘 E:，降低选错磁盘的风险。

分区操作仍有数据损坏和误选磁盘的风险。开始前将重要文件备份到另一块物理设备，并确认备份中的文件能够打开。不能承诺零风险。

## 1. 两份 GitHub 文档的核查结果

### 1.1 第一份：双系统安装方案

原文链接：

[在 Dell Inspiron 14 5410 上搭建 Windows 11 + Ubuntu 26.04.1 LTS 双系统](https://github.com/wayyet/setting_Install/blob/main/%E5%9C%A8%20Dell%20Inspiron%2014%205410%20%E4%B8%8A%E6%90%AD%E5%BB%BA%20Windows%2011%20%2B%20Ubuntu%2026.04.1%20LTS%20%E5%8F%8C%E7%B3%BB%E7%BB%9F.md)

原文的目标布局是：磁盘 0 为 ACASIS EC-7351 系统盘，分区依次为 EFI、MSR、C:、D:、WinRE、DELLSUPPORT；通过压缩 D: 腾出空间；机械硬盘 E: 不改动。

这个总体方向合理，但不建议采用原文自动分区配置，原因如下：

| 问题 | 核查结果 | 处理方式 |
|---|---|---|
| `autoinstall.yaml` 的存储配置版本 | 原文示例未明确声明与 `offset` 相匹配的 `storage.version: 2`；分区配置版本不同，字段语义可能不同 | 不使用原 YAML |
| `preserve: true` 的安全性 | 它不能保证所有错误都会安全中止。若现有分区没有被新配置正确声明，安装器可能改写或删除未匹配分区 | 不将它当作防误删保险 |
| P7/P8/P9 的手工偏移量 | 原文 P7 结束位置为 `836052713472`，P8 起点却为 `836488713472`，两者相差 `436000000` 字节；审查文档还指出 P8/P9 偏移量不满足 512 字节扇区对齐 | 不手算或硬编码 Ubuntu 新分区 offset |
| U 盘制作脚本 | 原文引用 `03-make-usb.ps1`，但第二份审查文档说明该文件不在当前仓库中；无法审阅其分区、格式化和写盘行为 | 用 Rufus 对空白 U 盘制作标准安装介质 |
| D: 压缩脚本 | 原文提到 `01-shrink-D-drive.ps1`，但仓库中未找到可审核的脚本实现 | 使用本手册提供的严格检查版 PowerShell 脚本，或使用 Windows“磁盘管理”手动压缩 |

另外，原文对 `Get-PartitionSupportedSize` 可压缩量的说明容易混淆。正确的计算方式是：

```powershell
$maxShrinkBytes = $currentSize - $supported.SizeMin
```

`SizeMin` 是 Windows 报告的分区最小支持大小；当前分区大小减去 `SizeMin` 才是理论可压缩量。不要用 `SizeMax - 当前大小` 计算压缩空间，因为它表达的是扩展方向的余量。

### 1.2 第二份：安装方案审查与安全操作手册

审查文档：

[Dell_Inspiron_5410_Windows11_Ubuntu26.04.1.md](https://github.com/wayyet/setting_Install/blob/main/Dell_Inspiron_5410_Windows11_Ubuntu26.04.1.md)

第二份文档的风险判断基本合理，本手册采纳以下建议：

- 先在 Windows 中核对目标盘、D: 所属磁盘、分区布局、BitLocker 状态和可压缩容量。
- 使用空白 U 盘；Rufus 会覆盖目标 U 盘的分区布局或数据。
- 压缩 D: 后，将新增区域保留为“未分配”。不要先格式化成 NTFS。
- Ubuntu 安装时选择 `Try Ubuntu` 试运行，确认磁盘型号、序列号和未分配区域都正确后再安装。
- 选择手动分区。只格式化新建的 Ubuntu 根分区；不得格式化 Windows EFI、C:、D:、WinRE 或 DELLSUPPORT。
- 安装后分别验证 Ubuntu、Windows Boot Manager 和 E: 数据盘。

**注意：** 本手册中的 PowerShell 脚本按文档所描述的 ACASIS EC-7351 六分区布局编写，带有严格的中止条件。它没有在你的实际机器上运行过，也不能替代现场核对。若机器当前布局与文档不同，脚本会主动拒绝执行。

## 2. 需要下载哪些文件

### 2.1 Ubuntu 桌面安装 ISO

官方发布目录：

https://releases.ubuntu.com/26.04.1/

下载以下两个文件即可：

| 文件 | 直接下载链接 | 用途 |
|---|---|---|
| Ubuntu Desktop AMD64 ISO | [ubuntu-26.04.1-desktop-amd64.iso](https://releases.ubuntu.com/26.04.1/ubuntu-26.04.1-desktop-amd64.iso) | Ubuntu 桌面安装镜像，约 6.1 GB |
| 官方校验和清单 | [SHA256SUMS](https://releases.ubuntu.com/26.04.1/SHA256SUMS) | 验证 ISO 下载完整且与官方文件一致 |
| 可选：校验和签名 | [SHA256SUMS.gpg](https://releases.ubuntu.com/26.04.1/SHA256SUMS.gpg) | 进一步验证校验和清单的签名；普通操作可先使用 SHA256 比对 |

**文件名核对：官方 `SHA256SUMS` 同时列出了 `ubuntu-26.04-desktop-amd64.iso` 和 `ubuntu-26.04.1-desktop-amd64.iso`，两者校验值不同。由于本次目标明确是 26.04.1，建议下载带 `.1` 的镜像，并只与校验文件里同名的 `.1` 条目比对。官方校验值为 `601e30fbf5d97759367c632e2c33630665039b7e2158fd068403da3ccf1bda1f`。发布目录的可见文件列表和 `SHA256SUMS` 呈现的信息不完全一致，因此这里优先采用校验清单中明确标注的 26.04.1 文件名。

Dell Inspiron 14 5410 使用 Intel x86-64 处理器，应选 **AMD64 desktop image**。这里的 AMD64 是 x86-64 架构名称，并不代表电脑必须使用 AMD 品牌 CPU。不要下载 Server ISO 或 WSL image。

建议把 ISO 和校验文件保存到电脑本地磁盘，例如：

```text
C:\ISO\Ubuntu26.04.1\ubuntu-26.04.1-desktop-amd64.iso
C:\ISO\Ubuntu26.04.1\SHA256SUMS
```

不要先把 ISO 下载到准备制作启动盘的 U 盘。

### 2.2 Rufus

Rufus 官网（简体中文）：

https://rufus.ie/zh/

当前官网列出的版本为 4.15（2026-06-30）。Windows 11 x64 电脑推荐下载标准版：

- **推荐，标准版 x64：** [rufus-4.15.exe](https://github.com/pbatard/rufus/releases/download/v4.15/rufus-4.15.exe)
- 可选，便携版 x64： [rufus-4.15p.exe](https://github.com/pbatard/rufus/releases/download/v4.15/rufus-4.15p.exe)
- 如果确认当前 Windows 是 ARM64，而非普通 Intel/AMD x64，才使用 [rufus-4.15_arm64.exe](https://github.com/pbatard/rufus/releases/download/v4.15/rufus-4.15_arm64.exe)。

Rufus 是免安装程序。建议从 Rufus 官网进入下载，不要从不明软件下载站获取。

## 3. 校验 Ubuntu ISO

打开普通 PowerShell 即可，不需要管理员权限。执行：

```powershell
Set-Location 'C:\ISO\Ubuntu26.04.1'

$line = Select-String -Path '.\SHA256SUMS' -Pattern 'ubuntu-26\.04\.1-desktop-amd64\.iso$' |
    Select-Object -First 1 -ExpandProperty Line

if (-not $line) {
    throw 'SHA256SUMS 中找不到 ubuntu-26.04.1-desktop-amd64.iso 条目。请确认下载的是同一发布目录的校验文件。'
}

$expected = ($line -split '\s+')[0].ToLowerInvariant()
$actual = (Get-FileHash '.\ubuntu-26.04.1-desktop-amd64.iso' -Algorithm SHA256).Hash.ToLowerInvariant()

[pscustomobject]@{
    ExpectedSHA256 = $expected
    ActualSHA256   = $actual
    Match          = ($actual -eq $expected)
}

if ($actual -ne $expected) {
    throw 'ISO 的 SHA-256 与官方值不一致。不要制作启动盘；删除 ISO 后从官方地址重新下载并再次校验。'
}
```

只有显示 `Match = True` 才继续。若校验失败，不要忽略，也不要用该 ISO 制作启动盘。

## 4. 用 Rufus 制作 Ubuntu 安装 U 盘

### 4.1 开始前

1. 准备一支**空白、专门用于安装的 U 盘**，建议容量至少 16 GB。
2. 先把 U 盘中的文件备份。Rufus 写入镜像会覆盖目标 U 盘上的数据；不要假设它会保留原有文件。
3. 将其他存有重要数据的 U 盘全部拔下，尤其是唯一保存资料的 U 盘。
4. 在 Windows 中确认这支空白 U 盘的容量、型号和盘符。不要只凭盘符判断设备身份。
5. 下载并校验 ISO 后，再启动 Rufus。

### 4.2 Rufus 设置

1. 双击运行 `rufus-4.15.exe`。
2. 在 **Device（设备）** 中，确认选择的是专用空白 U 盘。再次核对容量和设备；选择错设备可能导致数据丢失。
3. 在 **Boot selection（引导类型选择）** 中点击“选择”，选中：

   `C:\ISO\Ubuntu26.04.1\ubuntu-26.04.1-desktop-amd64.iso`

4. 对 UEFI + GPT 安装，确认：
   - **Partition scheme（分区方案）：** `GPT`
   - **Target system（目标系统）：** `UEFI (non CSM)`
   - 其他文件系统和格式化选项优先保留 Rufus 根据 ISO 给出的默认值，不要为了追求 FAT32 而手工强制修改。
5. 点击 **START（开始）**。
6. 如果弹出数据将被删除的警告，再次核对设备，确认确实是空白安装 U 盘后才继续。
7. 如果出现 ISOHybrid 模式提示，优先选择 **Write in ISO Image mode（以 ISO 镜像模式写入）**。
8. 等待状态显示 `READY`，关闭 Rufus。
9. 使用 Windows“安全删除硬件”弹出 U 盘，再插回或准备启动。

### 4.3 制作完成后不要做的事

- 不要再运行原文中无法审核的 `03-make-usb.ps1`。
- 不需要额外创建 `CIDATA` 分区。
- 不需要把 `autoinstall.yaml` 放到 U 盘根目录。
- 不要使用无人值守 Autoinstall 自动分区方案。
- 不要在原有数据 U 盘上运行 Rufus。

这里制作的是标准 Ubuntu 安装介质。实际安装过程由你在图形安装器中逐步确认。

## 5. 在 Windows 中给 D: 腾出未分配空间

### 5.1 操作前检查

1. 备份 C:、D: 以及其他重要数据，并确认备份可读。
2. 接通电源；关闭正在大量读写 D: 的程序；不要在操作过程中拔掉 ACASIS 硬盘盒或强制关机。
3. 打开管理员 PowerShell，执行以下只读命令，记录实际磁盘编号、型号、序列号和 D: 所在磁盘：

```powershell
Get-Disk |
    Sort-Object Number |
    Format-Table Number, FriendlyName, SerialNumber, UniqueId, BusType, PartitionStyle, OperationalStatus, IsBoot, IsSystem, Size -AutoSize

$d = Get-Partition -DriveLetter D
$d | Format-List DiskNumber, PartitionNumber, DriveLetter, Offset, Size, Type, GptType
Get-Volume -DriveLetter D | Format-List DriveLetter, FileSystem, FileSystemLabel, Size, SizeRemaining

$supported = Get-PartitionSupportedSize -DriveLetter D
$supported | Format-List SizeMin, SizeMax
$currentSize = (Get-Partition -DriveLetter D).Size
$maxShrinkBytes = $currentSize - $supported.SizeMin
[pscustomobject]@{
    CurrentGiB   = [math]::Round($currentSize / 1GB, 2)
    MaxShrinkGiB = [math]::Round($maxShrinkBytes / 1GB, 2)
}

manage-bde -status
```

4. 核对 D: 的 `DiskNumber` 对应 `ACASIS EC-7351` 系统盘，而不是机械硬盘 E: 或安装 U 盘。
5. 按本机记录，目标磁盘应为 GPT，D: 是 P4，后方 P5/P6 是 Windows Recovery / DELLSUPPORT。若现场与此不一致，先停止，不要套用旧的分区编号或 offset。
6. 检查 BitLocker 状态和恢复密钥。脚本在目标系统盘任一带盘符卷的保护状态为 `On` 时会中止。
7. 如果无法确认目标盘型号、D: 所属磁盘或备份状态，不要继续。

### 5.2 推荐用法：先预检脚本，再压缩

本手册提供一个单独脚本：

[下载 Shrink-DDriveForUbuntu.ps1](Shrink-DDriveForUbuntu.ps1)

把 `.ps1` 文件放在你可以写入的本地目录，例如桌面。使用**管理员身份**打开 Windows PowerShell，切换到该目录。先运行预检，不会调整分区：

```powershell
Set-Location "$env:USERPROFILE\Desktop"
.\Shrink-DDriveForUbuntu.ps1 -Preview
```

确认输出中的磁盘型号、序列号、D: 容量、最大可压缩量和目标大小都符合预期。默认目标是压缩 150 GiB。如果可压缩量不足，脚本会中止，不会自动改成更小的值。

预检完全符合预期后，再运行正式操作：

```powershell
.\Shrink-DDriveForUbuntu.ps1
```

脚本会要求你输入 `SHRINK D` 才执行 `Resize-Partition`。不要用脚本去创建、格式化或删除任何分区。

脚本会保存压缩前和压缩后的 JSON 分区快照，并检查：

- D: 的大小减少约指定容量；
- 新的未分配空间位于 D: 与 P5/WinRE 之间；
- P5、P6 的起始位置和大小未变化。

**重要限制：** 此脚本依据文档中记录的机器布局设置了严格门槛。如果它因为型号、分区数量、编号、恢复分区类型、BitLocker 或可压缩量问题中止，不要通过删除校验条件来强行运行。先重新检查实际布局。

### 5.3 替代方式：Windows 磁盘管理

如果不希望使用脚本，也可以使用 Windows 自带磁盘管理。它比执行未经审核的自动化脚本更直观：

1. 按 `Win + X`，打开“磁盘管理”（`diskmgmt.msc`）。
2. 根据型号、容量、C:、D: 和恢复分区的相对位置，确认是 ACASIS 目标磁盘。
3. 右键 D:，选择“压缩卷”。
4. 在“输入压缩空间量（MB）”中输入 `153600`，约为 150 GiB。只有在界面报告的可压缩空间不少于该数值时才继续。
5. 点击“压缩”，等待完成；不要拔盘、断电或强制关机。
6. 确认 D: 仍有盘符、文件可读、容量减少约 150 GiB。
7. 在 D: 右侧出现约 150 GiB 的黑色“未分配”空间。此空间应在 D: 与原有 WinRE/DELLSUPPORT 分区之间。
8. **保留为未分配空间**。不要在 Windows 中新建 NTFS 卷，不要格式化，不要删除 P5/WinRE 或 P6/DELLSUPPORT。
9. 重新启动 Windows 一次，确认能够正常进入且 D: 文件仍可打开。

如果磁盘管理显示的可压缩空间不足，不要删除恢复分区来凑空间。先检查不可移动文件或改用更小的 Ubuntu 空间。

## 6. 最终 D: 压缩脚本

以下是独立文件 `Shrink-DDriveForUbuntu.ps1` 的完整内容。建议优先下载并运行上面的 `.ps1` 文件，避免复制时破坏格式。

```powershell
#requires -RunAsAdministrator
<#
.SYNOPSIS
  在指定的 Windows NTFS D: 分区末端腾出未分配空间，供后续 Ubuntu 安装使用。
.DESCRIPTION
  默认只压缩 150 GiB。脚本不会创建、格式化或删除任何分区。
  为避免误操作，脚本会严格检查磁盘型号、系统盘身份、GPT、D: 分区号、
  后方两个恢复分区及 BitLocker 状态。任何检查不符合预期都会中止。
  建议先使用 -Preview 预检，再不带 -Preview 执行；正式执行前必须输入确认字符串。
.NOTES
  需在 Windows PowerShell 5.1 / Windows 11 管理员会话中运行。
  这是针对文档所述 ACASIS EC-7351 布局的保守脚本，不是在实际电脑上执行过的脚本。
#>

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z]$')]
    [string]$DriveLetter = 'D',

    [ValidateRange(60, 500)]
    [int]$TargetGiB = 150,

    [string]$ExpectedDiskNamePattern = '*ACASIS*EC-7351*',

    [switch]$Preview
)

$ErrorActionPreference = 'Stop'
$DriveLetter = $DriveLetter.ToUpperInvariant()
$TargetBytes = [int64]$TargetGiB * 1GB
$RecoveryGptGuid = 'de94bba4-06d1-4d40-a16a-bfd50179d6ac'

function Get-NormalizedGuid {
    param([Parameter(Mandatory = $false)]$Value)
    if ($null -eq $Value) { return '' }
    return ([string]$Value).Replace('{', '').Replace('}', '').ToLowerInvariant()
}

function Save-LayoutSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$DiskInfo,
        [Parameter(Mandatory = $true)]$PartitionInfo
    )
    $snapshot = [ordered]@{
        CapturedAt = (Get-Date).ToString('o')
        Disk = [ordered]@{
            Number = $DiskInfo.Number
            FriendlyName = $DiskInfo.FriendlyName
            SerialNumber = $DiskInfo.SerialNumber
            UniqueId = $DiskInfo.UniqueId
            SizeBytes = [int64]$DiskInfo.Size
            PartitionStyle = [string]$DiskInfo.PartitionStyle
            IsBoot = [bool]$DiskInfo.IsBoot
            IsSystem = [bool]$DiskInfo.IsSystem
        }
        Partitions = @(
            $PartitionInfo | Select-Object PartitionNumber, DriveLetter, Offset, Size, Type, GptType
        )
    }
    $snapshot | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
}

# 1. 管理员权限与必需模块
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw '请使用“以管理员身份运行”的 Windows PowerShell。未更改任何分区。'
}

Import-Module Storage -ErrorAction Stop
if (-not (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
    throw '无法检查 BitLocker 状态。请先运行 manage-bde -status 并确认目标系统盘各卷的保护状态已关闭，再使用具备 BitLocker cmdlet 的管理员 PowerShell。未更改任何分区。'
}

# 2. 通过盘符查找 D: 所在的真实磁盘，不写死 DiskNumber
$dPartitions = @(Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop)
if ($dPartitions.Count -ne 1) {
    throw "无法唯一确定 $DriveLetter`: 分区。未更改任何分区。"
}
$d = $dPartitions[0]
$disk = Get-Disk -Number $d.DiskNumber -ErrorAction Stop

if ($disk.FriendlyName -notlike $ExpectedDiskNamePattern) {
    throw "目标磁盘型号校验失败。实际 FriendlyName='$($disk.FriendlyName)'；预期匹配模式='$ExpectedDiskNamePattern'。请先核实 Get-Disk 输出。不要直接放宽检查。未更改任何分区。"
}
if ([string]$disk.PartitionStyle -ne 'GPT') {
    throw "目标磁盘不是 GPT 分区表（实际：$($disk.PartitionStyle)）。未更改任何分区。"
}
if (-not $disk.IsBoot -or -not $disk.IsSystem) {
    throw "目标磁盘未同时被 Windows 识别为当前启动/系统磁盘（IsBoot=$($disk.IsBoot), IsSystem=$($disk.IsSystem)）。为避免误操作，脚本中止。未更改任何分区。"
}
if ([int]$d.PartitionNumber -ne 4) {
    throw "D: 当前是分区 $($d.PartitionNumber)，而不是已审核布局中的第 4 分区。磁盘布局已变化；未更改任何分区。"
}

$volume = Get-Volume -DriveLetter $DriveLetter -ErrorAction Stop
if ([string]$volume.FileSystem -ne 'NTFS') {
    throw "$DriveLetter`: 文件系统不是 NTFS（实际：$($volume.FileSystem)）。未更改任何分区。"
}

# 3. 检查 D: 后方的 P5/P6 是预期恢复分区，而且当前 D: 与 P5 紧邻。
$allPartitions = @(Get-Partition -DiskNumber $disk.Number | Sort-Object PartitionNumber)
if ($allPartitions.Count -ne 6) {
    throw "目标磁盘当前有 $($allPartitions.Count) 个分区，而已审核布局应有 6 个（P1-P6）。未更改任何分区。"
}
$actualNumbers = @($allPartitions | ForEach-Object { [int]$_.PartitionNumber })
if (($actualNumbers -join ',') -ne '1,2,3,4,5,6') {
    throw '目标磁盘分区编号不是连续的 P1-P6。未更改任何分区。'
}
$p3 = $allPartitions | Where-Object { $_.PartitionNumber -eq 3 } | Select-Object -First 1
if ([string]$p3.DriveLetter -ne 'C') {
    throw '已审核布局要求目标盘 P3 为 C:。当前布局不匹配，未更改任何分区。'
}
$following = @($allPartitions | Where-Object { $_.PartitionNumber -gt $d.PartitionNumber })
if ($following.Count -ne 2 -or $following[0].PartitionNumber -ne 5 -or $following[1].PartitionNumber -ne 6) {
    throw 'D: 后方分区数量或编号与已审核布局不同（预期只有 P5、P6）。未更改任何分区。'
}
$p5 = $following[0]
$p6 = $following[1]
if ((Get-NormalizedGuid $p5.GptType) -ne $RecoveryGptGuid -or
    (Get-NormalizedGuid $p6.GptType) -ne $RecoveryGptGuid) {
    throw 'P5/P6 的 GPT 类型不是预期的 Windows Recovery 类型。未更改任何分区。'
}

$dEndBefore = [int64]$d.Offset + [int64]$d.Size
if ([int64]$p5.Offset -ne $dEndBefore) {
    throw 'D: 与 P5 之间已经存在未分配空间，或分区布局与预期不同。为防止重复压缩，脚本中止。未更改任何分区。'
}
if ([int64]$p6.Offset -ne ([int64]$p5.Offset + [int64]$p5.Size)) {
    throw 'P5 与 P6 不是连续布局。未更改任何分区。'
}

# 4. 检查目标系统盘上有盘符的卷的 BitLocker 保护状态
$targetLetters = @(
    $allPartitions |
        Where-Object { $_.DriveLetter } |
        ForEach-Object { ([string]$_.DriveLetter).TrimEnd(':').ToUpperInvariant() } |
        Sort-Object -Unique
)
foreach ($letter in $targetLetters) {
    $bl = Get-BitLockerVolume -MountPoint ("{0}:" -f $letter) -ErrorAction Stop
    if ([string]$bl.ProtectionStatus -eq 'On') {
        throw "目标磁盘上的 $letter`: 卷 BitLocker 保护状态为 On。请先确认恢复密钥与保护状态；脚本中止，未更改任何分区。"
    }
}

# 5. 正确计算可压缩量：当前分区大小 - SizeMin（不是 SizeMax - 当前大小）
$supported = Get-PartitionSupportedSize -DriveLetter $DriveLetter -ErrorAction Stop
$currentSize = [int64]$d.Size
$minimumSize = [int64]$supported.SizeMin
$maxShrinkBytes = $currentSize - $minimumSize
if ($maxShrinkBytes -lt $TargetBytes) {
    $maxShrinkGiB = [math]::Round($maxShrinkBytes / 1GB, 2)
    throw "可压缩量不足。要求 $TargetGiB GiB；Windows 报告最多约 $maxShrinkGiB GiB。脚本不会自动缩小目标值。未更改任何分区。"
}
$newSize = $currentSize - $TargetBytes
if ($newSize -lt $minimumSize) {
    throw '计算出的目标分区大小小于 Windows 报告的 SizeMin。未更改任何分区。'
}

$currentGiB = [math]::Round($currentSize / 1GB, 2)
$newGiB = [math]::Round($newSize / 1GB, 2)
$targetDiskSummary = [pscustomobject]@{
    DiskNumber = $disk.Number
    FriendlyName = $disk.FriendlyName
    SerialNumber = $disk.SerialNumber
    UniqueId = $disk.UniqueId
    PartitionNumber = $d.PartitionNumber
    DriveLetter = "$DriveLetter`:\"
    CurrentSizeGiB = $currentGiB
    TargetSizeGiB = $newGiB
    RequestedUnallocatedGiB = $TargetGiB
    MaximumShrinkGiB = [math]::Round($maxShrinkBytes / 1GB, 2)
    P5RecoveryOffset = [int64]$p5.Offset
    P6RecoveryOffset = [int64]$p6.Offset
}
$targetDiskSummary | Format-List | Out-String | Write-Host

if ($Preview) {
    Write-Host '预检完成：Preview 模式没有更改任何分区。确认磁盘型号、D: 和容量均正确后，才可再次运行且不带 -Preview。' -ForegroundColor Yellow
    return
}

# 6. 执行前二次确认
$confirmation = Read-Host "将压缩 $DriveLetter`: 约 $TargetGiB GiB。确认目标无误后，请准确输入 SHRINK $DriveLetter"
if ($confirmation -cne "SHRINK $DriveLetter") {
    throw '确认字符串不匹配。脚本未调用 Resize-Partition。'
}

# 保存调整前快照，便于事后比对
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$beforePath = Join-Path $PSScriptRoot "partition-before-$stamp.json"
$afterPath = Join-Path $PSScriptRoot "partition-after-$stamp.json"
Save-LayoutSnapshot -Path $beforePath -DiskInfo $disk -PartitionInfo $allPartitions
Write-Host "已保存调整前分区快照：$beforePath"

# 7. 只缩小 D:；不创建/格式化/删除任何分区
Resize-Partition -DriveLetter $DriveLetter -Size $newSize -ErrorAction Stop

# 8. 重新读取现场数据并验证未分配空间出现在 D: 与 P5 之间
$afterD = Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop
$afterParts = @(Get-Partition -DiskNumber $disk.Number | Sort-Object PartitionNumber)
$afterP5 = $afterParts | Where-Object { $_.PartitionNumber -eq 5 } | Select-Object -First 1
$afterP6 = $afterParts | Where-Object { $_.PartitionNumber -eq 6 } | Select-Object -First 1
if ($null -eq $afterP5 -or $null -eq $afterP6) {
    throw "压缩命令已返回，但无法重新读取 P5/P6。请立即打开磁盘管理检查，不要继续安装 Ubuntu。调整前快照：$beforePath"
}
$actualShrinkBytes = $currentSize - [int64]$afterD.Size
$actualUnallocatedBytes = [int64]$afterP5.Offset - ([int64]$afterD.Offset + [int64]$afterD.Size)
Save-LayoutSnapshot -Path $afterPath -DiskInfo $disk -PartitionInfo $afterParts

[pscustomobject]@{
    BeforeGiB = $currentGiB
    AfterGiB = [math]::Round(([int64]$afterD.Size) / 1GB, 2)
    ActualShrinkGiB = [math]::Round($actualShrinkBytes / 1GB, 4)
    UnallocatedBeforeP5GiB = [math]::Round($actualUnallocatedBytes / 1GB, 4)
    P5OffsetUnchanged = ([int64]$afterP5.Offset -eq [int64]$p5.Offset)
    P5SizeUnchanged = ([int64]$afterP5.Size -eq [int64]$p5.Size)
    P6OffsetUnchanged = ([int64]$afterP6.Offset -eq [int64]$p6.Offset)
    P6SizeUnchanged = ([int64]$afterP6.Size -eq [int64]$p6.Size)
    BeforeSnapshot = $beforePath
    AfterSnapshot = $afterPath
} | Format-List | Out-String | Write-Host

$toleranceBytes = 1MB
$valid = ([math]::Abs($actualShrinkBytes - $TargetBytes) -le $toleranceBytes) -and
         ([math]::Abs($actualUnallocatedBytes - $TargetBytes) -le $toleranceBytes) -and
         ([int64]$afterP5.Offset -eq [int64]$p5.Offset) -and
         ([int64]$afterP5.Size -eq [int64]$p5.Size) -and
         ([int64]$afterP6.Offset -eq [int64]$p6.Offset) -and
         ([int64]$afterP6.Size -eq [int64]$p6.Size)

if (-not $valid) {
    throw "事后校验未全部通过。不要继续安装 Ubuntu，也不要格式化这块未分配空间。先在 Windows 磁盘管理中检查，并保留快照：$beforePath / $afterPath"
}

Write-Host '压缩与事后校验通过。请打开 diskmgmt.msc 再人工确认：D: 右侧有约指定大小的黑色“未分配”空间，且 P5/WinRE、P6/DELLSUPPORT 均完整。此时不要在 Windows 中新建或格式化卷。' -ForegroundColor Green
```

## 7. 从 U 盘启动并先试运行 Ubuntu

1. 如果可操作，先关机并暂时物理断开机械硬盘 E:。不要在安装期间让目标盘和数据盘同时出现而无法分清。
2. 插入 Ubuntu 安装 U 盘，开机后连续按 Dell 的 `F12`，打开一次性启动菜单。
3. 选择带 `UEFI` 的 U 盘启动项。
4. 进入 Ubuntu 启动界面后选择 **Try Ubuntu（试用 Ubuntu）**，不要立即点击安装。
5. 进入桌面，打开终端，执行只读检查：

```bash
lsblk -o NAME,PATH,SIZE,MODEL,SERIAL,TRAN,FSTYPE,LABEL,MOUNTPOINTS
```

根据输出确认 ACASIS 目标盘的实际设备路径。Linux 里的 `/dev/sda`、`/dev/sdb` 等设备名可能随 USB 枚举顺序变化，不能照抄其他机器的名字。

将下方 `/dev/sdX` 替换成现场确认的目标设备路径，只执行查询命令：

```bash
sudo udevadm info --query=property --name=/dev/sdX | grep -E 'ID_MODEL=|ID_SERIAL=|ID_VENDOR='
sudo parted /dev/sdX unit MiB print free
```

必须同时确认：

- 目标盘型号/序列号和 Windows 预检记录一致；
- 目标盘是 GPT；
- D: 对应分区后方、P5/WinRE 前方有约 150 GiB 的未分配区域；
- 安装 U 盘与 ACASIS 目标盘能够明确区分；
- 如已断开 E:，E: 机械盘不应出现在输出中。

若任何一项不符合，退出试用环境并关机，不要继续安装。

## 8. Ubuntu 图形安装器：只在未分配空间中分区

### 8.1 选择手动安装

1. 在 Try Ubuntu 桌面启动安装程序。
2. 选择正常安装流程。
3. 到磁盘/安装类型页面，选择 `Manual partitioning`、`Manual installation` 或含义相同的手动分区选项。具体文字可能因安装器版本不同而变化。
4. **不要选择 `Erase disk and install Ubuntu`（清除磁盘并安装 Ubuntu）**，不要选择自动使用整块磁盘，也不要使用原文中的 `autoinstall.yaml`。

### 8.2 推荐创建的 Ubuntu 分区

只在约 150 GiB 的未分配空间中新建分区：

| 分区 | 大小 | 文件系统/类型 | 挂载点 | 说明 |
|---|---:|---|---|---|
| Ubuntu EFI（ESP） | 512 MiB | FAT32 / EFI System Partition | `/boot/efi`（如安装器要求） | 新建在未分配空间中，不格式化 Windows 原有 EFI 分区 |
| Ubuntu 根分区 | 剩余全部空间，约 149.5 GiB | ext4 | `/` | 只格式化这个新建分区 |

普通桌面安装通常可以使用根文件系统里的默认 swapfile（交换文件），不必预先切出固定大小的 swap 分区。若你明确需要休眠功能，应另行规划 swap 容量，不要直接假设 8 GiB 足够。

### 8.3 点击最终确认前复核

逐项确认安装器准备执行的操作：

- C:、D:、Windows EFI、MSR、WinRE、DELLSUPPORT 均仍存在；
- 没有勾选格式化或删除任何现有 Windows 分区；
- 只在未分配空间里新增 Ubuntu EFI 与 ext4 `/`；
- 只有新建的 Ubuntu 根分区被标记为需要格式化；
- 如果安装器要求指定引导设备，选择整块 ACASIS 目标盘，而不是安装 U 盘或 E: 机械盘。

如果最终摘要出现“清除整块磁盘”、删除 C:/D:、格式化 Windows EFI、删除 WinRE/DELLSUPPORT，或者操作含义无法解释，立即取消安装。

## 9. 安装完成后的验证

1. 安装结束后关机，拔掉 Ubuntu 安装 U 盘；E: 机械盘暂时保持断开。
2. 开机按 `F12`，选择 Ubuntu 对应的 UEFI 启动项。
3. 进入 Ubuntu 后检查：

```bash
lsblk -f
findmnt -no SOURCE,FSTYPE,TARGET /
sudo efibootmgr -v
```

确认 `/` 来自 ACASIS 盘上新建的 ext4 分区，Ubuntu EFI 分区存在，固件中能看到 Ubuntu 启动项。

4. 重启按 `F12`，选择 `Windows Boot Manager`，确认 Windows 11 正常启动。
5. 在 Windows 中确认 C:、D: 容量与文件正常；打开“磁盘管理”，核对原有 Windows EFI、MSR、C:、D:、WinRE、DELLSUPPORT 均保留。
6. 关机后重新连接 E: 机械硬盘，再次启动 Windows，检查 E: 盘符与重要文件。
7. 最后分别测试 Ubuntu 和 Windows 的启动入口。

如果 GRUB 菜单没有列出 Windows，先用 `F12` 单独测试 `Windows Boot Manager`。不要立即执行来源不明的 GRUB 修复命令。

## 10. 必须停止的情况

出现任何一条都不要继续安装：

- Windows 里不能唯一识别 ACASIS 目标盘或 D: 所属磁盘；
- 目标盘型号、分区数量或分区布局与文档不一致；
- D: 可压缩空间小于所需容量；
- 压缩后未分配空间没有出现在 D: 与 WinRE 之间；
- Try Ubuntu 中型号/序列号、分区表或未分配空间大小不符；
- 安装器准备删除整盘、格式化 C:/D:/Windows EFI、删除 WinRE/DELLSUPPORT；
- 重要数据尚未备份，或无法确认备份可读。

严禁为了凑出安装空间而删除 Windows 恢复分区；严禁在不确定目标盘时运行 `diskpart clean`、`mkfs`、`parted mkpart`、`parted rm` 等写入性命令。

## 11. 官方与审查资料

1. [Ubuntu 26.04.1 官方发布目录](https://releases.ubuntu.com/26.04.1/)
2. [Ubuntu ISO 官方 SHA256SUMS](https://releases.ubuntu.com/26.04.1/SHA256SUMS)
3. [Rufus 简体中文官方网站](https://rufus.ie/zh/)
4. [Rufus 4.15 x64 直接下载](https://github.com/pbatard/rufus/releases/download/v4.15/rufus-4.15.exe)
5. [第一份：双系统安装原文](https://github.com/wayyet/setting_Install/blob/main/%E5%9C%A8%20Dell%20Inspiron%2014%205410%20%E4%B8%8A%E6%90%AD%E5%BB%BA%20Windows%2011%20%2B%20Ubuntu%2026.04.1%20LTS%20%E5%8F%8C%E7%B3%BB%E7%BB%9F.md)
6. [第二份：安装方案审查文档](https://github.com/wayyet/setting_Install/blob/main/Dell_Inspiron_5410_Windows11_Ubuntu26.04.1.md)
7. [Curtin 官方存储配置文档](https://raw.githubusercontent.com/canonical/curtin/main/doc/topics/storage.rst)
8. [Subiquity 官方 Autoinstall 参考](https://raw.githubusercontent.com/canonical/subiquity/main/doc/reference/autoinstall-reference.rst)

---

**最终建议：** 使用 Rufus 制作标准启动 U 盘；先按本手册预检并压缩 D:，把空间保留为未分配；安装时先试运行，再在图形安装器中手动分区。不要执行未经核验的无人值守自动分区配置。
