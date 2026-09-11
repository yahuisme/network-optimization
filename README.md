# VPS 网络优化

Linux TCP / BBR 网络优化脚本，面向代理节点 VPS。

版本：`v26.09.11`

## 使用

应用优化（需要 root，会调整 sysctl 和 Swap）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yahuisme/network-optimization/main/script.sh)
```

删除本脚本的 sysctl 配置并重新加载系统配置：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yahuisme/network-optimization/main/script.sh) uninstall
```

恢复最近一次本脚本配置备份并重新加载：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yahuisme/network-optimization/main/script.sh) restore
```

## 说明

- 需要 root，按内存调整 TCP、UDP、队列和连接跟踪参数，仅写入内核支持的键。
- 无 Swap 时自动创建；现有容量不匹配时统一替换为 `/swapfile`，包含停用分区 Swap。空间不足或目标是未启用的已有文件时跳过。
- Swap 替换失败时恢复旧文件、启动配置和活动状态；恢复失败会报告并保留恢复文件。
- 配置文件：`/etc/sysctl.d/99-network-optimization.conf`，保留最近 3 份唯一命名的备份。
- 新配置准备完成后迁移 `99-bbr.conf`，旧文件保存为 `.migrated_` 备份。
- 应用后逐项验证实际参数；失败恢复原配置及目标参数的原运行值，不撤销已完成的 Swap 操作。
- `uninstall` 删除本脚本配置并重新加载剩余配置，**不恢复内核默认值**。
- `restore` 恢复最近一次配置备份；两者均不撤销 Swap 或旧配置迁移。
- 使用 `--help` 查看帮助，请勿并发运行。
