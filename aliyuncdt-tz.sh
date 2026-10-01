#!/bin/bash
# ============================================================
# 阿里云CDT流量监控（带时区选择 + traffic 快捷命令）
# 基于 TrafficCop 核心算法改造
# 用法:
#   sudo bash aliyuncdt-tz.sh              # 交互式安装
#   sudo bash aliyuncdt-tz.sh --uninstall  # 卸载
# ============================================================
# 注意：不用 set -e，因为某些检查命令（vnstat --add、tc qdisc del）即使失败也不该终止脚本
# ============================================================

# ========== 颜色 ==========
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

WORK_DIR="/root/TrafficCop"
CONFIG_FILE="$WORK_DIR/traffic_monitor_config.txt"
LOG_FILE="$WORK_DIR/traffic_monitor.log"
SCRIPT_PATH="$WORK_DIR/trafficcop.sh"
LOCK_FILE="$WORK_DIR/traffic_monitor.lock"
TRAFFIC_CMD="/usr/local/bin/traffic"

# ========== 卸载 ==========
if [ "$1" = "--uninstall" ]; then
    echo -e "${YELLOW}>>> 卸载中...${NC}"
    crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab - 2>/dev/null || true
    systemctl stop vnstat 2>/dev/null || true
    rm -rf "$WORK_DIR"
    rm -f "$TRAFFIC_CMD"
    echo -e "${GREEN}>>> 卸载完成${NC}"
    exit 0
fi

echo -e "${CYAN}=====================================================${NC}"
echo -e "${CYAN} 阿里云 CDT 流量监控（带时区选择 + traffic 命令）${NC}"
echo -e "${CYAN}=====================================================${NC}"

# ========== 1. 安装基础依赖 ==========
echo -e "${BLUE}>>> [1/6] 检查依赖...${NC}"
NEED_INSTALL=""
for pkg in vnstat jq bc iproute2 cron curl; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        NEED_INSTALL="$NEED_INSTALL $pkg"
    fi
done

if [ -n "$NEED_INSTALL" ]; then
    echo -e "${YELLOW}>>> 需要安装:$NEED_INSTALL${NC}"
    # 等 unattended-upgr
    if pgrep -x unattended-upgr > /dev/null 2>&1; then
        echo -e "${YELLOW}>>> 检测到 unattended-upgr，等待完成（最多3分钟）...${NC}"
        WAITED=0
        while pgrep -x unattended-upgr > /dev/null 2>&1 && [ $WAITED -lt 180 ]; do
            sleep 5
            WAITED=$((WAITED+5))
            [ $((WAITED % 30)) -eq 0 ] && echo "    已等待 ${WAITED} 秒..."
        done
    fi
    DEBIAN_FRONTEND=noninteractive timeout 180 apt-get install --no-install-recommends $NEED_INSTALL -y 2>&1 | tail -5
fi

# ========== 2. 时区选择（核心新增功能） ==========
echo -e "${BLUE}>>> [2/6] 选择时区...${NC}"
echo ""
echo "  1) UTC（默认）"
echo "  2) Asia/Shanghai（北京时间，+0800）"
echo "  3) Asia/Tokyo（东京时间，+0900）"
echo "  4) Asia/Singapore（新加坡时间，+0800）"
echo "  5) Asia/Hong_Kong（香港时间，+0800）"
echo "  6) Europe/London（伦敦时间，+0000/+0100）"
echo "  7) Europe/Berlin（柏林时间，+0100/+0200）"
echo "  8) America/New_York（纽约时间）"
echo "  9) 自定义 UTC±N（手动输入偏移量）"
echo ""

# 读取旧配置（如果存在）
OLD_TZ=""
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE" && OLD_TZ="$TIMEZONE"

read -p "请选择时区 [1-9，默认 1]: " TZ_CHOICE
TZ_CHOICE=${TZ_CHOICE:-1}

case $TZ_CHOICE in
    1) TIMEZONE="UTC" ;;
    2) TIMEZONE="Asia/Shanghai" ;;
    3) TIMEZONE="Asia/Tokyo" ;;
    4) TIMEZONE="Asia/Singapore" ;;
    5) TIMEZONE="Asia/Hong_Kong" ;;
    6) TIMEZONE="Europe/London" ;;
    7) TIMEZONE="Europe/Berlin" ;;
    8) TIMEZONE="America/New_York" ;;
    9)
        echo ""
        echo "  时区偏移示例："
        echo "    +8  = 北京/香港/新加坡"
        echo "    +9  = 东京/首尔"
        echo "    -5  = 纽约（标准时间）"
        echo "    0   = UTC"
        read -p "请输入 UTC 偏移量（如 +8 / -5 / 0）: " UTC_OFFSET
        # 验证
        if ! [[ "$UTC_OFFSET" =~ ^[+-]?[0-9]+$ ]]; then
            echo -e "${RED}无效输入，回退到 UTC${NC}"
            TIMEZONE="UTC"
        else
            # 转换为 Etc/GMT 格式（POSIX 标准，反向符号）
            # Etc/GMT+8 实际是 UTC-8，所以要反向
            SIGN=""
            NUM=$UTC_OFFSET
            if [[ $UTC_OFFSET == -* ]]; then
                SIGN="+"
                NUM=${UTC_OFFSET#-}
            elif [[ $UTC_OFFSET == +* ]]; then
                SIGN="-"
                NUM=${UTC_OFFSET#+}
            else
                SIGN="+"
            fi
            TIMEZONE="Etc/GMT${SIGN}${NUM}"
        fi
        ;;
    *) TIMEZONE="UTC" ;;
esac

echo -e "${GREEN}>>> 已选择时区: ${TIMEZONE}${NC}"

# ========== 2.5 进制选择（SI 1000 vs IEC 1024） ==========
echo -e "${BLUE}>>> 选择字节换算进制（字节→GB）...${NC}"
echo ""
echo "  1) SI 进制（1 GB = 1,000,000,000 字节）★ 推荐 - 阿里云账单标准"
echo "  2) IEC 进制（1 GiB = 1,073,741,824 字节）- vnstat 默认"
echo ""
echo "  ⚠️  阿里云按 1000 进制计费（180 GB）"
echo "  ⚠️  用 1024 进制会导致少算约 7%，永远不触发！"
echo ""
read -p "请选择进制 [1-2，默认 1]: " UNIT_CHOICE
UNIT_CHOICE=${UNIT_CHOICE:-1}
case $UNIT_CHOICE in
    1) UNIT_MODE="si" ;;   # 1000 - SI (阿里云)
    2) UNIT_MODE="iec" ;;  # 1024 - IEC (GiB)
    *) UNIT_MODE="si" ;;
esac
echo -e "${GREEN}>>> 进制模式: $UNIT_MODE ($( [ "$UNIT_MODE" = "si" ] && echo "1 GB = 1e9 字节" || echo "1 GiB = 2^30 字节" ))${NC}"

# 应用时区
echo -e "${BLUE}>>> 同步系统时区...${NC}"
timedatectl set-timezone "$TIMEZONE" 2>/dev/null || ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
echo "$TIMEZONE" > /etc/timezone
export TZ="$TIMEZONE"

# 配置 vnstat 时区
VNSTAT_CONF="/etc/vnstat.conf"
if [ -f "$VNSTAT_CONF" ]; then
    if grep -qE "^[[:space:]]*TimeZone" "$VNSTAT_CONF"; then
        sed -i "s|^[[:space:]]*TimeZone.*|TimeZone \"$TIMEZONE\"|" "$VNSTAT_CONF"
    else
        echo "TimeZone \"$TIMEZONE\"" >> "$VNSTAT_CONF"
    fi
fi

# ========== 3. 流量统计模式 ==========
echo -e "${BLUE}>>> [3/6] 选择流量统计模式...${NC}"
echo ""
echo "  1) 出站流量（TX，阿里云 CDT 主计费，推荐）"
echo "  2) 入站流量（RX）"
echo "  3) 出+入 总和"
echo "  4) 出/入 取大值"
echo ""

read -p "请选择 [1-4，默认 1]: " MODE_CHOICE
MODE_CHOICE=${MODE_CHOICE:-1}
case $MODE_CHOICE in
    1) TRAFFIC_MODE="out" ;;
    2) TRAFFIC_MODE="in" ;;
    3) TRAFFIC_MODE="total" ;;
    4) TRAFFIC_MODE="max" ;;
    *) TRAFFIC_MODE="out" ;;
esac
echo -e "${GREEN}>>> 统计模式: $TRAFFIC_MODE${NC}"

# ========== 4. 周期与阈值 ==========
echo -e "${BLUE}>>> [4/6] 配置周期与阈值...${NC}"
echo ""
echo "  1) monthly（每月）"
echo "  2) quarterly（每季）"
echo "  3) yearly（每年）"
echo ""
read -p "请选择周期 [1-3，默认 1]: " PERIOD_CHOICE
PERIOD_CHOICE=${PERIOD_CHOICE:-1}
case $PERIOD_CHOICE in
    1) TRAFFIC_PERIOD="monthly" ;;
    2) TRAFFIC_PERIOD="quarterly" ;;
    3) TRAFFIC_PERIOD="yearly" ;;
    *) TRAFFIC_PERIOD="monthly" ;;
esac

read -p "周期起始日（1-31，默认 1）: " PERIOD_START_DAY
PERIOD_START_DAY=${PERIOD_START_DAY:-1}
[[ "$PERIOD_START_DAY" =~ ^[1-9]$|^[12][0-9]$|^3[01]$ ]] || PERIOD_START_DAY=1

read -p "流量限制（GB）: " TRAFFIC_LIMIT
while ! [[ "$TRAFFIC_LIMIT" =~ ^[0-9]+(\.[0-9]+)?$ ]]; do
    read -p "无效，请重新输入流量限制（GB）: " TRAFFIC_LIMIT
done

read -p "容错范围（GB，默认 0）: " TRAFFIC_TOLERANCE
TRAFFIC_TOLERANCE=${TRAFFIC_TOLERANCE:-0}
[[ "$TRAFFIC_TOLERANCE" =~ ^[0-9]+(\.[0-9]+)?$ ]] || TRAFFIC_TOLERANCE=0

# ========== 5. 限制模式 ==========
echo -e "${BLUE}>>> [5/6] 选择超限动作...${NC}"
echo ""
echo "  1) shutdown（关机，最直接）"
echo "  2) tc 限速（保留服务，仅限速）"
echo ""
read -p "请选择 [1-2，默认 1]: " LIMIT_MODE_CHOICE
LIMIT_MODE_CHOICE=${LIMIT_MODE_CHOICE:-1}
case $LIMIT_MODE_CHOICE in
    1) LIMIT_MODE="shutdown"; LIMIT_SPEED="" ;;
    2)
        LIMIT_MODE="tc"
        read -p "限速 kbit/s（默认 20）: " LIMIT_SPEED
        LIMIT_SPEED=${LIMIT_SPEED:-20}
        [[ "$LIMIT_SPEED" =~ ^[0-9]+$ ]] || LIMIT_SPEED=20
        ;;
    *) LIMIT_MODE="shutdown"; LIMIT_SPEED="" ;;
esac

# ========== 6. 网卡检测 ==========
echo -e "${BLUE}>>> [6/6] 检测网卡...${NC}"
MAIN_INTERFACE=$(ip route | grep default | sed -n 's/^default via [0-9.]* dev \([^ ]*\).*/\1/p' | head -n1)
if [ -z "$MAIN_INTERFACE" ]; then
    MAIN_INTERFACE=$(ip link | grep 'state UP' | sed -n 's/^[0-9]*: \([^:]*\):.*/\1/p' | head -n1)
fi
if [ -z "$MAIN_INTERFACE" ]; then
    echo -e "${YELLOW}未自动检测到网卡，请手动输入：${NC}"
    ip -o link show | awk -F': ' '{print "  "$2}' | sed 's/:.*//'
    read -p "网卡名: " MAIN_INTERFACE
fi
echo -e "${GREEN}>>> 网卡: $MAIN_INTERFACE${NC}"

# 启动 vnstat
systemctl enable --now vnstat 2>/dev/null || true
systemctl restart vnstat 2>/dev/null || true
sleep 2

# 把网卡加入 vnstat（兼容 2.x）
vnstat --add -i "$MAIN_INTERFACE" 2>/dev/null || true

# ========== 写配置 ==========
mkdir -p "$WORK_DIR"
cat > "$CONFIG_FILE" << EOF
# 阿里云CDT流量监控配置
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
TIMEZONE=$TIMEZONE
UNIT_MODE=$UNIT_MODE
TRAFFIC_MODE=$TRAFFIC_MODE
TRAFFIC_PERIOD=$TRAFFIC_PERIOD
PERIOD_START_DAY=$PERIOD_START_DAY
TRAFFIC_LIMIT=$TRAFFIC_LIMIT
TRAFFIC_TOLERANCE=$TRAFFIC_TOLERANCE
LIMIT_SPEED=$LIMIT_SPEED
MAIN_INTERFACE=$MAIN_INTERFACE
LIMIT_MODE=$LIMIT_MODE
EOF
echo -e "${GREEN}>>> 配置已写入: $CONFIG_FILE${NC}"

# ========== 部署核心监控脚本 ==========
echo -e "${BLUE}>>> 部署核心监控脚本...${NC}"

cat > "$SCRIPT_PATH" << 'CORE_EOF'
#!/bin/bash
# 阿里云CDT流量监控核心（cron 跑，--run 模式）
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WORK_DIR="/root/TrafficCop"
CONFIG_FILE="$WORK_DIR/traffic_monitor_config.txt"
LOG_FILE="$WORK_DIR/traffic_monitor.log"
LOCK_FILE="$WORK_DIR/traffic_monitor.lock"

source "$CONFIG_FILE"
export TZ="$TIMEZONE"

# 文件锁
touch "$LOCK_FILE"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    exit 0
fi

# 获取周期起始日期
get_period_start_date() {
    local cy=$(date +%Y)
    local cm=$(date +%-m)
    local cd=$(date +%-d)
    case $TRAFFIC_PERIOD in
        monthly)
            if [ $cd -lt $PERIOD_START_DAY ]; then
                date -d "${cy}-${cm}-${PERIOD_START_DAY} -1 month" +%Y-%m-%d
            else
                date -d "${cy}-${cm}-${PERIOD_START_DAY}" +%Y-%m-%d 2>/dev/null || echo "${cy}-${cm}-01"
            fi
            ;;
        quarterly)
            local qm=$(( ((cm - 1) / 3) * 3 + 1 ))
            if [ $cd -lt $PERIOD_START_DAY ] || [ $cm -eq $qm ]; then
                date -d "${cy}-${qm}-${PERIOD_START_DAY} -3 month" +%Y-%m-%d
            else
                date -d "${cy}-${qm}-${PERIOD_START_DAY}" +%Y-%m-%d 2>/dev/null || echo "${cy}-${qm}-01"
            fi
            ;;
        yearly)
            if [ $cd -lt $PERIOD_START_DAY ] || [ $cm -eq 01 ]; then
                date -d "${cy}-01-${PERIOD_START_DAY} -1 year" +%Y-%m-%d
            else
                date -d "${cy}-01-${PERIOD_START_DAY}" +%Y-%m-%d 2>/dev/null || echo "${cy}-01-01"
            fi
            ;;
    esac
}

# 获取周期结束日期
get_period_end_date() {
    local cy=$(date +%Y)
    local cm=$(date +%-m)
    local cd=$(date +%-d)
    case $TRAFFIC_PERIOD in
        monthly)
            if [ $cd -lt $PERIOD_START_DAY ]; then
                date -d "${cy}-${cm}-${PERIOD_START_DAY} -1 day" +%Y-%m-%d
            else
                date -d "${cy}-${cm}-${PERIOD_START_DAY} +1 month -1 day" +%Y-%m-%d
            fi
            ;;
        quarterly)
            local qm=$(( ((cm - 1) / 3) * 3 + 1 ))
            if [ $cd -lt $PERIOD_START_DAY ] || [ $cm -eq $qm ]; then
                date -d "${cy}-${qm}-${PERIOD_START_DAY} +2 month -1 day" +%Y-%m-%d
            else
                date -d "${cy}-${qm}-${PERIOD_START_DAY} +5 month -1 day" +%Y-%m-%d
            fi
            ;;
        yearly)
            if [ $cd -lt $PERIOD_START_DAY ] || [ $cm -eq 01 ]; then
                date -d "${cy}-12-31" +%Y-%m-%d
            else
                date -d "$((cy + 1))-12-31" +%Y-%m-%d
            fi
            ;;
    esac
}

# 获取流量
get_traffic_usage() {
    local start_date=$(get_period_start_date)
    local end_date=$(get_period_end_date)
    local vnstat_json=$(vnstat -i "$MAIN_INTERFACE" --json d 2>/dev/null)
    if [ -z "$vnstat_json" ]; then
        echo "0.000"
        return 1
    fi
    local start_num=$(echo "$start_date" | tr -d '-')
    local end_num=$(echo "$end_date" | tr -d '-')
    local usage_bytes=0
    case $TRAFFIC_MODE in
        out)
            usage_bytes=$(echo "$vnstat_json" | jq --argjson s "$start_num" --argjson e "$end_num" \
                '[.interfaces[0].traffic.day[] | ((.date.year*10000)+(.date.month*100)+.date.day) as $d | select($d >= $s and $d <= $e) | .tx] | add // 0')
            ;;
        in)
            usage_bytes=$(echo "$vnstat_json" | jq --argjson s "$start_num" --argjson e "$end_num" \
                '[.interfaces[0].traffic.day[] | ((.date.year*10000)+(.date.month*100)+.date.day) as $d | select($d >= $s and $d <= $e) | .rx] | add // 0')
            ;;
        total)
            usage_bytes=$(echo "$vnstat_json" | jq --argjson s "$start_num" --argjson e "$end_num" \
                '[.interfaces[0].traffic.day[] | ((.date.year*10000)+(.date.month*100)+.date.day) as $d | select($d >= $s and $d <= $e) | (.rx + .tx)] | add // 0')
            ;;
        max)
            local rx=$(echo "$vnstat_json" | jq --argjson s "$start_num" --argjson e "$end_num" \
                '[.interfaces[0].traffic.day[] | ((.date.year*10000)+(.date.month*100)+.date.day) as $d | select($d >= $s and $d <= $e) | .rx] | add // 0')
            local tx=$(echo "$vnstat_json" | jq --argjson s "$start_num" --argjson e "$end_num" \
                '[.interfaces[0].traffic.day[] | ((.date.year*10000)+(.date.month*100)+.date.day) as $d | select($d >= $s and $d <= $e) | .tx] | add // 0')
            usage_bytes=$(printf '%s\n%s' "$rx" "$tx" | sort -rn | head -n1)
            ;;
    esac
    [ -z "$usage_bytes" ] || [ "$usage_bytes" = "null" ] && usage_bytes=0
    # 进制转换：SI (1000) 适合阿里云账单，IEC (1024) 适合精确字节
    # 1 GB (SI) = 1,000,000,000 字节（阿里云用这个）
    # 1 GiB (IEC) = 1,073,741,824 字节（vnstat 默认）
    if [ "${UNIT_MODE:-si}" = "iec" ]; then
        # 1024 进制 (GiB)
        local usage_gib=$(echo "scale=3; $usage_bytes/1024/1024/1024" | bc 2>/dev/null || echo "0.000")
    else
        # 1000 进制 (GB, 阿里云标准)
        local usage_gib=$(echo "scale=3; $usage_bytes/1000/1000/1000" | bc 2>/dev/null || echo "0.000")
    fi
    printf "%.3f\n" "$usage_gib" 2>/dev/null || echo "0.000"
}

# 检查并限制
check_and_limit_traffic() {
    local current_usage=$(get_traffic_usage)
    local threshold=$(echo "$TRAFFIC_LIMIT - $TRAFFIC_TOLERANCE" | bc 2>/dev/null || echo "0")
    local exceeded=$(echo "$current_usage > $threshold" | bc -l 2>/dev/null || echo "0")

    echo "$(date '+%Y-%m-%d %H:%M:%S') [时区:$TIMEZONE][进制:$UNIT_MODE] 用量: ${current_usage}/阈值: ${threshold}" >> "$LOG_FILE"

    if [ "$exceeded" = "1" ]; then
        if [ "$LIMIT_MODE" = "tc" ]; then
            if ! tc qdisc show dev "$MAIN_INTERFACE" | grep -q "tbf"; then
                tc qdisc add dev "$MAIN_INTERFACE" root tbf rate ${LIMIT_SPEED}kbit burst 32kbit latency 400ms 2>/dev/null
                echo "$(date '+%Y-%m-%d %H:%M:%S') 流量超限,TC 限速至 ${LIMIT_SPEED}kbit/s" >> "$LOG_FILE"
            fi
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') 流量超限,1分钟后关机" >> "$LOG_FILE"
            shutdown -h +1 "流量超限,系统将在1分钟后关机"
        fi
    else
        # 流量正常,清除限速
        if [ "$LIMIT_MODE" = "tc" ]; then
            tc qdisc del dev "$MAIN_INTERFACE" root 2>/dev/null && \
                echo "$(date '+%Y-%m-%d %H:%M:%S') 流量正常,清除限速" >> "$LOG_FILE"
        fi
    fi
}

# 检查是否新周期（清除限速）
check_reset_limit() {
    local start_date=$(get_period_start_date)
    if [[ "$(date +%Y-%m-%d)" == "$start_date" ]]; then
        if [ "$LIMIT_MODE" = "tc" ]; then
            tc qdisc del dev "$MAIN_INTERFACE" root 2>/dev/null
            echo "$(date '+%Y-%m-%d %H:%M:%S') 新周期开始,清除限速" >> "$LOG_FILE"
        fi
    fi
}

# --run 模式
if [ "$1" = "--run" ]; then
    check_reset_limit
    check_and_limit_traffic
fi

trap 'flock -u 9' EXIT
CORE_EOF

chmod +x "$SCRIPT_PATH"
echo -e "${GREEN}>>> 核心脚本已部署: $SCRIPT_PATH${NC}"

# ========== 部署 traffic 快捷命令 ==========
echo -e "${BLUE}>>> 部署 traffic 快捷命令...${NC}"

cat > "$TRAFFIC_CMD" << 'TRAFFIC_EOF'
#!/bin/bash
# traffic - 一行命令查流量
# 用法: traffic [--json] [--history] [--daily]
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LANG=en_US.UTF-8

WORK_DIR="/root/TrafficCop"
CONFIG_FILE="$WORK_DIR/traffic_monitor_config.txt"
SCRIPT_PATH="$WORK_DIR/trafficcop.sh"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "错误: 未找到配置，请先运行 bash aliyuncdt-tz.sh"
    exit 1
fi

source "$CONFIG_FILE"
export TZ="$TIMEZONE"

# 颜色
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; NC=''
fi

# 周期计算
get_period_start_date() {
    local cy=$(date +%Y); local cm=$(date +%-m); local cd=$(date +%-d)
    case $TRAFFIC_PERIOD in
        monthly)
            if [ $cd -lt $PERIOD_START_DAY ]; then
                date -d "${cy}-${cm}-${PERIOD_START_DAY} -1 month" +%Y-%m-%d
            else
                date -d "${cy}-${cm}-${PERIOD_START_DAY}" +%Y-%m-%d 2>/dev/null || echo "${cy}-${cm}-01"
            fi
            ;;
        quarterly)
            local qm=$(( ((cm - 1) / 3) * 3 + 1 ))
            if [ $cd -lt $PERIOD_START_DAY ] || [ $cm -eq $qm ]; then
                date -d "${cy}-${qm}-${PERIOD_START_DAY} -3 month" +%Y-%m-%d
            else
                date -d "${cy}-${qm}-${PERIOD_START_DAY}" +%Y-%m-%d 2>/dev/null || echo "${cy}-${qm}-01"
            fi
            ;;
        yearly)
            if [ $cd -lt $PERIOD_START_DAY ] || [ $cm -eq 01 ]; then
                date -d "${cy}-01-${PERIOD_START_DAY} -1 year" +%Y-%m-%d
            else
                date -d "${cy}-01-${PERIOD_START_DAY}" +%Y-%m-%d 2>/dev/null || echo "${cy}-01-01"
            fi
            ;;
    esac
}

get_period_end_date() {
    local cy=$(date +%Y); local cm=$(date +%-m); local cd=$(date +%-d)
    case $TRAFFIC_PERIOD in
        monthly)
            if [ $cd -lt $PERIOD_START_DAY ]; then
                date -d "${cy}-${cm}-${PERIOD_START_DAY} -1 day" +%Y-%m-%d
            else
                date -d "${cy}-${cm}-${PERIOD_START_DAY} +1 month -1 day" +%Y-%m-%d
            fi
            ;;
        quarterly)
            local qm=$(( ((cm - 1) / 3) * 3 + 1 ))
            if [ $cd -lt $PERIOD_START_DAY ] || [ $cm -eq $qm ]; then
                date -d "${cy}-${qm}-${PERIOD_START_DAY} +2 month -1 day" +%Y-%m-%d
            else
                date -d "${cy}-${qm}-${PERIOD_START_DAY} +5 month -1 day" +%Y-%m-%d
            fi
            ;;
        yearly)
            if [ $cd -lt $PERIOD_START_DAY ] || [ $cm -eq 01 ]; then
                date -d "${cy}-12-31" +%Y-%m-%d
            else
                date -d "$((cy + 1))-12-31" +%Y-%m-%d
            fi
            ;;
    esac
}

# 流量累计
calc_usage() {
    local start_date=$(get_period_start_date)
    local end_date=$(get_period_end_date)
    local vnstat_json=$(vnstat -i "$MAIN_INTERFACE" --json d 2>/dev/null)
    [ -z "$vnstat_json" ] && { echo "0|0|0|0"; return; }
    local start_num=$(echo "$start_date" | tr -d '-')
    local end_num=$(echo "$end_date" | tr -d '-')
    local tx=$(echo "$vnstat_json" | jq --argjson s "$start_num" --argjson e "$end_num" \
        '[.interfaces[0].traffic.day[] | ((.date.year*10000)+(.date.month*100)+.date.day) as $d | select($d >= $s and $d <= $e) | .tx] | add // 0')
    local rx=$(echo "$vnstat_json" | jq --argjson s "$start_num" --argjson e "$end_num" \
        '[.interfaces[0].traffic.day[] | ((.date.year*10000)+(.date.month*100)+.date.day) as $d | select($d >= $s and $d <= $e) | .rx] | add // 0')
    local total=$((tx + rx))
    local max_val=$(printf '%s\n%s' "$tx" "$rx" | sort -rn | head -n1)
    echo "$tx|$rx|$total|$max_val"
}

# 字节转 GB/GiB（按 UNIT_MODE 选进制）
bytes_to_gb() {
    local bytes=$1
    if [ "${UNIT_MODE:-si}" = "iec" ]; then
        echo "scale=3; $bytes/1024/1024/1024" | bc 2>/dev/null
    else
        echo "scale=3; $bytes/1000/1000/1000" | bc 2>/dev/null
    fi
}

# JSON 模式
if [ "$1" = "--json" ]; then
    result=$(calc_usage)
    IFS='|' read -r tx rx total max_val <<< "$result"
    unit_label=$([ "${UNIT_MODE:-si}" = "iec" ] && echo "GiB" || echo "GB")
    tx_gb=$(bytes_to_gb "$tx")
    rx_gb=$(bytes_to_gb "$rx")
    cat << JSON_EOF
{
  "timezone": "$TIMEZONE",
  "now": "$(date '+%Y-%m-%d %H:%M:%S')",
  "period_start": "$(get_period_start_date)",
  "period_end": "$(get_period_end_date)",
  "period_type": "$TRAFFIC_PERIOD",
  "interface": "$MAIN_INTERFACE",
  "traffic_mode": "$TRAFFIC_MODE",
  "unit_mode": "${UNIT_MODE:-si}",
  "unit_label": "$unit_label",
  "limit_gb": $TRAFFIC_LIMIT,
  "tolerance_gb": $TRAFFIC_TOLERANCE,
  "limit_mode": "$LIMIT_MODE",
  "limit_speed_kbit": ${LIMIT_SPEED:-null},
  "tx_$unit_label": ${tx_gb:-0},
  "rx_$unit_label": ${rx_gb:-0},
  "total_$unit_label": $(bytes_to_gb "$total")
}
JSON_EOF
    exit 0
fi

# 历史月份（按 UNIT_MODE 选进制）
if [ "$1" = "--history" ]; then
    unit_label=$([ "${UNIT_MODE:-si}" = "iec" ] && echo "GiB" || echo "GB")
    divisor=$([ "${UNIT_MODE:-si}" = "iec" ] && echo "1024" || echo "1000")
    vnstat -i "$MAIN_INTERFACE" --json m 2>/dev/null | \
        jq -r --argjson div "$divisor" '.interfaces[0].traffic.month[] | "\(.date.year)/\(.date.month | tostring | if length==1 then "0"+. else . end): TX \(.tx/($div*$div*$div) | . * 1000 / 1000 | floor * 1000 / 1000)'$unit_label', RX \(.rx/($div*$div*$div) | . * 1000 / 1000 | floor * 1000 / 1000)'$unit_label'"' | \
        awk -F': ' '{
            split($2, arr, ", ")
            printf "%-12s TX=%-10s RX=%s\n", $1, arr[1], arr[2]
        }' 2>/dev/null || \
        vnstat -i "$MAIN_INTERFACE" -m 2>/dev/null
    exit 0
fi

# 每日明细
if [ "$1" = "--daily" ]; then
    echo -e "${CYAN}每日流量明细（最近30天，时区:$TIMEZONE）${NC}"
    echo "----------------------------------------"
    vnstat -i "$MAIN_INTERFACE" -d 2>/dev/null | tail -n 35
    exit 0
fi

# 默认:详细视图
result=$(calc_usage)
IFS='|' read -r tx rx total max_val <<< "$result"

case $TRAFFIC_MODE in
    out) usage_bytes=$tx; mode_label="出站(TX)" ;;
    in) usage_bytes=$rx; mode_label="入站(RX)" ;;
    total) usage_bytes=$total; mode_label="出+入" ;;
    max) usage_bytes=$max_val; mode_label="出/入取大" ;;
esac

# 单位标签（按 UNIT_MODE 决定显示 GB 还是 GiB）
unit_label=$([ "${UNIT_MODE:-si}" = "iec" ] && echo "GiB" || echo "GB")
unit_desc=$([ "${UNIT_MODE:-si}" = "iec" ] && echo "IEC(1024)" || echo "Si(1000)")

usage_gib=$(bytes_to_gb "$usage_bytes")
limit_gib=$TRAFFIC_LIMIT
remain_gib=$(echo "scale=3; $limit_gib - $usage_gib" | bc 2>/dev/null || echo "0.000")
percent=$(echo "scale=2; $usage_gib * 100 / $limit_gib" | bc 2>/dev/null || echo "0.00")

# 颜色根据百分比
if (( $(echo "$percent > 90" | bc -l 2>/dev/null || echo 0) )); then
    COLOR=$RED
elif (( $(echo "$percent > 70" | bc -l 2>/dev/null || echo 0) )); then
    COLOR=$YELLOW
else
    COLOR=$GREEN
fi

start_date=$(get_period_start_date)
end_date=$(get_period_end_date)

cat << EOF
${CYAN}====================================================${NC}
${CYAN}  阿里云CDT流量监控 - $(date '+%Y-%m-%d %H:%M:%S')${NC}
${CYAN}====================================================${NC}
  时区:       ${TIMEZONE}
  网卡:       ${MAIN_INTERFACE}
  周期:       ${TRAFFIC_PERIOD} (从 ${start_date} 至 ${end_date})
  统计模式:   ${mode_label}
  进制:       ${unit_desc}  (1 ${unit_label} = $( [ "${UNIT_MODE}" = "iec" ] && echo "1,073,741,824" || echo "1,000,000,000" ) 字节)
  周期起始日: ${PERIOD_START_DAY} 号

${BLUE}  本周期已用:   ${COLOR}${usage_gib} ${unit_label}${NC}
  限制阈值:     ${limit_gib} ${unit_label}（容错 ${TRAFFIC_TOLERANCE} ${unit_label}）
  ${COLOR}剩余可用:     ${remain_gib} ${unit_label}${NC}
  ${COLOR}使用百分比:   ${percent}%${NC}
  超限动作:     ${LIMIT_MODE}$([ "$LIMIT_MODE" = "tc" ] && echo " (限速 ${LIMIT_SPEED}kbit/s)" || echo " (关机)")

  分项:
    出站(TX): $(bytes_to_gb "$tx") ${unit_label}
    入站(RX): $(bytes_to_gb "$rx") ${unit_label}

${CYAN}====================================================${NC}
EOF
TRAFFIC_EOF

chmod +x "$TRAFFIC_CMD"
echo -e "${GREEN}>>> traffic 命令已安装: $TRAFFIC_CMD${NC}"

# ========== 设置 cron ==========
echo -e "${BLUE}>>> 设置定时任务...${NC}"
crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab - 2>/dev/null || true
(crontab -l 2>/dev/null; echo "* * * * * export TZ='$TIMEZONE'; $SCRIPT_PATH --run") | crontab -
# 添加开机自检（@reboot 时强制同步时区）
(crontab -l 2>/dev/null; echo "@reboot bash -c 'export TZ=$TIMEZONE; timedatectl set-timezone $TIMEZONE 2>/dev/null; systemctl restart vnstat'") | crontab -
echo -e "${GREEN}>>> 每分钟检测 + 开机自检 已添加${NC}"

# ========== 完成 ==========
echo ""
echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN} 部署完成！${NC}"
echo -e "${GREEN}====================================================${NC}"
echo ""
echo -e "${BLUE}现在你可以：${NC}"
echo -e "  ${CYAN}traffic${NC}            # 查看流量"
echo -e "  ${CYAN}traffic --json${NC}     # JSON 格式"
echo -e "  ${CYAN}traffic --history${NC}  # 历史月份"
echo -e "  ${CYAN}traffic --daily${NC}    # 每日明细"
echo -e "  ${CYAN}tail -f $LOG_FILE${NC} # 实时日志"
echo ""
echo -e "${YELLOW}卸载命令:${NC}  sudo bash $0 --uninstall"
echo -e "${YELLOW}重新配置:${NC}  sudo bash $0 （再次运行会覆盖配置）"
echo ""
