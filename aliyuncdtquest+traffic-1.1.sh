#!/bin/bash
# 阿里云ECS 仅统计TX出网流量监控，超限关机【自动识别出口网卡】
# 参数 $1=流量阈值GB  网卡自动识别，不再需要传入网卡
# 阿里云CDT按10进制计费（1 GB = 1,000,000,000 字节），全脚本统一使用北京时间
# bash aws_out_traffic.sh 195

if [ $# -ne 1 ]; then
    echo "用法: $0 <阈值GB|query>"
    echo "示例1（部署）: $0 195"
    echo "示例2（查询）: $0 query"
    exit 1
fi

# =========query 子命令：查询当前流量统计=========
if [[ "$1" == "query" ]]; then
    QUERY_SCRIPT="/root/quest_traffic.sh"
    if [[ -f "${QUERY_SCRIPT}" ]]; then
        bash "${QUERY_SCRIPT}"
    else
        echo "错误：查询脚本 ${QUERY_SCRIPT} 不存在，请先执行部署: $0 bash <阈值GB>"
        exit 1
    fi
    exit 0
fi

traffic_limit_gb="$1"
# =========自动识别默认路由出口网卡=========
interface_name=$(ip route show default | awk '/default/ {print $5}')
if [[ -z "${interface_name}" ]];then
    echo "错误：自动识别网卡失败，请检查系统默认路由！"
    exit 1
fi

SCRIPT_PATH="/root/check.sh"
LOG_FILE="/root/shutdown_debug.log"

# =========强制设置系统时区为北京时间（保证cron重置和日志时间准确）=========
if command -v timedatectl &> /dev/null; then
    timedatectl set-timezone Asia/Shanghai 2>/dev/null
elif [ -f /usr/share/zoneinfo/Asia/Shanghai ]; then
    ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
    echo "Asia/Shanghai" > /etc/timezone
fi
export TZ='Asia/Shanghai'

# =========禁用 unattended-upgrades 自动更新=========
# 原因：
#   1. unattended-upgrades 会在随机时间锁住 dpkg，导致本脚本 apt install 失败
#   2. 它可能恰好在每月1号凌晨跑更新，撞上流量重置任务
#   3. 监控机器不需要自动安全更新（更新完通常也要重启才生效，反而中断监控）
# 如需恢复：systemctl enable --now unattended-upgrades
disable_unattended_upgrades() {
    # 停止当前正在跑的
    systemctl stop unattended-upgrades.service 2>/dev/null
    systemctl disable unattended-upgrades.service 2>/dev/null
    service unattended-upgrades stop 2>/dev/null

    # 屏蔽 apt 定时更新
    if [[ -d /etc/apt/apt.conf.d ]]; then
        cat > /etc/apt/apt.conf.d/20auto-upgrades <<'UEOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
APT::Periodic::AutocleanInterval "0";
UEOF
        echo ">>> 已禁用 apt 自动更新（/etc/apt/apt.conf.d/20auto-upgrades）"
    fi

    # 屏蔽 systemd timer（Ubuntu 20.04+ 用 apt-daily.timer / apt-daily-upgrade.timer）
    for t in apt-daily.timer apt-daily-upgrade.timer; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^${t}"; then
            systemctl disable "${t}" 2>/dev/null
            systemctl stop "${t}" 2>/dev/null
        fi
    done

    # 屏蔽 /etc/cron.daily 里的相关脚本
    for f in /etc/cron.daily/apt-daily /etc/cron.daily/apt-compat /etc/cron.daily/unattended-upgrade; do
        [[ -f "${f}" ]] && chmod -x "${f}" 2>/dev/null
    done
}

disable_unattended_upgrades
echo ""

# =========apt 锁等待工具=========
# Ubuntu/Debian 的 unattended-upgrades 会锁住 dpkg，导致 apt install 失败
# 这里主动等待锁释放，超时后再尝试
wait_apt_lock() {
    local timeout="${1:-180}"
    local waited=0
    echo ">>> 等待 apt/dpkg 锁释放（最多 ${timeout} 秒）..."
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
          fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
        if [ "${waited}" -ge "${timeout}" ]; then
            echo ">>> ⚠️  等待锁超时（${timeout}s），可能 unattended-upgrades 正在更新内核"
            echo ">>>    建议：稍后重试，或执行 'sudo systemctl stop unattended-upgrades' 后再运行"
            return 1
        fi
        sleep 5
        waited=$((waited + 5))
        if [ $((waited % 30)) -eq 0 ]; then
            echo ">>>    已等待 ${waited} 秒..."
        fi
    done
    echo ">>> apt 锁已释放"
    return 0
}

# 安全执行 apt（自动等待锁 + 失败重试一次）
safe_apt() {
    local action="$1"   # update / install
    shift
    local pkgs="$*"

    if ! wait_apt_lock 180; then
        # 尝试停止自动更新，释放锁
        systemctl stop unattended-upgrades 2>/dev/null
        service unattended-upgrades stop 2>/dev/null
        sleep 3
        wait_apt_lock 60 || true
    fi

    if [ "${action}" = "update" ]; then
        DEBIAN_FRONTEND=noninteractive apt-get update -y 2>&1 | tail -3
    else
        DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Use-Pty=0 "${pkgs}" 2>&1 | tail -5
    fi
    return 0
}

# =========自动安装 cron =========
if ! command -v crontab &> /dev/null
then
    echo ">>> 未检测到crontab，开始安装cron定时服务..."
    safe_apt update
    safe_apt install cron
    sleep 2
fi

# =========自动安装 vnstat =========
if ! command -v vnstat &> /dev/null
then
    echo ">>> 安装vnstat流量统计工具..."
    safe_apt update
    safe_apt install vnstat
    sleep 4
fi

# =========配置 vnstat 为1分钟统计粒度（默认5分钟）=========
# vnstatd 的 UpdateInterval 默认 300 秒（5分钟），改为 60 秒（1分钟）
# SaveInterval 默认 5（分钟），改为 1 让落盘也保持1分钟一致
# 注意：发行版默认配置里这些项前面带 ';' 是注释状态，必须同时处理
#       ;UpdateInterval 20  →  UpdateInterval 60
#       UpdateInterval 20   →  UpdateInterval 60
configure_vnstat_1min() {
    local conf="/etc/vnstat.conf"
    if [[ ! -f "${conf}" ]]; then
        echo ">>> ⚠️  未找到 ${conf}，vnstat 可能未使用配置文件"
        return
    fi
    # 备份原配置
    [[ -f "${conf}.bak" ]] || cp "${conf}" "${conf}.bak"

    # ---------- 通用配置项设置函数 ----------
    # 参数1: 配置项名  参数2: 目标值
    set_vnstat_opt() {
        local key="$1" val="$2"
        # 情况1: 已有未注释的有效配置项 → 直接替换值
        if grep -qE "^\s*${key}\s+" "${conf}"; then
            sed -i "s|^\s*${key}\s\+.*|${key} ${val}|" "${conf}"
        # 情况2: 只有注释掉的版本（;UpdateInterval 20）→ 取消注释并改值
        elif grep -qE "^\s*;\s*${key}\s" "${conf}"; then
            sed -i "s|^\s*;\s*${key}\s*.*|${key} ${val}|" "${conf}"
        # 情况3: 完全不存在 → 追加到 [global] 段
        else
            sed -i "/^\[global\]/a ${key} ${val}" "${conf}"
        fi
    }

    # UpdateInterval: 读取内核计数器的间隔（秒）
    set_vnstat_opt "UpdateInterval" "60"
    # SaveInterval: 内存数据落盘间隔（分钟）
    set_vnstat_opt "SaveInterval" "1"

    # 各网卡独立配置段 [ifs] 也统一处理一遍
    if grep -q '^\[ifs\]' "${conf}"; then
        sed -i '/^\[ifs\]/,/^\[/ s|^\s*;\?\s*UpdateInterval\s*.*|UpdateInterval 60|' "${conf}"
        sed -i '/^\[ifs\]/,/^\[/ s|^\s*;\?\s*SaveInterval\s*.*|SaveInterval 1|' "${conf}"
    fi

    echo ">>> vnstat 配置结果："
    grep -nE '^\s*UpdateInterval|^\s*SaveInterval' "${conf}" | sed 's/^/    /'
}

configure_vnstat_1min

# 重启 vnstatd 让新配置生效（兼容 systemd / SysV / 裸进程）
if command -v systemctl &> /dev/null && [[ -d /run/systemd/system ]]; then
    if systemctl list-unit-files 2>/dev/null | grep -q "vnstat.service"; then
        systemctl restart vnstat 2>/dev/null
    fi
    sleep 2
fi
if ! pgrep -x vnstatd >/dev/null 2>&1; then
    pkill -x vnstatd 2>/dev/null
    sleep 1
    vnstatd 2>/dev/null &
    sleep 2
fi
pgrep -af vnstatd | head -1

# =========自动安装 bc 计算器 =========
if ! command -v bc &> /dev/null
then
    echo ">>> 未检测到bc，安装bc计算工具..."
    safe_apt update
    safe_apt install bc
fi

# 校验网卡是否存在
if ! ip link show "${interface_name}" >/dev/null 2>&1;then
    echo "错误：网卡 ${interface_name} 不存在！"
    exit 1
fi

# 创建vnstat网卡数据库
vnstat --create -i "${interface_name}" 2>/dev/null

# 预先创建日志文件
touch "${LOG_FILE}"

# =========直接完整写入check.sh，不再使用sed替换=========
cat > "${SCRIPT_PATH}" <<'EOF'
#!/bin/bash
export TZ='Asia/Shanghai'
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
NET_IF="__INTERFACE__"
LIMIT_GB="__LIMIT_GB__"
LOG="/root/shutdown_debug.log"
STATE_FILE="/root/vnstat_reset.state"

[ ! -f "${LOG}" ] && touch "${LOG}"

# =========跨月补偿重置（开机补刀，防止cron错过）=========
# 当前北京时间年月，例如 202610
CUR_YM=$(date '+%Y%m')
LAST_YM=""
[ -f "${STATE_FILE}" ] && LAST_YM=$(cat "${STATE_FILE}" 2>/dev/null)
if [[ "${CUR_YM}" != "${LAST_YM}" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 检测到跨月（上次:${LAST_YM:-无} 当前:${CUR_YM}），立即重置vnstat" >> "${LOG_FILE}"
    /usr/bin/vnstat -i "${NET_IF}" --reset >> "${LOG_FILE}" 2>&1
    echo "${CUR_YM}" > "${STATE_FILE}"
fi

TX_BYTES=$(/usr/bin/vnstat --sync --oneline b -i "${NET_IF}" 2>/dev/null | awk -F';' '{print $10}')
# --sync 失败时回退到普通读取
if [[ -z "${TX_BYTES}" || ! "${TX_BYTES}" =~ ^[0-9]+$ ]]; then
    TX_BYTES=$(/usr/bin/vnstat --oneline b -i "${NET_IF}" 2>/dev/null | awk -F';' '{print $10}')
fi

# 空值防御：vnstat没有拿到数据直接跳过，避免integer expression expected报错
if [[ -z "${TX_BYTES}" || ! "${TX_BYTES}" =~ ^[0-9]+$ ]];then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 网卡${NET_IF}：vnstat流量数据无效，跳过本次检测" >> "${LOG}"
    exit 0
fi

# 阿里云CDT按10进制计费：1 GB = 1,000,000,000 字节（不是1024^3）
GB_UNIT=1000000000
TX_GB=$(echo "scale=4; ${TX_BYTES}/${GB_UNIT}" | bc)

echo "[$(date '+%Y-%m-%d %H:%M:%S')] 网卡${NET_IF} 出网TX:${TX_GB}GB 阈值:${LIMIT_GB}GB" >> "${LOG}"

COMP_RESULT=$(echo "${TX_GB} >= ${LIMIT_GB}" | bc)
if [ "${COMP_RESULT}" -eq 1 ];then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] !!!流量达到阈值，执行关机" >> "${LOG}"
    # 优先用 shutdown 命令（走 sysvinit 兼容路径，绕开 systemd-logind 拦截）
    if [ -x /usr/sbin/shutdown ]; then
        /usr/sbin/shutdown -h now "流量超限自动关机：TX=${TX_GB}GB"
    elif [ -x /sbin/shutdown ]; then
        /sbin/shutdown -h now "流量超限自动关机：TX=${TX_GB}GB"
    else
        systemctl poweroff 2>/dev/null || poweroff -f 2>/dev/null
    fi
fi
EOF

# 替换占位符为真实值（避免heredoc中变量提前展开）
sed -i "s|__INTERFACE__|${interface_name}|g; s|__LIMIT_GB__|${traffic_limit_gb}|g" "${SCRIPT_PATH}"
chmod +x "${SCRIPT_PATH}"

# 同时定义两条 cron 任务，最后一次性写入（避免分两次写互相覆盖）
CRON_JOB="*/1 * * * * /bin/bash ${SCRIPT_PATH} >> ${LOG_FILE} 2>&1"
RESET_JOB="CRON_TZ=Asia/Shanghai 0 0 1 * * /usr/bin/vnstat -i ${interface_name} --reset >> ${LOG_FILE} 2>&1"

# 一次性清掉本脚本管理的两条历史任务（按 SCRIPT_PATH 和 --reset 特征去重）
( crontab -l 2>/dev/null | grep -v -F "${SCRIPT_PATH}" | grep -v -F "--reset" ) | crontab -
# 再一次性追加两条，避免后一次写入覆盖前一次
( crontab -l 2>/dev/null; echo "${CRON_JOB}"; echo "${RESET_JOB}" ) | crontab -

echo ">>> 已添加/刷新crontab检测任务，每1分钟检测一次"
echo ">>> 已添加/刷新每月1号北京时间0点流量重置任务"

# =========关键：确保 cron 守护进程真的在运行==========
# 问题背景：容器/精简镜像里 cron 可能没装、没启用、或 service 文件名是 crond
# 如果 cron 不跑，crontab 里的任务就是摆设
echo ""
echo ">>> 检查并启动 cron 服务..."

# 先确认 crontab 命令可用（apt 安装失败的话这里会报出来）
if ! command -v crontab &> /dev/null; then
    echo ">>> ⚠️  crontab 命令不存在，尝试重新安装 cron..."
    safe_apt update
    safe_apt install cron
    sleep 2
fi

CRON_STARTED=0
# 方式1：systemd（Debian/Ubuntu 用 cron.service，RHEL 系用 crond.service）
if command -v systemctl &> /dev/null && [[ -d /run/systemd/system ]]; then
    for unit in cron crond; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^${unit}.service"; then
            systemctl enable "${unit}" 2>/dev/null
            systemctl restart "${unit}" 2>/dev/null
            if systemctl is-active --quiet "${unit}" 2>/dev/null; then
                echo ">>> ✅ systemd 启动 ${unit}.service 成功"
                CRON_STARTED=1
                break
            fi
        fi
    done
fi

# 方式2：SysV init（老系统）
if [ "${CRON_STARTED}" -eq 0 ] && command -v service &> /dev/null; then
    for svc in cron crond; do
        if service "${svc}" status >/dev/null 2>&1 || [[ -x "/etc/init.d/${svc}" ]]; then
            service "${svc}" start >/dev/null 2>&1
            sleep 1
            if pgrep -x "${svc}" >/dev/null 2>&1 || pgrep -x cron >/dev/null 2>&1; then
                echo ">>> ✅ SysV service 启动 ${svc} 成功"
                CRON_STARTED=1
                break
            fi
        fi
    done
fi

# 方式3：直接跑守护进程（容器场景，没有 init 系统时）
if [ "${CRON_STARTED}" -eq 0 ]; then
    if ! pgrep -x cron >/dev/null 2>&1 && ! pgrep -x crond >/dev/null 2>&1; then
        echo ">>> 尝试直接启动 cron 守护进程..."
        if command -v cron &> /dev/null; then
            cron 2>/dev/null
        elif command -v crond &> /dev/null; then
            crond 2>/dev/null
        fi
        sleep 2
    fi
    if pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1; then
        echo ">>> ✅ 直接启动 cron 守护进程成功"
        CRON_STARTED=1
    fi
fi

# 最终验证
sleep 1
if pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1; then
    echo ">>> ✅ cron 运行中（PID: $(pgrep -x cron 2>/dev/null || pgrep -x crond 2>/dev/null | head -1)）"
else
    echo ">>> ❌ cron 启动失败！定时任务不会执行，请手动排查："
    echo ">>>    systemctl status cron  |  service cron status  |  ls /etc/init.d/"
    CRON_STARTED=0
fi

echo ""
echo "====部署完成===="
echo "网卡：${interface_name}"
echo "出网流量阈值：${traffic_limit_gb} GB（按阿里云CDT 10进制计费）"
echo "时区：$(date '+%Z %z')（应为CST +0800）"
echo "vnstat配置：$(grep -E '^\s*UpdateInterval|^\s*SaveInterval' /etc/vnstat.conf 2>/dev/null | tr '\n' ' ')"
echo "cron状态：$(pgrep -x cron >/dev/null 2>&1 && echo '运行中 ✅' || echo '未运行 ❌')"
echo "crontab任务：$(crontab -l 2>/dev/null | grep -c "${SCRIPT_PATH}") 条检测 + $(crontab -l 2>/dev/null | grep -c -- "--reset") 条重置"
echo "检测脚本路径：${SCRIPT_PATH}"
echo "日志文件：${LOG_FILE}"
echo "查询命令：traffic"
echo "查看定时任务：crontab -l"
echo "实时查看日志：tail -f ${LOG_FILE}"

# =========生成独立查询脚本 /root/quest_traffic.sh=========
cat > "/root/quest_traffic.sh" <<'QEOF'
#!/bin/bash
export TZ='Asia/Shanghai'
NET_IF="__INTERFACE__"
LIMIT_GB_FILE="/root/traffic_limit_gb"
LOG="/root/shutdown_debug.log"

# 兜底时区（防止被cron调用时TZ丢失）
if [[ -z "${TZ:-}" ]] || [[ "${TZ}" != *"Shanghai"* ]]; then
    export TZ='Asia/Shanghai'
fi

[ ! -f "${LOG}" ] && touch "${LOG}"

# 阈值从文件读取（部署时生成）
LIMIT_GB=""
if [[ -f "${LIMIT_GB_FILE}" ]]; then
    LIMIT_GB=$(cat "${LIMIT_GB_FILE}" 2>/dev/null | tr -d '[:space:]')
fi
if [[ -z "${LIMIT_GB}" ]]; then
    echo "错误：未找到阈值文件 ${LIMIT_GB_FILE}，请重新执行部署脚本"
    exit 1
fi

# 当前月份（北京时间）
CUR_MONTH=$(date '+%Y-%m')

# 读取本月TX字节数（--sync 强制刷新内核数据，保证1分钟粒度准确）
TX_BYTES=$(/usr/bin/vnstat --sync --oneline b -i "${NET_IF}" 2>/dev/null | awk -F';' '{print $10}')
if [[ -z "${TX_BYTES}" || ! "${TX_BYTES}" =~ ^[0-9]+$ ]]; then
    TX_BYTES=$(/usr/bin/vnstat --oneline b -i "${NET_IF}" 2>/dev/null | awk -F';' '{print $10}')
fi

# 空值防御
if [[ -z "${TX_BYTES}" || ! "${TX_BYTES}" =~ ^[0-9]+$ ]]; then
    echo "❌ 网卡 ${NET_IF} 的流量数据无效，请检查 vnstat 是否正常运行"
    exit 1
fi

# 阿里云CDT按10进制计费：1 GB = 1,000,000,000 字节
GB_UNIT=1000000000
TX_GB=$(echo "scale=4; ${TX_BYTES}/${GB_UNIT}" | bc)

# 剩余流量（保留4位小数）
REMAIN_GB=$(echo "scale=4; ${LIMIT_GB} - ${TX_GB}" | bc)
# 如果剩余为负，归零
REMAIN_CHECK=$(echo "${REMAIN_GB} < 0" | bc)
if [[ "${REMAIN_CHECK}" == "1" ]]; then
    REMAIN_GB="0.0000"
fi

# 使用率（百分比，保留1位小数）
USAGE=$(echo "scale=1; (${TX_GB}*100)/${LIMIT_GB}" | bc)

# 状态分级（基于使用率百分比）
STATUS="✅ 正常"
USAGE_INT=$(echo "${USAGE}/1" | bc)
if [[ "${USAGE_INT}" -ge 90 ]]; then
    STATUS="🔴 即将关机（>=90%）"
elif [[ "${USAGE_INT}" -ge 75 ]]; then
    STATUS="⚠️  警告（>=75%）"
elif [[ "${USAGE_INT}" -ge 50 ]]; then
    STATUS="🟡 关注（>=50%）"
fi

echo "========================================"
echo "        阿里云 ECS 流量统计"
echo "========================================"
printf "%-12s：%s\n" "北京时间" "$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S')"
printf "%-12s：%s\n" "当前月份" "${CUR_MONTH}"
printf "%-12s：%s\n" "出口网卡" "${NET_IF}"
printf "%-12s：%s GB\n" "本月TX流量" "${TX_GB}"
printf "%-12s：%s GB\n" "流量阈值" "${LIMIT_GB}"
printf "%-12s：%s GB\n" "剩余流量" "${REMAIN_GB}"
printf "%-12s：%s%%\n" "使用率" "${USAGE}"
printf "%-12s：%s\n" "状态" "${STATUS}"
echo "========================================"

# 进度条（20字符宽度，可视化）
BAR_WIDTH=20
FILLED=$(echo "scale=0; (${USAGE}*${BAR_WIDTH})/100" | bc)
FILLED=${FILLED:-0}
if [[ ${FILLED} -gt ${BAR_WIDTH} ]]; then FILLED=${BAR_WIDTH}; fi
EMPTY=$((BAR_WIDTH - FILLED))
printf "进度：["
for ((i=0; i<FILLED; i++)); do printf "█"; done
for ((i=0; i<EMPTY; i++)); do printf "░"; done
printf "]\n"
QEOF

# 替换占位符
sed -i "s|__INTERFACE__|${interface_name}|g" "/root/quest_traffic.sh"
chmod +x "/root/quest_traffic.sh"

# 保存阈值到独立文件（让查询脚本能读到）
echo "${traffic_limit_gb}" > "/root/traffic_limit_gb"

# =========创建全局 traffic 命令（软链到 /usr/local/bin）=========
# 这样你 SSH 进去随时敲 'traffic' 就能查，不用记路径
TRAFFIC_BIN="/usr/local/bin/traffic"
if [[ -f "/root/quest_traffic.sh" ]]; then
    ln -sf /root/quest_traffic.sh "${TRAFFIC_BIN}"
    chmod +x /root/quest_traffic.sh "${TRAFFIC_BIN}"
    echo ""
    echo "✅ 全局命令已创建：traffic"
    echo "   现在在任意位置直接输入 traffic 回车即可查询流量"
    echo "   （新打开的 SSH 会话需要重新登录生效，或执行 source ~/.bashrc）"
fi

echo ""
echo "查询脚本已生成：/root/quest_traffic.sh"
echo "现在可执行查询：bash /root/quest_traffic.sh"