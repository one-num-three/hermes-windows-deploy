# 最新项目指导

## 项目目标

这个项目不是为了做一个复杂的 Windows 工具集合，而是为了完成一件具体的事：

帮助用户在 Windows 上一键安装好 Hermes，并自动把 Web UI 配好。

最终用户视角的成功标准只有一个：

- 安装完成后，能直接打开 [http://localhost:8648](http://localhost:8648)

## 当前产品策略

- 正式入口目标：GUI 安装器
- 当前第一优先级：先把 CLI 一键安装链路跑通
- 支持范围：Windows 10 / Windows 11
- WSL 路线：只保标准安装路线
- CDN 协议：当前先使用 HTTP

这意味着我们现在不要继续分散精力做旧版 WSL、Windows Server、复杂离线导入兼容，而是先把主链路打磨稳定。

## 当前安装链路应该负责什么

当前一键安装链路应该完成 3 件事：

1. 检查环境。
2. 安装环境。
3. 配好 Web UI。

展开来说，就是：

1. 检查用户是否具备管理员权限、WSL 能力、Windows 版本和基础网络条件。
2. 自动准备 WSL、Ubuntu、Python、Node、Hermes Agent。
3. 自动安装 `hermes-web-ui`，注册启动方式，并把 `localhost:8648` 跑起来。

## 当前真实架构

### Windows 侧

- 安装入口：[scripts/install-hermes.ps1](C:/Users/Keke_/Documents/Codex/2026-05-04/https-github-com-one-num-three/scripts/install-hermes.ps1)
- 开机自启：Windows Task Scheduler
- 默认访问地址：`http://localhost:8648`
- 安装日志：`C:\Users\<用户名>\hermes-install.log`

### WSL 侧

- 数据目录：`/root/.hermes`
- Hermes 源码目录：`/opt/hermes/hermes-agent`
- Web UI 源码目录：`/opt/hermes/hermes-web-ui`
- 启动脚本：`/usr/local/bin/hermes-start`

### Web UI 侧

当前使用的 UI 项目是：

- [EKKOLearnAI/hermes-web-ui](https://github.com/EKKOLearnAI/hermes-web-ui)

已确认的关键事实：

- 正确启动命令是 `hermes-web-ui start`
- 当前版本要求 Node `>=23`
- 默认 Web UI 端口为 `8648`

## CDN 方案

当前 CDN：

- `http://121.40.165.216/hermes-cdn/files/`

你已经确认可用的资源包括：

- `hermes-agent.tar.gz`
- `hermes-web-ui.tgz`
- `wsl.2.6.3.0.x64.msi`
- `wsl_update_x64.msi`
- `ubuntu-noble-wsl-amd64.wsl`
- `files.sha256`
- `HermesAgent-Offline-v0.2.0.zip`

当前脚本已经接入或应接入的方向：

- Hermes 主程序：CDN 优先，GitHub 回退
- Web UI：CDN 优先，GitHub 回退

当前还缺一个关键点：

- Node 23/24 安装资源最好也进入 CDN

因为 `hermes-web-ui` 当前要求 Node `>=23`，而之前的 `setup-node22.x` 已经不匹配现在的 UI 版本了。

## 当前脚本应该如何定义成功

成功不应再只是“脚本执行完了”，而应该同时满足：

1. Hermes 安装完成。
2. Web UI 安装完成。
3. 启动脚本已注册。
4. `http://localhost:8648` 可访问。

## 当前项目最重要的文件

### 当前主线文件

- [scripts/install-hermes.ps1](C:/Users/Keke_/Documents/Codex/2026-05-04/https-github-com-one-num-three/scripts/install-hermes.ps1)
- [scripts/hermes-start.sh](C:/Users/Keke_/Documents/Codex/2026-05-04/https-github-com-one-num-three/scripts/hermes-start.sh)
- [scripts/setup-systemd.sh](C:/Users/Keke_/Documents/Codex/2026-05-04/https-github-com-one-num-three/scripts/setup-systemd.sh)

### 暂时属于次级目标

- `gui/` 下的 GUI 安装器
- `desktop/` 下的聊天面板、审批面板、右键菜单增强
- `build.ps1`、`post-install.ps1`、`uninstall.ps1` 的历史逻辑

这些部分不是不重要，而是当前不应该抢占 CLI 主链路的修复优先级。

## 当前我对项目的建议

### P0

先把 CLI 一键安装做成真正稳定的主路径：

- 环境检查明确
- 日志明确
- CDN 优先明确
- Web UI 启动明确
- `localhost:8648` 健康检查明确

### P1

再让 GUI 成为这个 CLI 链路的壳，而不是重新实现一套不同的安装逻辑。

也就是说，GUI 最好只是调用已经跑通的 CLI 主链路，而不是和它分叉。

### P2

最后再回头清理扩展模块：

- `desktop/`
- 打包脚本
- 离线包说明
- 发布说明

## 当前文档策略

当前文档应该尽量只做三件事：

1. 告诉开发者项目到底要解决什么问题。
2. 告诉维护者当前真实链路是什么。
3. 告诉发布者 CDN 和安装链路如何配合。

不要再让 README 同时承担“宣传页、设计稿、完整测试报告、未来规划、历史记录”这些角色。

## 推荐的下一步

现在最合理的下一步是：

1. 继续把 `install-hermes.ps1` 收紧成稳定的 CDN 优先安装器。
2. 统一并修复 `build.ps1`、`post-install.ps1`、`uninstall.ps1` 的编码和过时逻辑。
3. 再补一份发布者文档，专门说明如何更新 CDN、如何出包、如何做回归测试。
