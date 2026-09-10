#!/usr/bin/env bash

# ==============================================================================
# Linux TCP/IP & BBR 智能优化脚本
#
# 版本: v26.09.10
# ==============================================================================

# --- 脚本版本号定义 ---
SCRIPT_VERSION="v26.09.10"

set -Eeuo pipefail

# --- 颜色定义 ---
GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
YELLOW=$'\033[1;33m'
BOLD=$'\033[1m'
NC=$'\033[0m'
BBR_AVAILABLE=false
CONF_WRITE_FILE=""

# --- 统一输出样式 ---

success() { printf '  %b✔%b %s\n' "$GREEN" "$NC" "$1"; }
warning() { printf '  %b⚠%b %s\n' "$YELLOW" "$NC" "$1" >&2; }
error() { printf '  %b✗%b %s\n' "$RED" "$NC" "$1" >&2; }

section() {
    printf '\n%b%s%b\n' "$BOLD" "$1" "$NC"
}
step() { printf '  ▸ %s/%s %s\n' "$1" "$2" "$3"; }


# --- 配置文件路径 ---
CONF_FILE="/etc/sysctl.d/99-network-optimization.conf"
LEGACY_CONF_FILE="/etc/sysctl.d/99-bbr.conf"
SWAP_FILE="/swapfile"

# --- 系统信息检测函数 ---
get_system_info() {
    TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
    CPU_CORES=$(nproc)
    
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        VIRT_TYPE=$(systemd-detect-virt) || VIRT_TYPE=${VIRT_TYPE:-unknown}
    elif grep -q -i "hypervisor" /proc/cpuinfo; then
        VIRT_TYPE="KVM/VMware"
    else
        VIRT_TYPE="Physical/Unknown"
    fi

    section "系统信息检测"
    printf '%b\n' "  内存大小：${TOTAL_MEM}MB"
    printf '%b\n' "  CPU 核心数：${CPU_CORES}"
    printf '%b\n' "  虚拟化类型：${VIRT_TYPE}"
    calculate_parameters
    printf '%b\n' "  优化档位：${VM_TIER}"
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
        printf '# %s\n' "$comment" || return 1
        printf '%s = %s\n\n' "$key" "$value"
    } >> "$target"
}

# --- 备份管理 ---
manage_backups() {
    if [[ -f "$CONF_FILE" ]]; then
        local backup
        backup=$(mktemp "${CONF_FILE}.bak_XXXXXX") || return 1
        cp -- "$CONF_FILE" "$backup" || { rm -f -- "$backup"; return 1; }
        # NUL-delimited names tolerate whitespace; keep the newest three.
        find "$(dirname "$CONF_FILE")" -maxdepth 1 -type f \
            -name "$(basename "$CONF_FILE").bak_*" -printf '%T@ %p\0' \
            | sort -z -nr | tail -z -n +4 | cut -z -d' ' -f2- | xargs -0 -r rm -f -- || return 1
    fi
}

migrate_legacy_config() {
    if [[ -f "$LEGACY_CONF_FILE" ]]; then
        LEGACY_BACKUP=$(mktemp "${LEGACY_CONF_FILE}.migrated_XXXXXX") || return 1
        cp -p -- "$LEGACY_CONF_FILE" "$LEGACY_BACKUP" || return 1
        rm -f -- "$LEGACY_CONF_FILE" || return 1
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
    local current_total_mb=0 size_bytes swap_line swap_sizes
    swap_sizes=$(swapon --show=NAME,SIZE --bytes --noheadings) || return 1
    while IFS= read -r swap_line; do
        [[ -n "$swap_line" ]] || continue
        size_bytes=$(awk '{print $2}' <<< "$swap_line")
        [[ "$size_bytes" =~ ^[0-9]+$ ]] && current_total_mb=$((current_total_mb + (size_bytes + 524288) / 1048576))
    done <<< "$swap_sizes"

    if [[ "$current_total_mb" -eq "$swap_mb" ]]; then
        success "现有 Swap 与目标一致（${current_total_mb}MB），保留。"
        return
    fi
    if [[ "$current_total_mb" -gt 0 ]]; then
        warning "现有 Swap ${current_total_mb}MB 与目标 ${swap_mb}MB 不一致，将统一替换为 /swapfile。"
    else
        printf '  未检测到 Swap，将创建 %sMiB。\n' "$swap_mb"
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
    local new_swap
    new_swap=$(mktemp "${SWAP_FILE}.new.XXXXXX") || return 1
    # fallocate 失败（如文件系统不支持）时回退 dd
    if ! { command -v fallocate &>/dev/null && fallocate -l "${swap_mb}M" "$new_swap" 2>/dev/null; } && \
       ! dd if=/dev/zero of="$new_swap" bs=1M count="$swap_mb" status=none 2>/dev/null; then
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
    local old_swap="" fstab_copy active_list active_swap failed=0 installed=false
    local -a stopped=()
    fstab_copy=$(mktemp /etc/fstab.network.XXXXXX) || { rm -f -- "$new_swap"; return 1; }
    if ! cp -p /etc/fstab "$fstab_copy"; then
        rm -f -- "$new_swap" "$fstab_copy"
        return 1
    fi
    if ! active_list=$(swapon --show=NAME --noheadings); then
        rm -f -- "$new_swap" "$fstab_copy"
        return 1
    fi
    while IFS= read -r active_swap; do
        [[ -n "$active_swap" ]] || continue
        if swapoff "$active_swap"; then
            stopped+=("$active_swap")
        else
            failed=1
            break
        fi
    done <<< "$active_list"
    if [[ "$failed" -eq 0 && -e "$SWAP_FILE" ]]; then
        old_swap=$(mktemp "${SWAP_FILE}.old.XXXXXX") || failed=1
        if [[ "$failed" -eq 0 ]] && ! mv -f -- "$SWAP_FILE" "$old_swap"; then
            rm -f -- "$old_swap"
            old_swap=""
            failed=1
        fi
    fi
    if [[ "$failed" -eq 0 ]]; then
        if mv -f -- "$new_swap" "$SWAP_FILE"; then installed=true; else failed=1; fi
    fi
    if [[ "$failed" -eq 0 ]] && ! swapon "$SWAP_FILE"; then failed=1; fi
    if [[ "$failed" -eq 0 ]]; then
        if ! sed -E '\|^[[:space:]]*[^#[:space:]][^[:space:]]*[[:space:]]+[^[:space:]]+[[:space:]]+swap([[:space:]]\|$)|d' "$fstab_copy" > /etc/fstab ||
           ! printf '%s\n' "$SWAP_FILE none swap sw 0 0" >> /etc/fstab; then failed=1; fi
    fi
    if [[ "$failed" -ne 0 ]]; then
        # Never unlink a file that may still be active; recover independent items.
        local now_active swap_path_safe=true recovery_failed=false
        if [[ "$installed" = true ]]; then
            if ! now_active=$(swapon --show=NAME --noheadings); then
                error "无法确认 Swap 状态；保留恢复文件：$old_swap $fstab_copy"
                swap_path_safe=false
            elif grep -Fxq "$SWAP_FILE" <<< "$now_active" && ! swapoff "$SWAP_FILE"; then
                error "无法关闭新 Swap；保留恢复文件：$old_swap $fstab_copy"
                swap_path_safe=false
            fi
            if [[ "$swap_path_safe" = true ]] && ! rm -f -- "$SWAP_FILE"; then
                swap_path_safe=false
            fi
        fi
        if [[ "$swap_path_safe" = true && -n "$old_swap" ]] && ! mv -f -- "$old_swap" "$SWAP_FILE"; then
            error "旧 Swap 文件恢复失败，保留：$old_swap $fstab_copy"
            swap_path_safe=false
        fi
        [[ "$swap_path_safe" = true ]] || recovery_failed=true
        if ! cp -p "$fstab_copy" /etc/fstab; then
            error "fstab 恢复失败，保留：$fstab_copy"
            recovery_failed=true
        fi
        for active_swap in "${stopped[@]}"; do
            if [[ "$active_swap" = "$SWAP_FILE" && "$swap_path_safe" = false ]]; then continue; fi
            if ! swapon "$active_swap"; then
                warning "无法重新启用旧 Swap：$active_swap"
                recovery_failed=true
            fi
        done
        rm -f -- "$new_swap"
        if [[ "$recovery_failed" = false ]]; then rm -f -- "$fstab_copy"; fi
        error "Swap 替换失败，已尝试恢复旧文件、fstab 和活动状态。"
        return 1
    fi
    rm -f -- "$fstab_copy" "$new_swap" || return 1
    if [[ -n "$old_swap" ]]; then rm -f -- "$old_swap" || return 1; fi
    success "Swap 已启用：${swap_mb}MiB"
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
    printf '  %s：%s\n' "BBR/FQ" "$bbr_status"
    printf '  %s：%s\n' "缓冲区上限" "$((RMEM_MAX / 1048576)) MiB"
    printf '  %s：%s\n' "连接队列" "$SOMAXCONN"
    printf '  %s：%s\n' "网卡积压" "$NETDEV_BACKLOG"
    printf '  %s：%s\n' "文件句柄" "$FILE_MAX"
    printf '  %s：%s\n' "Conntrack" "$conntrack_status"
    printf '  %s：%s\n' "Swap" "$swap_status"
}

apply_optimizations() {
    section "应用网络优化配置：${VM_TIER}"
    # The caller owns the staging file and its cleanup.
    if ! cat > "$CONF_WRITE_FILE" << EOF

# ==========================================================
# Linux Network Tuning (Proxy/Forwarding Optimized)
# 生成时间: $(date)
# 硬件环境: ${TOTAL_MEM}MB RAM, ${CPU_CORES} CPU
# ==========================================================
EOF
    then return 1; fi

    # 1. BBR 与 队列算法
    add_conf "net.core.default_qdisc" "fq" "FQ 队列算法" || return 1
    if [[ "$BBR_AVAILABLE" = true ]]; then
        add_conf "net.ipv4.tcp_congestion_control" "bbr" "开启 BBR" || return 1
    fi

    # 2. 缓冲区优化 (TCP & UDP) - 这对 Hysteria/QUIC 很重要
    add_conf "net.core.rmem_max" "$RMEM_MAX" "系统最大接收缓存" || return 1
    add_conf "net.core.wmem_max" "$WMEM_MAX" "系统最大发送缓存" || return 1
    add_conf "net.core.rmem_default" "262144" "默认接收缓存 (256k)" || return 1
    add_conf "net.core.wmem_default" "262144" "默认发送缓存 (256k)" || return 1
    # TCP 自动调优窗口
    add_conf "net.ipv4.tcp_rmem" "8192 262144 $TCP_MEM_MAX" "TCP读缓存 (min default max)" || return 1
    add_conf "net.ipv4.tcp_wmem" "8192 262144 $TCP_MEM_MAX" "TCP写缓存 (min default max)" || return 1
    add_conf "net.ipv4.udp_rmem_min" "16384" "UDP读缓存下限 (优化QUIC)" || return 1
    add_conf "net.ipv4.udp_wmem_min" "16384" "UDP写缓存下限 (优化QUIC)" || return 1

    # 3. 连接与队列上限
    add_conf "net.core.somaxconn" "$SOMAXCONN" "最大监听队列" || return 1
    add_conf "net.core.netdev_max_backlog" "$NETDEV_BACKLOG" "网卡积压队列" || return 1
    add_conf "net.ipv4.tcp_max_syn_backlog" "$SOMAXCONN" "SYN半连接队列" || return 1
    add_conf "net.ipv4.tcp_notsent_lowat" "16384" "降低缓冲区未发送数据阈值 (降低延迟)" || return 1

    # 4. TIME_WAIT 与 端口复用 (代理服务器的关键)
    add_conf "net.ipv4.tcp_tw_reuse" "1" "开启 TIME_WAIT 复用 (关键优化)" || return 1
    add_conf "net.ipv4.tcp_timestamps" "1" "开启时间戳 (配合 reuse 必须)" || return 1
    add_conf "net.ipv4.tcp_fin_timeout" "30" "缩短 FIN_WAIT 时间" || return 1
    add_conf "net.ipv4.ip_local_port_range" "10000 65535" "扩大本地端口范围" || return 1
    add_conf "net.ipv4.tcp_max_tw_buckets" "500000" "允许更多 TIME_WAIT socket 存在" || return 1

    # 5. TCP Keepalive (快速剔除死链)
    add_conf "net.ipv4.tcp_keepalive_time" "600" "TCP保活时间 (10分钟)" || return 1
    add_conf "net.ipv4.tcp_keepalive_intvl" "15" "探测间隔" || return 1
    add_conf "net.ipv4.tcp_keepalive_probes" "5" "探测次数" || return 1

    # 6. 连接跟踪 (Conntrack，add_conf 会自动跳过不支持的键)
    add_conf "net.netfilter.nf_conntrack_max" "$CONNTRACK_MAX" "最大连接跟踪数" || return 1
    add_conf "net.netfilter.nf_conntrack_tcp_timeout_established" "7200" "连接跟踪超时 (2小时)" || return 1
    add_conf "net.netfilter.nf_conntrack_tcp_timeout_time_wait" "120" "减少 TIME_WAIT 跟踪时间" || return 1
    [[ -e /proc/sys/net/netfilter/nf_conntrack_max ]] || warning "当前内核不支持 conntrack，跳过相关参数。"

    # 7. 其他系统级优化
    add_conf "fs.file-max" "$FILE_MAX" "最大文件句柄" || return 1
    add_conf "vm.swappiness" "10" "减少 Swap 使用" || return 1
    add_conf "net.ipv4.tcp_mtu_probing" "1" "开启 MTU 探测 (解决部分网络卡顿)" || return 1
    add_conf "net.ipv4.tcp_syncookies" "1" "防 SYN Flood" || return 1
    return 0
}

# --- 应用与验证 ---
config_targets() {
    awk -F= '/^[[:space:]]*[^#[:space:]][^=]*=/ {
        key=$1; gsub(/[[:space:]]/, "", key)
        value=substr($0,index($0,"=")+1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        print key "=" value
    }' "$1"
}

normalize_value() { awk '{$1=$1; print}'; }

apply_and_verify() {
    section "应用并验证"
    step 1 2 "正在加载 sysctl 配置..."
    local rc=0 key target actual targets
    if ! targets=$(config_targets "$CONF_FILE") || [[ -z "$targets" ]]; then
        error "配置目标解析失败或为空，未加载 sysctl 配置。"
        return 1
    fi
    sysctl --system >/dev/null 2>&1 || rc=$?
    step 2 2 "正在逐项读回生成的配置..."
    while IFS='=' read -r key target; do
        if ! actual=$(sysctl -n "$key" 2>/dev/null) ||
           [[ $(normalize_value <<< "$actual") != "$(normalize_value <<< "$target")" ]]; then
            warning "参数未达到目标：$key（目标：$target；实际：${actual:-无法读取}）"
            [[ "$rc" -ne 0 ]] || rc=1
        fi
    done <<< "$targets"
    if [[ "$rc" -eq 0 ]]; then success "生成的配置已逐项验证生效。"; fi
    return "$rc"
}

configure_network() {
    local staged previous="" snapshot key target actual targets rc=0 installed=false
    local config_restore_failed=false
    local LEGACY_BACKUP=""
    staged=$(mktemp "${CONF_FILE}.tmp.XXXXXX") || return 1
    CONF_WRITE_FILE="$staged"
    if ! apply_optimizations; then
        CONF_WRITE_FILE=""
        rm -f -- "$staged"
        error "配置生成失败，原配置未停用。"
        return 1
    fi
    CONF_WRITE_FILE=""
    if ! targets=$(config_targets "$staged") || [[ -z "$targets" ]]; then
        rm -f -- "$staged"
        error "配置目标解析失败或为空，原配置未停用。"
        return 1
    fi
    snapshot=$(mktemp "${CONF_FILE}.runtime.XXXXXX") || { rm -f -- "$staged"; return 1; }
    while IFS='=' read -r key target; do
        if ! actual=$(sysctl -n "$key") || ! printf '%s=%s\n' "$key" "$actual" >> "$snapshot"; then rc=1; break; fi
    done <<< "$targets"
    if [[ "$rc" -eq 0 && -f "$CONF_FILE" ]]; then
        previous=$(mktemp "${CONF_FILE}.previous.XXXXXX") || rc=1
        if [[ "$rc" -eq 0 ]] && ! cp -p -- "$CONF_FILE" "$previous"; then rc=1; fi
    fi
    if [[ "$rc" -eq 0 ]] && ! manage_backups; then rc=1; fi
    if [[ "$rc" -ne 0 ]]; then
        rm -f -- "$staged" "$snapshot"
        [[ -z "$previous" ]] || rm -f -- "$previous"
        return 1
    fi
    if mv -f -- "$staged" "$CONF_FILE"; then installed=true; else rc=1; fi
    if [[ "$rc" -eq 0 ]] && ! migrate_legacy_config; then rc=1; fi
    if [[ "$rc" -eq 0 ]]; then apply_and_verify || rc=$?; fi
    if [[ "$rc" -ne 0 ]]; then
        if [[ "$installed" = true ]]; then
            if [[ -n "$previous" ]]; then
                if ! cp -p -- "$previous" "$CONF_FILE"; then
                    config_restore_failed=true
                    error "配置恢复失败，保留：$previous"
                fi
            else
                if ! rm -f -- "$CONF_FILE"; then
                    config_restore_failed=true
                    error "无法撤销新配置"
                fi
            fi
        fi
        if [[ -n "$LEGACY_BACKUP" && ! -e "$LEGACY_CONF_FILE" ]]; then
            cp -p -- "$LEGACY_BACKUP" "$LEGACY_CONF_FILE" || warning "旧配置恢复失败，保留：$LEGACY_BACKUP"
        fi
        local restore_failed=false
        while IFS='=' read -r key target; do
            actual=$(sysctl -n "$key" 2>/dev/null) || actual=""
            if [[ $(normalize_value <<< "$actual") != "$(normalize_value <<< "$target")" ]]; then
                if ! sysctl -w "$key=$target" >/dev/null ||
                   ! actual=$(sysctl -n "$key") ||
                   [[ $(normalize_value <<< "$actual") != "$(normalize_value <<< "$target")" ]]; then
                    warning "运行值恢复失败：$key"
                    restore_failed=true
                fi
            fi
        done < "$snapshot"
        if [[ "$restore_failed" = true ]]; then warning "保留运行值快照：$snapshot"; else rm -f -- "$snapshot"; fi
        error "应用失败，已尝试恢复本脚本配置及目标运行值；不是全系统回滚，Swap 不受此恢复影响。"
    else
        rm -f -- "$snapshot" || return 1
    fi
    rm -f -- "$staged"
    if [[ -n "$previous" && "$config_restore_failed" = false ]]; then rm -f -- "$previous"; fi
    return "$rc"
}

# --- 主逻辑 ---
usage() {
    local out=/dev/stdout
    [[ "${1:-0}" -eq 0 ]] || out=/dev/stderr
    cat > "$out" <<EOF
VPS 网络优化 ${SCRIPT_VERSION}

用法：
  $0             应用网络优化并按内存调整 Swap（需要 root）
  $0 uninstall   删除本脚本配置并重新加载；不恢复内核默认值
  $0 restore     恢复最近一次本脚本配置备份并重新加载
  $0 --help      显示帮助（无需 root）

restore/uninstall 需要 root；不撤销 Swap 或旧配置迁移。
EOF
}

main() {
    case "${1:-}" in
        -h|--help)
            if [[ $# -ne 1 ]]; then
                error "选项 $1 不接受多余参数"
                usage 1
                exit 2
            fi
            usage 0
            exit 0
            ;;
        restore|uninstall)
            if [[ $# -ne 1 ]]; then
                error "选项 $1 不接受多余参数"
                usage 1
                exit 2
            fi
            require_root
            local backup
            backup=$(find "$(dirname "$CONF_FILE")" -maxdepth 1 -type f \
                -name "$(basename "$CONF_FILE").bak_*" -printf '%T@ %p\n' 2>/dev/null \
                | sort -nr | awk 'NR == 1 {sub(/^[^ ]+ /, ""); print}')
            if [[ "$1" == "restore" && -n "$backup" ]]; then
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
            elif [[ "$1" == "restore" ]]; then
                warning "未找到可恢复的备份。"
                exit 1
            fi
            section "卸载网络优化"
            warning "将删除优化配置并重新加载；不会恢复内核默认值或撤销 Swap。"
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
            ;;
        "")
            if [[ $# -ne 0 ]]; then
                error "不接受空参数或多余参数"
                usage 1
                exit 2
            fi
            ;;
        *)
            error "未知参数：$1"
            usage 1
            exit 2
            ;;
    esac

    printf '%b\n' "${BOLD}VPS 网络优化 ${SCRIPT_VERSION}${NC}"
    pre_flight_checks
    get_system_info
    show_optimization_plan
    configure_swap
    configure_network
}

main "$@"
