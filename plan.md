# 在 Dell Inspiron 14 5410 上搭建 Windows 11 + Ubuntu 26.04.1 LTS 双系统

## Summary

**目标**：保留现有 Windows 11 完整可用，在 `ACASIS EC-7351`（NVMe 硬盘盒，系统盘）上腾出一个**新建分区**安装 Ubuntu 26.04.1 LTS，形成 UEFI 双系统，开机可选。机械盘 `ST1000LM024`（E: 盘，约 746.7 GiB 视频）**完全不参与、不做任何改动**。

**关键设计决策**

1. **目标磁盘 = 磁盘 0（ACASIS EC-7351）**。用户明确排除机械盘方案。E: 盘数据零风险。
2. **腾空间的方式是压缩 D:，不是删恢复分区**。D: 有 727.9 GiB 容量但仅用了 48.4 GiB（空闲 679.5 GiB，占 93%），NTFS 压缩会把尾部未用空间直接让出来，未分配空间落在 D: 与 WinRE 之间。这是唯一不损失 WinRE / Dell 一键恢复的路径。
3. **分区声明采用 curtin action 语法 + 全部现有分区显式 `preserve: true` 并带精确 offset**。这是本次方案最重要的安全设计：curtin 存储配置 **version 2 会删除未在配置中声明的现有分区**。把 P1–P6 六个现有分区（含 C:/D:/WinRE/DELLSUPPORT）逐个写进配置并标注 offset，任何偏移量不符都会让 curtin **报错中止**，而不是静默抹盘。
4. **ESP 与 GRUB 放在新分区区内（磁盘 0 上）**。固件已经能从该 USB 盘上的 ESP 引导 Windows，说明它会枚举这个盘，Ubuntu 引导项同样能出现。
5. **磁盘选择器用预检实测的 udev `ID_MODEL` 精确值**。两盘容量完全相同（均报 1 TB），不能靠容量区分；且 Subiquity 的 match spec 支持的是 `model/vendor/path/serial/ssd/size`，**没有 `rotational` 字段**。
6. **不加密**。ext4 明文，不用 LUKS / TPM-FDE。
7. **前置条件全部已满足**：UEFI + GPT、Secure Boot 已关、快速启动已关、无 BitLocker。因此不需要关闭任何 Windows 安全功能。
8. **无人值守 + 图形安装器双轨**：U 盘根目录放 `autoinstall.yaml` 实现零按键自动安装；同时提供完全等价的图形安装器手动步骤作为兜底与验收对照。安装前必须先做一次 `Try Ubuntu` 试运行。

**范围**：本机磁盘分区与引导配置。不动 E: 盘，不动 C:/D: 现有数据，不删任何恢复分区，不改 BIOS 设置，不安装虚拟化方案。

**非目标**：不升级 BIOS、不装第三方显卡驱动（Intel 核显 Linux 原生支持）、不配置 Windows 侧开发环境、不启用磁盘加密。

---

## 一、本机现状（实测，2026-10-07）

### 硬件与固件

| 项目 | 实测值 |
| --- | --- |
| 机型 | Dell Inspiron 14 5410 2-in-1 |
| CPU | Intel Core i3-1125G4，4 核 8 线程，2.0 GHz |
| 内存 | 24 GiB |
| BIOS | 2.38.0（2026-05-27） |
| 显卡 | Intel UHD Graphics 核显，无独显 |
| 无线网卡 | Intel Wi-Fi 6 AX201 160MHz（Linux 原生驱动） |
| 指纹 | 无 |

### 操作系统

| 项目 | 实测值 |
| --- | --- |
| 系统 | Windows 11 专业版（EditionID = ProfessionalWorkstation），26H2 |
| 版本号 | 10.0.26300.9457 |
| 安装日期 | 2026-09-08 |
| 启动模式 | UEFI（GPT + EFI 系统分区 + SecureBoot 注册表项存在，三重佐证） |
| Secure Boot | **已关闭**（`HKLM\...\SecureBoot\State\UEFISecureBootEnabled = 0`） |
| 快速启动 | **已关闭**（`...\Session Manager\Power\HiberbootEnabled = 0`） |
| BitLocker | 未启用（需在管理员会话复核，见预检） |
| 待重启标志 | 无（CBS / WindowsUpdate 均为 False） |
| 存储控制器 | 无 Intel VMD / RST，无 RAID 驱动冲突 |
| WSL | 存在 `docker-desktop` 发行版，与本方案无冲突 |

### 磁盘布局

两块盘都是 **USB 外接**，经 Realtek RTL9210 UAS 桥接（`USB\VID_0BDA&PID_9201`）。笔记本内置盘未出现在系统磁盘列表中。

**磁盘 0 —— `ACASIS EC-7351`（NVMe 硬盘盒，1 TB，GPT，IsBoot/IsSystem）**

| 分区 | GPT 类型 GUID | Offset | Size | 说明 |
| --- | --- | --- | --- | --- |
| P1 | `c12a7328-…`（EFI） | 1,048,576 | 272,629,760（260 MiB） | Windows 引导 ESP，FAT32 |
| P2 | `e3c9e316-…`（MSR） | 273,678,336 | 16,777,216（16 MiB） | 保留 |
| P3 | `ebd0a0a2-…` | 290,455,552 | 214,748,364,800（200 GiB） | C:，NTFS，空闲 52.3 GiB |
| P4 | `ebd0a0a2-…` | 215,038,820,352 | 781,538,295,808（727.9 GiB） | D:，NTFS，**空闲 679.5 GiB** |
| P5 | `de94bba4-…`（恢复） | 996,577,116,160 | 2,097,152,000（2.0 GiB） | WinRE |
| P6 | `de94bba4-…`（恢复） | 998,674,268,160 | 1,518,338,048（1.41 GiB） | DELLSUPPORT |

磁盘总长 1,000,204,886,016 字节；末尾空闲仅 12.7 MiB。

**磁盘 1 —— `ST1000LM024 HN-M101MBB`（机械硬盘盒，1 TB，GPT）—— 本方案不触碰**

| 分区 | GPT 类型 GUID | Offset | Size | 说明 |
| --- | --- | --- | --- | --- |
| P1 | `ebd0a0a2-…` | 20,480 | 1,000,204,848,640（931.5 GiB） | E:，NTFS，已用约 746.7 GiB，空闲 184.8 GiB |

### 三条由此得出的硬约束

1. **不能删恢复分区**。D: 之后紧跟 P5/P6，若走"删恢复分区换空间"路线，只能腾出 3.41 GiB，收益与代价完全不成比例，而且会永久失去 WinRE 与 Dell 一键恢复。改用压缩 D:。
2. **两盘容量完全相同**（均报 `1000204886016` 字节），磁盘选择器**不能**用容量区分。
3. **Linux 下设备名不可预设**。安装 U 盘 + 两块硬盘共三个块设备，`/dev/sda`/`/dev/sdb` 顺序取决于 USB 枚举。所有配置必须用 match spec 与 offset，不能写死路径。

### 目标版本

- **Ubuntu 26.04.1 LTS (Resolute Raccoon)**，2026-08-27 发布，官方支持至 2031 年 4 月（5 年标准支持 + 5 年 ESM）。
- 另有 26.10 (Stonking Stingray) 临时版，仅维护 9 个月，长期使用选 LTS。
- 官方硬件门槛（双核 2 GHz / 6 GB 内存 / 25 GB 磁盘）本机全部满足。
- 依据：https://releases.ubuntu.com/ 、https://documentation.ubuntu.com/release-notes/26.04/

---

## 二、目标磁盘方案

### 2.1 压缩 D: 腾出空间

压缩 D: 的**尾部边界**，未分配空间落在 D: 与 P5(WinRE) 之间。

以压缩 **150 GiB**（161,061,273,600 字节）为例：

| 项 | 压缩前 | 压缩后 |
| --- | --- | --- |
| P4 (D:) Offset | 215,038,820,352 | 不变 |
| P4 (D:) Size | 781,538,295,808 | 620,477,022,208（591.5 GiB） |
| P4 结束位置 | 996,577,116,160 | 835,515,842,560 |
| 未分配空间 | — | 835,515,842,560 → 996,577,116,160（150 GiB） |

P1/P2/P3/P5/P6 的 offset 与 size **全部不变**。D: 剩余空闲从 679.5 GiB 降到 529.5 GiB，容量依然充裕。

**压缩量的自适应逻辑**（预检用 `Get-PartitionSupportedSize` 取系统权威值）：
- `可用压缩量 = SizeMax 与 当前大小 之差`，另留 20 GiB 安全余量。
- 目标 150 GiB；若不足则退到实际可用值。
- 若连 60 GiB 都腾不出，脚本中止并报告，让用户决定是否迁移 D: 尾部文件。

### 2.2 新建分区

在未分配区域内（以 150 GiB 为例）：

| 顺序 | Offset | Size | 文件系统 | 挂载 | 标志 |
| --- | --- | --- | --- | --- | --- |
| P7 | 835,515,842,560 | 536,870,912（512 MiB） | FAT32 | `/boot/efi` | esp / boot |
| P8 | 836,488,713,472 | 8,589,934,592（8 GiB） | swap | — | swap |
| P9 | 845,078,648,064 | 151,498,468,096（约 141.1 GiB） | ext4 | `/` | — |

- `/` 单分区包含 `/home`，不单独切分（桌面用途，后续可在线扩容）。
- ESP 独立 512 MiB，GRUB 装在**磁盘 0** 上。
- P9 用 `size: -1` 表示"吃满剩余空间"，偏移量由渲染脚本按实测值算出，不手写。

> 上表 offset 仅在压缩量恰为 150 GiB 时成立。实际值由 `render-autoinstall.ps1` 依据压缩后的实测分区表自动生成。

---

## 三、关键技术事实（已查证，非推测）

这些结论直接决定方案形态，实施时不得凭记忆推翻。

1. **Subiquity 加载 `autoinstall.yaml` 的优先级**：内核命令行 → 根文件系统 → cloud-config（CIDATA）→ **安装介质根目录**。
   官方文档明确：把 `autoinstall.yaml` 复制到"包含 `casper` 子目录的那一层分区根目录"，安装器自动发现并进入无人值守模式。
   来源：https://canonical-subiquity.readthedocs-hosted.com/en/latest/tutorial/providing-autoinstall.html

2. **CIDATA 数据源会被自动扫描**：Subiquity 会扫描所有块设备，找卷标为 `CIDATA` 或 `cidata` 的 FAT32 文件系统，读取其中的 `user-data` 与 `meta-data`。因此在 U 盘上额外放一个 CIDATA 分区是有效的第二保险。
   来源：cloud-init NoCloud datasource 行为，Subiquity 复用同一机制。

3. **curtin 存储配置 version 2 会删除未声明的现有分区**：
   > "the actions are bundled together to create a complete description of the partition table, and the `offset` of each action is respected if present. **Any partitions that already exist but are not referenced in the new config are (superblock-) wiped and deleted.**"

   来源：https://raw.githubusercontent.com/canonical/curtin/main/doc/topics/storage.rst

   **这就是本方案必须把 P1–P6 六个现有分区逐个显式声明（含 offset + `preserve: true`）的原因。** 漏写任何一个，Windows 的 C:、WinRE 或 Dell 恢复分区就可能被抹掉。

4. **curtin version 1（默认）**："actions are handled one by one and each partition is created (or assumed to exist, in the `preserve: true` case) just after that described by the previous action"。指定 `number` 可锁定 GPT 槽位。

5. **match spec 支持的键**：`model`（udev `ID_MODEL`，支持 glob）、`vendor`、`path`、`id_path`、`devpath`、`serial`、`ssd: true|false`、`size: largest|smallest`，以及 `install-media: true`。**不存在 `rotational` 字段**。`ssd` 与 `size` 选择器永不返回安装介质本身。
   来源：https://raw.githubusercontent.com/canonical/subiquity/main/doc/reference/autoinstall-reference.rst

6. **`flag: boot` 在 GPT 表上会把分区类型 GUID 设为 ESP**。curtin 的做法："On gpt partition tables, the boot flag sets partition type guid to the appropriate value for the EFI System Partition / ESP."

7. **GRUB 安装位置**：UEFI 启动下 curtin 把 grub 装到 ESP；可用磁盘 action 的 `grub_device: true` 指定目标盘。

---

## 四、交付物

全部落在工作目录 `E:\Documents\setting_Install\ubuntu-dual-boot\`：

| 文件 | 内容 |
| --- | --- |
| `README.md` | 总览、前置条件、按序号执行的操作清单 |
| `00-preflight-check.ps1` | **管理员**。BitLocker / 快速启动 / Secure Boot / 磁盘身份 / EFI 分区 / `Get-PartitionSupportedSize` 实测可压缩量 / ISO 校验和。任一项不达标立即中止 |
| `01-shrink-D-drive.ps1` | **管理员**。按实测可用量压缩 D:，输出 `layout-after-shrink.json`，含前后快照与结果校验 |
| `02-download-iso.ps1` | 从国内镜像下载 ISO，比对官方 `SHA256SUMS` |
| `03-make-usb.ps1` | **管理员**。U 盘两分区：ISO 内容 + `autoinstall.yaml`；小分区 CIDATA |
| `render-autoinstall.ps1` | 读 `layout-after-shrink.json`，自动算出新分区 offset，并要求填入试运行实测的 `ID_MODEL`，渲染最终 `autoinstall.yaml`。**所有 offset 由脚本计算，禁止手写** |
| `autoinstall.yaml` | 渲染产物 |
| `cidata/meta-data`、`cidata/user-data` | 备用数据源，与主文件内容等价 |
| `GUIDE-GUI.md` | 图形安装器手动步骤（分区方案与自动版完全一致），失败兜底 + 验收对照 |
| `04-verify-after-install.ps1` | 装完回 Windows 的校验：C:/D:/E: 容量与盘符、磁盘 0 分区表、P5/P6 完好 |
| `05-grub-repair.md` | 备选：GRUB 修复命令 |
| `99-uninstall-ubuntu.md` | 回滚：删 P7/P8/P9，D: 保持压缩后容量 |

---

## 五、执行流程

### 阶段 0：预检（管理员 PowerShell）

```powershell
Set-Location 'E:\Documents\setting_Install\ubuntu-dual-boot'
.\00-preflight-check.ps1
```

判定标准：

| 检查项 | 通过条件 | 不通过的处理 |
| --- | --- | --- |
| BitLocker | 所有卷 `ProtectionStatus ≠ On` | 必须先暂停保护并存好恢复密钥 |
| 快速启动 | `HiberbootEnabled = 0` | 当前已是 0；若为 1 需关闭 |
| Secure Boot | `UEFISecureBootEnabled = 0` | 当前已是 0；若为 1 需进 BIOS 关闭 |
| 待重启标志 | CBS / WindowsUpdate 均无 | 先重启再继续 |
| 磁盘身份 | `ACASIS EC-7351` 存在，容量 1,000,204,886,016 | 型号不符立即中止 |
| E: 盘 | 仅记录快照，不做任何写操作 | — |
| **D: 可压缩量** | `Get-PartitionSupportedSize -DiskNumber 0 -PartitionNumber 4` 返回 `SizeMax` ≥ 80 GiB 对应的量 | 低于 60 GiB 则中止并报告 |
| EFI 分区 | 磁盘 0 P1 存在且 ≥ 100 MiB | 中止 |

`Get-PartitionSupportedSize` 需要管理员权限，当前非提权会话已实测确认无法调用，因此这是预检的第一个执行项。

### 阶段 1：下载并校验 ISO

```powershell
.\02-download-iso.ps1
```

目标 `ubuntu-26.04.1-desktop-amd64.iso`（约 6–7 GB）。校验：`Get-FileHash -Algorithm SHA256` 与 `https://releases.ubuntu.com/26.04.1/SHA256SUMS` 官方值逐字节比对，不符即中止。

### 阶段 2：压缩 D:（不可逆，耗时）

```powershell
.\01-shrink-D-drive.ps1 -TargetGiB 150
```

- 前提：接通电源、期间不读写 D:、不拔 NVMe 硬盘盒。
- 耗时：D: 尾部若本就空闲，几乎瞬时；若尾部有数据需前移，NVMe 上通常几分钟到一小时。
- 失败：Windows NTFS 压缩为原子操作，失败自动回滚，D: 保持原状，重跑即可。
- 产出 `layout-after-shrink.json`，记录压缩后的实测 offset/size，作为阶段 4 的输入。
- 完成后校验：C:/D: 容量与盘符不变，P5/P6 offset/size 不变，磁盘尾部未分配空间等于预期。

### 阶段 3：制作安装 U 盘（需 ≥ 16 GB 空 U 盘，用户已确认会准备）

```powershell
.\03-make-usb.ps1
```

| 分区 | 大小 | 格式 | 卷标 | 内容 |
| --- | --- | --- | --- | --- |
| P1 | 2 GiB | FAT32 | `CIDATA` | `user-data`、`meta-data` |
| P2 | 剩余 | FAT32 | `UBUNTU` | ISO 全部内容 + 根目录 `autoinstall.yaml` |

### 阶段 4：试运行（唯一的防误装关口）

1. 插入 U 盘，重启按 `F12` 选 U 盘启动。
2. 选 `Try Ubuntu`（试用），**不要**点安装。
3. 采集真实标识：

```bash
lsblk -d -o NAME,SIZE,MODEL,ROTA,TRAN
udevadm info --query=property --name=/dev/sdX | grep -E 'ID_MODEL|ID_SERIAL'
sudo blkid
```

4. 记录三件事：
   - `ACASIS EC-7351` 对应的 `/dev/sdX`；
   - 它的 **udev `ID_MODEL` 精确字符串**（UAS 桥接下通常是把空格换成下划线的 SCSI 产品名，如 `ACASIS_EC-7351`）；
   - 未分配空间确实位于该盘 P4 之后、P5 之前。
5. 结果不符预期就**在此停止**，不做任何改动，回到阶段 2 调整。
6. 确认无误后执行 `render-autoinstall.ps1`，把上面记录的 `ID_MODEL` 填进去，生成 `autoinstall.yaml`，复制到 U 盘 P2 根目录。

### 阶段 5：自动安装（无人值守）

- 重启按 `F12` 启动 U 盘，安装器自动读取 `autoinstall.yaml`，**零按键**完成安装。
- 若未被识别：GRUB 菜单按 `e`，在 linux 行末尾追加 ` autoinstall` 后启动（3 秒可完成）。
- 装完自动重启，**拔掉 U 盘**。

### 阶段 6：双系统验证

- 开机按 `F12`，应出现 `ubuntu` 与 `Windows Boot Manager`。
- 进入 Ubuntu 验证：

```bash
lsblk -f
sudo efibootmgr
df -hT /
```

- GRUB 菜单应同时列出 `Ubuntu` 与 `Windows Boot Manager`。

### 阶段 7：回 Windows 最终校验

```powershell
.\04-verify-after-install.ps1
```

---

## 六、autoinstall.yaml 设计要点

完整文件由 `render-autoinstall.ps1` 生成；此处是决定成败的骨架与约束。

### 6.1 存储配置（安全核心）

```yaml
autoinstall:
  version: 1
  storage:
    config:
      # 1) 目标盘：只匹配预检实测到的 ACASIS，匹配不到就报错中止
      - type: disk
        id: nvme-box
        match:
          model: ACASIS*          # 试运行得到的 ID_MODEL 精确前缀
        preserve: true            # 只校验存在，不重建分区表
        grub_device: true         # GRUB 装到这块盘的新 ESP 上
        # 注意：此处绝对不能出现 ptable / wipe，否则会重写整张表

      # 2) 现有六个分区全部显式声明并保留 —— 漏一个就可能被删
      - { type: partition, id: p1-esp-windows, number: 1, preserve: true, offset: 1048576,           size: 272629760 }
      - { type: partition, id: p2-msr,           number: 2, preserve: true, offset: 273678336,         size: 16777216 }
      - { type: partition, id: p3-c-drive,       number: 3, preserve: true, offset: 290455552,         size: 214748364800 }
      - { type: partition, id: p4-d-drive,       number: 4, preserve: true, offset: 215038820352,      size: <压缩后的实测值> }
      - { type: partition, id: p5-winre,         number: 5, preserve: true, offset: 996577116160,      size: 2097152000 }
      - { type: partition, id: p6-dellsupport,   number: 6, preserve: true, offset: 998674268160,      size: 1518338048 }

      # 3) 三个新分区：offset 与 size 全部由渲染脚本按实测算出
      - { type: partition, id: p7-ubuntu-esp, number: 7, device: nvme-box, size: 536870912,  offset: <实测>, flag: boot }
      - { type: partition, id: p8-ubuntu-swap, number: 8, device: nvme-box, size: 8589934592, offset: <实测>, flag: swap }
      - { type: partition, id: p9-ubuntu-root, number: 9, device: nvme-box, size: -1, offset: <实测> }

      # 4) 文件系统与挂载
      - { type: format, id: fs-esp,  volume: p7-ubuntu-esp,  fstype: fat32, label: EFI }
      - { type: format, id: fs-swap, volume: p8-ubuntu-swap, fstype: swap }
      - { type: format, id: fs-root, volume: p9-ubuntu-root, fstype: ext4, label: ubuntu-root }
      - { type: mount,  id: m-esp,  path: /boot/efi, device: fs-esp }
      - { type: mount,  id: m-root, path: /,        device: fs-root }
```

设计约束（实施时必须遵守）：

- **磁盘 action 上不得出现 `ptable` 或 `wipe`**。一旦出现，curtin 会重建整张分区表，等于抹掉 Windows。
- **六个现有分区一个都不能少**，且 `offset` 必须与实测完全一致；对不上时 curtin 抛错中止，这是我们想要的失败方向。
- 新分区用 `number: 7/8/9`，槽位与现有 1–6 不冲突。
- `flag: boot` 在 GPT 上会把类型 GUID 设为 ESP（curtin 官方行为），正好用于 P7。
- `offset` 仅在 config version 2 下生效；默认 version 1 下 curtin 自行选择位置。渲染脚本需在试运行阶段实测新分区实际落点并复核；若发现 v1 未落到预期 offset，改为在 U 盘 `early-commands` 中先把 `/autoinstall.yaml` 换成已实测确认的版本。

### 6.2 其余关键字段

- `identity.username: wayyet`，`hostname: wayyet-ubuntu`，密码用 SHA-512 哈希，由渲染脚本生成并写入 `.user-data`，不落明文。
- `locale: zh_CN.UTF-8`，`keyboard.layout: us`，`variant: intl`，`timezone: Asia/Shanghai`。
- `source.id: ubuntu-desktop`（桌面版），`updates: all`。
- `shutdown: reboot`。
- `late-commands`：安装完成后开启 os-prober 并重建 GRUB 菜单，让 Windows 出现在菜单里：

```yaml
  late-commands:
    - curtin in-target --target=/target -- sh -c "sed -i 's/^GRUB_DISABLE_OS_PROBER=true/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub || true"
    - curtin in-target --target=/target -- update-grub
    - curtin in-target --target=/target -- systemctl enable fstrim.timer
```

- `error-commands`：失败时把 `/var/log/installer` 打包成 `installer-logs.tar.gz`，便于回 Windows 后查因。

### 6.3 落盘方式

同一份 YAML 同时写入 U 盘 P2 根目录（安装介质根目录方式）与 P1 的 `user-data`（CIDATA cloud-config 方式）。两处内容等价，命中哪一个结果都一样。

---

## 七、状态、归属与失败恢复语义

### 磁盘归属

| 对象 | 归属 | 本次是否修改 |
| --- | --- | --- |
| 磁盘 0 P1（Windows ESP） | Windows | 否 |
| 磁盘 0 P2（MSR） | 系统保留 | 否 |
| 磁盘 0 P3（C:） | Windows | 否 |
| 磁盘 0 P4（D:） | Windows | 仅缩小尾部边界 |
| 磁盘 0 P5（WinRE） | Windows 恢复 | 否 |
| 磁盘 0 P6（DELLSUPPORT） | Dell | 否 |
| 磁盘 0 P7/P8/P9 | Ubuntu | 新建 |
| 磁盘 1 P1（E:） | Windows 数据 | **否** |

### 阶段状态机

```
预检通过 → 下载校验 → 压缩 D:（原子，失败自动回滚）
        → 制作 U 盘 → 试运行实测 → 渲染 YAML → 自动安装 → GRUB 验证 → Windows 侧校验
```

每阶段幂等：重复执行已完成阶段只会提示"已满足"，不会造成额外损害。

### 失败点与恢复

| 失败点 | 现象 | 恢复 |
| --- | --- | --- |
| ISO 校验不符 | 脚本中止 | 重新下载 |
| D: 压缩失败 | Windows 自动回滚，D: 原样 | 排除占用后重跑 |
| D: 可压缩量不足 | 脚本报出实测可用量并中止 | 迁移 D: 尾部文件，或改用更小的目标值 |
| 试运行识别不符 | 手动中止，未动任何分区 | 修正 match 或重做压缩 |
| curtin 校验 offset 失败 | 安装器报错中止，未写盘 | 用实测值重新渲染 YAML |
| 自动安装未触发 | 进入常规 GUI 流程 | 按 `e` 加 ` autoinstall`，或走 `GUIDE-GUI.md` |
| GRUB 未出现在 F12 | 固件未枚举新 ESP | `05-grub-repair.md` |
| Windows 完全无法启动 | 极端情况 | 拔掉机械盘；固件应仍能从磁盘 0 的 P1 引导 Windows |

### 回滚

- 删除磁盘 0 的 P7/P8/P9。
- D: 保持压缩后容量（不会自动还原，需要时反向扩展）。
- P1–P6 自始至终未被触碰，无需恢复。

---

## 八、测试与验收标准

安装完成后逐条核对，任一条不通过即视为未完成：

1. ISO SHA256 与官方 `SHA256SUMS` 一致。
2. `layout-after-shrink.json` 记录显示：D: 容量减少目标值，C:/D: 盘符不变，P5/P6 的 offset 与 size 与阶段 0 快照**完全一致**。
3. 试运行阶段 `lsblk` 显示：恰有 1 个设备为 `ACASIS EC-7351`，且其尾部有目标大小的未分配空间。
4. 自动安装完成后，`lsblk -f` 看到 `/dev/sdX7` FAT32（ESP）、`sdX8` swap、`sdX9` ext4 挂载于 `/`，容量与渲染值一致。
5. `efibootmgr` 中存在指向该 ESP 的 `ubuntu` 启动项。
6. 回 Windows 执行 `04-verify-after-install.ps1`：C:/D:/E: 容量与盘符正常，磁盘 0 的 P1–P6 与阶段 0 快照逐字段一致。
7. F12 启动菜单中 `ubuntu` 与 `Windows Boot Manager` 均存在。
8. 从 GRUB 菜单能成功进入 Windows Boot Manager，Windows 11 正常开机。

---

## 九、风险登记

| 风险 | 等级 | 缓解 |
| --- | --- | --- |
| curtin version 2 语义会删除未声明分区，漏声明即毁盘 | **高** | 六个现有分区全部显式声明 + `preserve: true` + 精确 offset；offset 不符即报错中止 |
| `offset` 在默认 config version 1 下不生效，分区可能落到错误位置 | **高** | 试运行实测落点；必要时通过 `early-commands` 替换为已实测的 YAML |
| D: 实际可压缩量不足 150 GiB | 中 | 预检用 `Get-PartitionSupportedSize` 取权威值，自适应下调；不足 60 GiB 则中止 |
| Linux 下 udev `ID_MODEL` 字符串与预期不符 | 中 | 试运行实测后填入；`model` 用 glob 前缀；匹配不到即中止 |
| 自动安装未触发 | 中 | CIDATA + 介质根目录双投递；`e` 键追加 ` autoinstall` 兜底；`GUIDE-GUI.md` 兜底 |
| 固件不枚举新 ESP 导致 GRUB 不出现 | 中 | `05-grub-repair.md` |
| 本会话非管理员，`Get-PartitionSupportedSize` 无法调用 | 中 | 已确认；预检脚本首项即查 |
| `fs: swap`（action 语法下为 `fstype: swap`）行为异常 | 低 | curtin 文档明确支持 `fstype: swap`；异常时改用 swap 文件 |
| 执行中拔盘/断电 | 低 | 操作清单中明确标注 |

---

## 十、已确认的决策

| 决策项 | 结论 |
| --- | --- |
| 目标磁盘 | 磁盘 0 `ACASIS EC-7351`（NVMe 盒，系统盘） |
| E: 盘（机械盘） | 完全不参与，不动一个字节 |
| 腾空间方式 | 压缩 D:，不删恢复分区 |
| 版本 | Ubuntu 26.04.1 LTS (Resolute Raccoon) |
| 加密 | 不加密，ext4 明文 |
| 安装方式 | 无人值守（`autoinstall.yaml`）+ 图形安装器兜底 |
| 安装 U 盘 | 用户自行准备 ≥ 16 GB 空 U 盘 |
| Ubuntu 账户 | 用户名 `wayyet`（沿用 Windows 用户名） |

## 十一、待定项（实施时确定，不阻塞）

- Linux 下的 hostname：`wayyet-ubuntu` 为默认值，可改。
- Ubuntu 密码哈希：在渲染脚本中生成，届时由用户在本机设置。
- 是否启用 `nvidia`/`oem` 元包：本机为 Intel 核显，默认不装 OEM 元包。
- swap 大小 8 GiB 为默认值；若试运行决定改用 swap 文件，同步调整 P8。