# network-optimization

Linux TCP / BBR 网络优化脚本，面向代理节点 VPS。

**版本：v26.08.29**

## 使用

应用优化：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yahuisme/network-optimization/main/script.sh)
```

删除本脚本的 sysctl 配置：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yahuisme/network-optimization/main/script.sh) uninstall
```

恢复最近一次配置备份：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yahuisme/network-optimization/main/script.sh) restore
```

## 说明

- 需要 root 权限。
- 按内存自动调整代理节点的 TCP、UDP、队列和连接跟踪参数。
- 无 Swap 时按内存自动创建；已有 Swap 与目标不一致时统一替换为 `/swapfile`。
- 配置文件：`/etc/sysctl.d/99-network-optimization.conf`。
- 每次应用前保留最近 3 份配置备份。
- `uninstall` 只删除本脚本的 sysctl 配置，不删除已创建的 Swap。
- `restore` 只恢复最近一次本脚本配置备份。
