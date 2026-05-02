# =============================================================================
# Hermes 安装后配置脚本
# 创建桌面快捷方式、防火墙规则、文件关联等
# 用法: .\post-install.ps1 [-Port 8648]
# =============================================================================
param(
    [string]$Port = "8648",
    [string]$WslDistro = "Ubuntu-24.04"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Hermes 安装后配置 ===" -ForegroundColor Cyan

# 1. 创建桌面快捷方式
Write-Host "[1/4] 创建桌面快捷方式..."
$desktopPath = [Environment]::GetFolderPath("Desktop")
$shortcutPath = Join-Path $desktopPath "Hermes Agent.url"

$shortcut = @"
[InternetShortcut]
URL=http://localhost:$Port
IconFile=%SystemRoot%\System32\SHELL32.dll
IconIndex=14
"@

Set-Content -Path $shortcutPath -Value $shortcut
Write-Host "  桌面快捷方式已创建: $shortcutPath" -ForegroundColor Green

# 2. 创建启动菜单快捷方式
Write-Host "[2/4] 创建开始菜单快捷方式..."
$startMenu = [Environment]::GetFolderPath("StartMenu")
$startShortcut = Join-Path $startMenu "Programs\Hermes Agent.url"
New-Item -ItemType Directory -Path (Split-Path $startShortcut) -Force | Out-Null
Set-Content -Path $startShortcut -Value $shortcut

# 3. 注册 Windows 右键菜单
Write-Host "[3/4] 注册右键菜单..."
$shellScript = Join-Path $PSScriptRoot "..\desktop\shell\register-shell.ps1"
if (Test-Path $shellScript) {
    try {
        & $shellScript -Port $Port
        Write-Host "  右键菜单已注册（右键文件 → 发送到 Hermes）" -ForegroundColor Green
    } catch {
        Write-Host "  右键菜单注册失败（无管理员权限时跳过）" -ForegroundColor Yellow
    }
}

# 4. 确保 WSL 不自动休眠 — 读取现有配置进行合并，不覆盖
Write-Host "[4/4] 配置 WSL 持久化..."
$wslConfigPath = "$([Environment]::GetFolderPath('UserProfile'))\.wslconfig"

if (Test-Path $wslConfigPath) {
    $existing = Get-Content $wslConfigPath -Raw
    # 仅添加缺失的 localhostForwarding 条目
    if ($existing -notmatch "localhostForwarding") {
        Add-Content -Path $wslConfigPath -Value "`nlocalhostForwarding=true"
        Write-Host "  已追加 localhostForwarding 到现有 .wslconfig" -ForegroundColor Green
    } else {
        Write-Host "  .wslconfig 已包含 localhostForwarding，跳过" -ForegroundColor Green
    }
} else {
    $wslConfig = @"
# Hermes Agent - WSL 配置
# 文档: https://learn.microsoft.com/zh-cn/windows/wsl/wsl-config
[wsl2]
localhostForwarding=true
"@
    Set-Content -Path $wslConfigPath -Value $wslConfig
    Write-Host "  .wslconfig 已创建（仅含 localhostForwarding，避免覆盖其他配置）" -ForegroundColor Green
}
Write-Host "  .wslconfig 已配置" -ForegroundColor Green

# 可选：检查 Windows Terminal（仅信息显示，不占用步骤编号）
Write-Host "[i] 检查 Windows Terminal..."
$wtSettings = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
if (Test-Path $wtSettings) {
    Write-Host "  Windows Terminal 已安装" -ForegroundColor Green
}

Write-Host ""
Write-Host "=== 安装后配置完成 ===" -ForegroundColor Green
Write-Host ""
Write-Host "快速开始:" -ForegroundColor Cyan
Write-Host "  1. 双击桌面上的 'Hermes Agent' 图标" -ForegroundColor White
Write-Host "  2. 或者打开浏览器访问 http://localhost:$Port" -ForegroundColor White
Write-Host "  3. 如果无法访问，等待 30 秒后重试（WSL 首次启动较慢）" -ForegroundColor DarkGray
Write-Host ""

Read-Host "按 Enter 退出"
