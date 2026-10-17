# Windows 11 系统时间不准：诊断与自动同步修复方案

## Summary

本机（DESKTOP-H9JRHQJ，Dell Inspiron 14 5410）系统时间比真实时间**慢 8 小时**（实测偏差 −28800 秒）。已用两个互相独立的参照源交叉验证：百度 HTTP `Date` 响应头、阿里云 NTP；另有 6 个 NTP 服务器返回一致偏移。

根因是**双系统的主板 CMOS RTC 语义不一致**，不是网络问题、也不是时间服务被禁用：

- Ubuntu 默认把 **UTC** 写进 CMOS RTC；Windows 默认把 RTC 当作**本地时间**读。
- 本机快速启动已关闭（`HiberbootEnabled=0`），每次开机都重新从 RTC 取值，因此每次从 Ubuntu 切回 Windows，开机第一刻起时钟就正好差 `+08:00`。
- Windows 侧本来有 NTP 自愈能力，但 `w32time` 服务**开机后根本没有被拉起**（`Start=3` 手动、状态 Stopped、09:20 开机后事件日志零记录），所以 8 小时偏差一直挂着，直到今天 05:10 服务偶然运行才被修好过一次；2026-10-16 20:34 的历史事件显示当时曾发生过一次 +28800331 毫秒（正好 8 小时）的跳变修正。

**目标**：把 Windows 11 设为自动校时并修好当前 8 小时偏差。

**关键设计决策（已与用户确认）**：

1. **分两阶段实施**。第一阶段只做安全的 NTP 自动同步，立即消除 8 小时偏差；第二阶段再改 RTC 语义，必须重启并**实测验证**后才算成功。
2. **NTP 源以国内源为主**，`time.windows.com` 标记为「仅备用源」，而不是简单并列。
3. **第二阶段设置验证门**：社区资料记录「即使设了 `RealTimeIsUniversal=1`，Windows 时间服务写回 CMOS 时仍按本地时间写」，该说法无微软官方文档背书且与本机需求冲突。因此第二阶段先验证再定，验证失败则回滚并改走 Ubuntu 侧。
4. **不禁用 `w32time`**。禁用它是上述社区资料的建议做法，但直接违背用户「设置为自动同步」的要求，仅在第二阶段验证失败且用户改选时才考虑。

## 范围

### 在范围内

- `w32time` 服务：启动类型、运行状态、NTP 对等源列表
- `HKLM\SYSTEM\CurrentControlSet\Services\W32Time\Parameters` 的 `NtpServer` / `Type`
- `HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation\RealTimeIsUniversal`（第二阶段，需重启）
- 上述改动的验证与回滚

### 不在范围内（Non-goals）

- **不改时区**。当前 `China Standard Time` / `Bias=4294966816`（−480 分钟 = UTC+8）完全正确。
- 不改 BIOS/UEFI 里的 RTC 设置。
- 第一次不碰 Ubuntu。若第二阶段验证失败，才需要用户进 Ubuntu 执行一条命令（见「回滚与备选」）。
- 不清空或修补历史事件日志里已经写坏的时间戳。已有的错误时间戳保留为诊断证据。
- 不注册域、不改组策略。已确认 `HKLM\SOFTWARE\Policies\Microsoft\Windows\Time` 与 `...\TimeSync` 均不存在。

## 现状与证据

### 实测偏差（两个独立源交叉验证）

| 参照源 | 时刻（UTC） | 本机 UTC | 偏差 |
|---|---|---|---|
| 百度 HTTP `Date`（经 127.0.0.1:3067 代理） | 15:14:09 | 07:14:08 | −28800.39 s |
| `w32tm /stripchart` → ntp.aliyun.com | 15:15:33 | — | +28800.5014 s |

其余 5 个源偏移完全一致（`+28800.49` ~ `+28800.50`）：time.windows.com、ntp.ntsc.ac.cn、ntp.sjtu.edu.cn、cn.pool.ntp.org、time.cloudflare.com、ntp.tencent.com。

`time1.windows.com` DNS 解析失败（0x80072AF9），但它本就不在当前配置里，不影响。

### NTP 全部可达 —— 不是网络问题

所有被测服务器的 UDP 123 均能返回数据，`w32tm /stripchart` 全部成功。早期用 `Test-NetConnection`（走 TCP）测出 `False` 是误判，TCP 123 本就不是 NTP 使用的端口。

### RTC 里存的是 UTC（算术证明）

- 系统记录的开机时刻：`2026-10-17T01:20:24.500000000Z`（Kernel-General 事件 ID 12）。小数部分全零，是直接从 RTC 读取的特征。
- 该时刻真实 UTC ≈ 09:20（真实 UTC 15:15 − 运行时长 5.88 小时）。
- Windows 把它当作**本地时间 09:20** 读入 → 系统 UTC 变成 01:20 → **开机瞬间就慢 8 小时**。
- 旁证：`LastBootUpTime` 09:20:24，运行时长 352.8 分钟，两条独立数据互相吻合。

### 双系统确认

`Disk 2`（ACASIS EC-7351，GPT）分区 7 = 150.00 GB，类型 `Unknown`、无盘符 → Linux ext4 root。Linux 默认 RTC = UTC，Windows 默认 RTC = 本地时间，冲突成立。

### 服务为什么没自愈

- `HKLM\SYSTEM\CurrentControlSet\Services\W32Time` 下 `Start = 3`（手动）。
- `Get-Service w32time` → `Stopped`；`w32tm /query /status` → `0x80070426 服务尚未启动`。
- 事件日志 `Microsoft-Windows-Time-Service/Operational`（启用中，534 条）最新一条为 **2026-10-17 05:10:50**；按 `TimeCreated >= 09:00` 过滤**结果为空** → 09:20 开机后服务完全没运行过。
- `sc qtriggerinfo w32time` 显示运行时**确有**触发器（`CUSTOM SYSTEM STATE CHANGE EVENT {2d7a2816-0c5e-45fc-9ce7-570e5ecde9c9}`），但本次开机未触发。
  - 注册表里 `Services\W32Time\TriggerStart` 键不存在属于**正常现象** —— 触发器是运行时注册、不落盘。不要据此误判。

### 当前配置快照（改动前）

```
服务启动类型 : Manual (Start=3)   状态: Stopped
Type         : NTP
NtpServer    : time.windows.com,0x9
NtpClient    : Enabled=1, SpecialPollInterval=32768 (秒)
TimeZoneKey  : China Standard Time,  Bias=4294966816 (-480)
RealTimeIsUniversal : 不存在  →  Kernel-General 事件显示 "RTC 时间以 UTC： false"
HiberbootEnabled    : 0  (快速启动关闭)
HypervisorPresent   : True
```

NTP 对等源标志位含义（已核实）：`0x1`=特殊轮询间隔、`0x2`=仅作备用源、`0x4`=对称主动、`0x8`=客户端模式。故 `0x9` = 0x8+0x1 = 客户端+特殊轮询；`0xA` = 0x8+0x2 = 客户端+仅作备用。

## 实施步骤

### 前置：提权

当前会话 **非管理员**（`Elevated: False`，`bcdedit` 报 Access denied 可佐证）。所有变更必须在管理员上下文执行。

两种方式，任选：

```powershell
# 方式 A：弹 UAC 提权执行脚本（用户点「是」）
Start-Process pwsh -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','<脚本路径>' -Wait

# 方式 B：用户自行打开「管理员 PowerShell」后粘贴命令
```

所有 PowerShell 命令块开头加 `[Console]::OutputEncoding=[System.Text.Encoding]::UTF8`，否则中文输出在控制台显示为乱码（本机已复现）。

### 阶段一：恢复自动同步（安全，无重启）

按顺序执行，每步检查退出码。

```powershell
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# 1) 停服务，改对等源：国内源为主（0x9），time.windows.com 标为仅备用（0xA）
Stop-Service w32time -Force
w32tm /config /manualpeerlist:"ntp.aliyun.com,0x9 ntp.ntsc.ac.cn,0x9 ntp.sjtu.edu.cn,0x9 cn.pool.ntp.org,0x9 time.windows.com,0xA" /syncfromflags:manual /update

# 2) 改为自动启动，杜绝「触发器不触发 → 开机不同步」再次发生
Set-Service w32time -StartupType Automatic

# 3) 启动并立即校时
Start-Service w32time
w32tm /resync /nowait
```

设计说明：

- **步骤 1 必须在服务停止时做**。`w32tm /config` 会重写 `Parameters\NtpServer` 与 `Type`，运行中改会留下不一致状态。
- **步骤 2 用 Automatic 而非 Manual**。这是本次修复的核心可靠性动作：实测该机触发器注册了却没触发，靠「按需启动」不可靠。`w32time` 空闲时几乎不耗资源，长期驻留无实际代价。
- **步骤 3 必须服务已启动**，`w32tm /resync` 依赖服务运行，会重写 `0x80070426`。
- `0xA` 的作用：国内源全部不可达时，w32time 才回落到 `time.windows.com`，不会两个源互相争抢。

阶段一结束**立即生效、无需重启**，8 小时偏差当场修正。

### 阶段二：RTC 语义（需重启，且必须验证）

**这一阶段是有条件的**：它依赖一个尚未证实的假设。先做，再验，验不过就回滚。

```powershell
reg add "HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation" /v RealTimeIsUniversal /t REG_DWORD /d 1 /f
```

- 值名是 `RealTimeIsUniversal`，DWORD 类型（老版本 Windows 10 x64 曾有需 QWORD 的 bug，新版已修，本机为 Windows 11 26700 系列用 DWORD）。
- **必须重启才生效**。重启前须取得用户同意，并提醒保存工作。

重启后的验证门（核心步骤，不可跳过）：

```powershell
# a) 注册表值已生效
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' |
    Select-Object RealTimeIsUniversal

# b) 取最近一次时间跳变事件，看 Windows 是否已按 UTC 解读 RTC
Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Kernel-General'; Id=1} -MaxEvents 1 |
    Select-Object TimeCreated, Message | Format-List

# c) 看偏移是否已归零
w32tm /stripchart /computer:ntp.aliyun.com /dataonly /samples:3
```

判定标准 —— 事件 ID 1 的 `RTC 时间` 字段与真实 UTC 比对：

| 事件中 `RTC 时间` 的值 | 结论 | 动作 |
|---|---|---|
| ≈ 真实 UTC | 标志被完整遵守，根因彻底解决 | 保留，进入稳态验证 |
| ≈ 真实本地时间（UTC+8） | 时间服务确实按本地时间写回 CMOS | **回滚本阶段**，转 Ubuntu 侧方案 |

取「真实 UTC」的参照：同一次 `Get-WinEvent` 里的 `TimeCreated` 配合事件 `RTC 时间` 字段互算，或另开一次 `w32tm /stripchart` 交叉比对。误差超过 10 分钟即视为不遵守。

**预期现象（不是失败）**：改标志后的第一次重启，RTC 里仍是旧语义下由 Windows 写入的本地时间，Windows 会按 UTC 解读 → **时钟快 8 小时**，随后由阶段一已修好的自动同步在约 1 分钟内拉回。之后关机会以 UTC 写回 RTC，进入稳态。

## 状态、并发、失败与恢复语义

### 状态归属

| 状态 | 位置 | 本次是否改动 |
|---|---|---|
| 服务启动类型 | `HKLM\SYSTEM\CurrentControlSet\Services\W32Time\Start` | 是：3 → 2 |
| NTP 对等源 | `...\W32Time\Parameters\NtpServer` | 是 |
| 时间提供程序 | `...\W32Time\TimeProviders\NtpClient\Enabled` | 否（已为 1） |
| RTC 语义 | `...\Control\TimeZoneInformation\RealTimeIsUniversal` | 是（阶段二） |
| 时区 | `...\TimeZoneInformation\TimeZoneKeyName` / `Bias` | 否（已正确） |

### 并发

- `w32tm /config` 与服务启停必须串行，不要并发下发。
- Hyper-V 处于运行态（`HypervisorPresent=True`），时钟源是 hypervisor 而非 HPET/TSC。`w32time` 仍负责相位校正，对 8 小时量级误差无影响。
- 阶段二的注册表写入与后续重启之间不要插入其他关机/睡眠操作，否则会额外多覆盖一次 RTC。

### 失败处理

| 失败点 | 现象 | 处理 |
|---|---|---|
| `w32tm /config` 报服务已启动 | 0x80070426 之外的拒绝 | 先 `Stop-Service w32time` 再重跑 |
| `/resync` 无响应 | 命令挂起 | 加 `/nowait`；服务未起来时先 `Start-Service` |
| 同步后偏移仍 > 1s | 源被墙或 DNS 异常 | 逐个 `w32tm /stripchart` 定位，换掉不通的源 |
| 阶段二验证判定「不遵守」 | 事件 `RTC 时间` ≈ 本地时间 | 执行回滚，转 Ubuntu 侧 |
| 提权被拒 | UAC 弹窗点「否」 | 改用方式 B，手动开管理员 PowerShell |

### 恢复 / 回滚

阶段一全部回滚（回到原始配置）：

```powershell
Stop-Service w32time -Force
w32tm /config /manualpeerlist:"time.windows.com,0x9" /syncfromflags:manual /update
Set-Service w32time -StartupType Manual
Start-Service w32time
```

阶段二回滚：

```powershell
reg delete "HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation" /v RealTimeIsUniversal /f
```
随后重启。

**阶段二验证失败时的备选路径（需用户进 Ubuntu）**：

```bash
sudo timedatectl set-local-rtc 1 --adjust-system-clock
```

这条命令写入 `/etc/adjtime`，systemd 会持久遵守，使 Linux 认为 RTC 存本地时间，从而与 Windows 默认行为对齐。执行后同时回滚阶段二的注册表值。

配套说明（写入方案备注，不作为必需步骤）：

- 若 GRUB 内核参数显式带了 `rtc.localtime=0` 需改掉：`/etc/default/grub` 的 `GRUB_CMDLINE_LINUX_DEFAULT` 加 `rtc.localtime=1`，再 `sudo update-grub`。
- **不能用 WSL 里的 `Ubuntu-26.04` 执行**：它是 `%LOCALAPPDATA%` 下的独立 `ext4.vhdx` rootfs，与本机引导链和 CMOS RTC 无关。必须启动真实安装的 Ubuntu。
- 本机为 UEFI 引导（固件首项 `{ac0fd0b2}` = `\EFI\ubuntu\shimx64.efi`，GRUB），改 GRUB 后需留意固件 `timeout=5` 的启动菜单。

## 测试与验收标准

### 阶段一验收（全部必须通过）

| # | 检查 | 命令 | 通过标准 |
|---|---|---|---|
| 1 | 服务在跑且自动启动 | `Get-Service w32time \| Select Status,StartType` | `Running` + `Automatic` |
| 2 | 配置已写入 | `Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'` | `NtpServer` 含 aliyun/ntsc/sjtu/pool，末尾 `time.windows.com,0xA` |
| 3 | 已成功选源 | `w32tm /query /status` | `源:` 为列表中任一源；`上次成功同步时间` 为今天 |
| 4 | 8 小时偏差已消除 | `w32tm /stripchart /computer:ntp.aliyun.com /dataonly /samples:3` | 三次采样偏移绝对值 **< 1 秒** |
| 5 | 独立源复核 | `Invoke-WebRequest -Uri 'https://www.baidu.com' -Method Head -Proxy 'http://127.0.0.1:3067'` 对比 `Date` 头 | 与真实 UTC 偏差 **< 5 秒** |
| 6 | 服务错误日志干净 | `Get-WinEvent -LogName 'Microsoft-Windows-Time-Service/Operational' -MaxEvents 20` | 无 129 / 134 / 142 / 158 错误事件 |

### 阶段二验收

| # | 检查 | 通过标准 |
|---|---|---|
| 7 | 注册表值 | `RealTimeIsUniversal` = `1` |
| 8 | 内核已按 UTC 解读 | 事件 ID 1 显示 `RTC 时间以 UTC： true` |
| 9 | **冲突验证门** | 事件 `RTC 时间` ≈ 真实 UTC（通过则保留；不通过则回滚并转 Ubuntu 侧） |
| 10 | 重启后偏差仍为零 | `w32tm /stripchart` 偏移 < 1 秒 |
| 11 | 端到端 | 重启后**不做任何手动校时**，3 分钟内系统时间自动与真实 UTC 一致 |

### 回归检查（阶段二稳态后）

- 从 Windows → Ubuntu → 切回 Windows，全程不动任何校时设置，确认开机时间正确。
- 确认 `time.windows.com` 兜底有效：临时禁用国内源后 `w32tm /query /source` 仍能选出 `time.windows.com`。

## 未决事项与风险

### 需要在实施时通知用户的影响

1. **8 小时跳变会污染时间戳**。修正瞬间，所有新写入的事件日志、文件 mtime、git commit 时间会跳变 8 小时；**今天在此之前产生的文件时间戳仍然偏 8 小时**，包括本次会话产物。这是预期行为，不要「再修一次」。
2. **短窗口内 TLS 可能失败**。跳变瞬间证书有效期校验会失败，浏览器 / `git push` / `Invoke-WebRequest` 可能短暂报错。建议在网络正常、浏览器空闲时执行阶段一。
3. **阶段二需要重启**，会中断当前所有工作与未保存内容。必须先征得同意。

### 遗留不确定性

1. **`RealTimeIsUniversal` 是否被 `w32time` 完整遵守，未经验证**。该说法源自 2016 年前后的社区 gist（damvik / sibinx7），被多个站点转述，但**没有微软官方文档背书**；ArchWiki 的表述则相反，倾向于 Windows 会正确处理。这直接决定阶段二是否可行，必须靠验收项 9 实测裁定。**不要在没有跑过第 9 项的情况下宣布阶段二成功。**
2. **Ubuntu 侧 `timedatectl` 当前状态未知**。无法从 Windows 读到 Ubuntu 的 `/etc/adjtime`，也无法排除 GRUB 已带 `rtc.localtime` 参数。阶段二失败转 Ubuntu 方案时，需用户在 Ubuntu 内先跑 `timedatectl` 确认现状再改。
3. **为什么 09:20 开机时触发器没触发，根因未定**。已排除：服务被禁用（`Start=3`）、策略阻止（无相关策略键）、网络不通（NTP 全可达）。阶段一改用 `Automatic` 绕过该行为，不依赖查清触发器内部逻辑。

### 已知不影响的因素（排除记录）

- Hyper-V 虚拟化：影响亚秒级精度来源，不影响 8 小时量级误差。
- 时区配置：`Bias` 与 `TimeZoneKeyName` 均正确。
- CMOS 电池：偏差稳定为精确的 28800 秒而非随机漂移，不符合电池失效特征。

### 变更前建议留存的快照

执行前记录原始值，便于比对与回滚：

```powershell
reg query "HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation"
reg query "HKLM\SYSTEM\CurrentControlSet\Services\W32Time\Parameters" /v NtpServer /v Type
sc.exe qc w32time
```
