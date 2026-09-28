#!/bin/bash
# 阿里云ECS 仅统计TX出网流量监控，超限关机【自动识别出口网卡】
# 用法1：bash aliyuncdt.sh <阈值GB>          部署监控（每分钟检测）
# 用法2：bash aliyuncdt.sh traffic           查看当月流量统计面板
#
# 说明：
#   1 GB = 1,000,000,000 Bytes（十进制GB，匹配阿里云计费口径）
#   跨月自动清零：每次开机/执行流量检测时若检测到月份变更，自动 vnstat --reset

if [ $# -ne 1 ]; then
    echo "用法: $0 <阈值GB>"
    echo "      $0 traffic"
    echo "示例: $0 195"
    echo "      $0 traffic"
    exit 1
fi

SCRIPT_PATH="/root/check.sh"
LOG_FILE="/root/shutdown_debug.log"
MONTH_FILE="/root/cdt_last_month"
STATE_DIR="/root/cdt_state"

# =========自动识别默认路由出口网卡=========
interface_name=$(ip route show default | awk '/default/ {print $5}')
if [[ -z "${interface_name}" ]];then
    echo "错误：自动识别网卡失败，请检查系统默认路由！"
    exit 1
fi

# =========自动检测 apt 源，国内 ECS 自动换阿里云内网源=========
auto_swap_apt_source() {
    local SOURCES_LIST="/etc/apt/sources.list"
    [ ! -f "${SOURCES_LIST}" ] && return 0

    # 已换过（阿里云/中科大/清华任一）就跳过
    if grep -qE "mirrors\.aliyun\.com|mirrors\.ustc\.edu\.cn|mirrors\.tuna\.tsinghua\.edu\.cn" "${SOURCES_LIST}"; then
        return 0
    fi

    # 未换过：自动替换为阿里云内网源
    echo ">>> 检测到默认 apt 源，自动切换为阿里云内网源（避免Waiting for headers卡顿）"
    cp "${SOURCES_LIST}" "${SOURCES_LIST}.bak.$(date '+%Y%m%d%H%M%S')"
    sed -i 's|http://deb.debian.org|https://mirrors.aliyun.com|g; s|https://deb.debian.org|https://mirrors.aliyun.com|g' "${SOURCES_LIST}"
    sed -i 's|http://security.debian.org|https://mirrors.aliyun.com|g; s|https://security.debian.org|https://mirrors.aliyun.com|g' "${SOURCES_LIST}"
    sed -i 's|http://archive.ubuntu.com|https://mirrors.aliyun.com|g; s|https://archive.ubuntu.com|https://mirrors.aliyun.com|g' "${SOURCES_LIST}"
    sed -i 's|http://security.ubuntu.com|https://mirrors.aliyun.com|g; s|https://security.ubuntu.com|https://mirrors.aliyun.com|g' "${SOURCES_LIST}"
    apt update -y
}
# 任何带 apt 的部署流程前都先跑一次
auto_swap_apt_source

# =========================================================
# 子命令：traffic —— 直接输出当月流量面板（不进入部署流程）
# =========================================================
if [ "$1" = "traffic" ]; then
    # 取部署时记录的阈值
    LIMIT_GB="?"
    if [ -f "/root/cdt_limit" ]; then
        LIMIT_GB=$(cat /root/cdt_limit 2>/dev/null)
    fi

    # 读取当前月份与本机网卡
    CUR_MONTH=$(TZ='Asia/Shanghai' date '+%Y-%m')

    # 跨月自检：若月份变更则自动重置 vnstat 月统计
    if [ -f "${MONTH_FILE}" ]; then
        LAST_MONTH=$(cat "${MONTH_FILE}" 2>/dev/null)
        if [ "${CUR_MONTH}" != "${LAST_MONTH}" ]; then
            echo "[$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S')] 检测到跨月(${LAST_MONTH} -> ${CUR_MONTH})，自动重置流量统计" >> "${LOG_FILE}"
            vnstat -i "${interface_name}" --reset >> "${LOG_FILE}" 2>&1
            echo "${CUR_MONTH}" > "${MONTH_FILE}"
        fi
    else
        echo "${CUR_MONTH}" > "${MONTH_FILE}"
    fi

    # 拿当月 TX（bytes）
    TX_BYTES=$(vnstat --oneline b -i "${interface_name}" 2>/dev/null | awk -F';' '{print $10}')
    if [[ -z "${TX_BYTES}" || ! "${TX_BYTES}" =~ ^[0-9]+$ ]]; then
        TX_BYTES=0
    fi

    # 1 GB = 1,000,000,000 Bytes（十进制）
    GB_UNIT=1000000000
    TX_GB=$(awk -v b="${TX_BYTES}" -v u="${GB_UNIT}" 'BEGIN{printf "%.3f", b/u}')
    REMAIN_GB=$(awk -v u="${TX_GB}" -v l="${LIMIT_GB}" 'BEGIN{ if(l=="?"){print "?"}else{printf "%.3f", l-u} }')
    USAGE=$(awk -v u="${TX_GB}" -v l="${LIMIT_GB}" 'BEGIN{ if(l=="?"){print "?"}else{printf "%.2f", (u/l)*100} }')

    # 状态判断（awk 比较，整数小数阈值都OK）
    if [ "${LIMIT_GB}" != "?" ]; then
        OVER=$(awk -v u="${TX_GB}" -v l="${LIMIT_GB}" 'BEGIN{print (u>=l)?1:0}')
        if [ "${OVER}" = "1" ]; then
            STATUS="超限"
        else
            STATUS="正常"
        fi
    else
        STATUS="未部署阈值"
    fi

    echo "========================================"
    echo "        阿里云 ECS 流量统计"
    echo "========================================"
    printf "%-12s：%s\n" "北京时间" "$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S')"
    printf "%-12s：%s\n" "当前月份" "${CUR_MONTH}"
    printf "%-12s：%s\n" "出口网卡" "${interface_name}"
    printf "%-12s：%s GB\n" "本月TX流量" "${TX_GB}"
    printf "%-12s：%s GB\n" "流量阈值" "${LIMIT_GB}"
    printf "%-12s：%s GB\n" "剩余流量" "${REMAIN_GB}"
    printf "%-12s：%s%%\n" "使用率" "${USAGE}"
    printf "%-12s：%s\n" "状态" "${STATUS}"
    echo "========================================"
    exit 0
fi

# =========================================================
# 部署模式：必须传入流量阈值GB
# =========================================================
traffic_limit_gb="$1"

# =========自动安装 cron =========
if ! command -v crontab &> /dev/null
then
    echo ">>> 未检测到crontab，开始安装cron定时服务..."
    apt install --no-install-recommends cron -y
    systemctl enable --now cron
    sleep 2
fi

# =========自动安装 vnstat =========
if ! command -v vnstat &> /dev/null
then
    echo ">>> 安装vnstat流量统计工具..."
    apt install --no-install-recommends vnstat -y
    systemctl enable --now vnstat
    sleep 4
fi

# =========自动安装 bc 计算器 =========
if ! command -v bc &> /dev/null
then
    echo ">>> 未检测到bc，安装bc计算工具..."
    apt install --no-install-recommends bc -y
fi

# 校验网卡是否存在
if ! ip link show "${interface_name}" >/dev/null 2>&1;then
    echo "错误：网卡 ${interface_name} 不存在！"
    exit 1
fi

# 创建vnstat网卡数据库
vnstat --create -i "${interface_name}" 2>/dev/null

# 预先创建日志文件 & 状态目录
touch "${LOG_FILE}"
mkdir -p "${STATE_DIR}"

# 持久化阈值（traffic 子命令读取）
echo "${traffic_limit_gb}" > /root/cdt_limit

# 初始化月份记录文件
if [ ! -f "${MONTH_FILE}" ]; then
    TZ='Asia/Shanghai' date '+%Y-%m' > "${MONTH_FILE}"
fi

# =========写入check.sh（含跨月自检逻辑）==========
cat > "${SCRIPT_PATH}" <<EOF
#!/bin/bash
NET_IF="${interface_name}"
LIMIT_GB="${traffic_limit_gb}"
LOG="/root/shutdown_debug.log"
MONTH_FILE="/root/cdt_last_month"

[ ! -f "\${LOG}" ] && touch "\${LOG}"

# =========跨月自检：开机/每次检测前判断月份是否变更==========
CUR_MONTH=\$(TZ='Asia/Shanghai' date '+%Y-%m')
if [ -f "\${MONTH_FILE}" ]; then
    LAST_MONTH=\$(cat "\${MONTH_FILE}" 2>/dev/null)
    if [ "\${CUR_MONTH}" != "\${LAST_MONTH}" ]; then
        echo "[\$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S')] 检测到跨月(\${LAST_MONTH} -> \${CUR_MONTH})，自动重置vnstat月统计" >> "\${LOG}"
        vnstat -i "\${NET_IF}" --reset >> "\${LOG}" 2>&1
    fi
fi
echo "\${CUR_MONTH}" > "\${MONTH_FILE}"

# =========读取当月 TX 字节数==========
TX_BYTES=\$(vnstat --oneline b -i "\${NET_IF}" | awk -F';' '{print \$10}')

# 空值防御：vnstat没有拿到数据直接跳过，避免integer expression expected报错
if [[ -z "\${TX_BYTES}" || ! "\${TX_BYTES}" =~ ^[0-9]+\$ ]];then
    echo "[\$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S')] 网卡\${NET_IF}：vnstat流量数据无效，跳过本次检测" >> "\${LOG}"
    exit 0
fi

# 1 GB = 1,000,000,000 Bytes（十进制，与阿里云计费口径一致）
GB_UNIT=1000000000
TX_GB=\$(echo "scale=3; \${TX_BYTES}/\${GB_UNIT}" | bc)

echo "[\$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S')] 网卡\${NET_IF} 出网TX:\${TX_GB}GB 阈值:\${LIMIT_GB}GB" >> "\${LOG}"

# 改用 awk 比较：无论是整数阈值(180)还是小数阈值(195.5)，都稳定返回 1 或 0
COMP_RESULT=\$(awk -v t="\${TX_GB}" -v l="\${LIMIT_GB}" 'BEGIN{print (t>=l)?1:0}')
if [ "\${COMP_RESULT}" -eq 1 ];then
    echo "[\$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S')] !!!流量达到阈值，执行关机" >> "\${LOG}"
    systemctl poweroff
fi
EOF

chmod +x "${SCRIPT_PATH}"

# 添加定时任务：每1分钟运行一次
CRON_JOB="*/1 * * * * /bin/bash ${SCRIPT_PATH} >> ${LOG_FILE} 2>&1"
if ! crontab -l 2>/dev/null | grep -F -- "${SCRIPT_PATH}" >/dev/null;then
    echo ">>> 添加crontab定时任务，每1分钟检测一次"
    (crontab -l 2>/dev/null; echo "${CRON_JOB}") | crontab -
else
    echo ">>> 流量检测定时任务已存在，跳过"
fi

# @reboot 开机跨月自检任务（无论cron的每分钟任务是否到点，开机就先做一次跨月判断）
REBOOT_JOB="@reboot /bin/bash ${SCRIPT_PATH} >> ${LOG_FILE} 2>&1"
if ! crontab -l 2>/dev/null | grep -F -- "@reboot ${SCRIPT_PATH}" >/dev/null; then
    echo ">>> 添加开机自检任务(@reboot)，用于跨月自动清零"
    (crontab -l 2>/dev/null; echo "${REBOOT_JOB}") | crontab -
else
    echo ">>> 开机自检任务已存在，跳过"
fi

# =========生成 /usr/local/bin/traffic 快捷命令（本地小脚本，零依赖，瞬间出结果）=========
# 不再依赖远端 URL，traffic 直接调用 vnstat 查询，瞬间出流量面板
TRAFFIC_BIN="/usr/local/bin/traffic"
cat > "${TRAFFIC_BIN}" <<EOF
#!/bin/bash
# 自动生成的流量查询快捷命令（由 aliyuncdt.sh 部署时写入）
# 完全本地运行，不依赖任何远端 URL，瞬间出结果

NET_IF="${interface_name}"
LIMIT_GB="${traffic_limit_gb}"
GB_UNIT=1000000000

BEIJING_TIME=\$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')
CURRENT_MONTH=\$(TZ=Asia/Shanghai date '+%Y-%m')

VNSTAT_OUTPUT=\$(vnstat --oneline b -i "\${NET_IF}" 2>/dev/null)

if [[ -z "\${VNSTAT_OUTPUT}" ]]; then
    echo "错误：vnstat 没有返回数据"
    exit 1
fi

TX_BYTES=\$(echo "\${VNSTAT_OUTPUT}" | awk -F';' '{print \$10}')

if [[ -z "\${TX_BYTES}" || ! "\${TX_BYTES}" =~ ^[0-9]+\$ ]]; then
    echo "错误：无法获取 TX 流量"
    exit 1
fi

TX_GB=\$(echo "scale=3; \${TX_BYTES}/\${GB_UNIT}" | bc)
REMAIN_GB=\$(echo "scale=3; \${LIMIT_GB}-\${TX_GB}" | bc)

if (( \$(echo "\${REMAIN_GB} < 0" | bc -l) )); then
    REMAIN_GB="0.000"
fi

USAGE_PERCENT=\$(echo "scale=2; \${TX_GB}/\${LIMIT_GB}*100" | bc)

if (( \$(echo "\${TX_GB} >= \${LIMIT_GB}" | bc -l) )); then
    STATUS="!!! 已达到阈值 !!!"
else
    STATUS="正常"
fi

echo ""
echo "========================================"
echo "        阿里云 ECS 流量统计"
echo "========================================"
echo "北京时间   ：\${BEIJING_TIME}"
echo "当前月份   ：\${CURRENT_MONTH}"
echo "出口网卡   ：\${NET_IF}"
echo "本月TX流量 ：\${TX_GB} GB"
echo "流量阈值   ：\${LIMIT_GB} GB"
echo "剩余流量   ：\${REMAIN_GB} GB"
echo "使用率     ：\${USAGE_PERCENT}%"
echo "状态       ：\${STATUS}"
echo "========================================"
echo ""
EOF
chmod +x "${TRAFFIC_BIN}"
echo ">>> 已生成快捷命令: traffic（本地直查，瞬间出结果）"

echo ""
echo "====部署完成===="
echo "网卡：${interface_name}"
echo "出网流量阈值：${traffic_limit_gb} GB  （1 GB = 1,000,000,000 Bytes）"
echo "检测脚本路径：${SCRIPT_PATH}"
echo "日志文件：${LOG_FILE}"
echo "查看流量：traffic"
echo "查看定时任务：crontab -l"
echo "实时查看日志：tail -f ${LOG_FILE}"
