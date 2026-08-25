#!/usr/bin/env bash

# ==============================================================================
# Linux TCP/IP & BBR 智能优化脚本
#
# 版本: 2.0.0 (针对代理转发深度优化)
# 改进日志:
# - [核心] 启用 tcp_tw_reuse，解决高并发下的端口耗尽问题
# - [新增] 增加 TCP Keepalive 调优，快速释放死连接
# - [新增] 增加 UDP 缓冲区优化 (针对 Hysteria/QUIC)
# - [新增] 引入 tcp_notsent_lowat 降低延迟
# - [调整] 优化 conntrack 策略，防止表溢出
# ==============================================================================

# --- 脚本版本号定义 ---
SCRIPT_VERSION="2.0.0"

set -euo pipefail

# --- 颜色定义 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- 配置文件路径 ---
CONF_FILE="/etc/sysctl.d/99-network-optimization.conf"
LEGACY_CONF_FILE="/etc/sysctl.d/99-bbr.conf"
SWAP_FILE="/swapfile"

# --- 系统信息检测函数 ---
get_system_info() {
    TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}' | tr -d '\r')
    CPU_CORES=$(nproc | tr -d '\r')
    
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        VIRT_TYPE=$(systemd-detect-virt)
    elif grep -q -i "hypervisor" /proc/cpuinfo; then
        VIRT_TYPE="KVM/VMware"
    else
        VIRT_TYPE="Physical/Unknown"
    fi

    echo -e "${CYAN}>>> 系统信息检测：${NC}"
    echo -e "内存大小   : ${YELLOW}${TOTAL_MEM}MB${NC}"
    echo -e "CPU核心数  : ${YELLOW}${CPU_CORES}${NC}"
    echo -e "虚拟化类型 : ${YELLOW}${VIRT_TYPE}${NC}"
    
    calculate_parameters
}

# --- 动态参数计算函数 (针对转发业务调整) ---
calculate_parameters() {
    # 基础连接数设置 - 代理服务器需要更多的连接跟踪
    if [ "$TOTAL_MEM" -le 512 ]; then
        VM_TIER="入门级(≤512MB)"
        RMEM_MAX="16777216"   # 16MB
        WMEM_MAX="16777216"
        TCP_MEM_MAX="16777216"
        SOMAXCONN="4096"
        FILE_MAX="65535"
        CONNTRACK_MAX="65536"
    elif [ "$TOTAL_MEM" -le 1024 ]; then
        VM_TIER="基础级(1GB)"
        RMEM_MAX="33554432"   # 32MB
        WMEM_MAX="33554432"
        TCP_MEM_MAX="33554432"
        SOMAXCONN="16384"
        FILE_MAX="524288"
        CONNTRACK_MAX="262144"
    elif [ "$TOTAL_MEM" -le 4096 ]; then
        VM_TIER="进阶级(1GB-4GB)"
        RMEM_MAX="67108864"   # 64MB
        WMEM_MAX="67108864"
        TCP_MEM_MAX="67108864"
        SOMAXCONN="32768"
        FILE_MAX="1048576"
        CONNTRACK_MAX="524288"
    else
        VM_TIER="专业级(>4GB)"
        # 限制最大缓冲区，避免单连接吃光内存，注重并发总量
        RMEM_MAX="134217728"  # 128MB
        WMEM_MAX="134217728"
        TCP_MEM_MAX="134217728"
        SOMAXCONN="65535"
        FILE_MAX="2097152"
        CONNTRACK_MAX="1048576" # 100万连接足够绝大多数场景，过大浪费内核内存
    fi
}

# --- 预检查函数 ---
pre_flight_checks() {
    if [[ $(id -u) -ne 0 ]]; then
        echo -e "${RED}❌ 错误: 必须 root 权限。${NC}"
        exit 1
    fi
    # 加载必要的内核模块 (尤其是连接跟踪和BBR)
    modprobe nf_conntrack >/dev/null 2>&1 || true
    modprobe tcp_bbr >/dev/null 2>&1 || true
}

# --- 配置写入函数 ---
add_conf() {
    local key="$1"
    local value="$2"
    local comment="$3"
    echo "# $comment" >> "$CONF_FILE"
    echo "$key = $value" >> "$CONF_FILE"
    echo "" >> "$CONF_FILE"
}

# --- 备份管理 ---
manage_backups() {
    if [ -f "$CONF_FILE" ]; then
        cp "$CONF_FILE" "$CONF_FILE.bak_$(date +%F_%H-%M-%S)"
        # 保留最近3个备份
        find "$(dirname "$CONF_FILE")" -maxdepth 1 -type f \
            -name "$(basename "$CONF_FILE").bak_*" -printf '%T@ %p\n' 2>/dev/null \
            | sort -nr | awk 'NR > 3 {sub(/^[^ ]+ /, ""); print}' \
            | xargs -r rm -f
    fi
}

migrate_legacy_config() {
    if [[ -f "$LEGACY_CONF_FILE" ]]; then
        local backup="${LEGACY_CONF_FILE}.migrated_$(date +%F_%H-%M-%S)"
        cp "$LEGACY_CONF_FILE" "$backup"
        rm -f "$LEGACY_CONF_FILE"
        echo -e "${YELLOW}⚠️ 已备份并停用旧配置: ${LEGACY_CONF_FILE}${NC}"
    fi
}

configure_swap() {
    if swapon --show=NAME --noheadings 2>/dev/null | grep -q .; then
        echo -e "${GREEN}✅ 已检测到现有 Swap，跳过创建。${NC}"
        return
    fi

    local swap_mb
    if [ "$TOTAL_MEM" -le 512 ]; then
        swap_mb=512
    elif [ "$TOTAL_MEM" -le 1024 ]; then
        swap_mb=1024
    else
        swap_mb=2048
    fi

    local available_mb
    available_mb=$(df -Pm / | awk 'NR==2 {print $4}')
    if [[ -z "$available_mb" || "$available_mb" -lt $((swap_mb + 100)) ]]; then
        echo -e "${YELLOW}⚠️ 磁盘空间不足，跳过创建 ${swap_mb}MB Swap。${NC}"
        return
    fi

    echo -e "${CYAN}>>> 创建 ${swap_mb}MB Swap...${NC}"
    if [[ -e "$SWAP_FILE" ]]; then
        echo -e "${YELLOW}⚠️ ${SWAP_FILE} 已存在但未启用，为避免覆盖用户文件，跳过创建。${NC}"
        return
    fi
    if command -v fallocate >/dev/null 2>&1; then
        fallocate -l "${swap_mb}M" "$SWAP_FILE"
    else
        dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$swap_mb" status=none
    fi
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE" >/dev/null
    swapon "$SWAP_FILE"
    grep -qF "$SWAP_FILE none swap" /etc/fstab 2>/dev/null || \
        echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
    echo -e "${GREEN}✅ Swap 已启用: ${swap_mb}MB${NC}"
}

# --- 核心优化逻辑 (重写部分) ---
apply_optimizations() {
    echo -e "${CYAN}>>> 应用网络优化配置 (${YELLOW}${VM_TIER}${CYAN})...${NC}"
    > "$CONF_FILE"
    
    cat >> "$CONF_FILE" << EOF
# ==========================================================
# Linux Network Tuning (Proxy/Forwarding Optimized)
# 生成时间: $(date)
# 硬件环境: ${TOTAL_MEM}MB RAM, ${CPU_CORES} CPU
# ==========================================================
EOF

    # 1. BBR 与 队列算法
    add_conf "net.core.default_qdisc" "fq" "FQ 队列算法 (BBR 最佳拍档)"
    add_conf "net.ipv4.tcp_congestion_control" "bbr" "开启 BBR"

    # 2. 缓冲区优化 (TCP & UDP) - 这对 Hysteria/QUIC 很重要
    add_conf "net.core.rmem_max" "$RMEM_MAX" "系统最大接收缓存"
    add_conf "net.core.wmem_max" "$WMEM_MAX" "系统最大发送缓存"
    add_conf "net.core.rmem_default" "262144" "默认接收缓存 (256k)" 
    add_conf "net.core.wmem_default" "262144" "默认发送缓存 (256k)"
    # TCP 自动调优窗口
    add_conf "net.ipv4.tcp_rmem" "8192 262144 $TCP_MEM_MAX" "TCP读缓存 (min default max)"
    add_conf "net.ipv4.tcp_wmem" "8192 262144 $TCP_MEM_MAX" "TCP写缓存 (min default max)"
    add_conf "net.ipv4.udp_rmem_min" "16384" "UDP读缓存下限 (优化QUIC)"
    add_conf "net.ipv4.udp_wmem_min" "16384" "UDP写缓存下限 (优化QUIC)"

    # 3. 连接与队列上限
    add_conf "net.core.somaxconn" "$SOMAXCONN" "最大监听队列"
    add_conf "net.core.netdev_max_backlog" "$SOMAXCONN" "网卡积压队列"
    add_conf "net.ipv4.tcp_max_syn_backlog" "$SOMAXCONN" "SYN半连接队列"
    add_conf "net.ipv4.tcp_notsent_lowat" "16384" "降低缓冲区未发送数据阈值 (降低延迟)"

    # 4. TIME_WAIT 与 端口复用 (代理服务器的关键)
    add_conf "net.ipv4.tcp_tw_reuse" "1" "开启 TIME_WAIT 复用 (关键优化)"
    add_conf "net.ipv4.tcp_timestamps" "1" "开启时间戳 (配合 reuse 必须)"
    add_conf "net.ipv4.tcp_fin_timeout" "30" "缩短 FIN_WAIT 时间"
    add_conf "net.ipv4.ip_local_port_range" "10000 65535" "扩大本地端口范围"
    add_conf "net.ipv4.tcp_max_tw_buckets" "500000" "允许更多 TIME_WAIT socket 存在"

    # 5. TCP Keepalive (快速剔除死链)
    add_conf "net.ipv4.tcp_keepalive_time" "600" "TCP保活时间 (10分钟)"
    add_conf "net.ipv4.tcp_keepalive_intvl" "15" "探测间隔"
    add_conf "net.ipv4.tcp_keepalive_probes" "5" "探测次数"

    # 6. 连接跟踪 (Conntrack)
    # 如果模块未加载，写入配置可能会报错，这里做个判断（但通常文件写入没问题，是sysctl -p报错）
    if [[ -f /proc/sys/net/netfilter/nf_conntrack_max ]]; then
        add_conf "net.netfilter.nf_conntrack_max" "$CONNTRACK_MAX" "最大连接跟踪数"
        add_conf "net.netfilter.nf_conntrack_tcp_timeout_established" "7200" "连接跟踪超时 (2小时)"
        add_conf "net.netfilter.nf_conntrack_tcp_timeout_time_wait" "120" "减少 TIME_WAIT 跟踪时间"
    else
        echo -e "${YELLOW}⚠️ 当前内核不支持 conntrack，跳过相关参数。${NC}"
    fi

    # 7. 其他系统级优化
    add_conf "fs.file-max" "$FILE_MAX" "最大文件句柄"
    add_conf "vm.swappiness" "10" "减少 Swap 使用"
    add_conf "net.ipv4.tcp_mtu_probing" "1" "开启 MTU 探测 (解决部分网络卡顿)"
    add_conf "net.ipv4.tcp_syncookies" "1" "防 SYN Flood"
}

# --- 应用与验证 ---
apply_and_verify() {
    echo -e "${CYAN}>>> 应用配置...${NC}"
    local sysctl_rc=0
    sysctl --system >/dev/null 2>&1 || sysctl_rc=$?
    
    local cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    local reuse=$(sysctl -n net.ipv4.tcp_tw_reuse 2>/dev/null)
    if [[ "$sysctl_rc" -ne 0 ]]; then
        echo -e "${YELLOW}⚠️ 部分 sysctl 参数应用失败，请检查 ${CONF_FILE}。${NC}"
    else
        echo -e "${GREEN}✅ 优化配置已应用。${NC}"
    fi
    echo -e "拥塞控制: ${YELLOW}${cc}${NC} | 队列算法: ${YELLOW}${qdisc}${NC}"
    if [ "$reuse" == "1" ]; then
        echo -e "并发复用: ${GREEN}已启用 (tcp_tw_reuse)${NC}"
    else
        echo -e "并发复用: ${RED}未启用 (可能被覆盖)${NC}"
    fi
}

# --- 主逻辑 ---
main() {
    # 简单的参数处理
    if [[ "${1:-}" == "restore" || "${1:-}" == "uninstall" ]]; then
        local backup
        backup=$(ls -t "${CONF_FILE}.bak_"* 2>/dev/null | head -n1 || true)
        if [[ "${1:-}" == "restore" && -n "$backup" ]]; then
            cp "$backup" "$CONF_FILE"
            sysctl --system >/dev/null 2>&1 || true
            echo -e "${GREEN}已恢复备份: $backup${NC}"
            exit 0
        elif [[ "${1:-}" == "restore" ]]; then
            echo -e "${YELLOW}未找到可恢复的备份。${NC}"
            exit 1
        fi
        rm -f "$CONF_FILE"
        sysctl --system >/dev/null 2>&1 || true
        echo -e "${GREEN}已删除优化配置。${NC}"
        exit 0
    fi

    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}   Linux Network Optimizer (Proxy Edition) v${SCRIPT_VERSION}   ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    
    pre_flight_checks
    get_system_info
    configure_swap
    migrate_legacy_config
    manage_backups
    apply_optimizations
    apply_and_verify
}

main "$@"
