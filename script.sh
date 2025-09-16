#!/usr/bin/env bash

# ==============================================================================
# Linux TCP/IP & BBR 智能优化脚本 (深度追踪调试版)
#
# 作者: yahuisme
# 版本: 1.2.3 (Debug Trace)
# ==============================================================================

# 开启命令追踪 (-x)，并保留错误时退出 (-e)
set -exuo pipefail

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
    echo "--- DEBUG TRACE: Entering get_system_info ---"
    # [最终修复] 添加 tr -d '\r' 来清除free命令输出中可能包含的隐藏回车符
    TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}' | tr -d '\r')
    CPU_CORES=$(nproc | tr -d '\r')
    
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

    echo "--- DEBUG TRACE: Calling calculate_parameters ---"
    calculate_parameters
    echo "--- DEBUG TRACE: Returned from calculate_parameters ---"
}

# --- 动态参数计算函数 (已优化排版) ---
calculate_parameters() {
    echo "--- DEBUG TRACE: Entering calculate_parameters ---"
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
    else # 简化版，覆盖剩余所有情况
        VM_TIER="标准级或更高"
        RMEM_MAX="33554432";        WMEM_MAX="33554432"
        TCP_RMEM="4096 87380 33554432";      TCP_WMEM="4096 65536 33554432"
        SOMAXCONN="65535";          NETDEV_BACKLOG="32768"
        FILE_MAX="1048576";         CONNTRACK_MAX="524288"
    fi
    echo "--- DEBUG TRACE: Exiting calculate_parameters ---"
}

# --- 主函数 (简化以专注于问题点) ---
main() {
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}        Linux TCP/IP & BBR 智能优化脚本 (追踪模式)       ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    
    pre_flight_checks
    get_system_info
    # 此后的函数暂时不会执行到，但保留结构
    manage_backups
    apply_optimizations
    apply_and_verify
    show_tips
    
    echo -e "\n${GREEN}🎉 所有优化已完成并生效！${NC}"
}

# --- 预检查函数 (保持不变) ---
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

# --- 其他函数定义 (为了脚本能完整运行，这里放一个空定义) ---
manage_backups() { :; }
apply_optimizations() { :; }
apply_and_verify() { :; }
show_tips() { :; }

# --- 脚本入口 ---
main "$@"
