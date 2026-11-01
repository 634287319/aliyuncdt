# Alibaba Cloud CDT Egress Traffic Monitor & Auto Shutdown

> Purpose-built for **Alibaba Cloud ECS + CDT (Cloud Data Transfer)** egress billing.
> Fixes the core problem with off-the-shelf traffic monitors: **wrong accounting basis → wrong shutdown timing → wasted money or premature shutdowns**.

[English](README_EN.md) | [简体中文](README.md)

---

## ⚠️ TL;DR — Why Most Traffic Monitors Are Inaccurate

Nearly every open-source traffic monitoring script (and most cloud-console stats) has the following defects. **Each one makes your bill differ from your expectation**:

| Common Problem | How It Manifests | Consequence |
|---|---|---|
| **① Not on Beijing time** | Server defaults to `UTC`, script calls `date` directly | Alibaba Cloud CDT resets monthly traffic on **Beijing time (UTC+8)**. Using UTC means you're **off by 8 hours every single day** |
| **② Uses 1024-based GB** | `GB_UNIT=$((1024*1024*1024))` | Alibaba Cloud CDT bills in **decimal** (1 GB = 1,000,000,000 bytes). 1024-based math **under-counts by ~7%**, making your threshold effectively meaningless |
| **③ Wrong month-reset timing** | `0 0 1 * *` relies on the system timezone | On a UTC server it actually fires at **08:00 Beijing time**. Traffic from 00:00–08:00 on the 1st gets billed to the **wrong month** — and you get shut down for no reason |
| **④ Misses reset when powered off across month boundary** | Reset depends solely on cron | If the machine is **off at midnight** on the 1st, cron never runs → traffic isn't cleared on boot → you keep burning last month's quota |
| **⑤ 5-minute data lag** | vnstat defaults to `UpdateInterval 300` | Traffic is already over the limit, but the monitor still says "OK" — **you waste 5 more minutes paying for it** |
| **⑥ Counts RX or mixes RX+TX** | Wrong vnstat field selected | CDT only bills **egress (TX)**. Including inbound traffic makes you **shut down prematurely** |

> **This project fixes all 6 issues above.**

---

## 🎯 Key Features

### 1️⃣ Monthly reset strictly on Beijing time, exactly as Alibaba Cloud CDT does

```bash
# Force the system timezone to Beijing time at deploy time
timedatectl set-timezone Asia/Shanghai

# CRON_TZ forces cron to parse the time fields in Beijing time (belt-and-suspenders)
CRON_TZ=Asia/Shanghai 0 0 1 * * /usr/bin/vnstat -i ens5 --reset
```

**Two layers of protection**:
- System timezone = `Asia/Shanghai` (`date '+%Z %z'` shows `CST +0800`)
- Cron job carries `CRON_TZ=Asia/Shanghai` — even if someone changes the system timezone back, the reset still fires on Beijing time

### 2️⃣ Immediate reset across month boundaries — even if powered off

**Three independent defenses** — every scenario is covered:

| Defense | Trigger | Covers |
|---|---|---|
| ① `CRON_TZ` cron job | 00:00 on the 1st (Beijing time) | Normal online operation |
| ② **Boot-time compensation check** | Every check compares year-month | **Powered off at midnight, booted at 02:00** → auto-reset within 1 minute of boot |
| ③ vnstat's own `MonthRotate` | Database period rotation | Month attribution inside the database stays correct |

**How it works**: the last reset year-month is persisted (`/root/vnstat_reset.state`). Each run compares it against the current Beijing year-month; if they differ, an immediate `--reset` is issued.

### 3️⃣ Strict 1000-based (decimal) GB — identical to Alibaba Cloud CDT billing

```bash
GB_UNIT=1000000000        # 1 GB = 1,000,000,000 bytes, NOT 1024^3
TX_GB=$(echo "scale=4; ${TX_BYTES}/${GB_UNIT}" | bc)
```

### 4️⃣ Egress-only (TX) accounting — inbound traffic never counted

Reads vnstat's **column 10** in byte mode (current month cumulative rx + tx), aligned with CDT's egress billing basis.

### 5️⃣ One-command query: `traffic`

After deployment, just SSH in and type:

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

## 📦 Repository Files

This repo contains exactly two scripts. Pick the one that fits your needs:

| File | Granularity | Description |
|---|---|---|
| **`aliyuncdtquest+traffic.sh`** | **5 minutes** | Default vnstat granularity (`UpdateInterval 300`) — lowest CPU/IO overhead |
| **`aliyuncdtquest+traffic-1.sh`** | **1 minute** | Forces vnstat to 1-minute granularity (`UpdateInterval 60` + `SaveInterval 1`) and uses `vnstat --sync` for live refresh — **lowest data latency** |

> 💡 **Recommendation**: On a modest server where precision isn't critical → use the 5-minute version.
> If **egress traffic is expensive** and you want to **detect the breach and shut down immediately** → use the 1-minute version.

Both scripts have **identical deployment steps and usage**; they differ only in internal sampling precision.

---

## 🚀 Quick Start

### Requirements

- Alibaba Cloud ECS (Ubuntu 20.04 / 22.04 / Debian, or any apt-based distro)
- Root privileges
- An egress interface detectable via the default route

### One-Liner Deploy (Recommended)

**Run directly from GitHub — no file upload needed:**

```bash
# 5-minute version (lowest overhead)
wget -O - https://raw.githubusercontent.com/634287319/aliyuncdt/main/aliyuncdtquest+traffic.sh | bash -s -- 190

# 1-minute version (lowest latency — recommended when egress is costly)
wget -O - https://raw.githubusercontent.com/634287319/aliyuncdt/main/aliyuncdtquest+traffic-1.sh | bash -s -- 190
```

> 📌 The trailing `190` is the **traffic threshold in GB** — adjust it to your needs.
> Alibaba Cloud CDT bills in decimal: 1 GB = 1,000,000,000 bytes.

**Or download first, review, then execute:**

```bash
wget https://raw.githubusercontent.com/634287319/aliyuncdt/main/aliyuncdtquest+traffic-1.sh
cat aliyuncdtquest+traffic-1.sh
bash aliyuncdtquest+traffic-1.sh
```

> ⚠️ Piping straight into `bash` leaves no file behind — downloading first lets you audit the script.

The deployment script automatically:

- ✅ Forces the system timezone to `Asia/Shanghai`
- ✅ Auto-installs `cron` / `vnstat` / `bc` if missing
- ✅ Configures vnstat sampling granularity (the 1-minute version switches it to 60s)
- ✅ Auto-detects the egress interface (default-route interface)
- ✅ Generates the check script `/root/check.sh`
- ✅ Generates the query script `/root/quest_traffic.sh`
- ✅ Creates the global `traffic` command
- ✅ Installs cron jobs (per-minute check + monthly reset at 00:00 Beijing time on the 1st)

### Parameters

```bash
# Deploy (threshold in GB, decimal basis)
bash aliyuncdtquest+traffic.sh 195

# Query current traffic stats
bash aliyuncdtquest+traffic.sh query

# After deployment, from any directory
traffic
```

### Verify After Deployment

```bash
# 1. Timezone MUST be CST +0800
date '+%Z %z'

# 2. Cron jobs MUST be present
crontab -l

# 3. vnstat config (1-minute version should show UpdateInterval 60)
grep -E 'UpdateInterval|SaveInterval' /etc/vnstat.conf

# 4. Watch the log — it should update every minute
tail -f /root/shutdown_debug.log
```

---

## 🔄 Redeploy / Cleanup

```bash
# Remove every deployment artifact
crontab -r 2>/dev/null
pkill -f cron 2>/dev/null
rm -f /root/check.sh /root/quest_traffic.sh /root/traffic_limit_gb
rm -f /root/vnstat_reset.state /root/shutdown.lock /root/shutdown_debug.log
rm -f /usr/local/bin/traffic
```

---

## 📁 Runtime Artifacts

| Path | Purpose |
|---|---|
| `/root/check.sh` | Per-minute check + shutdown-on-breach script |
| `/root/quest_traffic.sh` | Query script (the `traffic` command points here) |
| `/root/traffic_limit_gb` | Stores the traffic threshold (GB) |
| `/root/vnstat_reset.state` | Year-month of the last reset (for cross-month detection) |
| `/root/shutdown_debug.log` | Check & shutdown logs |
| `/usr/local/bin/traffic` | Global `traffic` command symlink |
| `/etc/vnstat.conf` | vnstat configuration (backed up to `vnstat.conf.bak`) |

---

## ❓ FAQ

### Q1: Why didn't my previous script auto-shut-down?

Most likely one of these:

1. **Server timezone is UTC** → cron's `0 0 1 * *` actually fires at 08:00 Beijing time
2. **The cron daemon isn't running** → common in containers/minimal images; `crontab -l` shows the job but nobody executes it
3. **`systemctl poweroff` is blocked by systemd-logind** → use `shutdown -h now` instead

This project already guards against #2 and #3 (the deploy step force-starts and verifies cron, and every shutdown attempt is logged).

### Q2: Is the statistics lost when the machine shuts down?

**No.** vnstat's database lives in `/var/lib/vnstat/` and survives shutdowns/restarts.
The only thing that clears it is a manual `vnstat --reset` — avoid running that outside a month boundary.

### Q3: Which timezone does `CST` refer to?

`CST` is ambiguous across regions, but **an offset of `+0800` always means China Standard Time (Beijing time)**.
After deployment this project shows `CST +0800` and additionally verifies the IANA timezone name.

### Q4: Can I install both the 1-minute and 5-minute versions together?

**Not recommended.** Both write to `/root/check.sh` and share the same vnstat database, so the later deployment overwrites the earlier one.
Clean up first, then deploy the other.

### Q5: My traffic is already over the threshold (e.g. 2.66 GB) — will it shut down immediately after deploying?

**Yes**, and that's expected behavior (the script checks right after deployment).
If you'd rather observe first, deploy with a large threshold, then adjust it:

```bash
sed -i 's/LIMIT_GB=".*"/LIMIT_GB="2.66"/' /root/check.sh
```

---

## 📄 Notes

- Traffic counters are collected via `vnstat`; high-precision division is done with `bc`
- The shutdown action is executed by system commands — the script must run as root
- Please set a reasonable traffic threshold according to your actual business scenario

## ⭐ Star

If this project saved you from unnecessary egress charges, a ⭐ Star is greatly appreciated!
