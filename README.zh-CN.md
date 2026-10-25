# ProcessLens（进程监视器）

原生 macOS 进程监视与管理工具 —— 基于 SwiftUI 与 AppKit 打造的「活动监视器」式应用。

[![macOS](https://img.shields.io/badge/macOS-14.0%2B-000000?style=flat-square&logo=apple&logoColor=white)](https://github.com/cduyzh/ProcessLens/releases)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-F05138?style=flat-square&logo=swift&logoColor=white)](https://developer.apple.com/swift/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green?style=flat-square)](LICENSE)
[![Author](https://img.shields.io/badge/Author-cduyzh-blue?style=flat-square)](https://github.com/cduyzh)

[English](README.md) · **简体中文**

ProcessLens 展示 Mac 正在运行的工作：实时 CPU、内存、磁盘与网络数据，可搜索的进程列表，以及紧凑的详情面板。所有数字均来自对本机系统的真实采样，不做估算或模拟。完全原生实现，无任何第三方依赖。

## 功能

- **进程概览** —— CPU、内存、启动磁盘容量与物理网络接口吞吐，每项均配有由最近 40 次真实采样绘制的曲线。
- **进程列表** —— 按 CPU、内存、名称或 PID 排序；按应用/后台筛选；可搜索名称、PID、用户和可执行路径。
- **应用进程** —— 分组展示 `.app` 包内的进程（含 Helper），数量表示每个应用拥有的进程数。
- **持续关注** —— 按可执行路径持久化关注进程；关注列表在应用重启后依然保留，重新启动的程序也能再次找到。
- **进程详情** —— 用户、父进程、线程数、运行时长、状态与可执行文件，支持一键复制与访达定位。
- **监听端口** —— 按需读取 TCP LISTEN 与 UDP 绑定端点；支持搜索、排序、复制和跳转进程。
- **进程操作** —— 结束（SIGTERM）与强制退出（SIGKILL），均有二次确认；执行前核对 UID 与微秒级启动时间，并保护系统、自身、上级和其他用户进程。
- **CSV 导出** —— 导出当前筛选后的进程快照，采用 UTF-8 BOM，并防护电子表格公式注入。
- **菜单栏** —— 随时查看 CPU、内存与进程数量，悬停可展开深色统计面板，复用主窗口采样。
- **浏览器诊断** —— 通过可证的启动来源、进程树、隔离目录、脱敏参数与 RSS 估算，区分日常浏览器与自动化 Chromium、Electron 实例；按实例正常退出并回读结果，随后可选择对原快照中的幸存 renderer 强制退出。
- **开机启动项管理** —— 识别用户与管理员 LaunchAgent、LaunchDaemon 以及可见的登录和后台项目，展示启动条件与实际允许状态；符合条件的用户启动项可停用、备份和恢复，系统管理项直接跳转原生系统设置。
- **安装镜像清理** —— 查看已挂载的 DMG/ISO 镜像及其卷、挂载位置和来源文件；支持多选推出，仅在推出成功后才将安装包移入废纸篓；仍在使用中的安装包会被保留。
- **顶部监控面板** —— 状态栏等宽 CPU 数值，点击展开为实时资源面板。
- **设置** —— 1/2/5/10 秒采样间隔、系统/浅色/深色外观、菜单栏开关、快捷键说明，以及真实的运行版本与应用路径。
- **版本与历史** —— 应用内版本与更新历史，根 `Info.plist` 与 `Resources/ReleaseHistory.json` 自动校验一致。

## 下载与安装

从 [Releases 页面](https://github.com/cduyzh/ProcessLens/releases) 下载最新 DMG：

1. 下载最新版本的 `.dmg` 文件。
2. 打开镜像，将应用拖入「应用程序」文件夹。
3. 启动应用。首次运行时，macOS 可能会提示确认打开从互联网下载的应用。

## 从源码构建

需要 macOS 14 或更新版本，并安装 Xcode 或 Command Line Tools（Swift 5.9+）。

```bash
git clone https://github.com/cduyzh/ProcessLens.git
cd ProcessLens
./build_app.sh
```

脚本会编译 Release 产物并组装 `.app`，不会自动安装。本地安装与发行打包请参考仓库内脚本。

## 版本历史

- 当前版本：**0.3.0**（构建 3，2026-10-24）

完整历史请查看 [CHANGELOG.md](CHANGELOG.md)。

## 隐私

所有数据 —— 进程、端口、网络计数、挂载镜像与启动项 —— 均通过标准系统 API 在本地读取。不上传任何内容，也没有分析或遥测。CSV 导出仅在你明确请求时生成。任何数据都不会离开你的 Mac。

## 许可证

以 [MIT License](LICENSE) 发布。

## 作者

**cduyzh**

- GitHub：<https://github.com/cduyzh>
- 个人网站：<https://www.cduyzh.top>
- Goal：<https://www.cduyzh.top/goal>
