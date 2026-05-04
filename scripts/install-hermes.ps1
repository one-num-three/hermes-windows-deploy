param(
    [switch]$Unattended,
    [switch]$SkipWsl,
    [string]$ConfigPath,
    [ValidatePattern("^[a-z_][a-z0-9_-]*$")]
    [string]$UbuntuUser = "hermes",
    [ValidatePattern("^\d{1,5}$")]
    [string]$Port = "8648",
    [ValidatePattern("^[A-Za-z0-9_.-]+$")]
    [string]$WslDistro = "Ubuntu-24.04",
    [string]$LogPath = "$([Environment]::GetFolderPath('UserProfile'))\hermes-install.log"
)

$ErrorActionPreference = "Stop"

# 尽早开始记录，确保任何崩溃都有日志
$_earlyLog = if ($LogPath) { $LogPath } else { "$env:USERPROFILE\hermes-install.log" }
try { Start-Transcript -Path $_earlyLog -Append -Force | Out-Null } catch {}


function Resolve-WslExePath {
    $candidates = @(
        "C:\Program Files\WSL\wsl.exe",
        "$env:WINDIR\System32\wsl.exe",
        "$env:WINDIR\Sysnative\wsl.exe"
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) {
            return $candidate
        }
    }

    $command = Get-Command "wsl.exe" -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    return $null
}

$Script:ProjectRoot = $PSScriptRoot
$Script:RepoRoot = Split-Path $PSScriptRoot -Parent
$Script:ConfigPath = if ($ConfigPath) { $ConfigPath } else { Join-Path $Script:RepoRoot "config\release.json" }
$Script:Port = [int]$Port
$Script:WslDistro = $WslDistro
$Script:UbuntuUser = $UbuntuUser
$Script:CdnBase = "http://121.40.165.216/hermes-cdn/files"
$Script:HermesArchiveUrl = "$Script:CdnBase/hermes-agent.tar.gz"
$Script:HermesArchiveFallbackUrl = "https://github.com/NousResearch/hermes-agent/archive/refs/heads/main.tar.gz"
$Script:WebUiArchiveUrl = "$Script:CdnBase/hermes-web-ui.tgz"
$Script:WebUiArchiveFallbackUrl = "https://github.com/EKKOLearnAI/hermes-web-ui/archive/refs/heads/main.tar.gz"
$Script:WslMsiUrl = "$Script:CdnBase/wsl.2.6.3.0.x64.msi"
$Script:WslKernelMsiUrl = "$Script:CdnBase/wsl_update_x64.msi"
$Script:UbuntuImageUrl = "$Script:CdnBase/ubuntu-noble-wsl-amd64.wsl"
$Script:StateDir = "$env:USERPROFILE\.hermes"
$Script:StateFile = Join-Path $Script:StateDir "install-state.json"
$Script:WslExe = Resolve-WslExePath
$Script:CacheDir = Join-Path $Script:ProjectRoot "_cache"
$Script:NodeSetupUrl = "https://deb.nodesource.com/setup_23.x"
$Script:WslMsiPath = $null
$Script:WslKernelMsiPath = $null
$Script:UbuntuImagePath = $null
$Script:NodeSetupPath = $null
$Script:PortWasExplicit = $PSBoundParameters.ContainsKey("Port")
$Script:DistroWasExplicit = $PSBoundParameters.ContainsKey("WslDistro")

function Append-LogLine {
    param([string]$Text)

    $logDir = Split-Path $LogPath -Parent
    if ($logDir -and -not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($LogPath, $Text + [Environment]::NewLine, $utf8NoBom)
}

function Invoke-DownloadWithProgress {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $parent = Split-Path $Destination -Parent
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $tempPath = "$Destination.download"
    $handler = New-Object System.Net.Http.HttpClientHandler
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromMinutes(30)

    $response = $null
    $responseStream = $null
    $fileStream = $null

    try {
        $response = $client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $response.EnsureSuccessStatusCode()

        $totalBytes = $response.Content.Headers.ContentLength
        $responseStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $fileStream = [System.IO.File]::Open($tempPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)

        $buffer = New-Object byte[] 1048576
        $downloadedBytes = 0L
        $lastPercent = -1

        while (($read = $responseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $fileStream.Write($buffer, 0, $read)
            $downloadedBytes += $read

            if ($totalBytes -and $totalBytes -gt 0) {
                $percent = [int][Math]::Floor(($downloadedBytes * 100.0) / $totalBytes)
                if ($percent -ge ($lastPercent + 5) -or $percent -eq 100) {
                    Write-Progress -Activity $Label -Status "$percent% ($([math]::Round($downloadedBytes / 1MB, 1)) / $([math]::Round($totalBytes / 1MB, 1)) MB)" -PercentComplete $percent
                    Append-LogLine -Text ("{0} [   ] {1} {2}% ({3} / {4} MB)" -f (Get-Date -Format "HH:mm:ss"), $Label, $percent, [math]::Round($downloadedBytes / 1MB, 1), [math]::Round($totalBytes / 1MB, 1))
                    $lastPercent = $percent
                }
            }
        }

        Write-Progress -Activity $Label -Completed
        Move-Item $tempPath $Destination -Force
    } finally {
        if ($fileStream) { $fileStream.Dispose() }
        if ($responseStream) { $responseStream.Dispose() }
        if ($response) { $response.Dispose() }
        if ($client) { $client.Dispose() }
        Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
    }
}

function Resolve-LocalPath {
    param([string]$RelativeOrAbsolutePath)

    if (-not $RelativeOrAbsolutePath) {
        return $null
    }

    if ([System.IO.Path]::IsPathRooted($RelativeOrAbsolutePath)) {
        return $RelativeOrAbsolutePath
    }

    return Join-Path $Script:RepoRoot $RelativeOrAbsolutePath
}

function Resolve-AssetSource {
    param(
        [string]$RelativePath,
        [string]$RemoteUrl
    )

    $localPath = Resolve-LocalPath $RelativePath
    if ($localPath -and (Test-Path $localPath)) {
        return Convert-ToWslPath $localPath
    }

    return $RemoteUrl
}

function Ensure-StateDirectory {
    if (-not (Test-Path $Script:StateDir)) {
        New-Item -ItemType Directory -Path $Script:StateDir -Force | Out-Null
    }
}

function Get-OrDownload-Asset {
    param(
        [string]$PreferredPath,
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string]$Url
    )

    if ($PreferredPath -and (Test-Path $PreferredPath)) {
        return $PreferredPath
    }

    Ensure-StateDirectory
    $downloadPath = Join-Path $Script:StateDir $FileName
    if (Test-Path $downloadPath) {
        return $downloadPath
    }

    Write-Step "Downloading $FileName from CDN..." "start"
    Invoke-DownloadWithProgress -Url $Url -Destination $downloadPath -Label "Downloading $FileName"
    Write-Step "$FileName downloaded." "ok"
    return $downloadPath
}

function Import-ReleaseConfig {
    if (-not (Test-Path $Script:ConfigPath)) {
        return
    }

    $config = Get-Content $Script:ConfigPath -Raw | ConvertFrom-Json
    if ($config.cdnBase) {
        $Script:CdnBase = $config.cdnBase
        $Script:HermesArchiveUrl = "$Script:CdnBase/hermes-agent.tar.gz"
        $Script:WebUiArchiveUrl = "$Script:CdnBase/hermes-web-ui.tgz"
        $Script:WslMsiUrl = "$Script:CdnBase/wsl.2.6.3.0.x64.msi"
        $Script:WslKernelMsiUrl = "$Script:CdnBase/wsl_update_x64.msi"
        $Script:UbuntuImageUrl = "$Script:CdnBase/ubuntu-noble-wsl-amd64.wsl"
    }
    if ($config.port -and -not $Script:PortWasExplicit) {
        $Script:Port = [int]$config.port
    }
    if ($config.distro -and -not $Script:DistroWasExplicit) {
        $Script:WslDistro = [string]$config.distro
    }
    if ($config.cache) {
        $Script:HermesArchiveUrl = Resolve-AssetSource -RelativePath $config.cache.hermesArchive -RemoteUrl "$Script:CdnBase/hermes-agent.tar.gz"
        $Script:WebUiArchiveUrl = Resolve-AssetSource -RelativePath $config.cache.webUiArchive -RemoteUrl "$Script:CdnBase/hermes-web-ui.tgz"
        $Script:WslMsiPath = Resolve-LocalPath $config.cache.wslMsi
        $Script:WslKernelMsiPath = Resolve-LocalPath $config.cache.wslKernelMsi
        $Script:UbuntuImagePath = Resolve-LocalPath $config.cache.ubuntuImage
        $Script:NodeSetupPath = Resolve-LocalPath $config.cache.nodeSetup
    }
}

function Write-Step {
    param(
        [string]$Message,
        [ValidateSet("start", "ok", "warn", "error", "info", "skip")]
        [string]$Status = "info"
    )

    $timestamp = Get-Date -Format "HH:mm:ss"
    $prefix = switch ($Status) {
        "start" { "[...]" }
        "ok"    { "[OK ]" }
        "warn"  { "[ ! ]" }
        "error" { "[ERR]" }
        "skip"  { "[ ->]" }
        default { "[   ]" }
    }

    $line = "$timestamp $prefix $Message"
    $color = switch ($Status) {
        "ok"    { "Green" }
        "warn"  { "Yellow" }
        "error" { "Red" }
        "skip"  { "DarkGray" }
        default { "White" }
    }

    Write-Host $line -ForegroundColor $color
    Append-LogLine -Text $line
}

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw "Run this script from an elevated PowerShell window."
    }
}

function Convert-ToWslPath {
    param([Parameter(Mandatory = $true)][string]$WindowsPath)

    $full = [System.IO.Path]::GetFullPath($WindowsPath)
    $drive = $full.Substring(0, 1).ToLowerInvariant()
    $rest = $full.Substring(3).Replace("\", "/")
    return "/mnt/$drive/$rest"
}

function Get-WslDistros {
    $raw = & $Script:WslExe -l -q 2>$null | Out-String
    return $raw -split "[`r`n]+" |
        ForEach-Object { ($_ -replace "`0", "").Trim() } |
        Where-Object { $_ }
}

function Invoke-WslCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [string]$User = "root",
        [switch]$IgnoreExitCode
    )

    $output = & $Script:WslExe -d $Script:WslDistro -u $User -- bash -lc $Command 2>&1
    $exitCode = $LASTEXITCODE
    if ($output) {
        $output | ForEach-Object { Append-LogLine -Text ([string]$_) }
    }
    if (-not $IgnoreExitCode -and $exitCode -ne 0) {
        throw "WSL command failed (exit $exitCode): $Command"
    }
    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output   = $output
    }
}

function Invoke-WslScript {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [string]$User = "root",
        [switch]$IgnoreExitCode
    )

    $tempFile = Join-Path $env:TEMP ("hermes-" + [guid]::NewGuid().ToString() + ".sh")
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tempFile, $Content, $utf8NoBom)
    try {
        $wslPath = Convert-ToWslPath $tempFile
        $output = & $Script:WslExe -d $Script:WslDistro -u $User -- bash $wslPath 2>&1
        $exitCode = $LASTEXITCODE
        if ($output) {
            $output | ForEach-Object { Append-LogLine -Text ([string]$_) }
        }
        if (-not $IgnoreExitCode -and $exitCode -ne 0) {
            throw "WSL script failed (exit $exitCode): $tempFile"
        }
        return [PSCustomObject]@{
            ExitCode = $exitCode
            Output   = $output
        }
    } finally {
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    }
}

function Wait-HttpReady {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$Attempts = 12,
        [int]$DelaySeconds = 5
    )

    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500) {
                return $true
            }
        } catch {
            Start-Sleep -Seconds $DelaySeconds
        }
    }
    return $false
}

function Get-WebUiLoginUrl {
    $tokenScript = @'
mkdir -p /root/.hermes-web-ui
token_file="/root/.hermes-web-ui/.token"
running_token=""

if [ -f "$token_file" ]; then
  file_token=$(tr -d '\r\n' <"$token_file")
  if printf '%s' "$file_token" | grep -Eq '^[0-9a-f]{64}$'; then
    printf '%s' "$file_token"
    exit 0
  fi
fi

running_token=$(python3 - <<'PY'
from pathlib import Path

needle = b"/opt/hermes/hermes-web-ui/dist/server/index.js"
for cmdline in Path("/proc").glob("*/cmdline"):
    try:
        data = cmdline.read_bytes()
    except OSError:
        continue
    if needle not in data:
        continue

    environ = cmdline.parent / "environ"
    try:
        env_data = environ.read_bytes().split(b"\0")
    except OSError:
        continue

    for entry in env_data:
        if entry.startswith(b"AUTH_TOKEN="):
            token = entry.split(b"=", 1)[1].decode("utf-8", "ignore").strip()
            print(token)
            raise SystemExit(0)
PY
)

if printf '%s' "$running_token" | grep -Eq '^[0-9a-f]{64}$'; then
  printf '%s\n' "$running_token" > "$token_file"
  chmod 600 "$token_file"
  printf '%s' "$running_token"
  exit 0
fi

if [ ! -f "$token_file" ] || ! tr -d '\r\n' <"$token_file" | grep -Eq '^[0-9a-f]{64}$'; then
  python3 - <<'PY' > /root/.hermes-web-ui/.token
import secrets
print(secrets.token_hex(32))
PY
  chmod 600 /root/.hermes-web-ui/.token
fi
tr -d '\r\n' <"$token_file"
'@

    $result = Invoke-WslScript -Content $tokenScript -IgnoreExitCode
    $token = (($result.Output | Out-String).Trim())
    if ($token) {
        return "http://localhost:$Script:Port/#/?token=$token"
    }

    return "http://localhost:$Script:Port"
}

function Ensure-WslInstalled {
    Write-Step "Checking WSL..." "start"

    if (-not $Script:WslExe) {
        if ($SkipWsl) {
            throw "WSL executable was not found and -SkipWsl was provided."
        }

        $resolvedWslMsi = Get-OrDownload-Asset -PreferredPath $Script:WslMsiPath -FileName "wsl.2.6.3.0.x64.msi" -Url $Script:WslMsiUrl
        $resolvedKernelMsi = Get-OrDownload-Asset -PreferredPath $Script:WslKernelMsiPath -FileName "wsl_update_x64.msi" -Url $Script:WslKernelMsiUrl

        Write-Step "Enabling Windows WSL and VirtualMachinePlatform features..." "start"
        $dismWsl = Start-Process -FilePath "dism.exe" -ArgumentList @("/online", "/enable-feature", "/featurename:Microsoft-Windows-Subsystem-Linux", "/all", "/norestart") -Wait -PassThru
        Write-Step "DISM WSL feature exit code: $($dismWsl.ExitCode)" "info"
        $dismVmp = Start-Process -FilePath "dism.exe" -ArgumentList @("/online", "/enable-feature", "/featurename:VirtualMachinePlatform", "/all", "/norestart") -Wait -PassThru
        Write-Step "DISM VMP feature exit code: $($dismVmp.ExitCode)" "info"

        Write-Step "Installing WSL core components from CDN..." "start"
        $msiLog = Join-Path $env:TEMP "hermes-wsl-install.log"
        $msiArgs = @("/i", $resolvedWslMsi, "/qb", "/norestart", "/l*v", $msiLog)
        $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru
        Write-Step "WSL MSI exit code: $($proc.ExitCode). MSI log: $msiLog" "info"
        if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
            throw "Failed to install WSL MSI from CDN (exit $($proc.ExitCode)). See $msiLog"
        }

        if ($resolvedKernelMsi -and (Test-Path $resolvedKernelMsi)) {
            Write-Step "Installing WSL kernel update from CDN..." "start"
            $kernelLog = Join-Path $env:TEMP "hermes-wsl-kernel.log"
            $kernelArgs = @("/i", $resolvedKernelMsi, "/qb", "/norestart", "/l*v", $kernelLog)
            $kernelProc = Start-Process -FilePath "msiexec.exe" -ArgumentList $kernelArgs -Wait -PassThru
            Write-Step "WSL kernel MSI exit code: $($kernelProc.ExitCode). MSI log: $kernelLog" "info"
            if ($kernelProc.ExitCode -ne 0 -and $kernelProc.ExitCode -ne 3010) {
                throw "Failed to install WSL kernel MSI from CDN (exit $($kernelProc.ExitCode)). See $kernelLog"
            }
        }

        $Script:WslExe = Resolve-WslExePath
        if (-not $Script:WslExe) {
            throw "WSL installation finished but wsl.exe is still unavailable. Reboot Windows, then run this script again."
        }
    }

    $wslCommand = Get-Command $Script:WslExe -ErrorAction SilentlyContinue
    if (-not $wslCommand) {
        if ($SkipWsl) {
            throw "WSL is not installed and -SkipWsl was provided."
        }

        if ($Script:WslMsiPath -and (Test-Path $Script:WslMsiPath)) {
            Write-Step "Enabling Windows WSL and VirtualMachinePlatform features..." "start"
            Start-Process -FilePath "dism.exe" -ArgumentList @("/online", "/enable-feature", "/featurename:Microsoft-Windows-Subsystem-Linux", "/all", "/norestart") -Wait | Out-Null
            Start-Process -FilePath "dism.exe" -ArgumentList @("/online", "/enable-feature", "/featurename:VirtualMachinePlatform", "/all", "/norestart") -Wait | Out-Null

            Write-Step "Installing bundled WSL package..." "start"
            $msiLog = Join-Path $env:TEMP "hermes-wsl-install.log"
            $msiArgs = @("/i", $Script:WslMsiPath, "/qb", "/norestart", "/l*v", $msiLog)
            $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru
            Write-Step "WSL MSI exit code: $($proc.ExitCode). MSI log: $msiLog" "info"
            if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
                throw "Failed to install bundled WSL MSI (exit $($proc.ExitCode)). See $msiLog"
            }
            if ($Script:WslKernelMsiPath -and (Test-Path $Script:WslKernelMsiPath)) {
                Write-Step "Installing bundled WSL kernel update..." "start"
                $kernelLog = Join-Path $env:TEMP "hermes-wsl-kernel.log"
                $kernelArgs = @("/i", $Script:WslKernelMsiPath, "/qb", "/norestart", "/l*v", $kernelLog)
                $kernelProc = Start-Process -FilePath "msiexec.exe" -ArgumentList $kernelArgs -Wait -PassThru
                Write-Step "WSL kernel MSI exit code: $($kernelProc.ExitCode). MSI log: $kernelLog" "info"
                if ($kernelProc.ExitCode -ne 0 -and $kernelProc.ExitCode -ne 3010) {
                    throw "Failed to install bundled WSL kernel update (exit $($kernelProc.ExitCode)). See $kernelLog"
                }
            }
        } else {
            Write-Step "Installing WSL core components..." "start"
            & $Script:WslExe --install --no-distribution 2>&1 | Out-File $LogPath -Append
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to install WSL."
            }
        }

        $Script:WslExe = Resolve-WslExePath
        $wslCommand = Get-Command $Script:WslExe -ErrorAction SilentlyContinue
        if (-not $wslCommand) {
            throw "WSL installation finished but wsl.exe is still unavailable. Reboot Windows, then run this script again."
        }
    }

    & $Script:WslExe --set-default-version 2 2>&1 | Out-File $LogPath -Append
    Write-Step "WSL is available." "ok"
}

function Ensure-UbuntuInstalled {
    Write-Step "Checking $Script:WslDistro..." "start"

    $distros = Get-WslDistros
    if ($distros -contains $Script:WslDistro) {
        Write-Step "$Script:WslDistro is already installed." "skip"
        return
    }

    if ($SkipWsl) {
        throw "$Script:WslDistro is missing and -SkipWsl was provided."
    }

    $resolvedUbuntuImage = $null
    if ($Script:UbuntuImagePath -and (Test-Path $Script:UbuntuImagePath)) {
        $resolvedUbuntuImage = $Script:UbuntuImagePath
    } elseif (-not $SkipWsl) {
        $resolvedUbuntuImage = Get-OrDownload-Asset -PreferredPath $null -FileName "ubuntu-noble-wsl-amd64.wsl" -Url $Script:UbuntuImageUrl
    }

    if ($resolvedUbuntuImage -and (Test-Path $resolvedUbuntuImage)) {
        $installBase = Join-Path $env:LOCALAPPDATA "HermesWSL\$Script:WslDistro"
        New-Item -ItemType Directory -Path $installBase -Force | Out-Null
        Write-Step "Importing bundled Ubuntu image..." "start"
        & $Script:WslExe --import $Script:WslDistro $installBase $resolvedUbuntuImage --version 2 2>&1 | Out-File $LogPath -Append
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to import bundled Ubuntu image for $Script:WslDistro."
        }
    } else {
        Write-Step "Installing $Script:WslDistro..." "start"
        & $Script:WslExe --install -d $Script:WslDistro 2>&1 | Out-File $LogPath -Append
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to install $Script:WslDistro."
        }

        throw "$Script:WslDistro was installed. If Windows asks for a restart or first-run setup, finish that first, then rerun this script."
    }

    Write-Step "$Script:WslDistro was imported." "ok"
}

function Ensure-WslResponsive {
    Write-Step "Starting WSL distro..." "start"

    & $Script:WslExe --shutdown 2>&1 | Out-File $LogPath -Append

    for ($attempt = 1; $attempt -le 6; $attempt++) {
        $result = Invoke-WslCommand -Command "true" -IgnoreExitCode
        if ($result.ExitCode -eq 0) {
            Write-Step "WSL distro is ready." "ok"
            return
        }

        $outputText = ($result.Output | Out-String)
        if ($outputText -match "HCS_E_SERVICE_NOT_AVAILABLE") {
            Write-Step "WSL backend is not ready yet. Restarting WSL services (attempt $attempt/6)..." "warn"
            foreach ($serviceName in @("WSLService", "vmcompute")) {
                $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
                if ($service) {
                    try {
                        if ($service.Status -eq "Running") {
                            Restart-Service -Name $serviceName -Force -ErrorAction Stop
                        } else {
                            Start-Service -Name $serviceName -ErrorAction Stop
                        }
                    } catch {
                        Write-Step "Could not restart service ${serviceName}: $($_.Exception.Message)" "warn"
                    }
                }
            }
        } else {
            Write-Step "WSL startup attempt $attempt/6 failed. Retrying..." "warn"
        }

        Start-Sleep -Seconds ([Math]::Min(3 * $attempt, 15))
    }

    throw "WSL did not become responsive. If this happened right after a reboot, wait 15-30 seconds and run the installer again."
}

function Install-HermesStack {
    Write-Step "Installing Hermes core and hermes-web-ui..." "start"

    $installScript = @'
#!/bin/bash
set -euo pipefail
trap 'echo "FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
export DEBIAN_FRONTEND=noninteractive

INSTALL_ROOT="/opt/hermes"
AGENT_DIR="$INSTALL_ROOT/hermes-agent"
WEBUI_DIR="$INSTALL_ROOT/hermes-web-ui"
DATA_DIR="/root/.hermes"

install_from_archive() {
  local name="$1"
  local target_dir="$2"
  shift 2
  local parent_dir
  local temp_dir
  local archive_path
  local source_dir
  local archive_url
  local curl_err

  parent_dir="$(dirname "$target_dir")"
  temp_dir="$(mktemp -d)"
  archive_path="$temp_dir/source.tar.gz"
  curl_err="$temp_dir/curl.err"

  mkdir -p "$parent_dir"

  if [ -d "$target_dir" ]; then
    mv "$target_dir" "${target_dir}.bak.$(date +%Y%m%d%H%M%S)"
  fi

  for archive_url in "$@"; do
    [ -n "$archive_url" ] || continue
    echo "Downloading $name archive from $archive_url"
    : > "$curl_err"
    if curl -fsSL --retry 3 --connect-timeout 20 --max-time 1800 "$archive_url" -o "$archive_path" 2>"$curl_err"; then
      break
    else
      cat "$curl_err" >&2 || true
    fi
  done
  if [ ! -s "$archive_path" ]; then
    echo "Failed to download archive for $name from all sources." >&2
    exit 1
  fi

  tar -xzf "$archive_path" -C "$temp_dir"
  source_dir="$temp_dir"

  if [ ! -f "$source_dir/pyproject.toml" ] && [ ! -f "$source_dir/setup.py" ] && [ ! -f "$source_dir/package.json" ]; then
    local child_count
    child_count="$(find "$temp_dir" -mindepth 1 -maxdepth 1 -type d | wc -l)"
    if [ "$child_count" = "1" ]; then
      local first_dir
      first_dir="$(find "$temp_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
      if [ -f "$first_dir/pyproject.toml" ] || [ -f "$first_dir/setup.py" ] || [ -f "$first_dir/package.json" ]; then
        source_dir="$first_dir"
      fi
    fi
  fi

  if [ ! -f "$source_dir/pyproject.toml" ] && [ ! -f "$source_dir/setup.py" ] && [ ! -f "$source_dir/package.json" ]; then
    echo "Archive for $name did not unpack to a recognizable project root." >&2
    find "$temp_dir" -maxdepth 2 -type f | sed -n '1,40p' >&2 || true
    exit 1
  fi

  mkdir -p "$target_dir"
  cp -a "$source_dir"/. "$target_dir"/
  rm -rf "$temp_dir"
}

is_hermes_installed() {
  [ -f "$AGENT_DIR/pyproject.toml" ] &&
  [ -d "$AGENT_DIR/venv" ] &&
  [ -x /usr/local/bin/hermes ]
}

is_webui_installed() {
  [ -f "$WEBUI_DIR/package.json" ] &&
  [ -d "$WEBUI_DIR/dist" ] &&
  command -v hermes-web-ui >/dev/null 2>&1
}

if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
  sed -i 's|http://archive.ubuntu.com/ubuntu/|https://mirrors.tuna.tsinghua.edu.cn/ubuntu/|g' /etc/apt/sources.list.d/ubuntu.sources || true
  sed -i 's|http://security.ubuntu.com/ubuntu/|https://mirrors.tuna.tsinghua.edu.cn/ubuntu/|g' /etc/apt/sources.list.d/ubuntu.sources || true
fi

apt-get update
apt-get install -y ca-certificates curl git python3 python3-pip python3-venv build-essential

if ! command -v node >/dev/null 2>&1 || ! node --version 2>/dev/null | grep -Eq '^v2(3|4)\.'; then
  if [ -f "__NODE_SETUP__" ]; then
    bash "__NODE_SETUP__"
  else
    curl -fsSL "__NODE_SETUP__" | bash -
  fi
  apt-get install -y nodejs
fi

mkdir -p "$INSTALL_ROOT" "$DATA_DIR" /var/log/hermes

if is_hermes_installed; then
  echo "Hermes core already installed, skipping reinstall."
else
  install_from_archive "Hermes core" "$AGENT_DIR" "__HERMES_ARCHIVE__" "__HERMES_ARCHIVE_FALLBACK__"

  cd "$AGENT_DIR"

  if [ ! -d venv ]; then
    python3 -m venv venv
  fi

  source venv/bin/activate
  python -m pip install --upgrade pip setuptools wheel
  pip config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple || true
  npm config set registry https://registry.npmmirror.com || true
  pip install -e .

  cat > /usr/local/bin/hermes <<'EOF'
#!/bin/bash
cd /opt/hermes/hermes-agent
source venv/bin/activate 2>/dev/null
export HERMES_HOME=/root/.hermes
exec python3 /opt/hermes/hermes-agent/hermes "$@"
EOF
  chmod +x /usr/local/bin/hermes
fi

if is_webui_installed; then
  echo "Hermes Web UI already installed, skipping reinstall."
else
  install_from_archive "Hermes Web UI" "$WEBUI_DIR" "__WEBUI_ARCHIVE__" "__WEBUI_ARCHIVE_FALLBACK__"

  if [ -d "$WEBUI_DIR/dist" ] && [ -f "$WEBUI_DIR/package.json" ]; then
    cd "$WEBUI_DIR"
    npm install --omit=dev
    npm install -g "$WEBUI_DIR"
  else
    cd "$WEBUI_DIR"
    npm install
    npm run build
    npm install -g "$WEBUI_DIR"
  fi
fi
'@
    $nodeSetupSource = if ($Script:NodeSetupPath -and (Test-Path $Script:NodeSetupPath)) { Convert-ToWslPath $Script:NodeSetupPath } else { $Script:NodeSetupUrl }
    $installScript = $installScript.Replace('__HERMES_ARCHIVE__', $Script:HermesArchiveUrl).Replace('__HERMES_ARCHIVE_FALLBACK__', $Script:HermesArchiveFallbackUrl).Replace('__WEBUI_ARCHIVE__', $Script:WebUiArchiveUrl).Replace('__WEBUI_ARCHIVE_FALLBACK__', $Script:WebUiArchiveFallbackUrl).Replace('__NODE_SETUP__', $nodeSetupSource)

    Invoke-WslScript -Content $installScript | Out-Null
    Write-Step "Hermes core and hermes-web-ui were installed." "ok"
}

function Install-StartupFiles {
    Write-Step "Syncing startup helper scripts..." "start"

    $startScriptSource = Join-Path $Script:ProjectRoot "hermes-start.sh"
    $systemdScriptSource = Join-Path $Script:ProjectRoot "setup-systemd.sh"

    if (-not (Test-Path $startScriptSource)) {
        throw "Missing helper script: $startScriptSource"
    }
    if (-not (Test-Path $systemdScriptSource)) {
        throw "Missing helper script: $systemdScriptSource"
    }

    $startScriptWsl = Convert-ToWslPath $startScriptSource
    $systemdScriptWsl = Convert-ToWslPath $systemdScriptSource

    Invoke-WslCommand -Command "cp '$startScriptWsl' /usr/local/bin/hermes-start && chmod +x /usr/local/bin/hermes-start" | Out-Null
    Invoke-WslCommand -Command "cp '$systemdScriptWsl' /usr/local/bin/setup-hermes-systemd && chmod +x /usr/local/bin/setup-hermes-systemd" | Out-Null

    $quotedUser = $Script:UbuntuUser
    $quotedPort = $Script:Port
    $systemdResult = Invoke-WslCommand -Command "WSL_USER='$quotedUser' WEB_PORT='$quotedPort' /usr/local/bin/setup-hermes-systemd" -IgnoreExitCode
    if ($systemdResult.ExitCode -ne 0) {
        Write-Step "systemd setup did not complete. CLI startup will continue without relying on systemd." "warn"
    }

    Write-Step "Startup helper scripts are in place." "ok"
}

function Configure-WindowsIntegration {
    Write-Step "Configuring Windows startup integration..." "start"

    try {
        New-NetFirewallRule -DisplayName "Hermes Web UI" -Direction Inbound -LocalPort $Script:Port -Protocol TCP -Action Allow -ErrorAction SilentlyContinue | Out-Null
    } catch {
        Write-Step "Firewall rule could not be updated. Continuing." "warn"
    }

    $taskName = "HermesAgent-StartWSL"
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if (-not $existingTask) {
        $action = New-ScheduledTaskAction -Execute $Script:WslExe -Argument "-d $Script:WslDistro -u root -- /usr/local/bin/hermes-start $Script:Port"
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        Write-Step "Startup task was registered." "ok"
    } else {
        Write-Step "Startup task already exists." "skip"
    }
}

function Start-HermesNow {
    Write-Step "Starting Hermes services..." "start"
    Invoke-WslCommand -Command "hermes-web-ui stop >/dev/null 2>&1 || true; pkill -f 'hermes-start|hermes-web-ui|hermes dashboard|vite --host --port $Script:Port' || true; fuser -k $Script:Port/tcp >/dev/null 2>&1 || true" -IgnoreExitCode | Out-Null
    Invoke-WslCommand -Command "nohup /usr/local/bin/hermes-start $Script:Port </dev/null >>/var/log/hermes/webui.log 2>&1 &" | Out-Null

    $ready = Wait-HttpReady -Url "http://localhost:$Script:Port"
    if (-not $ready) {
        Invoke-WslCommand -Command "tail -n 50 /var/log/hermes-start.log || true; tail -n 50 /var/log/hermes/webui.log || true; tail -n 50 /root/.hermes-web-ui/server.log || true" -IgnoreExitCode | Out-Null
        throw "Hermes did not become reachable at http://localhost:$Script:Port"
    }

    Write-Step "Hermes is reachable at http://localhost:$Script:Port" "ok"
}

function Save-State {
    if (-not (Test-Path $Script:StateDir)) {
        New-Item -ItemType Directory -Path $Script:StateDir -Force | Out-Null
    }

    $state = [PSCustomObject]@{
        distro = $Script:WslDistro
        port   = $Script:Port
        url    = (Get-WebUiLoginUrl)
        time   = (Get-Date).ToString("s")
    }
    $state | ConvertTo-Json | Set-Content -Path $Script:StateFile -Encoding UTF8
}

function Main {
    Write-Step "Log file: $LogPath" "info"
    Write-Step "Project root: $Script:ProjectRoot" "info"

    Assert-Admin
    Ensure-WslInstalled
    Ensure-UbuntuInstalled
    Ensure-WslResponsive
    Install-HermesStack
    Install-StartupFiles
    Configure-WindowsIntegration
    Start-HermesNow
    Save-State

    $loginUrl = Get-WebUiLoginUrl
    Write-Step "Install completed successfully." "ok"
    Write-Step "Open URL: $loginUrl" "info"
    Start-Process $loginUrl

    if (-not $Unattended) {
        Write-Host ""
        Write-Host "Open: $loginUrl" -ForegroundColor Cyan
        Write-Host "Press Enter to exit."
        [void](Read-Host)
    }
}

try {
    Import-ReleaseConfig
    Main
    Stop-Transcript | Out-Null
} catch {
    $errMsg = $_.Exception.Message
    $errStack = $_.ScriptStackTrace
    Write-Host "$(Get-Date -Format 'HH:mm:ss') [ERR] $errMsg" -ForegroundColor Red
    Write-Host "$errStack" -ForegroundColor Red
    Write-Host ""
    Write-Host "Install failed. See log: $LogPath" -ForegroundColor Red
    try { Stop-Transcript | Out-Null } catch {}
    if (-not $Unattended) {
        Read-Host "按 Enter 键退出（日志已保存至 $LogPath）"
    }
    exit 1
}
