# =============================================================================
# Hermes 卸载脚本
# 移除 Hermes、hermes-web-ui、WSL 发行版（可选）
# 用法: .\uninstall.ps1 [-RemoveWsl] [-Force]
# =============================================================================
param(
    [switch]$RemoveWsl,     # 同时移除 WSL Ubuntu 发行版
    [switch]$Force,        # 跳过确认提示
    [string]$WslDistro = "Ubuntu-24.04"
)

Write-Host "=== Hermes Agent 卸载程序 ===" -ForegroundColor Red
Write-Host ""

if (-not $Force) {
    Write-Host "此脚本将移除 Hermes Agent 及相关配置。" -ForegroundColor Yellow
    Write-Host ""
    $confirm = Read-Host "确认卸载？(y/n)"
    if ($confirm -ne "y") { exit 0 }
}

# 1. 停止 WSL 内服务
Write-Host "[1/6] 停止 Hermes 服务..."
try {
    wsl -d $WslDistro -u root -- systemctl stop hermes 2>$null
    wsl -d $WslDistro -u root -- systemctl disable hermes 2>$null
    wsl -d $WslDistro -u root -- rm -f /etc/systemd/system/hermes.service 2>$null
    Write-Host "  服务已停止" -ForegroundColor Green
} catch {
    Write-Host "  服务停止失败（可能未运行）" -ForegroundColor Yellow
}

# 2. 移除 Task Scheduler 任务
Write-Host "[2/6] 移除开机自启任务..."
try {
    Unregister-ScheduledTask -TaskName "HermesAgent-StartWSL" -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "  计划任务已删除" -ForegroundColor Green
} catch {
    Write-Host "  计划任务可能不存在" -ForegroundColor Yellow
}

# 3. 移除防火墙规则
Write-Host "[3/6] 移除防火墙规则..."
try {
    Remove-NetFirewallRule -DisplayName "Hermes Web UI" -ErrorAction SilentlyContinue
    Write-Host "  防火墙规则已删除" -ForegroundColor Green
} catch {
    Write-Host "  防火墙规则可能不存在" -ForegroundColor Yellow
}

# 4. 清除桌面快捷方式
Write-Host "[4/6] 清除快捷方式..."
$shortcuts = @(
    (Join-Path ([Environment]::GetFolderPath("Desktop")) "Hermes Agent.url"),
    (Join-Path ([Environment]::GetFolderPath("StartMenu")) "Programs\Hermes Agent.url")
)
foreach ($s in $shortcuts) {
    if (Test-Path $s) {
        Remove-Item $s -Force
        Write-Host "  已删除: $s" -ForegroundColor Green
    }
}

# 5. 清除安装状态和日志
Write-Host "[5/6] 清除安装状态..."
Remove-Item "$env:USERPROFILE\.hermes\install-state.json" -Force -ErrorAction SilentlyContinue
Remove-Item "$env:USERPROFILE\hermes-install.log" -Force -ErrorAction SilentlyContinue

# 6. WSL 发行版（可选）
if ($RemoveWsl) {
    Write-Host "[6/6] 移除 WSL Ubuntu 发行版..."
    try {
        wsl --unregister $WslDistro
        Write-Host "  WSL 发行版已移除" -ForegroundColor Green
    } catch {
        Write-Host "  WSL 发行版移除失败" -ForegroundColor Red
    }
} else {
    Write-Host "[6/6] WSL 发行版已保留 (使用 -RemoveWsl 一并移除)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== 卸载完成 ===" -ForegroundColor Green
Write-Host ""

# 检查是否还有残余
$wslConfig = "$env:USERPROFILE\.wslconfig"
if (Test-Path $wslConfig) {
    Write-Host "提示: .wslconfig 仍然存在 ($wslConfig)" -ForegroundColor DarkGray
    Write-Host "  如果不再使用 WSL，可手动删除此文件" -ForegroundColor DarkGray
}

Read-Host "按 Enter 退出"
