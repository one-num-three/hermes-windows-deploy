# =============================================================================
# Hermes 环境检测工具
# 独立运行，仅检测不安装
# 用法: .\utils\test-env.ps1
# =============================================================================

Write-Host ""
Write-Host "=== Hermes 安装环境检测 ===" -ForegroundColor Cyan
Write-Host ""

$allPassed = $true

function Test-Item {
    param([string]$Label, [ScriptBlock]$Check)
    try {
        $result = & $Check
        if ($result) {
            Write-Host "  [ ✓ ] $Label" -ForegroundColor Green
            return $true
        } else {
            Write-Host "  [ ✗ ] $Label" -ForegroundColor Red
            $script:allPassed = $false
            return $false
        }
    } catch {
        Write-Host "  [ ✗ ] $Label — $_" -ForegroundColor Red
        $script:allPassed = $false
        return $false
    }
}

# 系统信息
Write-Host "系统信息:" -ForegroundColor White
Test-Item "操作系统: $(Get-CimInstance Win32_OperatingSystem | Select-Object -ExpandProperty Caption)" { $true }
Test-Item "Windows 版本 >= 10.0.19041" {
    $ver = [Environment]::OSVersion.Version
    $ver.Major -ge 10 -and $ver.Build -ge 19041
}
Test-Item "64 位系统" { [Environment]::Is64BitOperatingSystem }

# 硬件信息
Write-Host ""
Write-Host "硬件信息:" -ForegroundColor White
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
Test-Item "CPU: $($cpu.Name.Trim())" { $true }
Test-Item "虚拟化已启用" { $cpu.VirtualizationFirmwareEnabled }
$totalMem = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
Test-Item "内存: ${totalMem}GB (需要 >= 8GB)" { $totalMem -ge 8 }
$freeDisk = [math]::Round((Get-PSDrive -Name C).Free / 1GB, 1)
Test-Item "C 盘可用空间: ${freeDisk}GB (需要 >= 20GB)" { $freeDisk -ge 20 }

# 管理员权限
Write-Host ""
Write-Host "权限:" -ForegroundColor White
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
Test-Item "管理员权限" { $isAdmin }

# WSL 状态
Write-Host ""
Write-Host "WSL 状态:" -ForegroundColor White
$wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
Test-Item "WSL 命令可用" { $wsl -ne $null }

if ($wsl) {
    try {
        $wslVersion = wsl --version 2>&1 | Select-Object -First 1
        Test-Item "WSL 版本: $wslVersion" { $true }
    } catch { }

    $distros = wsl -l -v 2>&1
    Test-Item "已安装发行版:`n    $($distros -join "`n    ")" { $true }
}

# 网络
Write-Host ""
Write-Host "网络:" -ForegroundColor White
try {
    $ip = Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 5
    Test-Item "互联网连通: $ip" { $true }
} catch {
    Test-Item "互联网连通" { $false }
}

try {
    $test = Invoke-WebRequest -Uri "https://github.com" -TimeoutSec 5 -UseBasicParsing
    Test-Item "GitHub 可访问 (状态: $($test.StatusCode))" { $true }
} catch {
    Test-Item "GitHub 可访问" { $false }
}

# 端口
Write-Host ""
Write-Host "端口状态:" -ForegroundColor White
$port = 8648
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
try {
    $listener.Start()
    $listener.Stop()
    Test-Item "端口 $port 空闲" { $true }
} catch {
    Test-Item "端口 $port 空闲" { $false }
}

Write-Host ""
Write-Host "====================================" -ForegroundColor Cyan
if ($allPassed) {
    Write-Host "所有检测通过，可以安装!" -ForegroundColor Green
} else {
    Write-Host "部分检测未通过，请解决红色项后重试" -ForegroundColor Yellow
}
Write-Host "====================================" -ForegroundColor Cyan
Write-Host ""

if (-not $isAdmin) {
    Write-Host "提示: 未以管理员运行，安装时需要管理员权限" -ForegroundColor Yellow
}
