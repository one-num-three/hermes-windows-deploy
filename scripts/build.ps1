# =============================================================================
# Hermes Windows 部署工具 — 自举构建脚本（零手动依赖）
# 自动下载 dotnet SDK + Inno Setup → 编译 → 打包 → 输出 exe
# 用法: .\scripts\build.ps1              # 首次运行，自动下载工具链
#       .\scripts\build.ps1 -Clean       # 清理后重新构建
#       .\scripts\build.ps1 -DryRun      # 仅检测，不实际构建
# =============================================================================
param(
    [switch]$Clean,       # 清理所有构建缓存和工具链
    [switch]$DryRun       # 仅检测环境，不构建
)

$ErrorActionPreference = "Stop"
$Script:BuildStart = Get-Date

# =============================================================================
# 配置
# =============================================================================
$TOOLS_DIR   = "$PSScriptRoot\..\.tools"          # 便携工具链目录（不污染系统）
$DOTNET_DIR  = "$TOOLS_DIR\dotnet"
$ISCC_DIR    = "$TOOLS_DIR\innosetup"
$NUGET_CACHE = "$TOOLS_DIR\nuget-cache"

$DOTNET_VERSION = "8.0"
$DOTNET_INSTALL_URL = "https://dot.net/v1/dotnet-install.ps1"
$INNO_URL = "https://files.jrsoftware.org/is/6/innosetup-6.2.2.exe"

$SOLUTION   = "$PSScriptRoot\..\gui\HermesInstaller\HermesInstaller.csproj"
$ISS_SCRIPT = "$PSScriptRoot\..\installer\hermes-installer.iss"
$OUTPUT_DIR = "$PSScriptRoot\..\installer\output"

# =============================================================================
# 工具函数
# =============================================================================

function Write-Step { param($Msg, $Status="") 
    $icons = @{ok="[ ✓ ]";err="[ ✗ ]";warn="[ ! ]";skip="[ → ]";info="[ i ]";dl="[ ↓ ]"}
    $colors = @{ok="Green";err="Red";warn="Yellow";skip="DarkGray";info="Cyan";dl="Cyan"}
    $icon = if ($icons.ContainsKey($Status)) { $icons[$Status] } else { "[...]" }
    $color = if ($colors.ContainsKey($Status)) { $colors[$Status] } else { "White" }
    Write-Host "$icon $Msg" -ForegroundColor $color
}

function Invoke-Download {
    param($Url, $OutFile, $Description="文件")
    Write-Step "下载 $Description..." "dl"
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -TimeoutSec 300
        Write-Step "$Description 下载完成" "ok"
        return $true
    } catch {
        Write-Host "  错误: $_" -ForegroundColor Red
        Write-Step "$Description 下载失败" "err"
        return $false
    }
}

function Invoke-Exec {
    param($Exe, $Args, $Msg="执行命令")
    Write-Step $Msg "info"
    $output = & $Exe @Args 2>&1
    $ok = ($LASTEXITCODE -eq 0)
    if (-not $ok) { Write-Host "  $output" -ForegroundColor DarkGray }
    return @{Ok=$ok; Output=$output}
}

# =============================================================================
# 清理
# =============================================================================
function Invoke-Clean {
    Write-Step "清理构建缓存..." "info"
    Remove-Item $TOOLS_DIR -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$PSScriptRoot\..\gui\HermesInstaller\bin" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$PSScriptRoot\..\gui\HermesInstaller\obj" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $OUTPUT_DIR -Recurse -Force -ErrorAction SilentlyContinue
    Write-Step "清理完成" "ok"
}

# =============================================================================
# Step 1: 自举 dotnet SDK（便携版，不装系统）
# =============================================================================
function Step-BootstrapDotnet {
    Write-Host ""
    Write-Host "--- .NET SDK ---" -ForegroundColor Cyan

    # 检查系统是否已有 dotnet
    $systemDotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($systemDotnet) {
        try {
            $sysVer = & dotnet --version 2>$null
            if ($sysVer -and [Version]$sysVer -ge [Version]$DOTNET_VERSION) {
                Write-Step "dotnet v$sysVer（系统已有）" "ok"
                return $true
            }
        } catch {}
    }

    # 检查 .tools 里的便携版
    $localDotnet = "$DOTNET_DIR\dotnet.exe"
    if (Test-Path $localDotnet) {
        try {
            $localVer = & $localDotnet --version 2>$null
            if ($localVer -and [Version]$localVer -ge [Version]$DOTNET_VERSION) {
                Write-Step "dotnet v$localVer（便携版就绪）" "ok"
                $env:PATH = "$DOTNET_DIR;$env:PATH"
                return $true
            }
        } catch {}
    }

    # 下载安装脚本
    Write-Step "dotnet 未找到或版本过低，开始自举安装..." "info"
    $installScript = "$env:TEMP\dotnet-install.ps1"
    if (-not (Invoke-Download $DOTNET_INSTALL_URL $installScript "dotnet-install.ps1")) {
        return $false
    }

    # 安装到便携目录（非系统级）
    New-Item -ItemType Directory -Path $DOTNET_DIR -Force | Out-Null
    & $installScript -Channel $DOTNET_VERSION -InstallDir $DOTNET_DIR -NoPath
    Remove-Item $installScript -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path $localDotnet)) {
        Write-Step "dotnet 安装失败" "err"
        return $false
    }

    $env:PATH = "$DOTNET_DIR;$env:PATH"
    $localVer = & $localDotnet --version 2>$null
    Write-Step "dotnet v$localVer 已安装到 .tools\dotnet\" "ok"
    return $true
}

# =============================================================================
# Step 2: 自举 Inno Setup（便携版）
# =============================================================================
function Step-BootstrapInno {
    Write-Host ""
    Write-Host "--- Inno Setup ---" -ForegroundColor Cyan

    # 检查系统是否已有 iscc
    $sysIscc = Get-Command iscc -ErrorAction SilentlyContinue
    if (-not $sysIscc) {
        # 搜索常见安装路径
        $commonPaths = @(
            "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
            "C:\Program Files\Inno Setup 6\ISCC.exe",
            "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
        )
        foreach ($p in $commonPaths) {
            if (Test-Path $p) { $sysIscc = $p; break }
        }
    }
    if ($sysIscc) {
        Write-Step "Inno Setup 已安装: $sysIscc" "ok"
        $global:IsccPath = $sysIscc
        return $true
    }

    # 检查便携版
    $localIscc = "$ISCC_DIR\ISCC.exe"
    if (Test-Path $localIscc) {
        Write-Step "Inno Setup 便携版就绪" "ok"
        $global:IsccPath = $localIscc
        return $true
    }

    # 下载并静默安装到便携目录
    Write-Step "Inno Setup 未找到，开始自举安装..." "info"
    $installer = "$env:TEMP\innosetup.exe"
    if (-not (Invoke-Download $INNO_URL $installer "Inno Setup 6")) {
        return $false
    }

    New-Item -ItemType Directory -Path $ISCC_DIR -Force | Out-Null
    Write-Step "安装 Inno Setup 到 .tools\innosetup\..." "info"
    $proc = Start-Process $installer -ArgumentList "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /DIR=`"$ISCC_DIR`"" -Wait -PassThru
    Remove-Item $installer -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path $localIscc)) {
        Write-Step "Inno Setup 安装失败" "err"
        Write-Host "  手动下载: https://jrsoftware.org/isdl.php" -ForegroundColor Yellow
        return $false
    }

    $global:IsccPath = $localIscc
    Write-Step "Inno Setup 已安装到 .tools\innosetup\" "ok"
    return $true
}

# =============================================================================
# Step 3: NuGet 还原 + 编译 WPF
# =============================================================================
function Step-BuildWpf {
    Write-Host ""
    Write-Host "--- 编译 WPF 安装向导 ---" -ForegroundColor Cyan

    $dotnet = "$DOTNET_DIR\dotnet.exe"
    if (-not (Test-Path $dotnet)) { $dotnet = "dotnet" }

    # NuGet 还原
    $restore = Invoke-Exec $dotnet @("restore", $SOLUTION, "--packages", $NUGET_CACHE) "NuGet 还原"
    if (-not $restore.Ok) { Write-Step "NuGet 还原失败" "err"; return $false }

    # 编译发布
    $publishDir = "$PSScriptRoot\..\gui\HermesInstaller\bin\Release\net8.0-windows\publish"
    $build = Invoke-Exec $dotnet @(
        "publish", $SOLUTION,
        "-c", "Release",
        "-r", "win-x64",
        "--self-contained", "false",
        "-p:PublishSingleFile=false",
        "-o", $publishDir
    ) "编译 HermesInstaller.exe"

    if (-not $build.Ok) { Write-Step "编译失败" "err"; return $false }

    $exe = "$publishDir\HermesInstaller.exe"
    if (Test-Path $exe) {
        $mb = [math]::Round((Get-Item $exe).Length/1MB, 1)
        Write-Step "编译成功: HermesInstaller.exe (${mb}MB)" "ok"
        return $true
    }
    Write-Step "编译产物缺失" "err"
    return $false
}

# =============================================================================
# Step 4: Inno Setup 打包
# =============================================================================
function Step-PackageExe {
    Write-Host ""
    Write-Host "--- 打包安装程序 ---" -ForegroundColor Cyan

    $iscc = $global:IsccPath
    if (-not $iscc) {
        Write-Step "iscc 路径未找到" "err"
        return $false
    }

    New-Item -ItemType Directory -Path $OUTPUT_DIR -Force | Out-Null
    $pkg = Invoke-Exec $iscc @("/O$OUTPUT_DIR", $ISS_SCRIPT) "Inno Setup 打包"

    if (-not $pkg.Ok) { Write-Step "打包失败" "err"; return $false }

    $exe = Get-ChildItem $OUTPUT_DIR -Filter "HermesAgent-Setup-*.exe" | Sort-Object LastWriteTime -Desc | Select-Object -First 1
    if ($exe) {
        $mb = [math]::Round($exe.Length/1MB, 1)
        Write-Step "打包完成: $($exe.Name) (${mb}MB)" "ok"
        return $true
    }
    Write-Step "打包产物缺失" "err"
    return $false
}

# =============================================================================
# Step 5: 清理临时文件
# =============================================================================
function Step-CleanupTemp {
    Write-Host ""
    Write-Step "清理临时文件..." "info"
    Remove-Item "$env:TEMP\dotnet-install.ps1" -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:TEMP\innosetup.exe" -Force -ErrorAction SilentlyContinue
    Write-Step "临时文件已清理" "ok"
}

# =============================================================================
# 主流程
# =============================================================================
function Main {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║   Hermes Installer — 自举构建（零手动）   ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

    if ($Clean) {
        Invoke-Clean
        Write-Host "清理完成，重新运行 build.ps1 开始构建" -ForegroundColor Green
        return
    }

    Write-Step "工具链目录: $TOOLS_DIR" "info"
    Write-Step "首次运行会自动下载 dotnet + Inno Setup（约 300MB）" "info"
    Write-Host ""

    # 自举工具链
    if (-not (Step-BootstrapDotnet)) { Write-Host "构建中止" -ForegroundColor Red; return }
    if (-not (Step-BootstrapInno))  { Write-Host "构建中止" -ForegroundColor Red; return }

    if ($DryRun) {
        Write-Host ""
        Write-Step "环境检测通过，可以构建" "ok"
        return
    }

    # 构建流水线
    if (-not (Step-BuildWpf))   { Write-Host "构建中止" -ForegroundColor Red; return }
    if (-not (Step-PackageExe)) { Write-Host "构建中止" -ForegroundColor Red; return }

    Step-CleanupTemp

    # 完成
    $elapsed = [math]::Round(((Get-Date) - $Script:BuildStart).TotalSeconds, 1)
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║    构建完成！ ${elapsed}s                       ║" -ForegroundColor Green
    Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""
    Write-Host "  输出: $OUTPUT_DIR\" -ForegroundColor White
    Get-ChildItem $OUTPUT_DIR -Filter "*.exe" | ForEach-Object {
        Write-Host "    → $($_.Name) ($([math]::Round($_.Length/1MB,1))MB)" -ForegroundColor Green
    }
    Write-Host ""
}

Main
