# network-optimization

Linux TCP / BBR 网络优化脚本，自动根据内存配置参数。

## 使用

需要 root 权限。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yahuisme/network-optimization/main/script.sh)
```

删除本脚本配置：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yahuisme/network-optimization/main/script.sh) uninstall
```

恢复最近一次备份：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yahuisme/network-optimization/main/script.sh) restore
```

## 说明

- 支持 Debian 和 Ubuntu。
- 无已启用 Swap 且 `/swapfile` 不存在时，按内存自动创建 Swap；已有 Swap 不修改。
- 配置文件：`/etc/sysctl.d/99-network-optimization.conf`。
- 每次应用前自动备份配置，保留最近 3 份。
- 内核不支持 BBR 或 conntrack 时跳过对应参数。
- `uninstall` 只删除本脚本配置，不删除 Swap，也不保证恢复优化前的运行时参数。
