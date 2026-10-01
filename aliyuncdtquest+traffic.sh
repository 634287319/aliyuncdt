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

# =========自动安装 cron =========
if ! command -v crontab &> /dev/null
then
    echo ">>> 未检测到crontab，开始安装cron定时服务..."
    apt update -y
    apt install cron -y
    systemctl enable --now cron
    sleep 2
fi

# =========自动安装 vnstat =========
if ! command -v vnstat &> /dev/null
then
    echo ">>> 安装vnstat流量统计工具..."
    apt update -y
    apt install vnstat -y
    systemctl enable --now vnstat
    sleep 4
fi

# =========自动安装 bc 计算器 =========
if ! command -v bc &> /dev/null
then
    echo ">>> 未检测到bc，安装bc计算工具..."
    apt update -y
    apt install bc -y
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

TX_BYTES=$(vnstat --oneline b -i "${NET_IF}" | awk -F';' '{print $10}')

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
    systemctl poweroff
fi
EOF

# 替换占位符为真实值（避免heredoc中变量提前展开）
sed -i "s|__INTERFACE__|${interface_name}|g; s|__LIMIT_GB__|${traffic_limit_gb}|g" "${SCRIPT_PATH}"
chmod +x "${SCRIPT_PATH}"

# 添加定时任务：每1分钟运行一次
CRON_JOB="*/1 * * * * /bin/bash ${SCRIPT_PATH} >> ${LOG_FILE} 2>&1"
# 先清理掉历史残留的检测任务（按SCRIPT_PATH路径去重，避免重复添加）
( crontab -l 2>/dev/null | grep -v -F "${SCRIPT_PATH}" ) | crontab -
( crontab -l 2>/dev/null; echo "${CRON_JOB}" ) | crontab -
echo ">>> 已添加/刷新crontab检测任务，每1分钟检测一次"

# =========每月1号北京时间0点0分重置vnstat统计=========
# 关键：CRON_TZ 强制cron按北京时间解析时间字段，避免服务器是UTC时少算8小时
RESET_JOB="CRON_TZ=Asia/Shanghai 0 0 1 * * /usr/bin/vnstat -i ${interface_name} --reset >> ${LOG_FILE} 2>&1"
# 清理历史重置任务
( crontab -l 2>/dev/null | grep -v -F "--reset" ) | crontab -
( crontab -l 2>/dev/null; echo "${RESET_JOB}" ) | crontab -
echo ">>> 已添加/刷新每月1号北京时间0点流量重置任务"

echo ""
echo "====部署完成===="
echo "网卡：${interface_name}"
echo "出网流量阈值：${traffic_limit_gb} GB（按阿里云CDT 10进制计费）"
echo "时区：$(date '+%Z %z')（应为CST +0800）"
echo "检测脚本路径：${SCRIPT_PATH}"
echo "日志文件：${LOG_FILE}"
echo "查询命令：bash aliyuncdtquest+traffic.sh query"
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

# 读取本月TX字节数（取 vnstat 第10列 = rx+tx，本月只用第9列 TX）
# 这里用第10列（总流量），与原check.sh脚本保持一致
TX_BYTES=$(vnstat --oneline b -i "${NET_IF}" | awk -F';' '{print $10}')

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

echo ""
echo "查询脚本已生成：/root/quest_traffic.sh"
echo "现在可执行查询：bash /root/quest_traffic.sh"