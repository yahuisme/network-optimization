# network-optimization

Linux TCP / BBR 网络优化脚本，适用于代理、转发等高并发场景。

## 使用

需要 root 权限。

应用优化：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yahuisme/network-optimization/main/script.sh)
```

删除配置：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yahuisme/network-optimization/main/script.sh) uninstall
```

恢复最近一次备份：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yahuisme/network-optimization/main/script.sh) restore
```

## 说明

- 根据系统内存自动配置参数。
- 无 Swap 时按内存自动创建，已有 Swap 不修改。
- 配置文件：`/etc/sysctl.d/99-network-optimization.conf`。
- 每次应用前自动备份，保留最近 3 份。
