#!/usr/bin/env bash

# ==============================================================================
# Linux TCP/IP & BBR 智能优化脚本 (已修复版本)
#
# 描述: 此脚本实现了核心网络参数的动态适配与BBR的自动启用。
#       具备完善的预检查、自动化备份与清理机制，确保操作既高效又安全。
#       此版本优化了代码排版，提高了可读性和可维护性。
#
# 作者: yahuisme
# 版本: 1.2.1 (修复版)
# ==============================================================================

set -euo pipefail

# --- 颜色定义 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- 配置文件路径 ---
CONF_FILE="/etc/sysctl.d/99-bbr.conf"

# --- 系统信息检测函数 ---
get_system_info() {
    TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
    CPU_CORES=$(nproc)
    # 尝试检测虚拟化类型，失败则为 unknown
    if systemd-detect-virt >/dev/null 2>&1; then
        VIRT_TYPE=$(systemd-detect-virt)
    else
        VIRT_TYPE="unknown"
    fi

    echo -e "${CYAN}>>> 系统信息检测：${NC}"
    echo -e "内存大小   : ${YELLOW}${TOTAL_MEM}MB${NC}"
    echo -e "CPU核心数  : ${YELLOW}${CPU_CORES}${NC}"
    echo -e "虚拟化类型 : ${YELLOW}${VIRT_TYPE}${NC}"

    # [修复] 在此调用参数计算函数，确保 TOTAL_MEM 变量作用域有效
    calculate_parameters
}

# --- 动态参数计算函数 (已优化排版) ---
calculate_parameters() {
    # 根据总内存 (MB) 分级设置网络参数
    if [ "$TOTAL_MEM" -le 512 ]; then # 经典级 (≤512MB)
        VM_TIER="经典级(≤512MB)"
        RMEM_MAX="8388608";         WMEM_MAX="8388608"
        TCP_RMEM="4096 65536 8388608";       TCP_WMEM="4096 65536 8388608"
        SOMAXCONN="32768";          NETDEV_BACKLOG="16384"
        FILE_MAX="262144";          CONNTRACK_MAX="131072"
    elif [ "$TOTAL_MEM" -le 1024 ]; then # 轻量级 (512MB-1GB)
        VM_TIER="轻量级(512MB-1GB)"
        RMEM_MAX="16777216";        WMEM_MAX="16777216"
        TCP_RMEM="4096 65536 16777216";      TCP_WMEM="4096 65536 16777216"
        SOMAXCONN="49152";          NETDEV_BACKLOG="24576"
        FILE_MAX="524288";          CONNTRACK_MAX="262144"
    elif [ "$TOTAL_MEM" -le 2048 ]; then # 标准级 (1GB-2GB)
        VM_TIER="标准级(1GB-2GB)"
        RMEM_MAX="33554432";        WMEM_MAX="33554432"
        TCP_RMEM="4096 87380 33554432";      TCP_WMEM="4096 65536 33554432"
        SOMAXCONN="65535";          NETDEV_BACKLOG="32768"
        FILE_MAX="1048576";         CONNTRACK_MAX="524288"
    elif [ "$TOTAL_MEM" -le 4096 ]; then # 高性能级 (2GB-4GB)
        VM_TIER="高性能级(2GB-4GB)"
        RMEM_MAX="67108864";        WMEM_MAX="67108864"
        TCP_RMEM="4096 131072 67108864";     TCP_WMEM="4096 87380 67108864"
        SOMAXCONN="65535";          NETDEV_BACKLOG="65535"
        FILE_MAX="2097152";         CONNTRACK_MAX="1048576"
    elif [ "$TOTAL_MEM" -le 8192 ]; then # 企业级 (4GB-8GB)
        VM_TIER="企业级(4GB-8GB)"
        RMEM_MAX="134217728";        WMEM_MAX="134217728"
        TCP_RMEM="8192 131072 134217728";    TCP_WMEM="8192 87380 134217728"
        SOMAXCONN="65535";          NETDEV_BACKLOG="65535"
        FILE_MAX="4194304";         CONNTRACK_MAX="2097152"
    else # 旗舰级 (>8GB)
        VM_TIER="旗舰级(>8GB)"
        RMEM_MAX="134217728";        WMEM_MAX="134217728"
        TCP_RMEM="8192 131072 134217728";    TCP_WMEM="8192 87380 134217728"
        SOMAXCONN="65535";          NETDEV_BACKLOG="65535"
        FILE_MAX="8388608";         CONNTRACK_MAX="2097152"
    fi
}

# --- 预检查函数 ---
pre_flight_checks() {
    echo -e "${BLUE}>>> 执行预检查...${NC}"
    if [[ $(id -u) -ne 0 ]]; then
        echo -e "${RED}❌ 错误: 此脚本必须以root权限运行。${NC}"; exit 1
    fi

    local KERNEL_VERSION
    KERNEL_VERSION=$(uname -r)

    if [[ $(printf '%s\n' "4.9" "$KERNEL_VERSION" | sort -V | head -n1) != "4.9" ]]; then
        echo -e "${RED}❌ 错误: 内核版本 $KERNEL_VERSION 不支持BBR (需要 4.9+)。${NC}"; exit 1
    else
        echo -e "${GREEN}✅ 内核版本 $KERNEL_VERSION, 支持BBR。${NC}"
    fi

    if ! sysctl net.ipv4.tcp_available_congestion_control | grep -q "bbr"; then
        echo -e "${YELLOW}⚠️  警告: BBR模块未加载，尝试加载...${NC}"
        modprobe tcp_bbr 2>/dev/null || { echo -e "${RED}❌ 无法加载BBR模块, 请检查内核。${NC}"; exit 1; }
    fi
}

# --- 配置写入函数 ---
add_conf() {
    local key="$1"
    local value="$2"
    local comment="$3"
    echo "# $comment" >> "$CONF_FILE"
    echo "$key = $value" >> "$CONF_FILE"
    echo "" >> "$CONF_FILE"
    echo -e "[${GREEN}设置${NC}] $key = ${YELLOW}$value${NC}"
}

# --- 备份管理与清理函数 ---
manage_backups() {
    # 1. 优先创建当前的新备份
    if [ -f "$CONF_FILE" ]; then
        BAK_FILE="$CONF_FILE.bak_$(date +%F_%H-%M-%S)"
        echo -e "${YELLOW}>>> 创建当前配置备份: $BAK_FILE${NC}"
        cp "$CONF_FILE" "$BAK_FILE"
    fi

    # 2. 清理旧备份, 只保留最新的一个
    local old_backups
    old_backups=$(ls -t "$CONF_FILE.bak_"* 2>/dev/null | tail -n +2)

    if [ -n "$old_backups" ]; then
        echo -e "${CYAN}>>> 清理旧的备份文件...${NC}"
        # 使用 xargs -r 选项，如果输入为空则不执行rm，更安全
        echo "$old_backups" | xargs -r rm
        echo -e "${GREEN}✅ 旧备份清理完成。${NC}"
    fi
}

# --- 主要优化配置 ---
apply_optimizations() {
    echo -e "${CYAN}>>> 应用核心网络优化配置 (${YELLOW}${VM_TIER}${CYAN})...${NC}"
    # 清空并写入文件头
    > "$CONF_FILE"
    cat >> "$CONF_FILE" << EOF
# ==========================================================
# TCP/IP & BBR 优化配置 (由脚本自动生成)
# 生成时间: $(date)
# 针对硬件: ${TOTAL_MEM}MB 内存, ${CPU_CORES}核CPU (${VM_TIER})
# ==========================================================

EOF
    # --- BBR & FQ 队列设置 ---
    add_conf "net.core.default_qdisc" "fq" "使用Fair Queue队列调度器, 配合BBR效果更佳"
    add_conf "net.ipv4.tcp_congestion_control" "bbr" "启用BBR拥塞控制算法"

    # --- 内存与缓冲区设置 ---
    add_conf "net.core.rmem_max" "$RMEM_MAX" "最大socket读缓冲区"
    add_conf "net.core.wmem_max" "$WMEM_MAX" "最大socket写缓冲区"
    add_conf "net.ipv4.tcp_rmem" "$TCP_RMEM" "TCP读缓冲区 (min/default/max)"
    add_conf "net.ipv4.tcp_wmem" "$TCP_WMEM" "TCP写缓冲区 (min/default/max)"

    # --- 连接队列设置 ---
    add_conf "net.core.somaxconn" "$SOMAXCONN" "最大监听队列长度"
    add_conf "net.core.netdev_max_backlog" "$NETDEV_BACKLOG" "网络设备最大排队数"
    add_conf "net.ipv4.tcp_max_syn_backlog" "$SOMAXCONN" "SYN队列最大长度 (与somaxconn保持一致)"
    
    # --- TIME_WAIT/FIN_WAIT 状态优化 ---
    add_conf "net.ipv4.tcp_fin_timeout" "15" "缩短FIN_WAIT_2状态超时, 加快资源回收"
    add_conf "net.ipv4.tcp_tw_reuse" "0" "禁用TIME_WAIT重用 (现代网络下更稳定安全)"
    add_conf "net.ipv4.tcp_max_tw_buckets" "180000" "增加TIME_WAIT socket最大数量"

    # --- 系统级资源限制 ---
    add_conf "fs.file-max" "$FILE_MAX" "系统级最大文件句柄数"
    add_conf "fs.nr_open" "$FILE_MAX" "单进程最大文件句柄数"
    
    # --- 其他网络行为优化 ---
    add_conf "net.ipv4.tcp_slow_start_after_idle" "0" "禁用空闲后慢启动, 保持高吞吐"
    add_conf "vm.swappiness" "10" "降低Swap使用倾向, 优先使用物理内存"

    # --- 防火墙连接跟踪表 (如果存在) ---
    if [ -f /proc/sys/net/netfilter/nf_conntrack_max ]; then
        add_conf "net.netfilter.nf_conntrack_max" "$CONNTRACK_MAX" "连接跟踪表最大条目数 (防火墙/NAT)"
    fi
}

# --- 应用与验证 ---
apply_and_verify() {
    echo -e "${CYAN}>>> 使配置生效...${NC}"
    sysctl --system || { echo -e "${RED}❌ 配置应用失败, 请检查 $CONF_FILE 文件格式。${NC}"; exit 1; }
    
    echo -e "${GREEN}✅ 配置已动态生效。${NC}"
    
    echo -e "${CYAN}>>> 验证优化结果...${NC}"
    local CURRENT_CC; CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control)
    local CURRENT_QDISC; CURRENT_QDISC=$(sysctl -n net.core.default_qdisc)
    
    echo -e "当前拥塞控制算法: ${YELLOW}$CURRENT_CC${NC}"
    echo -e "当前网络队列调度器: ${YELLOW}$CURRENT_QDISC${NC}"

    if [[ "$CURRENT_CC" == "bbr" && "$CURRENT_QDISC" == "fq" ]]; then
        echo -e "${GREEN}✅ BBR 与 FQ 已成功启用!${NC}"
    else
        echo -e "${RED}❌ 优化未完全生效, 请检查系统日志。${NC}"
    fi
}

# --- 提示信息 ---
show_tips() {
    echo ""
    echo -e "${YELLOW}-------------------- 操作完成 --------------------${NC}"
    echo -e "配置文件已写入: ${CYAN}$CONF_FILE${NC}"
    
    local bak_file_hint
    bak_file_hint=$(ls -t "$CONF_FILE.bak_"* 2>/dev/null | head -n 1)

    if [ -n "$bak_file_hint" ]; then
        echo -e "如需撤销本次优化, 可运行以下命令恢复最新备份:"
        echo -e "${GREEN}mv \"$bak_file_hint\" \"$CONF_FILE\" && sysctl --system${NC}"
        echo -e "或者直接运行: ${GREEN}bash $0 uninstall${NC}"
    fi
    echo -e "${YELLOW}--------------------------------------------------${NC}"
}

# --- [新增] 幂等性检查函数 ---
check_if_already_applied() {
    if grep -q "# 由脚本自动生成" "$CONF_FILE" 2>/dev/null; then
        local current_cc
        current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
        if [[ "$current_cc" == "bbr" ]]; then
            echo -e "${GREEN}✅ 系统已被此脚本优化，且BBR已启用，无需重复操作。${NC}"
            exit 0
        fi
    fi
}

# --- [新增] 撤销与卸载函数 ---
revert_optimizations() {
    echo -e "${YELLOW}>>> 正在尝试撤销优化...${NC}"
    
    local latest_backup
    latest_backup=$(ls -t "$CONF_FILE.bak_"* 2>/dev/null | head -n 1)

    if [ -f "$latest_backup" ]; then
        echo -e "找到最新备份文件: ${CYAN}$latest_backup${NC}"
        # 检查root权限
        if [[ $(id -u) -ne 0 ]]; then
            echo -e "${RED}❌ 错误: 恢复操作必须以root权限运行。${NC}"; exit 1
        fi
        mv "$latest_backup" "$CONF_FILE"
        echo -e "${GREEN}✅ 已通过备份文件恢复。${NC}"
    elif [ -f "$CONF_FILE" ]; then
        echo -e "${YELLOW}未找到备份文件，将直接删除配置文件...${NC}"
        if [[ $(id -u) -ne 0 ]]; then
            echo -e "${RED}❌ 错误: 删除操作必须以root权限运行。${NC}"; exit 1
        fi
        rm -f "$CONF_FILE"
        echo -e "${GREEN}✅ 配置文件已删除。${NC}"
    else
        echo -e "${GREEN}✅ 系统未发现优化配置文件，无需操作。${NC}"
        return 0
    fi
    
    # 让配置生效
    echo -e "${CYAN}>>> 使恢复后的配置生效...${NC}"
    sysctl --system >/dev/null 2>&1
    echo -e "${GREEN}🎉 优化已成功撤销！系统将恢复到内核默认或之前的配置。${NC}"
}


# --- 主函数 (已改造) ---
main() {
    # 参数处理：检查是否为卸载命令
    if [[ "${1:-}" == "uninstall" || "${1:-}" == "--revert" ]]; then
        revert_optimizations
        exit 0
    fi

    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}        Linux TCP/IP & BBR 智能优化脚本        ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    
    check_if_already_applied
    pre_flight_checks
    get_system_info
    # [修复] calculate_parameters 已被移动到 get_system_info 内部，故删除此行
    manage_backups
    apply_optimizations
    apply_and_verify
    show_tips
    
    echo -e "\n${GREEN}🎉 所有优化已完成并生效！${NC}"
}

# --- 脚本入口 (已改造) ---
# 使用 "$@" 将所有命令行参数传递给主函数
main "$@"
