#!/usr/bin/env bash

# ==============================================================================
# 精简优化版Linux TCP/IP & BBR网络脚本
#
# 描述: 此脚本结合了精简的核心网络参数与精细的动态内存分级逻辑，
#       实现性能与简洁的完美统一。
# ==============================================================================

set -e

# --- 颜色定义 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

# --- 配置文件路径 ---
CONF_FILE="/etc/sysctl.d/99-bbr.conf"

# --- 系统信息检测函数 ---
get_system_info() {
    # 获取内存大小(MB)
    TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')

    # 获取CPU核心数
    CPU_CORES=$(nproc)

    # 检测虚拟化环境
    if systemd-detect-virt >/dev/null 2>&1; then
        VIRT_TYPE=$(systemd-detect-virt)
    else
        VIRT_TYPE="unknown"
    fi

    echo -e "${CYAN}>>> 系统信息检测：${NC}"
    echo -e "内存大小: ${YELLOW}${TOTAL_MEM}MB${NC}"
    echo -e "CPU核心数: ${YELLOW}${CPU_CORES}${NC}"
    echo -e "虚拟化类型: ${YELLOW}${VIRT_TYPE}${NC}"
}

# --- 动态参数计算函数 (已优化分级) ---
calculate_parameters() {
    # 根据内存大小动态调整缓冲区 (按区间范围划分)
    if [ $TOTAL_MEM -le 512 ]; then
        # 经典级VPS (≤512MB)
        RMEM_MAX="8388608"; WMEM_MAX="8388608"; TCP_RMEM="4096 65536 8388608"; TCP_WMEM="4096 65536 8388608"
        SOMAXCONN="32768"; NETDEV_BACKLOG="16384"; FILE_MAX="262144"; CONNTRACK_MAX="131072"; VM_TIER="经典级(≤512MB)"
    elif [ $TOTAL_MEM -le 1024 ]; then
        # 轻量级VPS (512MB-1GB)
        RMEM_MAX="16777216"; WMEM_MAX="16777216"; TCP_RMEM="4096 65536 16777216"; TCP_WMEM="4096 65536 16777216"
        SOMAXCONN="49152"; NETDEV_BACKLOG="24576"; FILE_MAX="524288"; CONNTRACK_MAX="262144"; VM_TIER="轻量级(512MB-1GB)"
    elif [ $TOTAL_MEM -le 2048 ]; then
        # 标准级VPS (1GB-2GB)
        RMEM_MAX="33554432"; WMEM_MAX="33554432"; TCP_RMEM="4096 87380 33554432"; TCP_WMEM="4096 65536 33554432"
        SOMAXCONN="65535"; NETDEV_BACKLOG="32768"; FILE_MAX="1048576"; CONNTRACK_MAX="524288"; VM_TIER="标准级(1GB-2GB)"
    elif [ $TOTAL_MEM -le 4096 ]; then
        # 高性能VPS (2GB-4GB)
        RMEM_MAX="67108864"; WMEM_MAX="67108864"; TCP_RMEM="4096 131072 67108864"; TCP_WMEM="4096 87380 67108864"
        SOMAXCONN="65535"; NETDEV_BACKLOG="65535"; FILE_MAX="2097152"; CONNTRACK_MAX="1048576"; VM_TIER="高性能级(2GB-4GB)"
    elif [ $TOTAL_MEM -le 8192 ]; then
        # 企业级VPS (4GB-8GB)
        RMEM_MAX="134217728"; WMEM_MAX="134217728"; TCP_RMEM="8192 131072 134217728"; TCP_WMEM="8192 87380 134217728"
        SOMAXCONN="65535"; NETDEV_BACKLOG="65535"; FILE_MAX="4194304"; CONNTRACK_MAX="2097152"; VM_TIER="企业级(4GB-8GB)"
    else
        # 旗舰级VPS (>8GB)
        RMEM_MAX="134217728"; WMEM_MAX="134217728"; TCP_RMEM="8192 131072 134217728"; TCP_WMEM="8192 87380 134217728"
        SOMAXCONN="65535"; NETDEV_BACKLOG="65535"; FILE_MAX="8388608"; CONNTRACK_MAX="2097152"; VM_TIER="旗舰级(>8GB)"
    fi
}

# --- 预检查函数 ---
pre_flight_checks() {
    echo -e "${BLUE}>>> 执行预检查...${NC}"
    if [[ $(id -u) -ne 0 ]]; then echo -e "${RED}❌ 错误: 此脚本必须以root权限运行${NC}"; exit 1; fi
    KERNEL_VERSION=$(uname -r); KERNEL_MAJOR=$(echo "$KERNEL_VERSION" | cut -d. -f1); KERNEL_MINOR=$(echo "$KERNEL_VERSION" | cut -d. -f2)
    if (( KERNEL_MAJOR < 4 )) || (( KERNEL_MAJOR == 4 && KERNEL_MINOR < 9 )); then
        echo -e "${RED}❌ 错误: 内核版本 $KERNEL_VERSION 不支持BBR (需要 4.9+)${NC}"; exit 1
    else
        echo -e "${GREEN}✅ 内核版本 $KERNEL_VERSION 支持BBR${NC}"
    fi
    if [[ ! $(cat /proc/sys/net/ipv4/tcp_available_congestion_control) =~ "bbr" ]]; then
        echo -e "${YELLOW}⚠️  警告: BBR模块未加载，尝试加载...${NC}"
        modprobe tcp_bbr 2>/dev/null || echo -e "${RED}❌ 无法加载BBR模块${NC}"
    fi
}

# --- 配置添加函数 ---
add_conf() {
    local key="$1"
    local value="$2"
    local comment="$3"
    echo "# $comment" >> "$CONF_FILE"; echo "$key = $value" >> "$CONF_FILE"
    echo -e "[${GREEN}设置${NC}] $key = ${YELLOW}$value${NC}"
}

# --- 备份现有配置 ---
backup_existing_config() {
    if [ -f "$CONF_FILE" ]; then
        BAK_FILE="$CONF_FILE.bak_$(date +%F_%H-%M-%S)"
        echo -e "${YELLOW}>>> 备份现有配置到: $BAK_FILE${NC}"
        cp "$CONF_FILE" "$BAK_FILE"
    fi
}

# --- 主要优化配置 (精简版) ---
apply_optimizations() {
    echo -e "${CYAN}>>> 应用核心网络优化配置...${NC}"
    echo -e "检测到配置: ${YELLOW}${VM_TIER}${NC}"
    > "$CONF_FILE"
    cat >> "$CONF_FILE" << EOF
# 核心网络优化配置 (精简版) - 生成于 $(date)
# 针对 ${TOTAL_MEM}MB 内存(${VM_TIER}), ${CPU_CORES}核CPU 的系统优化

EOF
    add_conf "net.core.default_qdisc" "fq" "使用Fair Queue调度器"
    add_conf "net.ipv4.tcp_congestion_control" "bbr" "启用BBR拥塞控制算法"
    echo "" >> "$CONF_FILE"
    
    add_conf "net.core.rmem_max" "$RMEM_MAX" "最大socket读缓冲区"
    add_conf "net.core.wmem_max" "$WMEM_MAX" "最大socket写缓冲区"
    add_conf "net.ipv4.tcp_rmem" "$TCP_RMEM" "TCP读缓冲区 (min/default/max)"
    add_conf "net.ipv4.tcp_wmem" "$TCP_WMEM" "TCP写缓冲区 (min/default/max)"
    echo "" >> "$CONF_FILE"

    add_conf "net.core.somaxconn" "$SOMAXCONN" "最大监听队列长度"
    add_conf "net.core.netdev_max_backlog" "$NETDEV_BACKLOG" "网络设备最大排队数"
    add_conf "net.ipv4.tcp_max_syn_backlog" "$SOMAXCONN" "SYN队列最大长度"
    echo "" >> "$CONF_FILE"

    add_conf "net.ipv4.tcp_fin_timeout" "15" "缩短FIN_WAIT_2超时时间"
    add_conf "net.ipv4.tcp_tw_reuse" "0" "禁用TIME_WAIT重用以增强稳定性"
    add_conf "net.ipv4.tcp_max_tw_buckets" "180000" "增加TIME_WAIT socket最大数量"
    echo "" >> "$CONF_FILE"

    add_conf "fs.file-max" "$FILE_MAX" "系统最大文件句柄数"
    add_conf "fs.nr_open" "$FILE_MAX" "进程最大文件句柄数"
    echo "" >> "$CONF_FILE"

    add_conf "net.ipv4.tcp_slow_start_after_idle" "0" "禁用空闲后慢启动，保持高吞吐"
    add_conf "vm.swappiness" "10" "降低swap使用倾向"
    echo "" >> "$CONF_FILE"

    if [ -f /proc/sys/net/netfilter/nf_conntrack_max ]; then
        add_conf "net.netfilter.nf_conntrack_max" "$CONNTRACK_MAX" "连接跟踪表最大条目数 (防火墙/NAT)"
    fi
}

# --- 应用与验证 ---
apply_and_verify() {
    echo -e "${CYAN}>>> 应用sysctl配置...${NC}"
    sysctl --system >/dev/null 2>&1 || { echo -e "${RED}❌ 配置应用失败${NC}"; exit 1; }
    echo -e "${GREEN}✅ 配置应用成功${NC}"
    echo -e "${CYAN}>>> 验证优化结果...${NC}"
    CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control)
    CURRENT_QDISC=$(sysctl -n net.core.default_qdisc)
    echo -e "TCP拥塞控制: ${YELLOW}$CURRENT_CC${NC}"
    echo -e "队列调度算法: ${YELLOW}$CURRENT_QDISC${NC}"
    if [[ "$CURRENT_CC" == "bbr" ]]; then echo -e "${GREEN}✅ BBR已启用${NC}"; else echo -e "${RED}❌ BBR未启用${NC}"; fi
}

# --- 提示信息 ---
show_tips() {
    echo ""
    echo -e "${YELLOW}配置文件位置: $CONF_FILE${NC}"
    local bak_file_hint=$(ls -t "$CONF_FILE.bak_"* 2>/dev/null | head -n 1)
    if [ -n "$bak_file_hint" ]; then
        echo -e "${YELLOW}要撤销优化，请运行: ${CYAN}mv \"$bak_file_hint\" \"$CONF_FILE\" && sysctl --system${NC}"
    fi
}

# --- 主函数 ---
main() {
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}         精简优化版VPS网络脚本         ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    pre_flight_checks
    get_system_info
    calculate_parameters
    backup_existing_config
    apply_optimizations
    apply_and_verify
    show_tips
    echo -e "\n${GREEN}🎉 核心网络优化完成！所有参数已动态生效。${NC}"
}

main
