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
