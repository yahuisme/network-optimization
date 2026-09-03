#!/usr/bin/env bash

# ==============================================================================
# Linux TCP/IP & BBR 智能优化脚本
#
# 版本: v26.09.03
# ==============================================================================

# --- 脚本版本号定义 ---
SCRIPT_VERSION="v26.09.03"

set -euo pipefail

# --- 颜色定义 ---
GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
BLUE=$'\033[0;34m'
BOLD=$'\033[1m'
NC=$'\033[0m'
BBR_AVAILABLE=false
CONF_WRITE_FILE=""

# --- 统一输出样式 ---

success() { printf '\n%b  [✔] %s%b\n\n' "$GREEN" "$1" "$NC" >&2; }
warning() { printf '\n%b  [⚠] %s%b\n\n' "$YELLOW" "$1" "$NC" >&2; }
error() { printf '\n%b  [✖] %s%b\n\n' "$RED" "$1" "$NC" >&2; }

section() {
    printf '\n%b==> %b%s%b\n' "$CYAN" "$BOLD" "$1" "$NC"
}
step() { printf '%b  -> [%s/%s] %s%b\n' "$BLUE" "$1" "$2" "$3" "$NC"; }


# --- 配置文件路径 ---
CONF_FILE="/etc/sysctl.d/99-network-optimization.conf"
LEGACY_CONF_FILE="/etc/sysctl.d/99-bbr.conf"
SWAP_FILE="/swapfile"

# --- 系统信息检测函数 ---
get_system_info() {
    TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
    CPU_CORES=$(nproc)
    
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        VIRT_TYPE=$(systemd-detect-virt)
    elif grep -q -i "hypervisor" /proc/cpuinfo; then
        VIRT_TYPE="KVM/VMware"
    else
        VIRT_TYPE="Physical/Unknown"
    fi

    section "系统信息检测"
    printf '%b\n' "  内存大小   : ${YELLOW}${TOTAL_MEM}MB${NC}"
    printf '%b\n' "  CPU 核心数 : ${YELLOW}${CPU_CORES}${NC}"
    printf '%b\n' "  虚拟化类型 : ${YELLOW}${VIRT_TYPE}${NC}"
    calculate_parameters
    printf '%b\n' "  优化档位   : ${YELLOW}${VM_TIER}${NC}"
}

# --- 动态参数计算函数 (针对转发业务调整) ---
calculate_parameters() {
    # 基础连接数设置 - 代理服务器需要更多的连接跟踪
    if [ "$TOTAL_MEM" -le 512 ]; then
        VM_TIER="入门级(≤512MB)"
        RMEM_MAX="8388608"    # 8MB
        WMEM_MAX="8388608"
        TCP_MEM_MAX="8388608"
        SOMAXCONN="4096"
        NETDEV_BACKLOG="4096"
        FILE_MAX="131072"
        CONNTRACK_MAX="32768"
    elif [ "$TOTAL_MEM" -le 1024 ]; then
        VM_TIER="基础级(1GB)"
        RMEM_MAX="16777216"   # 16MB
        WMEM_MAX="16777216"
        TCP_MEM_MAX="16777216"
        SOMAXCONN="8192"
        NETDEV_BACKLOG="8192"
        FILE_MAX="262144"
        CONNTRACK_MAX="65536"
    elif [ "$TOTAL_MEM" -le 4096 ]; then
        VM_TIER="进阶级(1GB-4GB)"
        RMEM_MAX="33554432"   # 32MB
        WMEM_MAX="33554432"
        TCP_MEM_MAX="33554432"
        SOMAXCONN="16384"
        NETDEV_BACKLOG="16384"
        FILE_MAX="524288"
        CONNTRACK_MAX="131072"
    else
        VM_TIER="专业级(>4GB)"
        # 限制最大缓冲区，避免单连接吃光内存，注重并发总量
        RMEM_MAX="67108864"    # 64MB
        WMEM_MAX="67108864"
        TCP_MEM_MAX="67108864"
        SOMAXCONN="32768"
        NETDEV_BACKLOG="32768"
        FILE_MAX="1048576"
        CONNTRACK_MAX="262144"
    fi
}

# --- 预检查函数 ---
require_root() {
    if [[ $(id -u) -ne 0 ]]; then
        error "必须使用 root 权限运行。"
        exit 1
    fi
}

sysctl_supported() {
    [[ -e "/proc/sys/${1//./\/}" ]]
}

pre_flight_checks() {
    require_root
    # 加载必要的内核模块 (尤其是连接跟踪和BBR)
    modprobe nf_conntrack >/dev/null 2>&1 || true
    modprobe tcp_bbr >/dev/null 2>&1 || true
    if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        BBR_AVAILABLE=true
    else
        warning "当前内核不支持 BBR，将跳过 BBR 配置。"
    fi
}

# --- 配置写入函数 ---
add_conf() {
    local key="$1"
    local value="$2"
    local comment="$3"
    local target="${CONF_WRITE_FILE:-$CONF_FILE}"
    if ! sysctl_supported "$key"; then
        return 0
    fi
    {
        printf '# %s\n' "$comment"
        printf '%s = %s\n\n' "$key" "$value"
    } >> "$target"
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
        local backup
        backup="${LEGACY_CONF_FILE}.migrated_$(date +%F_%H-%M-%S)"
        cp "$LEGACY_CONF_FILE" "$backup"
        rm -f "$LEGACY_CONF_FILE"
        warning "已备份并停用旧配置：${LEGACY_CONF_FILE}"
    fi
}

configure_swap() {
    local swap_mb
    if [ "$TOTAL_MEM" -le 512 ]; then
        swap_mb=512
    elif [ "$TOTAL_MEM" -le 1024 ]; then
        swap_mb=1024
    else
        swap_mb=2048
    fi

    # 计算当前总 Swap（含分区与 swapfile）
    local current_total_mb=0 size_bytes swap_line
    while IFS= read -r swap_line; do
        [[ -n "$swap_line" ]] || continue
        size_bytes=$(awk '{print $2}' <<< "$swap_line")
        [[ "$size_bytes" =~ ^[0-9]+$ ]] && current_total_mb=$((current_total_mb + (size_bytes + 524288) / 1048576))
    done < <(swapon --show=NAME,SIZE --bytes --noheadings 2>/dev/null)

    if [[ "$current_total_mb" -eq "$swap_mb" ]]; then
        success "现有 Swap 与目标一致（${current_total_mb}MB），保留。"
        return
    fi
    if [[ "$current_total_mb" -gt 0 ]]; then
        warning "现有 Swap ${current_total_mb}MB 与目标 ${swap_mb}MB 不一致，将统一替换为 /swapfile。"
    else
        success "未检测到 Swap，将创建 ${swap_mb}MB。"
    fi

    local available_mb
    available_mb=$(df -Pm / | awk 'NR==2 {print $4}')
    if [[ -z "$available_mb" || "$available_mb" -lt $((swap_mb + 100)) ]]; then
        warning "磁盘空间不足，跳过创建 ${swap_mb}MB Swap。"
        return
    fi

    section "创建 Swap"
    step 1 2 "正在准备 ${swap_mb}MB Swap..."
    # 保护：/swapfile 存在但未启用时视为用户文件，不覆盖
    if [[ -e "$SWAP_FILE" ]] && ! swapon --show=NAME --noheadings 2>/dev/null | grep -Fxq "$SWAP_FILE"; then
        warning "${SWAP_FILE} 已存在但未启用，为避免覆盖用户文件，跳过创建。"
        return
    fi
    local new_swap="${SWAP_FILE}.new.$$"
    # 清理上次运行可能残留的临时 Swap 文件（已格式化但未启用）
    for stale_swap in "${SWAP_FILE}.new"*; do
        [[ -e "$stale_swap" ]] || continue
        [[ "$stale_swap" = "$new_swap" ]] && continue
        swapoff "$stale_swap" 2>/dev/null || true
        rm -f -- "$stale_swap"
    done
    # fallocate 失败（如文件系统不支持）时回退 dd
    if ! fallocate -l "${swap_mb}M" "$new_swap" 2>/dev/null && ! dd if=/dev/zero of="$new_swap" bs=1M count="$swap_mb" status=none 2>/dev/null; then
        rm -f -- "$new_swap"
        error "Swap 文件创建失败。"
        return 1
    fi
    if ! chmod 600 "$new_swap"; then
        rm -f -- "$new_swap"
        error "无法设置 Swap 文件权限，已清理残留文件。"
        return 1
    fi
    if ! mkswap "$new_swap" >/dev/null; then
        rm -f -- "$new_swap"
        error "Swap 初始化失败，已清理残留文件。"
        return 1
    fi

    step 2 2 "替换并启用 Swap..."
    # 新文件就绪后，再关闭全部旧 Swap 并移除 fstab 条目（含分区 Swap）
    if [[ "$current_total_mb" -gt 0 ]]; then
        local active_swap
        while IFS= read -r active_swap; do
            [[ -n "$active_swap" ]] || continue
            if ! swapoff "$active_swap" >/dev/null 2>&1; then
                rm -f -- "$new_swap"
                error "无法关闭现有 Swap：${active_swap}，中止替换。"
                return 1
            fi
        done < <(swapon --show=NAME --noheadings 2>/dev/null)
        sed -i -E '\|^[[:space:]]*[^#[:space:]][^[:space:]]*[[:space:]]+[^[:space:]]+[[:space:]]+swap([[:space:]]\|$)|d' /etc/fstab
        rm -f -- "$SWAP_FILE"
    fi
    if ! mv -f "$new_swap" "$SWAP_FILE"; then
        rm -f -- "$new_swap"
        error "Swap 文件替换失败。"
        return 1
    fi
    if ! swapon "$SWAP_FILE" >/dev/null; then
        rm -f -- "$SWAP_FILE"
        error "Swap 启用失败，已清理残留文件。"
        return 1
    fi
    if ! grep -qF "$SWAP_FILE none swap" /etc/fstab 2>/dev/null; then
        if ! printf '%s\n' "$SWAP_FILE none swap sw 0 0" >> /etc/fstab; then
            swapoff "$SWAP_FILE" >/dev/null 2>&1 || true
            rm -f -- "$SWAP_FILE"
            error "无法写入 /etc/fstab，已撤销并清理 Swap。"
            return 1
        fi
    fi
    success "Swap 已启用：${swap_mb}MB"
}

show_optimization_plan() {
    local bbr_status="跳过" conntrack_status="跳过" swap_status="按内存配置"
    [[ "$BBR_AVAILABLE" = true ]] && bbr_status="启用"
    [[ -e /proc/sys/net/netfilter/nf_conntrack_max ]] && conntrack_status="按内存配置"
    if swapon --show=NAME --noheadings 2>/dev/null | grep -q .; then
        swap_status="将按目标调整"
    else
        swap_status="将按内存创建"
    fi
    printf '%b\n' "${BOLD}  优化参数规划：${NC}"
    printf '    • %-10s : %b%s%b\n' "BBR/FQ" "$YELLOW" "$bbr_status" "$NC"
    printf '    • %-10s : %b%s%b\n' "缓冲区上限" "$YELLOW" "$RMEM_MAX" "$NC"
    printf '    • %-10s : %b%s%b\n' "连接队列" "$YELLOW" "$SOMAXCONN" "$NC"
    printf '    • %-10s : %b%s%b\n' "网卡积压" "$YELLOW" "$NETDEV_BACKLOG" "$NC"
    printf '    • %-10s : %b%s%b\n' "文件句柄" "$YELLOW" "$FILE_MAX" "$NC"
    printf '    • %-10s : %b%s%b\n' "Conntrack" "$YELLOW" "$conntrack_status" "$NC"
    printf '    • %-10s : %b%s%b\n' "Swap" "$YELLOW" "$swap_status" "$NC"
}

apply_optimizations() {
    section "应用网络优化配置：${VM_TIER}"
    show_optimization_plan
    local tmp_file="${CONF_FILE}.tmp.$$"
    trap 'rm -f -- "$tmp_file"' ERR
    CONF_WRITE_FILE="$tmp_file"
    cat > "$tmp_file" << EOF
# ==========================================================
# Linux Network Tuning (Proxy/Forwarding Optimized)
# 生成时间: $(date)
# 硬件环境: ${TOTAL_MEM}MB RAM, ${CPU_CORES} CPU
# ==========================================================
EOF

    # 1. BBR 与 队列算法
    add_conf "net.core.default_qdisc" "fq" "FQ 队列算法"
    [[ "$BBR_AVAILABLE" = true ]] && add_conf "net.ipv4.tcp_congestion_control" "bbr" "开启 BBR"

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
    add_conf "net.core.netdev_max_backlog" "$NETDEV_BACKLOG" "网卡积压队列"
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

    # 6. 连接跟踪 (Conntrack，add_conf 会自动跳过不支持的键)
    add_conf "net.netfilter.nf_conntrack_max" "$CONNTRACK_MAX" "最大连接跟踪数"
    add_conf "net.netfilter.nf_conntrack_tcp_timeout_established" "7200" "连接跟踪超时 (2小时)"
    add_conf "net.netfilter.nf_conntrack_tcp_timeout_time_wait" "120" "减少 TIME_WAIT 跟踪时间"
    [[ -e /proc/sys/net/netfilter/nf_conntrack_max ]] || warning "当前内核不支持 conntrack，跳过相关参数。"

    # 7. 其他系统级优化
    add_conf "fs.file-max" "$FILE_MAX" "最大文件句柄"
    add_conf "vm.swappiness" "10" "减少 Swap 使用"
    add_conf "net.ipv4.tcp_mtu_probing" "1" "开启 MTU 探测 (解决部分网络卡顿)"
    add_conf "net.ipv4.tcp_syncookies" "1" "防 SYN Flood"
    CONF_WRITE_FILE=""
    mv -f "$tmp_file" "$CONF_FILE"
    trap - ERR
}

# --- 应用与验证 ---
apply_and_verify() {
    section "应用并验证"
    step 1 2 "正在加载 sysctl 配置..."
    local sysctl_rc=0
    sysctl --system >/dev/null 2>&1 || sysctl_rc=$?

    local cc qdisc reuse
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
    reuse=$(sysctl -n net.ipv4.tcp_tw_reuse 2>/dev/null || true)
    if [[ "$sysctl_rc" -ne 0 ]]; then
        warning "部分 sysctl 参数应用失败，请检查 ${CONF_FILE}。"
    else
        success "优化配置已应用。"
    fi
    printf '%b\n' "${BOLD}  当前生效参数${NC}"
    printf '%b\n' "  拥塞控制 : ${YELLOW}${cc:-未知}${NC}"
    printf '%b\n' "  队列算法 : ${YELLOW}${qdisc:-未知}${NC}"
    if [ "$reuse" = "1" ]; then
        printf '%b\n' "  TCP 复用  : ${GREEN}已启用${NC}"
    else
        printf '%b\n' "  TCP 复用  : ${RED}未启用${NC}"
    fi
    return "$sysctl_rc"
}

# --- 主逻辑 ---
usage() {
    local out=/dev/stdout
    [[ "${1:-0}" -eq 0 ]] || out=/dev/stderr
    cat > "$out" <<EOF
Linux Network Optimizer ${SCRIPT_VERSION}

用法：
  $0             应用网络优化
  $0 uninstall   删除本脚本配置并重新加载系统参数
  $0 restore     恢复最近一次备份
EOF
}

main() {
    if [[ $# -eq 1 && ("${1:-}" == "--help" || "${1:-}" == "-h") ]]; then usage; exit 0; fi
    if [[ $# -eq 1 && ("${1:-}" == "restore" || "${1:-}" == "uninstall") ]]; then
        require_root
        local backup
        backup=$(ls -t "${CONF_FILE}.bak_"* 2>/dev/null | head -n1 || true)
        if [[ "${1:-}" == "restore" && -n "$backup" ]]; then
            section "恢复备份"
            step 1 2 "正在恢复：$backup"
            if ! cp "$backup" "$CONF_FILE"; then
                error "备份恢复失败：$backup"
                exit 1
            fi
            step 2 2 "正在重新加载 sysctl..."
            if sysctl --system >/dev/null 2>&1; then
                success "已恢复配置文件并重新加载系统参数：$backup"
            else
                error "配置文件已恢复，但系统参数重新加载失败。"
                exit 1
            fi
            exit 0
        elif [[ "${1:-}" == "restore" ]]; then
            warning "未找到可恢复的备份。"
            exit 1
        fi
        section "卸载网络优化"
        warning "将删除优化配置并重新加载系统参数。"
        step 1 2 "正在删除：$CONF_FILE"
        rm -f "$CONF_FILE"
        step 2 2 "正在重新加载 sysctl..."
        if sysctl --system >/dev/null 2>&1; then
            success "网络优化配置已删除并重新加载系统参数。"
        else
            error "网络优化配置已删除，但系统参数重新加载失败。"
            exit 1
        fi
        exit 0
    fi
    if [[ $# -gt 0 ]]; then
        error "未知参数：$1"
        usage 1
        exit 2
    fi

    printf '%b\n' "${CYAN}${BOLD}==> Linux Network Optimizer ${SCRIPT_VERSION} (TCP / BBR / Proxy Edition)${NC}"
    pre_flight_checks
    get_system_info
    configure_swap
    migrate_legacy_config
    manage_backups
    apply_optimizations
    apply_and_verify
}

main "$@"
