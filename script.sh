#!/bin/bash

# ==============================================================================
# 改进版Linux TCP/IP & BBR网络优化脚本 - 速度与性能完美平衡
#
# 描述: 这个脚本启用TCP BBR并应用平衡的sysctl优化配置
#       支持自动检测系统规格并动态调整参数
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
    echo -e "内存大小: ${YELLOW}${TOTAL_MEM}MB (${VM_TIER})${NC}"
    echo -e "CPU核心数: ${YELLOW}${CPU_CORES}${NC}"
    echo -e "虚拟化类型: ${YELLOW}${VIRT_TYPE}${NC}"
}

# --- 动态参数计算函数 ---
calculate_parameters() {
    # 根据内存大小动态调整缓冲区 (适配现代VPS配置)
    if [ $TOTAL_MEM -le 1024 ]; then
        # 入门级VPS (1GB)
        RMEM_MAX="16777216"     # 16MB
        WMEM_MAX="16777216"     # 16MB
        TCP_RMEM="4096 87380 16777216"
        TCP_WMEM="4096 65536 16777216"
        SOMAXCONN="65535"
        NETDEV_BACKLOG="32768"
        FILE_MAX="524288"
        CONNTRACK_MAX="262144"
        VM_TIER="入门级(1GB)"
    elif [ $TOTAL_MEM -le 2048 ]; then
        # 标准级VPS (2GB)
        RMEM_MAX="33554432"     # 32MB
        WMEM_MAX="33554432"     # 32MB
        TCP_RMEM="4096 87380 33554432"
        TCP_WMEM="4096 65536 33554432"
        SOMAXCONN="65535"
        NETDEV_BACKLOG="65535"
        FILE_MAX="1048576"
        CONNTRACK_MAX="524288"
        VM_TIER="标准级(2GB)"
    elif [ $TOTAL_MEM -le 4096 ]; then
        # 高性能VPS (4GB)
        RMEM_MAX="67108864"     # 64MB
        WMEM_MAX="67108864"     # 64MB
        TCP_RMEM="4096 131072 67108864"
        TCP_WMEM="4096 87380 67108864"
        SOMAXCONN="65535"
        NETDEV_BACKLOG="65535"
        FILE_MAX="2097152"
        CONNTRACK_MAX="1048576"
        VM_TIER="高性能级(4GB)"
    elif [ $TOTAL_MEM -le 8192 ]; then
        # 企业级VPS (8GB)
        RMEM_MAX="134217728"    # 128MB
        WMEM_MAX="134217728"    # 128MB
        TCP_RMEM="8192 131072 134217728"
        TCP_WMEM="8192 87380 134217728"
        SOMAXCONN="65535"
        NETDEV_BACKLOG="65535"
        FILE_MAX="4194304"
        CONNTRACK_MAX="2097152"
        VM_TIER="企业级(8GB)"
    else
        # 旗舰级VPS (>8GB)
        RMEM_MAX="268435456"    # 256MB
        WMEM_MAX="268435456"    # 256MB
        TCP_RMEM="8192 262144 268435456"
        TCP_WMEM="8192 131072 268435456"
        SOMAXCONN="65535"
        NETDEV_BACKLOG="65535"
        FILE_MAX="8388608"
        CONNTRACK_MAX="4194304"
        VM_TIER="旗舰级(>8GB)"
    fi
    
    # 根据CPU核心数调整RPS队列和其他参数
    RPS_SOCK_FLOW_ENTRIES=$((65536 * CPU_CORES))
    
    # CPU核心数优化调整
    if [ $CPU_CORES -ge 4 ]; then
        NETDEV_BUDGET="1000"
    else
        NETDEV_BUDGET="600"
    fi
}

# --- 预检查函数 ---
pre_flight_checks() {
    echo -e "${BLUE}>>> 执行预检查...${NC}"
    
    # 检查root权限
    if [[ $(id -u) -ne 0 ]]; then
        echo -e "${RED}❌ 错误: 此脚本必须以root权限运行${NC}"
        echo -e "${YELLOW}请尝试: sudo $0${NC}"
        exit 1
    fi
    
    # 检查内核版本(BBR需要4.9+)
    KERNEL_VERSION=$(uname -r)
    KERNEL_MAJOR=$(echo "$KERNEL_VERSION" | cut -d. -f1)
    KERNEL_MINOR=$(echo "$KERNEL_VERSION" | cut -d. -f2)
    
    if (( KERNEL_MAJOR < 4 )) || (( KERNEL_MAJOR == 4 && KERNEL_MINOR < 9 )); then
        echo -e "${RED}❌ 错误: 内核版本 $KERNEL_VERSION 不支持BBR${NC}"
        echo -e "${RED}需要Linux内核 4.9+ 版本${NC}"
        exit 1
    else
        echo -e "${GREEN}✅ 内核版本 $KERNEL_VERSION 支持BBR${NC}"
    fi
    
    # 检查BBR支持
    if [ ! -f /proc/sys/net/ipv4/tcp_available_congestion_control ]; then
        echo -e "${RED}❌ 系统不支持拥塞控制配置${NC}"
        exit 1
    fi
    
    # 检查可用的拥塞控制算法
    AVAILABLE_CC=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control)
    if [[ ! $AVAILABLE_CC =~ "bbr" ]]; then
        echo -e "${YELLOW}⚠️  警告: BBR模块未加载，尝试加载...${NC}"
        modprobe tcp_bbr 2>/dev/null || echo -e "${RED}❌ 无法加载BBR模块${NC}"
    fi
}

# --- 配置添加函数 ---
add_conf() {
    local key="$1"
    local value="$2"
    local comment="$3"
    
    if [ -n "$comment" ]; then
        echo "# $comment" >> "$CONF_FILE"
    fi
    echo "$key = $value" >> "$CONF_FILE"
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

# --- 主要优化配置 ---
apply_optimizations() {
    echo -e "${CYAN}>>> 开始应用网络优化配置...${NC}"
    
    # 初始化配置文件
    > "$CONF_FILE"
    cat >> "$CONF_FILE" << EOF
# 网络优化配置 - 生成于 $(date)
# 针对 ${TOTAL_MEM}MB 内存(${VM_TIER}), ${CPU_CORES}核CPU 的系统优化
# 虚拟化环境: ${VIRT_TYPE}

EOF

    echo -e "${PURPLE}>>> TCP拥塞控制优化${NC}"
    add_conf "net.core.default_qdisc" "fq" "使用Fair Queue调度器"
    add_conf "net.ipv4.tcp_congestion_control" "bbr" "启用BBR拥塞控制"
    echo "" >> "$CONF_FILE"

    echo -e "${PURPLE}>>> 缓冲区和内存优化${NC}"
    add_conf "net.core.rmem_default" "262144" "默认socket读缓冲区"
    add_conf "net.core.rmem_max" "$RMEM_MAX" "最大socket读缓冲区"
    add_conf "net.core.wmem_default" "262144" "默认socket写缓冲区"
    add_conf "net.core.wmem_max" "$WMEM_MAX" "最大socket写缓冲区"
    add_conf "net.ipv4.tcp_rmem" "$TCP_RMEM" "TCP读缓冲区 min/default/max"
    add_conf "net.ipv4.tcp_wmem" "$TCP_WMEM" "TCP写缓冲区 min/default/max"
    add_conf "net.ipv4.udp_rmem_min" "8192" "UDP最小读缓冲区"
    add_conf "net.ipv4.udp_wmem_min" "8192" "UDP最小写缓冲区"
    echo "" >> "$CONF_FILE"

    echo -e "${PURPLE}>>> 连接队列优化${NC}"
    add_conf "net.core.somaxconn" "$SOMAXCONN" "最大监听队列长度"
    add_conf "net.core.netdev_max_backlog" "$NETDEV_BACKLOG" "网络设备最大队列长度"
    add_conf "net.ipv4.tcp_max_syn_backlog" "16384" "SYN队列最大长度"
    add_conf "net.core.netdev_budget" "$NETDEV_BUDGET" "NAPI处理包数预算(根据CPU调整)"
    echo "" >> "$CONF_FILE"

    echo -e "${PURPLE}>>> TCP行为优化${NC}"
    add_conf "net.ipv4.tcp_fastopen" "3" "启用TCP Fast Open"
    add_conf "net.ipv4.tcp_mtu_probing" "1" "启用MTU探测"
    add_conf "net.ipv4.tcp_window_scaling" "1" "启用窗口缩放"
    add_conf "net.ipv4.tcp_timestamps" "1" "启用时间戳"
    add_conf "net.ipv4.tcp_sack" "1" "启用选择性ACK"
    add_conf "net.ipv4.tcp_fack" "1" "启用前向ACK"
    add_conf "net.ipv4.tcp_dsack" "1" "启用重复SACK"
    echo "" >> "$CONF_FILE"

    echo -e "${PURPLE}>>> 连接超时优化${NC}"
    add_conf "net.ipv4.tcp_fin_timeout" "15" "FIN_WAIT_2状态超时时间"
    add_conf "net.ipv4.tcp_keepalive_time" "600" "TCP keepalive探测间隔"
    add_conf "net.ipv4.tcp_keepalive_intvl" "30" "keepalive探测频率"
    add_conf "net.ipv4.tcp_keepalive_probes" "3" "keepalive探测次数"
    add_conf "net.ipv4.tcp_synack_retries" "2" "SYN-ACK重试次数"
    add_conf "net.ipv4.tcp_syn_retries" "2" "SYN重试次数"
    echo "" >> "$CONF_FILE"

    echo -e "${PURPLE}>>> TIME_WAIT状态优化${NC}"
    add_conf "net.ipv4.tcp_tw_reuse" "1" "启用TIME_WAIT socket重用"
    add_conf "net.ipv4.tcp_max_tw_buckets" "180000" "TIME_WAIT socket最大数量"
    echo "" >> "$CONF_FILE"

    echo -e "${PURPLE}>>> 端口范围和文件句柄${NC}"
    add_conf "net.ipv4.ip_local_port_range" "1024 65535" "本地端口范围"
    add_conf "fs.file-max" "$FILE_MAX" "系统最大文件句柄数"
    add_conf "fs.nr_open" "$FILE_MAX" "进程最大文件句柄数"
    echo "" >> "$CONF_FILE"

    echo -e "${PURPLE}>>> 连接跟踪优化${NC}"
    if [ -f /proc/sys/net/netfilter/nf_conntrack_max ]; then
        add_conf "net.netfilter.nf_conntrack_max" "$CONNTRACK_MAX" "连接跟踪表最大条目数"
        add_conf "net.netfilter.nf_conntrack_tcp_timeout_established" "1800" "已建立连接超时时间"
        add_conf "net.netfilter.nf_conntrack_tcp_timeout_time_wait" "1" "TIME_WAIT连接超时时间"
    fi
    echo "" >> "$CONF_FILE"

    echo -e "${PURPLE}>>> 网络性能调优${NC}"
    add_conf "net.core.rps_sock_flow_entries" "$RPS_SOCK_FLOW_ENTRIES" "RPS socket流表大小"
    add_conf "net.ipv4.tcp_slow_start_after_idle" "0" "禁用空闲后慢启动"
    add_conf "net.ipv4.tcp_no_metrics_save" "1" "禁用路由缓存指标"
    add_conf "net.ipv4.tcp_ecn" "1" "启用显式拥塞通知"
    add_conf "net.ipv4.tcp_frto" "2" "启用F-RTO算法"
    echo "" >> "$CONF_FILE"

    echo -e "${PURPLE}>>> 其他系统优化${NC}"
    add_conf "vm.swappiness" "10" "降低swap使用倾向"
    add_conf "vm.dirty_ratio" "15" "脏页面比例阈值"
    add_conf "vm.dirty_background_ratio" "5" "后台回写脏页面比例"
    add_conf "kernel.pid_max" "65536" "最大进程ID"
}

# --- 应用配置 ---
apply_config() {
    echo -e "${CYAN}>>> 应用sysctl配置...${NC}"
    if sysctl --system >/dev/null 2>&1; then
        echo -e "${GREEN}✅ 配置应用成功${NC}"
    else
        echo -e "${RED}❌ 配置应用失败，请检查配置文件${NC}"
        exit 1
    fi
}

# --- 验证配置 ---
verify_optimization() {
    echo -e "${CYAN}>>> 验证优化结果...${NC}"
    
    # 检查BBR状态
    CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    CURRENT_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
    
    echo -e "TCP拥塞控制: ${YELLOW}$CURRENT_CC${NC}"
    echo -e "队列调度算法: ${YELLOW}$CURRENT_QDISC${NC}"
    
    if [[ "$CURRENT_CC" == "bbr" ]]; then
        if lsmod | grep -q tcp_bbr 2>/dev/null; then
            echo -e "${GREEN}✅ BBR模块已加载并启用${NC}"
        else
            echo -e "${GREEN}✅ BBR已内建于内核并启用${NC}"
        fi
    else
        echo -e "${RED}❌ BBR未正确启用${NC}"
    fi
    
    # 显示关键参数
    echo -e "Socket读缓冲区最大值: ${YELLOW}$(sysctl -n net.core.rmem_max)${NC}"
    echo -e "Socket写缓冲区最大值: ${YELLOW}$(sysctl -n net.core.wmem_max)${NC}"
    echo -e "最大监听队列长度: ${YELLOW}$(sysctl -n net.core.somaxconn)${NC}"
    echo -e "系统最大文件句柄: ${YELLOW}$(sysctl -n fs.file-max)${NC}"
}

# --- 性能测试建议 ---
show_performance_tips() {
    echo -e "${CYAN}>>> 性能测试建议${NC}"
    echo -e "${YELLOW}优化已立即生效！可以使用以下工具测试网络性能：${NC}"
    echo -e "• speedtest-cli: ${CYAN}pip install speedtest-cli${NC}"
    echo -e "• iperf3: ${CYAN}apt install iperf3 或 yum install iperf3${NC}"
    echo -e "• curl测试: ${CYAN}curl -o /dev/null -s -w '%{speed_download}\\n' http://speedtest.example.com/file${NC}"
    echo -e "• 查看当前连接数: ${CYAN}ss -s${NC}"
    echo ""
    echo -e "${YELLOW}配置文件位置: $CONF_FILE${NC}"
    echo -e "${YELLOW}要撤销优化，请删除该文件并运行: sysctl --system${NC}"
    echo -e "${GREEN}💡 提示: 网络优化参数已动态加载，立即生效！${NC}"
}

# --- 主函数 ---
main() {
    echo -e "${CYAN}================================================================${NC}"
    echo -e "${CYAN}         改进版VPS网络优化脚本 - 智能动态调优${NC}"
    echo -e "${CYAN}================================================================${NC}"
    
    pre_flight_checks
    get_system_info
    calculate_parameters
    backup_existing_config
    apply_optimizations
    apply_config
    verify_optimization
    show_performance_tips
    
    echo -e "${CYAN}================================================================${NC}"
    echo -e "${GREEN}🎉 网络优化完成！所有参数已动态生效，无需重启系统。${NC}"
    echo -e "${CYAN}================================================================${NC}"
}

# 运行主函数
main
