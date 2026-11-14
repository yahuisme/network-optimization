# VPS 网络优化

面向代理节点 VPS，按内存配置 TCP / BBR 参数和 Swap。

## 使用

需要 **root** 和 `curl`。运行后直接应用，不另行确认。

```bash
curl -fsSLo network-optimization.sh https://raw.githubusercontent.com/yahuisme/network-optimization/main/script.sh && bash network-optimization.sh
```

**Swap**：内存 ≤512 MiB 配 512 MiB，≤1024 MiB 配 1024 MiB，其余配 2048 MiB。现有总量一致则保留，否则停用全部现有 Swap（含分区）并替换为 `/swapfile`。

## 恢复与卸载

完成上方下载后，可执行：

```bash
bash network-optimization.sh restore    # 恢复并加载最近一次本脚本配置备份
bash network-optimization.sh uninstall  # 仅删除本脚本配置，当前运行参数不变
bash network-optimization.sh --help     # 查看帮助
```

`restore` 和 `uninstall` 均不撤销 Swap 或其他配置中的同名参数接管，也不恢复内核默认值。

## 配置说明

- 配置写入 `/etc/sysctl.d/99-network-optimization.conf`，仅加载并逐项验证本脚本配置；内核不支持的参数跳过，`fs.file-max` 保留现有更高上限。
- 其他配置中的同名参数先备份再注释，无关设置保留；原件保存在对应文件的 `.network-backup.*` 中。
- 应用、`restore` 或 Swap 替换的变更阶段失败/收到 TERM、INT 时，分别尝试局部恢复；保留原活动 Swap 的优先级及 fstab discard 选项，恢复不完整会保留证据并报错。不是全系统回滚，不保证 SIGKILL、掉电或提交后的清理中断恢复。
- `restore` 仅支持本脚本生成且未经手改的备份，不重新接管其他配置；leading `-` 等扩展语法不在支持范围。
- Conntrack 重启持久化依赖发行版在 sysctl 加载前启用模块；本脚本不新增模块启动配置或服务，请在重启后核对相关值。
- 请勿并发运行；系统或其他工具重写配置后可重新执行。
