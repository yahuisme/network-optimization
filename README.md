# VPS 网络优化

面向代理节点 VPS 的 TCP / BBR 优化脚本。版本：`v26.09.27`。

## 使用

需要 root，默认直接调整网络参数和 Swap。

```bash
curl -fsSLo network-optimization.sh https://raw.githubusercontent.com/yahuisme/network-optimization/main/script.sh
bash network-optimization.sh
```

```bash
bash network-optimization.sh restore    # 恢复最近一次本脚本配置备份
bash network-optimization.sh uninstall  # 删除本脚本配置
bash network-optimization.sh --help
```

## 行为

- 按内存生成内核支持的参数，统一写入 `/etc/sysctl.d/99-network-optimization.conf`；仅加载并逐项验证本脚本配置。
- 其他配置中的同名参数备份后注释，无关设置保留；`fs.file-max` 保留现有更高上限。
- Swap 目标与 VPS 初始化一致：内存 ≤512 MiB 为 512 MiB，≤1024 MiB 为 1024 MiB，其余为 2048 MiB。总量不符时停用全部现有 Swap，统一替换为 `/swapfile`；容量一致时保留并检查该文件的启动条目。
- 应用失败恢复本次配置及目标运行值；Swap 替换失败独立恢复。
- `restore` 仅恢复、加载本脚本备份；`uninstall` 仅删除本脚本配置，当前运行参数不变。两者不撤销 Swap 或同名参数接管，也不恢复内核默认值。外部配置原件保存在 `.network-backup.*`。

请勿并发运行；系统或其他工具重写配置后，可重新执行接管。
