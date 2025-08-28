# bbr-optimization
一个精简版 Linux TCP/IP &amp; BBR 参数智能优化脚本

## 脚本详情
BBR + TCP 智能调参一键脚本，自动识别 VPS 的核心和内存数，智能配置网络参数。支持Debian 和 Ubuntu。
此脚本不仅实现了核心参数的精简优化与硬件的动态适配，还具备自动备份管理功能，每次运行会创建新备份并自动清理更早的备份，确保配置目录的整洁。

## 一键安装
```
bash <(curl -sL https://raw.githubusercontent.com/yahuisme/network-optimization/main/script.sh)
```
