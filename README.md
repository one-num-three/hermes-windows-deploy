# Hermes Agent Windows 一键部署

让任何 Windows 用户 **15 分钟内** 完成 Hermes Agent 的完整部署，无需接触命令行。

## 快速开始

```powershell
# 以管理员身份运行 PowerShell，执行：
.\scripts\install-hermes.ps1
```

## 做了什么

| 步骤 | 内容 |
|------|------|
| WSL2 | 自动安装/检测 Windows Subsystem for Linux 2 |
| Ubuntu 24.04 | 在 WSL2 中安装 Ubuntu |
| 镜像加速 | 自动配置清华/淘宝镜像源（国内网络优化） |
| Hermes Agent | 安装 Hermes AI Agent 框架 |
| Web UI | 安装 hermes-web-ui 管理面板 |
| 开机自启 | 配置 systemd + Task Scheduler 自动启动 |
| 浏览器 | 安装完成后自动打开 http://localhost:8648 |

## 项目结构

```
hermes-windows-deploy/
├── README.md
├── 实现计划书.md                         # 完整开发计划（8章）
│
├── scripts/                             # Phase 1: 命令行安装
│   ├── install-hermes.ps1              # ★ 主安装脚本（23KB, 7步）
│   ├── wsl-bootstrap.sh                # WSL 用户/环境初始化
│   ├── setup-mirrors.sh                # apt/pip/npm 镜像源切换
│   ├── setup-systemd.sh                # systemd 服务 + 自启
│   ├── post-install.ps1                # 桌面快捷方式 + 防火墙
│   ├── uninstall.ps1                   # 完整卸载
│   └── utils/
│       └── test-env.ps1                # 12项环境检测
│
├── gui/                                 # Phase 2: GUI 安装向导
│   └── HermesInstaller/
│       ├── HermesInstaller.csproj      # .NET 8 WPF 项目
│       ├── App.xaml / App.xaml.cs      # 应用入口 + 全局样式
│       ├── MainWindow.xaml/.cs         # 主窗口（4步向导）
│       ├── InstallContext.cs           # 安装上下文状态
│       ├── Steps/
│       │   ├── WelcomeStep.xaml/.cs    # 欢迎页
│       │   ├── CheckStep.xaml/.cs      # 环境检测页
│       │   ├── InstallStep.xaml/.cs    # 安装进度页
│       │   └── FinishStep.xaml/.cs     # 完成页
│       └── Services/
│           └── PowerShellRunner.cs     # PowerShell 执行服务
│
├── installer/                           # Phase 2: 打包
│   └── hermes-installer.iss           # Inno Setup 打包脚本
│
├── desktop/                             # Phase 3: 桌面增强功能
│   ├── chat/
│   │   ├── server/
│   │   │   └── chat-endpoint.js        # /api/chat SSE 流式端点
│   │   └── client/
│   │       └── ChatPage.vue            # Agent Chat 对话面板
│   ├── shell/
│   │   ├── register-shell.ps1          # 右键菜单注册
│   │   ├── unregister-shell.ps1        # 右键菜单注销
│   │   └── send-to-hermes.ps1          # 文件发送桥接
│   ├── hitl/
│   │   ├── server/
│   │   │   └── approval-ws.js          # WebSocket 审批推送
│   │   └── client/
│   │       └── ApprovalPanel.vue       # 审批面板 UI
│   └── mcp/
│       └── ToolHub.vue                 # MCP/ACP Tool Hub
│
└── docs/                                # 文档（待补充截图）
```

## 系统要求

- Windows 10 2004+ / Windows 11 / Windows Server 2022
- 64 位操作系统
- **建议** 8GB+ 内存（最低 2GB，WSL 会以 512MB 运行）
- 5GB+ 可用磁盘空间
- BIOS 虚拟化已启用（Intel VT-x / AMD-V）
- 互联网连接

> **注意**: 低于 8GB 内存时脚本会警告但不阻断。在 2GB 云服务器上经过实测，脚本可完整运行，但 WSL + Ubuntu + Hermes 运行会受限。

## 自建 CDN 加速

为国内用户提供全量依赖加速，所有大文件均托管在自建 CDN：

| 文件 | 大小 | 说明 |
|------|------|------|
| `hermes-agent.tar.gz` | 73 MB | Hermes Agent 主程序 |
| `wsl.2.6.3.0.x64.msi` | 236 MB | WSL 完整安装包（兼容旧版 Windows Server） |
| `wsl_update_x64.msi` | 17 MB | WSL2 内核更新 |

> CDN 地址: `http://121.40.165.216/hermes-cdn/files/`  
> 详见 [docs/依赖清单.md](docs/依赖清单.md)

## 安装选项

```powershell
# 无人值守安装（推荐）
.\scripts\install-hermes.ps1 -Unattended

# 自定义端口
.\scripts\install-hermes.ps1 -Port 9000

# 自定义 WSL 安装路径（绕过 Microsoft Store，适用于 Server 或离线环境）
.\scripts\install-hermes.ps1 -WslPath D:\WSL

# 跳过 WSL/Ubuntu（已安装时使用）
.\scripts\install-hermes.ps1 -SkipWsl

# 完整参数
.\scripts\install-hermes.ps1 -Unattended -Port 8648 -WslPath D:\WSL -UbuntuUser hermes
```

## 环境检测

```powershell
.\scripts\utils\test-env.ps1
```

## 卸载

```powershell
# 仅移除 Hermes（保留 WSL）
.\scripts\uninstall.ps1

# 同时移除 WSL Ubuntu 发行版
.\scripts\uninstall.ps1 -RemoveWsl
```

## 实机测试

2026-05-03 在阿里云 Windows Server 2022 (2GB/1vCPU) 实机上完成全流程测试：

- ✅ 脚本解析无崩溃
- ✅ 7 个步骤全部执行
- ✅ 环境检测、磁盘/内存/端口/WSL 状态正确
- ✅ WSL 旧版自动检测 + CDN 更新逻辑就绪
- ✅ Ubuntu 376MB rootfs 成功下载（自定义路径模式）
- ⚠️ WSL 需更新后重启才能完成 Ubuntu 导入（云实例限制）

详见 [docs/实机测试报告.md](docs/实机测试报告.md)

## 已修复问题（R8 实测轮次）

| # | 严重度 | 问题 | 修复 |
|---|--------|------|------|
| 1 | 中 | `Get-CimInstance Win32_Processor` 云 VM 返回 null | null 检查 + 优雅降级 |
| 2 | 高 | UTF-8 无 BOM → 中文 Windows GBK 乱码 | 传输前加 BOM |
| 3 | 中 | `-SkipWsl` 跳过不完整 | 扩展到全部 WSL 步骤 |
| 4 | **高** | `\$` 在 PS 双引号中不是转义符 | `@'...'@` + `.Replace()` |
| 5 | 中 | `-f` 格式化与 awk `{}` 冲突 | 改 `.Replace()` |
| 6 | 中 | `.Any(...)` LINQ 不兼容 PS | 改 `IndexOfAny()` |
| 7 | 中 | Ubuntu rootfs URL 迁移 | 更新 cdimages 地址 |
| 8 | **高** | 旧版 WSL 不支持 `--import` | 自动检测 + CDN 下载安装 WSL MSI |

## 常见问题

**Q: 安装中途重启了怎么办？**
A: 重启后会自动继续。如果没有，重新以管理员运行安装脚本，它会跳过已完成的步骤。

**Q: GitHub 访问不了？**
A: 脚本已使用 GHProxy 代理。如果仍有问题，重新运行 `.\install-hermes.ps1 -MirrorGitee`

**Q: 浏览器打开 localhost:8648 显示无法访问？**
A: WSL 首次启动较慢，等待 30-60 秒后刷新。如仍不通，运行 `wsl -d Ubuntu-24.04 -- systemctl start hermes`

**Q: 可以更换端口吗？**
A: 安装时使用 `-Port` 参数指定，如 `.\install-hermes.ps1 -Port 9000`

## 开发构建

```powershell
# 一键构建（自动下载 dotnet + Inno Setup，不污染系统）
.\scripts\build.ps1

# 清理重置
.\scripts\build.ps1 -Clean
```

**零前置依赖：** PowerShell 5.1+（Windows 自带）→ 跑 `build.ps1` → 脚本自己下载 dotnet SDK + Inno Setup 到 `.tools/` 目录 → 编译 WPF → 打包 exe → 输出到 `installer/output/`。

全程不需要手动安装任何东西。

- [x] Phase 1: PowerShell 一键安装脚本（7 个脚本，断点续装 + 国内镜像 + 自启）
- [x] Phase 2: WPF GUI 安装向导 + Inno Setup exe 打包
- [x] Phase 3: Agent Chat 对话面板 + 右键集成 + HITL 审批 + MCP Tool Hub

详见 [实现计划书.md](./实现计划书.md)

## 许可证

MIT
