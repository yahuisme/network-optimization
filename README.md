# bbr-optimization
一个精简的 Linux TCP/IP & BBR 参数智能优化脚本

## 功能特点
- BBR + TCP 智能调参一键脚本
- 自动识别 VPS 的核心和内存数，智能配置网络参数
- 支持Debian 和 Ubuntu
- 支持自动备份管理功能
- 支持一键撤销修改和恢复备份
- 无 Swap 时自动创建适量 Swap，已有 Swap 则保留

## 一键安装
```
bash <(curl -sL https://raw.githubusercontent.com/yahuisme/network-optimization/main/script.sh)
```

脚本需要 root 权限。没有 Swap 时会按内存自动创建 `/swapfile`：512MB 内存创建 512MB，1GB 创建 1GB，其他情况创建 2GB；已有 Swap 不会修改。脚本不会自动删除或调整已有 Swap。

撤销优化配置：

```bash
bash <(curl -sL https://raw.githubusercontent.com/yahuisme/network-optimization/main/script.sh) uninstall
```

恢复最近一次优化配置备份：

```bash
bash <(curl -sL https://raw.githubusercontent.com/yahuisme/network-optimization/main/script.sh) restore
```

脚本使用独立配置文件 `/etc/sysctl.d/99-network-optimization.conf`，不会覆盖其他 BBR 或 sysctl 配置。首次运行时如果发现旧版脚本的 `/etc/sysctl.d/99-bbr.conf`，会先备份后停用旧文件，避免两套配置互相覆盖。当前内核不支持 conntrack 时会自动跳过相关参数。
