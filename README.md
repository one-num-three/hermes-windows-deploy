# Hermes Windows Deploy

这个项目的目标很明确：帮助 Windows 用户一键安装好 Hermes，并把 Web UI 配好，让用户最终能直接打开 `http://localhost:8648` 使用。

当前策略：

- 最终正式入口会是 GUI 安装器
- 但当前优先把 CLI 一键安装链路跑通
- 当前只保 Windows 10 / Windows 11 的标准 WSL 安装路线
- 下载策略采用 CDN 优先，官方源回退

推荐先看这份最新说明：

- [docs/project-guide-zh.md](C:/Users/Keke_/Documents/Codex/2026-05-04/https-github-com-one-num-three/docs/project-guide-zh.md)

## 当前核心目标

我们现在要做的事情，本质上就是这三步：

1. 检查用户环境是否满足安装条件。
2. 自动安装并配置 Hermes 运行环境。
3. 自动安装并配置 Web UI，确保用户能打开 `localhost:8648`。

## 当前安装入口

管理员 PowerShell：

```powershell
cd C:\Users\Keke_\Documents\Codex\2026-05-04\https-github-com-one-num-three
.\scripts\install-hermes.ps1
```

安装成功后访问：

- [http://localhost:8648](http://localhost:8648)

## 当前关键实现

- 安装脚本：[scripts/install-hermes.ps1](C:/Users/Keke_/Documents/Codex/2026-05-04/https-github-com-one-num-three/scripts/install-hermes.ps1)
- 启动脚本：[scripts/hermes-start.sh](C:/Users/Keke_/Documents/Codex/2026-05-04/https-github-com-one-num-three/scripts/hermes-start.sh)
- systemd 配置：[scripts/setup-systemd.sh](C:/Users/Keke_/Documents/Codex/2026-05-04/https-github-com-one-num-three/scripts/setup-systemd.sh)

## CDN 现状

当前 CDN 基址：

- `http://121.40.165.216/hermes-cdn/files/`

当前安装脚本已接入：

- `hermes-agent.tar.gz`
- `hermes-web-ui.tgz`

当前仍建议补齐：

- Node 23/24 对应的安装资源
- `files.sha256` 校验接入

## 当前约束

- 先不追旧版 WSL / Windows Server 兼容
- 先不切 HTTPS，暂时继续用 HTTP CDN
- GUI 是后续正式入口，但当前不阻塞 CLI 主链路
