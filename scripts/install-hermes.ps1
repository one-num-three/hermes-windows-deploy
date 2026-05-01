# =============================================================================
# Hermes Agent Windows 一键安装脚本
# Version: 0.1.0
# 用法: 右键 → 以管理员身份运行
# =============================================================================

param(
    [switch]$Unattended,          # 无人值守模式（跳过所有提示）
    [switch]$SkipWsl,            # 跳过 WSL 安装（已安装时使用）
    [switch]$SkipUbuntu,         # 跳过 Ubuntu 安装
    [string]$UbuntuUser = "",    # 手动指定 Ubuntu 用户名（默认自动生成）
    [string]$Port = "8648",      # Web UI 端口
    [switch]$MirrorGitee,       # 使用 Gitee 镜像（替代 GitHub）
    [string]$WslPath = "",      # WSL 安装路径（如 D:\WSL），留空则默认 C 盘
    [string]$LogPath = "$env:USERPROFILE\hermes-install.log"
)

# =============================================================================
# 配置区
# =============================================================================
$Script:WSL_DISTRO = "Ubuntu-24.04"
$Script:WSL_USER = ""
$Script:WEB_PORT = $Port
$Script:STATE_FILE = "$env:USERPROFILE\.hermes\install-state.json"
$Script:CDN_BASE = "http://121.40.165.216/hermes-cdn/files"
$Script:GITHUB_PROXY = "https://ghproxy.com/"  # GitHub 加速代理（备用）
$Script:HERMES_REPO = "https://github.com/NousResearch/hermes-agent.git"
$Script:HERMES_INSTALL_SCRIPT_URL = "https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh"

# 国内镜像源
$Script:MIRRORS = @{
    apt     = "https://mirrors.tuna.tsinghua.edu.cn/ubuntu/"
    pip     = "https://pypi.tuna.tsinghua.edu.cn/simple"
    npm     = "https://registry.npmmirror.com"
}

# =============================================================================
# 工具函数
# =============================================================================

function Write-Step {
    param([string]$Message, [string]$Status = "")
    $timestamp = Get-Date -Format "HH:mm:ss"
    $icon = switch ($Status) {
        "start"   { "[...]" }
        "ok"      { "[ ✓ ]" }
        "error"   { "[ ✗ ]" }
        "warn"    { "[ ! ]" }
        "skip"    { "[ → ]" }
        default   { "[   ]" }
    }
    $line = "$timestamp $icon $Message"
    Write-Host $line -ForegroundColor $(
        switch ($Status) {
            "ok"    { "Green" }
            "error" { "Red" }
            "warn"  { "Yellow" }
            "skip"  { "DarkGray" }
            default { "White" }
        }
    )
    Add-Content -Path $LogPath -Value $line
}

function Write-Error-And-Log {
    param([string]$Message)
    Write-Step $Message "error"
    Add-Content -Path $LogPath -Value "  ERROR DETAIL: $Message"
}

function Test-Admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
    if (-not $isAdmin) {
        Write-Host "此脚本需要管理员权限。" -ForegroundColor Red
        Write-Host "请右键此脚本 → '以管理员身份运行'" -ForegroundColor Yellow
        pause
        exit 1
    }
}

function Test-WindowsVersion {
    $ver = [Environment]::OSVersion.Version
    if ($ver.Major -lt 10 -or ($ver.Major -eq 10 -and $ver.Build -lt 19041)) {
        Write-Error-And-Log "Windows 版本过旧: $($ver.ToString())，需要 Windows 10 2004 (Build 19041) 或更高版本"
        return $false
    }
    return $true
}

function Test-Virtualization {
    $cpuInfo = Get-CimInstance Win32_Processor | Select-Object -First 1
    $vmSupport = $cpuInfo.VirtualizationFirmwareEnabled
    if (-not $vmSupport) {
        Write-Step "BIOS 虚拟化未开启，WSL2 无法运行" "warn"
        Write-Host ""
        Write-Host "  请在 BIOS 中启用 Intel VT-x 或 AMD-V：" -ForegroundColor Yellow
        Write-Host "  1. 重启电脑，按 F2/Del/Esc 进入 BIOS" -ForegroundColor Gray
        Write-Host "  2. 找到 'Virtualization Technology' 或 'SVM Mode'" -ForegroundColor Gray
        Write-Host "  3. 设置为 'Enable'" -ForegroundColor Gray
        Write-Host "  4. 保存退出，重新运行本脚本" -ForegroundColor Gray
        Write-Host ""
        if (-not $Unattended) {
            $continue = Read-Host "仍要继续安装？可能失败 (y/n)"
            if ($continue -ne "y") { exit 1 }
        }
        return $false
    }
    return $true
}

function Test-DiskSpace {
    # 固定检测系统盘 C:（WSL 默认安装在系统盘）
    $drive = Get-PSDrive -Name C
    $freeGB = [math]::Round($drive.Free / 1GB, 1)
    if ($freeGB -lt 5) {
        Write-Error-And-Log "磁盘空间不足: ${freeGB}GB，需要至少 5GB（实际安装约 3-4GB）"
        return $false
    }
    Write-Step "磁盘空间: ${freeGB}GB 可用" "ok"
    return $true
}

function Test-Memory {
    $totalGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
    if ($totalGB -lt 8) {
        Write-Error-And-Log "内存不足: ${totalGB}GB，需要至少 8GB"
        return $false
    }
    # 配置 WSL 内存限制为总内存的一半
    $Script:WSL_MEMORY_LIMIT = [math]::Max(2, [math]::Floor($totalGB / 2))
    Write-Step "内存: ${totalGB}GB（WSL 限制: ${Script:WSL_MEMORY_LIMIT}GB）" "ok"
    return $true
}

function Invoke-WithRetry {
    param(
        [ScriptBlock]$Command,
        [int]$MaxRetries = 3,
        [string]$ErrorPrefix = "命令执行失败"
    )
    $attempt = 0
    while ($attempt -lt $MaxRetries) {
        try {
            $attempt++
            & $Command
            return $true
        } catch {
            if ($attempt -ge $MaxRetries) {
                Write-Step "$ErrorPrefix (已重试 $MaxRetries 次)" "error"
                return $false
            }
            Write-Step "重试 $attempt/$MaxRetries ..." "warn"
            Start-Sleep -Seconds (5 * $attempt)
        }
    }
}

# =============================================================================
# 状态管理（断点续装）
# =============================================================================

function Get-InstallState {
    if (Test-Path $Script:STATE_FILE) {
        try {
            $loaded = Get-Content $Script:STATE_FILE -Raw | ConvertFrom-Json
            # 确保返回 PSCustomObject（兼容空文件）
            if ($null -eq $loaded) { return [PSCustomObject]@{} }
            return $loaded
        } catch {
            return [PSCustomObject]@{}
        }
    }
    return [PSCustomObject]@{}
}

function Set-InstallState {
    param([string]$Step, [string]$Status)
    $state = Get-InstallState
    $state | Add-Member -MemberType NoteProperty -Name $Step -Value @{
        status = $Status
        time   = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    } -Force
    $dir = Split-Path $Script:STATE_FILE -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $state | ConvertTo-Json | Set-Content $Script:STATE_FILE
}

function Test-StepDone {
    param([string]$Step)
    $state = Get-InstallState
    return ($state.$Step.status -eq "done")
}

# =============================================================================
# 安装步骤
# =============================================================================

# ---- Step 0: 环境检测 ----

function Step-Environment {
    Write-Step "=== Step 0: 环境检测 ===" "start"

    if (Test-StepDone "environment") {
        Write-Step "环境检测已通过，跳过" "skip"
        return $true
    }

    if (-not (Test-WindowsVersion)) { return $false }
    if (-not (Test-DiskSpace)) { return $false }
    if (-not (Test-Memory)) { return $false }

    Test-Virtualization | Out-Null  # 仅警告，不阻断

    Set-InstallState "environment" "done"
    Write-Step "环境检测通过" "ok"
    return $true
}

# ---- Step 1: 安装 WSL2 ----

function Step-InstallWsl {
    Write-Step "=== Step 1: 安装 WSL2 ===" "start"

    if (Test-StepDone "wsl") {
        Write-Step "WSL2 已安装，跳过" "skip"
        return $true
    }

    $wslCmd = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if (-not $wslCmd) {
        Write-Step "正在安装 WSL..." "start"
        try {
            $wslOutput = wsl --install --no-distribution 2>&1
            $wslOutput | Out-File $LogPath -Append
            Write-Step "WSL 安装完成，请重启电脑后重新运行本脚本" "warn"
            Set-InstallState "wsl" "need_reboot"

            # 注册 RunOnce 自动继续
            $scriptPath = $MyInvocation.MyCommand.Path
            $runOnceKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
            Set-ItemProperty -Path $runOnceKey -Name "HermesContinue" -Value "powershell.exe -File `"$scriptPath`" -SkipWsl" -Force
            Write-Step "已设置重启后自动继续安装" "ok"

            shutdown /r /t 30 /c "Hermes 安装需要重启以启用 WSL2，30 秒后重启..."
            exit 0
        } catch {
            Write-Error-And-Log "WSL 安装失败: $_"
            return $false
        }
    }

    # 设置 WSL 默认版本为 2
    $exitCode = 0
    wsl --set-default-version 2 2>&1 | Tee-Object -FilePath $LogPath -Append | Out-Null
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        # WSL2 内核可能未安装，尝试安装
        Write-Step "WSL2 内核未安装，正在下载..." "warn"
        $kernelUrl = "https://wslstorestorage.blob.core.windows.net/wslblob/wsl_update_x64.msi"
        $kernelPath = "$env:TEMP\wsl_update_x64.msi"
        try {
            Invoke-WebRequest -Uri $kernelUrl -OutFile $kernelPath
            Start-Process msiexec.exe -ArgumentList "/i `"$kernelPath`" /quiet /norestart" -Wait
            wsl --set-default-version 2
        } catch {
            Write-Error-And-Log "WSL2 内核安装失败: $_"
            return $false
        }
    }

    # 配置 .wslconfig
    $wslConfig = @"
[wsl2]
memory=${Script:WSL_MEMORY_LIMIT}GB
processors=4
swap=2GB
networkingMode=mirrored
"@
    $wslConfigPath = "$env:USERPROFILE\.wslconfig"
    if (-not (Test-Path $wslConfigPath)) {
        Set-Content -Path $wslConfigPath -Value $wslConfig
        Write-Step ".wslconfig 已配置（mirrored 网络模式）" "ok"
    }

    Set-InstallState "wsl" "done"
    Write-Step "WSL2 就绪" "ok"
    return $true
}

# ---- Step 2: 安装 Ubuntu ----

function Step-InstallUbuntu {
    Write-Step "=== Step 2: 安装 Ubuntu ===" "start"

    if (Test-StepDone "ubuntu") {
        Write-Step "Ubuntu 已安装，跳过" "skip"
        return $true
    }

    $distros = wsl -l -q 2>$null
    if ($distros -match $Script:WSL_DISTRO) {
        Write-Step "Ubuntu 24.04 已存在" "skip"
        Set-InstallState "ubuntu" "done"
        Write-Step "Ubuntu 24.04 就绪" "ok"
        return $true
    }

    # ---- 自定义路径安装（推荐 D 盘用户） ----
    if ($WslPath) {
        Write-Step "自定义 WSL 安装路径: $WslPath" "start"

        $wslDir = $WslPath
        if (-not (Test-Path $wslDir)) {
            New-Item -ItemType Directory -Path $wslDir -Force | Out-Null
        }

        # 检查目标盘剩余空间
        $targetDrive = (Get-Item $wslDir).PSDrive
        $targetFreeGB = [math]::Round($targetDrive.Free / 1GB, 1)
        if ($targetFreeGB -lt 5) {
            Write-Error-And-Log "目标磁盘空间不足: ${targetFreeGB}GB，需要至少 5GB"
            return $false
        }
        Write-Step "目标磁盘可用空间: ${targetFreeGB}GB" "ok"

        # 下载 Ubuntu rootfs
        $rootfsUrl = "https://cloud-images.ubuntu.com/wsl/noble/current/ubuntu-noble-wsl-amd64-rootfs.tar.gz"
        $rootfsFile = "$env:TEMP\ubuntu-rootfs.tar.gz"
        $distroPath = Join-Path $wslDir $Script:WSL_DISTRO

        Write-Step "下载 Ubuntu 24.04 rootfs（约 500MB）..." "start"
        try {
            Invoke-WebRequest -Uri $rootfsUrl -OutFile $rootfsFile -TimeoutSec 600
            Write-Step "下载完成" "ok"
        } catch {
            Write-Error-And-Log "rootfs 下载失败: $_"
            return $false
        }

        # 导入到自定义路径
        Write-Step "导入 Ubuntu 到 $distroPath..." "start"
        try {
            wsl --import $Script:WSL_DISTRO $distroPath $rootfsFile --version 2 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Error-And-Log "WSL 导入失败"
                return $false
            }
            Remove-Item $rootfsFile -Force -ErrorAction SilentlyContinue
            Write-Step "Ubuntu 已安装到 $wslDir" "ok"
        } catch {
            Write-Error-And-Log "WSL 导入失败: $_"
            return $false
        }
    }
    # ---- 默认路径安装（C 盘） ----
    else {
        Write-Step "正在安装 Ubuntu 24.04 LTS 到默认位置（系统盘）..." "start"
        Write-Step "提示: 使用 -WslPath 'D:\\WSL' 可安装到其他盘" "warn"
        try {
            $ubuntuOutput = wsl --install -d $Script:WSL_DISTRO 2>&1
            $exitCode = $LASTEXITCODE
            $ubuntuOutput | Out-File $LogPath -Append
            if ($exitCode -ne 0) {
                Write-Error-And-Log "WSL Ubuntu 安装失败，请手动安装: wsl --install -d Ubuntu-24.04"
                return $false
            }
        } catch {
            Write-Error-And-Log "Ubuntu 安装失败: $_"
            return $false
        }
    }

    Set-InstallState "ubuntu" "done"
    Write-Step "Ubuntu 24.04 就绪" "ok"
    return $true
}

# ---- Step 3: 引导 WSL 环境 ----

function Step-BootstrapWsl {
    Write-Step "=== Step 3: 引导 WSL 环境 ===" "start"

    if (Test-StepDone "bootstrap") {
        Write-Step "WSL 环境已初始化，跳过" "skip"
        return $true
    }

    # 在 WSL 中创建用户（如果需要）
    $existingUser = wsl -d $Script:WSL_DISTRO -- bash -c "whoami" 2>$null
    if ($existingUser -eq "root") {
        # 需要创建非 root 用户
        if ([string]::IsNullOrEmpty($UbuntuUser)) {
            $Script:WSL_USER = [System.Environment]::UserName.ToLower()
        } else {
            $Script:WSL_USER = $UbuntuUser
        }

        Write-Step "创建 Ubuntu 用户: $Script:WSL_USER" "start"

        # 生成随机密码（12 位，含大小写和数字）
        $chars = "abcdefghkmnpqrstuvwxyzABCDEFGHKMNPQRSTUVWXYZ23456789"
        $random = -join ((1..12) | ForEach-Object { $chars[(Get-Random -Max $chars.Length)] })
        $Script:WSL_PASSWORD = $random

        wsl -d $Script:WSL_DISTRO -u root -- bash -c "
            useradd -m -s /bin/bash $Script:WSL_USER
            echo '$Script:WSL_USER:$Script:WSL_PASSWORD' | chpasswd
            echo '$Script:WSL_USER ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$Script:WSL_USER
        " 2>&1 | Out-File $LogPath -Append

        Write-Step "用户已创建，密码已自动生成" "ok"
    } else {
        $Script:WSL_USER = $existingUser.Trim()
    }

    # 拷贝 bootstrap 脚本到 WSL
    $bootstrapScript = Join-Path $PSScriptRoot "wsl-bootstrap.sh"
    $mirrorScript = Join-Path $PSScriptRoot "setup-mirrors.sh"
    $systemdScript = Join-Path $PSScriptRoot "setup-systemd.sh"

    if (Test-Path $bootstrapScript) {
        $wslPath = "\\wsl$\$Script:WSL_DISTRO\tmp\bootstrap.sh"
        Copy-Item $bootstrapScript -Destination $wslPath -Force
    }
    if (Test-Path $mirrorScript) {
        Copy-Item $mirrorScript -Destination "\\wsl$\$Script:WSL_DISTRO\tmp\setup-mirrors.sh" -Force
    }
    if (Test-Path $systemdScript) {
        Copy-Item $systemdScript -Destination "\\wsl$\$Script:WSL_DISTRO\tmp\setup-systemd.sh" -Force
    }

    # 运行镜像源配置
    Write-Step "配置国内镜像源..." "start"
    if (Test-Path $mirrorScript) {
        $mirrorOutput = wsl -d $Script:WSL_DISTRO -u root -- bash /tmp/setup-mirrors.sh 2>&1
        $exitCode = $LASTEXITCODE
        $mirrorOutput | Out-File $LogPath -Append
        if ($exitCode -ne 0) {
            Write-Step "镜像源配置部分失败，继续安装" "warn"
        }
    }

    Set-InstallState "bootstrap" "done"
    Write-Step "WSL 环境初始化完成" "ok"
    return $true
}

# ---- Step 4: 安装 Hermes Agent ----

function Step-InstallHermes {
    Write-Step "=== Step 4: 安装 Hermes Agent ===" "start"

    if (Test-StepDone "hermes") {
        Write-Step "Hermes 已安装，跳过" "skip"
        return $true
    }

    # 构造 WSL 内安装命令（全部从自建 CDN 下载，零外部依赖）
    $installScript = @"
#!/bin/bash
set -e

echo "[Hermes] 开始安装..."
export HOME=/home/$Script:WSL_USER
CDN="$($Script:CDN_BASE)"

# 安装基础依赖（apt 走清华镜像，已在 setup-mirrors.sh 中配置）
sudo apt-get update -qq
sudo apt-get install -y -qq python3 python3-pip python3-venv curl

# 从 CDN 下载安装脚本并执行
echo "[Hermes] 从 CDN 下载安装脚本..."
curl -fsSL "\$CDN/hermes-install-standalone.sh" -o /tmp/hermes-install.sh

# 下载校验文件并验证完整性
echo "[Hermes] 验证文件完整性..."
curl -fsSL "\$CDN/files.sha256" -o /tmp/files.sha256
if ! grep -q "hermes-install-standalone.sh" /tmp/files.sha256; then
    echo "[Hermes] 校验文件无效，中止安装"
    exit 1
fi
pushd /tmp > /dev/null
if ! sha256sum -c files.sha256 --ignore-missing 2>/dev/null; then
    pushd /tmp > /dev/null
    if ! sha256sum --check files.sha256 --ignore-missing 2>/dev/null; then
        echo "[Hermes] 文件校验失败！可能被篡改或下载损坏"
        echo "[Hermes] 请重新运行安装脚本"
        exit 1
    fi
    popd > /dev/null
fi
popd > /dev/null
echo "[Hermes] 校验通过"

bash /tmp/hermes-install.sh

echo "[Hermes] Done."
"@

    $hermesOutput = $installScript | wsl -d $Script:WSL_DISTRO -u $Script:WSL_USER -- bash -s 2>&1
    $exitCode = $LASTEXITCODE
    $hermesOutput | Out-File $LogPath -Append

    if ($exitCode -ne 0) {
        Write-Error-And-Log "Hermes 安装失败"
        return $false
    }

    Set-InstallState "hermes" "done"
    Write-Step "Hermes Agent 安装完成" "ok"
    return $true
}

# ---- Step 5: 安装 hermes-web-ui ----

function Step-InstallWebUi {
    Write-Step "=== Step 5: 安装 hermes-web-ui ===" "start"

    if (Test-StepDone "webui") {
        Write-Step "hermes-web-ui 已安装，跳过" "skip"
        return $true
    }

    $webUiScript = @"
#!/bin/bash
set -e
export HOME=/home/$Script:WSL_USER
export NVM_DIR="\$HOME/.nvm"
CDN="$($Script:CDN_BASE)"

echo "[WebUI] 安装 Node.js..."
curl -fsSL "\$CDN/setup-node22.x" | sudo -E bash -
sudo apt-get install -y nodejs

echo "[WebUI] 配置 npm 镜像..."
npm config set registry $($Script:MIRRORS['npm'])

echo "[WebUI] 安装 hermes-web-ui..."
npm install -g hermes-web-ui

echo "[WebUI] Done."
"@

    $webUiOutput = $webUiScript | wsl -d $Script:WSL_DISTRO -u $Script:WSL_USER -- bash -s 2>&1
    $exitCode = $LASTEXITCODE
    $webUiOutput | Out-File $LogPath -Append

    if ($exitCode -ne 0) {
        Write-Error-And-Log "hermes-web-ui 安装失败"
        return $false
    }

    Set-InstallState "webui" "done"
    Write-Step "hermes-web-ui 安装完成" "ok"
    return $true
}

# ---- Step 5.5: 集成桌面增强功能 ----

function Step-IntegrateDesktop {
    Write-Step "=== Step 5.5: 集成桌面增强功能 ===" "start"

    if (Test-StepDone "integrate") {
        Write-Step "桌面功能已集成，跳过" "skip"
        return $true
    }

    # 拷贝 Phase 3 文件到 WSL
    $desktopDir = Join-Path $PSScriptRoot "..\desktop"

    # Chat API
    $chatSrc = Join-Path $desktopDir "chat\server\chat-endpoint.js"
    if (Test-Path $chatSrc) {
        Copy-Item $chatSrc -Destination "\\wsl$\$Script:WSL_DISTRO\tmp\chat-endpoint.js" -Force
    }

    # Vue 组件
    $chatVue = Join-Path $desktopDir "chat\client\ChatPage.vue"
    $approvalVue = Join-Path $desktopDir "hitl\client\ApprovalPanel.vue"
    $toolHubVue = Join-Path $desktopDir "mcp\ToolHub.vue"

    if (Test-Path $chatVue) {
        Copy-Item $chatVue -Destination "\\wsl$\$Script:WSL_DISTRO\tmp\ChatPage.vue" -Force
    }
    if (Test-Path $approvalVue) {
        Copy-Item $approvalVue -Destination "\\wsl$\$Script:WSL_DISTRO\tmp\ApprovalPanel.vue" -Force
    }
    if (Test-Path $toolHubVue) {
        Copy-Item $toolHubVue -Destination "\\wsl$\$Script:WSL_DISTRO\tmp\ToolHub.vue" -Force
    }

    # Approval WebSocket
    $approvalSrc = Join-Path $desktopDir "hitl\server\approval-ws.js"
    if (Test-Path $approvalSrc) {
        Copy-Item $approvalSrc -Destination "\\wsl$\$Script:WSL_DISTRO\tmp\approval-ws.js" -Force
    }

    # 拷贝并执行集成脚本
    $integrateScript = Join-Path $PSScriptRoot "integrate-desktop.sh"
    if (Test-Path $integrateScript) {
        Copy-Item $integrateScript -Destination "\\wsl$\$Script:WSL_DISTRO\tmp\integrate-desktop.sh" -Force
        Write-Step "正在注入桌面增强模块..." "start"
        $integrateOutput = wsl -d $Script:WSL_DISTRO -u root -- bash /tmp/integrate-desktop.sh $Script:WSL_USER 2>&1
        $exitCode = $LASTEXITCODE
        $integrateOutput | Out-File $LogPath -Append
        if ($exitCode -ne 0) {
            Write-Step "部分集成失败，基础功能仍可用" "warn"
        } else {
            Write-Step "Agent Chat + 审批面板 + Tool Hub 已集成" "ok"
        }
    } else {
        Write-Step "集成脚本未找到，跳过桌面功能" "warn"
    }

    Set-InstallState "integrate" "done"
    return $true
}

# ---- Step 6: 配置开机自启 ----

function Step-SetupAutoStart {
    Write-Step "=== Step 6: 配置开机自启 ===" "start"

    if (Test-StepDone "autostart") {
        Write-Step "开机自启已配置，跳过" "skip"
        return $true
    }

    # 创建 systemd 服务
    if (Test-Path (Join-Path $PSScriptRoot "setup-systemd.sh")) {
        wsl -d $Script:WSL_DISTRO -u root -- bash -c "
            export WSL_USER=$Script:WSL_USER
            export WEB_PORT=$Script:WEB_PORT
            bash /tmp/setup-systemd.sh
        " 2>&1 | Out-File $LogPath -Append
        Write-Step "systemd 服务已创建" "ok"
    }

    # 添加 Windows 防火墙规则
    Write-Step "配置 Windows 防火墙..." "start"
    try {
        New-NetFirewallRule -DisplayName "Hermes Web UI" -Direction Inbound -LocalPort $Script:WEB_PORT -Protocol TCP -Action Allow -ErrorAction SilentlyContinue
        Write-Step "防火墙规则已添加 (端口 $Script:WEB_PORT)" "ok"
    } catch {
        Write-Step "防火墙规则添加失败（可能已存在）" "warn"
    }

    # Windows Task Scheduler 开机自启
    $taskName = "HermesAgent-StartWSL"
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if (-not $existingTask) {
        $action = New-ScheduledTaskAction -Execute "wsl.exe" -Argument "-d $Script:WSL_DISTRO -u root -- systemctl start hermes"
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force
        Write-Step "Task Scheduler 开机任务已注册" "ok"
    } else {
        Write-Step "Task Scheduler 任务已存在" "skip"
    }

    # 启动服务
    Write-Step "启动 Hermes 服务..." "start"
    $svcOutput = wsl -d $Script:WSL_DISTRO -u root -- systemctl daemon-reload 2>&1
    $svcOutput | Out-File $LogPath -Append
    $svcOutput2 = wsl -d $Script:WSL_DISTRO -u root -- systemctl enable hermes 2>&1
    $svcOutput2 | Out-File $LogPath -Append
    $svcOutput3 = wsl -d $Script:WSL_DISTRO -u root -- systemctl start hermes 2>&1
    $exitCode = $LASTEXITCODE
    $svcOutput3 | Out-File $LogPath -Append

    if ($exitCode -ne 0) {
        Write-Step "systemd 启动失败，WSL 可能未运行 systemd" "warn"
        Write-Step "请手动运行: wsl -d $Script:WSL_DISTRO -- hermes gateway" "warn"
    }

    Set-InstallState "autostart" "done"
    Write-Step "开机自启配置完成" "ok"
    return $true
}

# ---- Step 7: 健康检查 ----

function Step-HealthCheck {
    Write-Step "=== Step 7: 健康检查 ===" "start"

    Write-Step "等待服务启动..." "start"
    Start-Sleep -Seconds 10

    $maxRetries = 6
    for ($i = 1; $i -le $maxRetries; $i++) {
        try {
            $response = Invoke-WebRequest -Uri "http://localhost:$Script:WEB_PORT" -TimeoutSec 5 -UseBasicParsing
            if ($response.StatusCode -eq 200) {
                Write-Step "hermes-web-ui 响应正常 (端口 $Script:WEB_PORT)" "ok"
                return $true
            }
        } catch {
            Write-Step "等待服务就绪 ($i/$maxRetries)..." "warn"
            Start-Sleep -Seconds 5
        }
    }

    Write-Step "健康检查超时，请检查 WSL 日志" "warn"
    return $true  # 不阻断，继续
}

# =============================================================================
# 主流程
# =============================================================================

function Main {
    Clear-Host
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║     Hermes Agent Windows 一键安装程序     ║" -ForegroundColor Cyan
    Write-Host "║           Version 0.1.0                   ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

    # 检查管理员权限
    Test-Admin

    # 初始化日志
    if (Test-Path $LogPath) { Remove-Item $LogPath -Force }
    Write-Step "安装日志: $LogPath" ""
    Write-Step "开始安装 Hermes Agent..." "start"
    Write-Step "状态文件: $Script:STATE_FILE" ""

    $steps = @(
        @{Name="environment";   Fn=${function:Step-Environment};   Label="环境检测"},
        @{Name="wsl";           Fn=${function:Step-InstallWsl};    Label="安装 WSL2"},
        @{Name="ubuntu";        Fn=${function:Step-InstallUbuntu}; Label="安装 Ubuntu"},
        @{Name="bootstrap";     Fn=${function:Step-BootstrapWsl};  Label="引导 WSL 环境"},
        @{Name="hermes";        Fn=${function:Step-InstallHermes}; Label="安装 Hermes Agent"},
        @{Name="webui";         Fn=${function:Step-InstallWebUi};  Label="安装 Web UI"},
        @{Name="integrate";     Fn=${function:Step-IntegrateDesktop}; Label="集成桌面增强"},
        @{Name="autostart";     Fn=${function:Step-SetupAutoStart};Label="配置开机自启"},
        @{Name="healthcheck";   Fn=${function:Step-HealthCheck};   Label="健康检查"}
    )

    # 根据参数跳过步骤
    if ($SkipWsl) {
        $steps = $steps | Where-Object { $_.Name -ne "wsl" -and $_.Name -ne "ubuntu" }
    }

    $failedSteps = @()
    $global:InstallAborted = $false
    foreach ($step in $steps) {
        if ($global:InstallAborted) { break }
        $result = & $step.Fn
        if (-not $result) {
            $failedSteps += $step.Label
            if (-not $Unattended) {
                Write-Host ""
                $choice = Read-Host "步骤 [$($step.Label)] 失败。选择: (r)重试 (s)跳过 (q)退出"
                switch ($choice) {
                    "r" {
                        Set-InstallState $step.Name "failed"  # 清除状态以便重试
                        $result = & $step.Fn
                        if (-not $result) { $failedSteps += "$($step.Label)(重试仍失败)" }
                    }
                    "s" {
                        Write-Step "已跳过: $($step.Label)" "skip"
                        continue
                    }
                    "q" { $global:InstallAborted = $true; break }
                }
            }
        }
    }

    # 安装完成
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║          安装完成！                       ║" -ForegroundColor Green
    Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""

    if ($failedSteps.Count -gt 0) {
        Write-Host "部分步骤未能完成:" -ForegroundColor Yellow
        foreach ($s in $failedSteps) {
            Write-Host "  ✗ $s" -ForegroundColor Red
        }
        Write-Host ""
    }

    Write-Host "Web UI 地址:  http://localhost:$Script:WEB_PORT" -ForegroundColor Cyan
    if ($Script:WSL_PASSWORD) {
        Write-Host "Ubuntu 用户:  $Script:WSL_USER" -ForegroundColor White
        Write-Host "Ubuntu 密码:  $Script:WSL_PASSWORD" -ForegroundColor White
        Write-Host "（日常使用不需要密码，仅 sudo/ssh 时需要）" -ForegroundColor DarkGray
    }
    Write-Host "安装日志:    $LogPath" -ForegroundColor DarkGray
    Write-Host ""

    # 打开浏览器
    Write-Step "正在打开浏览器..." "start"
    Start-Process "http://localhost:$Script:WEB_PORT"

    Write-Host "按任意键退出..." -ForegroundColor DarkGray
    if (-not $Unattended) {
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
}

Main
