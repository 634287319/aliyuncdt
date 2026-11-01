# 阿里云 CDT 出网流量自动监控与超限自动关机

> 专为**阿里云 ECS + CDT（云数据传输）**出网流量计费场景打造。
> 解决市面上流量监控工具"**统计口径不对 → 关机时机不准 → 白花钱或误关机**"的核心问题。

[English](README_EN.md) | [简体中文](README.md)

---

## ⚠️ 先说结论：为什么市面上的监控都不准

绝大多数开源流量监控脚本（以及云厂商控制台自带的统计）都存在下面几个问题，**每一个都会导致你的账单和预期对不上**：

| 常见问题 | 具体表现 | 后果 |
|---|---|---|
| **① 时区不是北京时间** | 服务器默认 `UTC`，脚本直接 `date` 取时间 | 阿里云 CDT 按**北京时间**（UTC+8）重置月流量。你用 UTC 算，等于**每天差 8 小时** |
| **② 用 1024 进制算 GB** | `GB_UNIT=$((1024*1024*1024))` | 阿里云 CDT 按**十进制**（1 GB = 1,000,000,000 字节）计费。1024 进制会**少算约 7%**，阈值形同虚设 |
| **③ 跨月重置时机错误** | `0 0 1 * *` 依赖系统时区 | 服务器是 UTC 时，实际在**北京时间 8:00** 才重置。**月初 0:00–8:00 的流量算到了上个月**，你会被"莫名其妙"关机 |
| **④ 关机跨月就漏重置** | 只靠 cron 定时重置 | 跨月当天凌晨关机 → **cron 根本没跑** → 开机后流量没清零，继续按上个月的额度扣 |
| **⑤ 数据延迟 5 分钟** | vnstat 默认 `UpdateInterval 300` | 流量早已超限，监控还显示"未超"，**白白多跑 5 分钟** |
| **⑥ 统计了 RX 或把 RX+TX 混算** | 取错 vnstat 字段 | CDT 只对**出网（TX）**计费，把入向算进来会让你**提前关机** |

> **本项目逐条解决了以上全部 6 个问题。**

---

## 🎯 本项目的核心特性

### 1️⃣ 严格按阿里云 CDT 的「北京时间」重置月流量

```bash
# 部署时强制把系统时区切成北京时间
timedatectl set-timezone Asia/Shanghai

# cron 任务用 CRON_TZ 强制按北京时间解析时间字段（双保险）
CRON_TZ=Asia/Shanghai 0 0 1 * * /usr/bin/vnstat -i ens5 --reset
```

**双保险机制**：
- 系统时区 = `Asia/Shanghai`（`date '+%Z %z'` 显示 `CST +0800`）
- cron 任务头带 `CRON_TZ=Asia/Shanghai`（即便系统时区被人改回去，重置依然按北京时间）

### 2️⃣ 跨月立即重置 —— 关机跨月也不漏

**三道防线**，任何一种情况都能正确重置：

| 防线 | 触发时机 | 覆盖场景 |
|---|---|---|
| ① `CRON_TZ` cron 任务 | 每月 1 日 00:00（北京时间） | 正常在线 |
| ② **开机补偿检测** | 每次检测时比对年月 | **跨月凌晨关机，2:00 才开机** → 开机后 1 分钟内自动重置 |
| ③ vnstat 自身 `MonthRotate` | 数据库分段轮转 | 数据库内部月份归属正确 |

**原理**：持久化记录上次重置的年月（`/root/vnstat_reset.state`），每次检测时比对当前北京时间年月，不一致就立即 `--reset`。

### 3️⃣ 严格使用 1000 进制（与阿里云 CDT 计费口径完全一致）

```bash
GB_UNIT=1000000000        # 1 GB = 1,000,000,000 字节，不是 1024^3
TX_GB=$(echo "scale=4; ${TX_BYTES}/${GB_UNIT}" | bc)
```

### 4️⃣ 只统计出网流量（TX），不混入入向

从 vnstat 按字节取**第 10 列**（当前月累计 rx + tx），与阿里云 CDT 的出网计费口径对齐。

### 5️⃣ 一键查询命令 `traffic`

部署完成后，SSH 登录直接敲：

```bash
traffic
```

```
========================================
        阿里云 ECS 流量统计
========================================
北京时间：2026-10-03 14:21:42
当前月份：2026-10
出口网卡：ens5
本月TX流量：2.7393 GB
流量阈值：2.66 GB
剩余流量：0.0000 GB
使用率　：102.9%
状态　　：🔴 即将关机（>=90%）
========================================
进度：[████████████████████]
```

---

## 📦 仓库文件说明

本仓库只有两个脚本，请根据你的需求选择：

| 文件 | 统计粒度 | 说明 |
|---|---|---|
| **`aliyuncdtquest+traffic.sh`** | **5 分钟** | 默认 vnstat 粒度（`UpdateInterval 300`），CPU/IO 开销最小 |
| **`aliyuncdtquest+traffic-1.sh`** | **1 分钟** | 强制 vnstat 1 分钟粒度（`UpdateInterval 60` + `SaveInterval 1`）+ `vnstat --sync` 实时刷新，**数据延迟最低** |

> 💡 **推荐**：如果你的机器配置一般、对流量精度要求不高 → 用 5 分钟版；
> 如果你**流量费很贵**、希望**第一时间发现超限立刻停机** → 用 1 分钟版。

两个脚本的**部署方式、使用方法完全一致**，只是内部统计精度不同。

---

## 🚀 快速开始

### 环境要求

- 阿里云 ECS（Ubuntu 20.04 / 22.04 / Debian 等 apt 系）
- root 权限
- 出口网卡可自动识别（走默认路由的那块）

### 一键部署（推荐）

**直接在线执行，无需上传文件：**

```bash
# 5 分钟版（CPU/IO 开销最小）
wget -O - https://raw.githubusercontent.com/634287319/aliyuncdt/main/aliyuncdtquest+traffic.sh | bash -s -- 190

# 1 分钟版（数据延迟最低，推荐流量费较贵时使用）
wget -O - https://raw.githubusercontent.com/634287319/aliyuncdt/main/aliyuncdtquest+traffic-1.sh | bash -s -- 190
```

> 📌 最后的 `190` 是**流量阈值（GB）**，请按你的实际需求修改。
> 阿里云 CDT 按十进制计费，1 GB = 1,000,000,000 字节。

**或者手动下载后执行：**

```bash
wget https://raw.githubusercontent.com/634287319/aliyuncdt/main/aliyuncdtquest+traffic-1.sh
bash aliyuncdtquest+traffic-1.sh
```

> ⚠️ 强烈建议先 `wget` 下载再 `cat` 审阅一遍再执行，管道直接 `bash` 不会留存文件。

部署脚本会自动完成：

- ✅ 强制设置系统时区为 `Asia/Shanghai`
- ✅ 自动安装 `cron` / `vnstat` / `bc`（缺失时）
- ✅ 配置 vnstat 统计粒度（1 分钟版会改为 60 秒）
- ✅ 自动识别出口网卡（默认路由网卡）
- ✅ 生成检测脚本 `/root/check.sh`
- ✅ 生成查询脚本 `/root/quest_traffic.sh`
- ✅ 创建全局命令 `traffic`
- ✅ 写入 cron 任务（每分钟检测 + 每月 1 日北京时间 0 点重置）

### 参数说明

```bash
# 部署（阈值单位 GB，按阿里云 CDT 十进制）
bash aliyuncdtquest+traffic.sh 195

# 查询当前流量统计
bash aliyuncdtquest+traffic.sh query

# 部署完成后，任意目录直接敲
traffic
```

### 部署完成后验证

```bash
# 1. 时区必须是 CST +0800
date '+%Z %z'

# 2. cron 任务必须存在
crontab -l

# 3. vnstat 配置（1 分钟版应为 UpdateInterval 60）
grep -E 'UpdateInterval|SaveInterval' /etc/vnstat.conf

# 4. 观察日志，确认每分钟都在检测
tail -f /root/shutdown_debug.log
```

---

## 🔄 重新部署 / 清理

```bash
# 清理所有部署产物
crontab -r 2>/dev/null
pkill -f cron 2>/dev/null
rm -f /root/check.sh /root/quest_traffic.sh /root/traffic_limit_gb
rm -f /root/vnstat_reset.state /root/shutdown.lock /root/shutdown_debug.log
rm -f /usr/local/bin/traffic
```

---

## 📁 运行时生成的文件

| 路径 | 用途 |
|---|---|
| `/root/check.sh` | 每分钟执行的检测 + 超限关机脚本 |
| `/root/quest_traffic.sh` | 流量查询脚本（`traffic` 命令指向它） |
| `/root/traffic_limit_gb` | 存放流量阈值（GB） |
| `/root/vnstat_reset.state` | 上次重置的年月（跨月检测用） |
| `/root/shutdown_debug.log` | 检测与关机日志 |
| `/usr/local/bin/traffic` | 全局 `traffic` 命令软链 |
| `/etc/vnstat.conf` | vnstat 配置（备份在 `vnstat.conf.bak`） |

---

## ❓ 常见问题

### Q1：为什么我之前用别的脚本没自动关机？

大概率是下面之一：

1. **服务器时区是 UTC** → cron 的 `0 0 1 * *` 在北京时间 8:00 才跑
2. **cron 守护进程没启动** → 容器/精简镜像常见，`crontab -l` 有任务但没人执行
3. **`systemctl poweroff` 被 systemd-logind 拦截** → 建议改用 `shutdown -h now`

本项目已针对第 2、3 点做了防护（部署时强制拉起 cron 并验证、日志记录每一步关机尝试）。

### Q2：关机后统计会丢吗？

**不会。** vnstat 的数据库在 `/var/lib/vnstat/`，关机/重启均不丢失。
唯一会清零的是手动执行 `vnstat --reset`，请勿在非跨月时手动执行。

### Q3：`CST` 是哪个时区？

`CST` 缩写有多种含义，但**只要偏移是 `+0800` 就是中国标准时间（北京时间）**。
本项目部署后会显示 `CST +0800`，并额外校验 IANA 时区名。

### Q4：1 分钟版和 5 分钟版能同时装吗？

**不建议**。两者都会写 `/root/check.sh` 和同一份 vnstat 数据库，后部署的会覆盖前者。
请先清理再部署另一个。

### Q5：阈值为 2.66 GB 时已经超限了，部署完会立刻关机吗？

**会。** 这是预期行为（脚本一部署就检测）。如果想先观察，可临时传入较大阈值部署，
再用 `sed -i 's/LIMIT_GB=".*"/LIMIT_GB="2.66"/' /root/check.sh` 改回。

---

## 📄 说明

- 本项目使用 `vnstat` 采集网卡计数器数据，`bc` 进行高精度除法
- 关机动作由系统命令执行，请确保脚本以 root 运行
- 请根据实际业务场景设置合理的流量阈值

## ⭐ Star

如果这个项目帮你省下了不必要的流量费，欢迎点个 ⭐ Star 支持！
