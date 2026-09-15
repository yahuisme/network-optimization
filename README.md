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
- 默认执行不另行确认。Swap 目标：内存 ≤512 MiB 时为 512 MiB，≤1024 MiB 时为 1024 MiB，否则为 2048 MiB；现有总量一致则保留。
- 无 Swap 时自动创建；现有容量不匹配时统一替换为 `/swapfile`，包含停用分区 Swap。空间不足或目标是未启用的已有文件时跳过。
- Swap 替换失败时恢复旧文件、启动配置和活动状态；恢复失败会报告并保留恢复文件。
- 配置文件：`/etc/sysctl.d/99-network-optimization.conf`，保留最近 3 份唯一命名的备份。
- 检查 `/etc/sysctl.d`、`/run/sysctl.d`、`/usr/local/lib/sysctl.d`、`/usr/lib/sysctl.d`、`/lib/sysctl.d` 中所有 `*.conf` 及 `/etc/sysctl.conf`。仅注释本次实际生成参数的同名赋值（包括 `99-bbr.conf`），不比较原值，其他参数及注释保留；不同目录的同名文件也检查，软链接按真实路径去重并保留链接和权限。
- 修改前保存 `.network-backup.*` 原件；应用失败独立恢复文件及目标运行值，恢复失败保留证据。备份不自动轮换。通配符赋值原样保留，不展开、不接管，也不因此中止；不要并发修改配置。软件包升级或重启可能重建 vendor 或 `/run` 配置，届时需重新运行。
- `fs.file-max` 生成时保留现有更高运行上限，应用后验证不低于生成目标；其他参数仍须与目标一致。
- 应用后逐项验证实际参数；失败恢复原配置及目标参数的原运行值，不撤销已完成的 Swap 操作。
- `uninstall` 删除本脚本配置并重新加载剩余配置，**不恢复内核默认值**。
- `restore` 恢复最近一次配置备份；两者均不撤销 Swap 或其他配置中的同名参数接管（可从 `.network-backup.*` 手动恢复）。
- 使用 `--help` 查看帮助，请勿并发运行。
