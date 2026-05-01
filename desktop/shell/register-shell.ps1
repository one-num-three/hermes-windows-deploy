# =============================================================================
# Hermes Windows 右键菜单注册脚本
# 用法（管理员 PowerShell）: .\register-shell.ps1 [-Port 8648]
# =============================================================================
param(
    [string]$Port = "8648",
    [string]$AppName = "Hermes Agent"
)

$ErrorActionPreference = "Continue"
$errors = @()

function Safe-Registry {
    param([string]$Operation, [scriptblock]$Script)
    try {
        & $Script
    } catch {
        $errors += "[$Operation] $_"
        Write-Host "  警告: $Operation 失败 - $_" -ForegroundColor Yellow
    }
}

Write-Host "=== 注册 Hermes 右键菜单 ===\" -ForegroundColor Cyan

# 注册表路径
$shellKey = "HKCR:\*\shell\HermesAgent"
$directoryKey = "HKCR:\Directory\shell\HermesAgent"
$directoryBgKey = "HKCR:\Directory\Background\shell\HermesAgent"

# 菜单文本
$menuText = "发送到 Hermes Agent"

# ---- 1. 所有文件右键 ----

Write-Host "[1/3] 注册文件右键菜单..."

# 主菜单项
New-Item -Path $shellKey -Force | Out-Null
Set-ItemProperty -Path $shellKey -Name "MUIVerb" -Value $menuText
Set-ItemProperty -Path $shellKey -Name "Icon" -Value "powershell.exe"
Set-ItemProperty -Path $shellKey -Name "ExtendedSubCommandsKey" -Value ""

# 安全：使用单引号拼接避免 $PSScriptRoot 中特殊字符导致的命令注入
$safeRoot = $PSScriptRoot -replace "'", "''"
$sendToScript = "$safeRoot\send-to-hermes.ps1"

# 子菜单：分析文件
$subKey = "$shellKey\shell\analyze"
New-Item -Path $subKey -Force | Out-Null
Set-ItemProperty -Path $subKey -Name "MUIVerb" -Value "分析此文件"
Set-ItemProperty -Path $subKey -Name "Icon" -Value "shell32.dll,166"

$cmdKey = "$subKey\command"
New-Item -Path $cmdKey -Force | Out-Null
Set-ItemProperty -Path $cmdKey -Name "(Default)" -Value "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$sendToScript`" -FilePath `"%1`" -Port $Port"

# 子菜单：读取文件内容
$readKey = "$shellKey\shell\read"
New-Item -Path $readKey -Force | Out-Null
Set-ItemProperty -Path $readKey -Name "MUIVerb" -Value "让 Hermes 解释内容"
Set-ItemProperty -Path $readKey -Name "Icon" -Value "shell32.dll,23"

$readCmdKey = "$readKey\command"
New-Item -Path $readCmdKey -Force | Out-Null
Set-ItemProperty -Path $readCmdKey -Name "(Default)" -Value "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$sendToScript`" -FilePath `"%1`" -Action `"explain`" -Port $Port"

# ---- 2. 文件夹右键 ----

Write-Host "[2/3] 注册文件夹右键菜单..."

New-Item -Path $directoryKey -Force | Out-Null
Set-ItemProperty -Path $directoryKey -Name "MUIVerb" -Value $menuText
Set-ItemProperty -Path $directoryKey -Name "Icon" -Value "powershell.exe"
Set-ItemProperty -Path $directoryKey -Name "ExtendedSubCommandsKey" -Value ""

$dirAnalyzeKey = "$directoryKey\shell\analyze"
New-Item -Path $dirAnalyzeKey -Force | Out-Null
Set-ItemProperty -Path $dirAnalyzeKey -Name "MUIVerb" -Value "分析项目结构"
Set-ItemProperty -Path $dirAnalyzeKey -Name "Icon" -Value "shell32.dll,4"

$dirCmdKey = "$dirAnalyzeKey\command"
New-Item -Path $dirCmdKey -Force | Out-Null
Set-ItemProperty -Path $dirCmdKey -Name "(Default)" -Value "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$sendToScript`" -FilePath `"%1`" -Action `"analyze-project`" -Port $Port"

# ---- 3. 文件夹背景右键 ----

New-Item -Path $directoryBgKey -Force | Out-Null
Set-ItemProperty -Path $directoryBgKey -Name "MUIVerb" -Value $menuText
Set-ItemProperty -Path $directoryBgKey -Name "Icon" -Value "powershell.exe"

$bgCmdKey = "$directoryBgKey\command"
New-Item -Path $bgCmdKey -Force | Out-Null
Set-ItemProperty -Path $bgCmdKey -Name "(Default)" -Value "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$sendToScript`" -FilePath `"%V`" -Action `"open-chat`" -Port $Port"

Write-Host "[3/3] 注册完成" -ForegroundColor Green
Write-Host ""
Write-Host "右键菜单已启用：" -ForegroundColor Cyan
Write-Host "  • 右键任意文件 → 发送到 Hermes Agent → 分析此文件" -ForegroundColor White
Write-Host "  • 右键任意文件 → 发送到 Hermes Agent → 让 Hermes 解释内容" -ForegroundColor White
Write-Host "  • 右键任意文件夹 → 发送到 Hermes Agent → 分析项目结构" -ForegroundColor White
Write-Host ""
Write-Host "需要重启资源管理器才能看到效果，或者注销后重新登录" -ForegroundColor DarkGray

# 错误汇总
if ($errors.Count -gt 0) {
    Write-Host ""
    Write-Host "=== 以下操作失败，请检查权限后重试 ===" -ForegroundColor Red
    $errors | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    Write-Host "提示: 请以管理员身份运行此脚本" -ForegroundColor Yellow
} else {
    Write-Host "所有注册表项已成功写入" -ForegroundColor Green
}
