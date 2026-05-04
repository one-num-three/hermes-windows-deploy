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

function Write-ConsoleLine {
    param(
        [string]$Text,
        [string]$Color = "White"
    )

    if ($Unattended) {
        return
    }

    try {
        Write-Host $Text -ForegroundColor $Color
    } catch {
        # In headless or partially initialized hosts, console color APIs can fail or hang.
        # Fall back to plain output only for interactive runs.
        try {
            [Console]::WriteLine($Text)
        } catch {
            # Ignore console write failures; the log file remains the source of truth.
        }
    }
}

function Normalize-ExternalOutputLine {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    $text = $text -replace "`0", ""
    $text = $text -replace "[\x00-\x08\x0B\x0C\x0E-\x1F]", ""
    $text = $text.TrimEnd()

    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    return $text
}

function Join-ProcessArguments {
    param([string[]]$Arguments)

    return (($Arguments | ForEach-Object {
        if ($_ -match '[\s"]') {
            '"' + ($_ -replace '"', '\"') + '"'
        } else {
            $_
        }
    }) -join ' ')
}

function Invoke-ProcessWithTimeout {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [int]$TimeoutSeconds = 60,
        [string]$Label = "process",
        [switch]$IgnoreExitCode
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    $psi.Arguments = Join-ProcessArguments -Arguments $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi

    try {
        [void]$process.Start()

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try {
                $process.Kill()
                $process.WaitForExit()
            } catch {
                # Ignore kill failures while timing out.
            }

            $message = "$Label timed out after ${TimeoutSeconds}s."
            Append-LogLine -Text ("{0} [ ! ] {1}" -f (Get-Date -Format "HH:mm:ss"), $message)
            return [PSCustomObject]@{
                TimedOut = $true
                ExitCode = -1
                Output   = @($message)
            }
        }

        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $output = @()
        if ($stdout) { $output += ($stdout -split "[`r`n]+") }
        if ($stderr) { $output += ($stderr -split "[`r`n]+") }

        $normalized = $output |
            ForEach-Object { Normalize-ExternalOutputLine $_ } |
            Where-Object { $_ }

        foreach ($line in $normalized) {
            Append-LogLine -Text $line
        }

        if (-not $IgnoreExitCode -and $process.ExitCode -ne 0) {
            throw "$Label failed with exit code $($process.ExitCode)."
        }

        return [PSCustomObject]@{
            TimedOut = $false
            ExitCode = $process.ExitCode
            Output   = @($normalized)
        }
    } finally {
        $process.Dispose()
    }
}

function Restart-WindowsServiceWithTimeout {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$TimeoutSeconds = 45
    )

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Step "Windows service $Name was not found." "warn"
        return
    }

    try {
        if ($service.Status -eq "Running") {
            Restart-Service -Name $Name -Force -ErrorAction Stop
        } else {
            Start-Service -Name $Name -ErrorAction Stop
        }
    } catch {
        Write-Step "Could not request restart for ${Name}: $($_.Exception.Message)" "warn"
        return
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Seconds 1
        $service.Refresh()
        if ($service.Status -eq "Running") {
            Write-Step "Windows service $Name is running again." "info"
            return
        }
    } while ((Get-Date) -lt $deadline)

    Write-Step "Windows service $Name did not reach Running state within ${TimeoutSeconds}s." "warn"
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

    Write-ConsoleLine -Text $line -Color $color
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
        $output |
            ForEach-Object { Normalize-ExternalOutputLine $_ } |
            Where-Object { $_ } |
            ForEach-Object { Append-LogLine -Text $_ }
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
    $unixContent = $Content -replace "`r`n", "`n"
    $unixContent = $unixContent -replace "`r", "`n"
    [System.IO.File]::WriteAllText($tempFile, $unixContent, $utf8NoBom)
    $stdoutPath = Join-Path $env:TEMP ("hermes-" + [guid]::NewGuid().ToString() + ".stdout.log")
    $stderrPath = Join-Path $env:TEMP ("hermes-" + [guid]::NewGuid().ToString() + ".stderr.log")
    try {
        Write-Step "Invoke-WslScript BEGIN temp=$tempFile user=$User" "info"
        $wslPath = Convert-ToWslPath $tempFile
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $Script:WslExe
        $psi.Arguments = Join-ProcessArguments -Arguments @("-d", $Script:WslDistro, "-u", $User, "--", "bash", $wslPath)
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true

        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $psi
        [void]$process.Start()
        Write-Step "Invoke-WslScript launched pid=$($process.Id) wslPath=$wslPath" "info"

        $output = New-Object System.Collections.Generic.List[string]
        $syncRoot = New-Object object
        $onLine = {
            param([string]$Line)
            $normalized = Normalize-ExternalOutputLine $Line
            if ($normalized) {
                Append-LogLine -Text $normalized
                [System.Threading.Monitor]::Enter($syncRoot)
                try {
                    [void]$output.Add($normalized)
                } finally {
                    [System.Threading.Monitor]::Exit($syncRoot)
                }
            }
        }

        Write-Step "Invoke-WslScript attaching stdout/stderr readers for pid=$($process.Id)" "info"
        $stdoutTask = [System.Threading.Tasks.Task]::Run([Action]{
            try {
                while (($line = $process.StandardOutput.ReadLine()) -ne $null) {
                    & $onLine $line
                }
            } catch {
                & $onLine ("[reader] stdout exception: " + $_.Exception.Message)
            }
        })
        $stderrTask = [System.Threading.Tasks.Task]::Run([Action]{
            try {
                while (($line = $process.StandardError.ReadLine()) -ne $null) {
                    & $onLine $line
                }
            } catch {
                & $onLine ("[reader] stderr exception: " + $_.Exception.Message)
            }
        })

        $waitStartedAt = Get-Date
        while (-not $process.WaitForExit(5000)) {
            $runningFor = [int]((Get-Date) - $waitStartedAt).TotalSeconds
            Write-Step "Invoke-WslScript waiting on pid=$($process.Id) for ${runningFor}s..." "info"
        }
        $process.WaitForExit()
        try {
            [void][System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), 5000)
        } catch {
            Write-Step "Invoke-WslScript reader wait did not complete cleanly: $($_.Exception.Message)" "warn"
        }
        $exitCode = $process.ExitCode
        Write-Step "Invoke-WslScript END pid=$($process.Id) exit=$exitCode outputLines=$($output.Count)" "info"

        if (-not $IgnoreExitCode -and $exitCode -ne 0) {
            throw "WSL script failed (exit $exitCode): $tempFile"
        }
        return [PSCustomObject]@{
            ExitCode = $exitCode
            Output   = @($output)
        }
    } finally {
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        Remove-Item $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Wait-HttpReady {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$Attempts = 12,
        [int]$DelaySeconds = 5
    )

    for ($i = 1; $i -le $Attempts; $i++) {
        Write-Step "HTTP readiness probe $i/$Attempts for $Url" "info"
        try {
            $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500) {
                Write-Step "HTTP readiness probe succeeded with status $($response.StatusCode)." "ok"
                return $true
            }
        } catch {
            Write-Step "HTTP readiness probe $i/$Attempts did not succeed yet: $($_.Exception.Message)" "warn"
            Start-Sleep -Seconds $DelaySeconds
        }
    }
    Write-Step "HTTP readiness probes exhausted for $Url." "warn"
    return $false
}

function Test-WslResponsiveProbe {
    param([int]$TimeoutSeconds = 45)

    $result = Invoke-ProcessWithTimeout `
        -FilePath $Script:WslExe `
        -Arguments @("-d", $Script:WslDistro, "-u", "root", "--", "bash", "-lc", "true") `
        -TimeoutSeconds $TimeoutSeconds `
        -Label "WSL startup probe" `
        -IgnoreExitCode

    return [PSCustomObject]@{
        ExitCode = $result.ExitCode
        Output   = $result.Output
    }
}

function Get-WebUiLoginUrl {
    $tokenScript = @'
#!/bin/bash
set -e
out_file="$1"
mkdir -p /root/.hermes-web-ui
token_file="/root/.hermes-web-ui/.token"

if [ ! -f "$token_file" ] || ! tr -d '\r\n' <"$token_file" | grep -Eq '^[0-9a-f]{64}$'; then
  python3 - <<'PY' > /root/.hermes-web-ui/.token
import secrets
print(secrets.token_hex(32))
PY
  chmod 600 /root/.hermes-web-ui/.token
fi
tr -d '\r\n' <"$token_file" > "$out_file"
'@

    $tempScript = Join-Path $env:TEMP ("hermes-token-" + [guid]::NewGuid().ToString() + ".sh")
    $tempOut = Join-Path $env:TEMP ("hermes-token-" + [guid]::NewGuid().ToString() + ".txt")
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    try {
        $unixScript = $tokenScript -replace "`r`n", "`n"
        $unixScript = $unixScript -replace "`r", "`n"
        [System.IO.File]::WriteAllText($tempScript, $unixScript, $utf8NoBom)

        $scriptWsl = Convert-ToWslPath $tempScript
        $outWsl = Convert-ToWslPath $tempOut
        $output = & $Script:WslExe -d $Script:WslDistro -u root -- bash $scriptWsl $outWsl 2>&1
        $exitCode = $LASTEXITCODE
        if ($output) {
            $output |
                ForEach-Object { Normalize-ExternalOutputLine $_ } |
                Where-Object { $_ } |
                ForEach-Object { Append-LogLine -Text $_ }
        }
        if ($exitCode -ne 0) {
            Write-Step "Could not read Web UI token from WSL (exit $exitCode)." "warn"
            return "http://localhost:$Script:Port"
        }

        if (Test-Path $tempOut) {
            $raw = Get-Content -LiteralPath $tempOut -Raw -ErrorAction SilentlyContinue
            $match = [regex]::Match([string]$raw, "[0-9a-f]{64}")
            if ($match.Success) {
                return "http://localhost:$Script:Port/#/?token=$($match.Value)&lang=zh"
            }
        }
    } finally {
        Remove-Item $tempScript, $tempOut -Force -ErrorAction SilentlyContinue
    }

    Write-Step "Web UI token was not found. Falling back to plain URL." "warn"
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

    $setDefaultOutput = & $Script:WslExe --set-default-version 2 2>&1
    $setDefaultExitCode = $LASTEXITCODE
    if ($setDefaultExitCode -ne 0) {
        $setDefaultOutput |
            ForEach-Object { Normalize-ExternalOutputLine $_ } |
            Where-Object { $_ } |
            ForEach-Object { Append-LogLine -Text $_ }
        throw "Failed to set WSL default version to 2."
    }
    Write-Step "WSL default version is set to 2." "info"
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
        if ($Unattended) {
            throw "$Script:WslDistro is missing and no bundled Ubuntu image is available. Interactive 'wsl --install -d $Script:WslDistro' is disabled in unattended mode."
        }

        Write-Step "Installing $Script:WslDistro interactively..." "start"
        $installResult = Invoke-ProcessWithTimeout -FilePath $Script:WslExe -Arguments @("--install", "-d", $Script:WslDistro) -TimeoutSeconds 900 -Label "Interactive WSL distro install" -IgnoreExitCode
        if ($installResult.ExitCode -ne 0) {
            throw "Failed to install $Script:WslDistro."
        }

        throw "$Script:WslDistro was installed. If Windows asks for a restart or first-run setup, finish that first, then rerun this script."
    }

    Write-Step "$Script:WslDistro was imported." "ok"
}

function Ensure-WslResponsive {
    Write-Step "Starting WSL distro..." "start"

    $shutdownResult = Invoke-ProcessWithTimeout -FilePath $Script:WslExe -Arguments @("--shutdown") -TimeoutSeconds 20 -Label "WSL shutdown" -IgnoreExitCode
    if ($shutdownResult.TimedOut) {
        Write-Step "WSL shutdown timed out. Continuing with startup probes anyway." "warn"
    } elseif ($shutdownResult.ExitCode -ne 0) {
        Write-Step "WSL shutdown returned exit code $($shutdownResult.ExitCode). Continuing with startup probes." "warn"
    }

    for ($attempt = 1; $attempt -le 6; $attempt++) {
        Write-Step "WSL startup probe $attempt/6..." "info"
        $probeTimeout = if ($attempt -le 2) { 60 } else { 45 }
        $result = Test-WslResponsiveProbe -TimeoutSeconds $probeTimeout
        if ($result.ExitCode -eq 0) {
            Write-Step "WSL distro is ready." "ok"
            return
        }

        $outputText = ($result.Output | Out-String)
        if ($outputText -match "HCS_E_SERVICE_NOT_AVAILABLE") {
            Write-Step "WSL backend is not ready yet. Restarting WSL services (attempt $attempt/6)..." "warn"
            foreach ($serviceName in @("WSLService", "vmcompute")) {
                Restart-WindowsServiceWithTimeout -Name $serviceName -TimeoutSeconds 45
            }
        } elseif ($result.ExitCode -eq -1) {
            Write-Step "WSL startup probe $attempt/6 timed out after ${probeTimeout}s. Retrying..." "warn"
        } else {
            Write-Step "WSL startup attempt $attempt/6 failed. Retrying..." "warn"
        }

        $delay = [Math]::Min(3 * $attempt, 15)
        Write-Step "Waiting ${delay}s before the next WSL probe..." "info"
        Start-Sleep -Seconds $delay
    }

    throw "WSL did not become responsive. If this happened right after a reboot, wait 15-30 seconds and run the installer again."
}

function Install-HermesStack {
    Write-Step "Installing Hermes core and hermes-web-ui..." "start"
    Write-Step "Install-HermesStack: preparing WSL installer script..." "info"

    $installScript = @'
#!/bin/bash
set -euo pipefail
trap 'echo "FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
export DEBIAN_FRONTEND=noninteractive

INSTALL_ROOT="/opt/hermes"
AGENT_DIR="$INSTALL_ROOT/hermes-agent"
WEBUI_DIR="$INSTALL_ROOT/hermes-web-ui"
DATA_DIR="/root/.hermes"

echo "[hermes-stack] BEGIN"
echo "[hermes-stack] INSTALL_ROOT=$INSTALL_ROOT"

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

echo "[hermes-stack] checking installed state"

hermes_ready=0
webui_ready=0

if is_hermes_installed; then
  hermes_ready=1
fi

if is_webui_installed; then
  webui_ready=1
fi

if [ "$hermes_ready" = "1" ]; then
  echo "Hermes core already installed, skipping reinstall."
fi

if [ "$webui_ready" = "1" ]; then
  echo "Hermes Web UI already installed, skipping reinstall."
fi

if [ "$hermes_ready" = "1" ] && [ "$webui_ready" = "1" ]; then
  echo "Hermes runtime is already present. Skipping package install steps."
  echo "[hermes-stack] END early-skip"
  exit 0
fi

echo "[hermes-stack] package install path entered"

if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
  sed -i 's|http://archive.ubuntu.com/ubuntu/|https://mirrors.tuna.tsinghua.edu.cn/ubuntu/|g' /etc/apt/sources.list.d/ubuntu.sources || true
  sed -i 's|http://security.ubuntu.com/ubuntu/|https://mirrors.tuna.tsinghua.edu.cn/ubuntu/|g' /etc/apt/sources.list.d/ubuntu.sources || true
fi

apt-get update
apt-get install -y ca-certificates curl git python3 python3-pip python3-venv build-essential
echo "[hermes-stack] base packages ready"

if ! command -v node >/dev/null 2>&1 || ! node --version 2>/dev/null | grep -Eq '^v2(3|4)\.'; then
  if [ -f "__NODE_SETUP__" ]; then
    bash "__NODE_SETUP__"
  else
    curl -fsSL "__NODE_SETUP__" | bash -
  fi
  apt-get install -y nodejs
fi
echo "[hermes-stack] node ready"

mkdir -p "$INSTALL_ROOT" "$DATA_DIR" /var/log/hermes
echo "[hermes-stack] directories ready"

if [ "$hermes_ready" = "1" ]; then
  echo "Hermes core install step skipped."
else
  echo "[hermes-stack] installing Hermes core"
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
echo "[hermes-stack] Hermes core ready"

if [ "$webui_ready" = "1" ]; then
  echo "Hermes Web UI install step skipped."
else
  echo "[hermes-stack] installing Hermes Web UI"
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
echo "[hermes-stack] Hermes Web UI ready"
echo "[hermes-stack] END"
'@
    $nodeSetupSource = if ($Script:NodeSetupPath -and (Test-Path $Script:NodeSetupPath)) { Convert-ToWslPath $Script:NodeSetupPath } else { $Script:NodeSetupUrl }
    $installScript = $installScript.Replace('__HERMES_ARCHIVE__', $Script:HermesArchiveUrl).Replace('__HERMES_ARCHIVE_FALLBACK__', $Script:HermesArchiveFallbackUrl).Replace('__WEBUI_ARCHIVE__', $Script:WebUiArchiveUrl).Replace('__WEBUI_ARCHIVE_FALLBACK__', $Script:WebUiArchiveFallbackUrl).Replace('__NODE_SETUP__', $nodeSetupSource)
    Write-Step "Install-HermesStack: WSL script prepared, invoking..." "info"
    $installResult = Invoke-WslScript -Content $installScript
    Write-Step "Install-HermesStack: WSL script returned exit=$($installResult.ExitCode) lines=$($installResult.Output.Count)" "info"
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
    $action = New-ScheduledTaskAction -Execute $Script:WslExe -Argument "-d $Script:WslDistro -u root -- /usr/local/bin/hermes-start $Script:Port"
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Days 3650)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Step "Startup task was registered or updated." "ok"
}

function Test-WindowsHermesHelperRunning {
    $escapedDistro = [regex]::Escape($Script:WslDistro)
    $processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -ieq "wsl.exe" -and
            $_.CommandLine -match $escapedDistro -and
            $_.CommandLine -match "/usr/local/bin/hermes-start"
        }

    return [bool]$processes
}

function Stop-WindowsHermesHelpers {
    $escapedDistro = [regex]::Escape($Script:WslDistro)
    $processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -ieq "wsl.exe" -and
            $_.CommandLine -match $escapedDistro -and
            $_.CommandLine -match "/usr/local/bin/hermes-start"
        }

    foreach ($process in $processes) {
        try {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
            Write-Step "Stopped stale Windows WSL foreground helper pid=$($process.ProcessId)." "info"
        } catch {
            Write-Step "Could not stop stale WSL helper pid=$($process.ProcessId): $($_.Exception.Message)" "warn"
        }
    }
}

function Start-WindowsHermesHelper {
    if (Test-WindowsHermesHelperRunning) {
        Write-Step "Windows WSL foreground helper is already running." "skip"
        return
    }

    Write-Step "Launching Windows WSL foreground helper to keep Hermes alive..." "info"
    $args = @("-d", $Script:WslDistro, "-u", "root", "--", "/usr/local/bin/hermes-start", "$Script:Port")
    Start-Process -FilePath $Script:WslExe -ArgumentList $args -WindowStyle Hidden | Out-Null
}

function Start-HermesNow {
    Write-Step "Starting Hermes services..." "start"

    $targetUrl = "http://127.0.0.1:$Script:Port"
    Start-WindowsHermesHelper

    Write-Step "Checking whether Hermes is already reachable before restart..." "info"
    if (Wait-HttpReady -Url $targetUrl -Attempts 2 -DelaySeconds 1) {
        Write-Step "Hermes is already reachable at $targetUrl. Skipping restart to avoid interrupting the Web UI." "ok"
        return
    }

    Write-Step "Hermes is not reachable yet. Restarting foreground helper..." "info"
    Stop-WindowsHermesHelpers
    Invoke-WslCommand -Command "hermes-web-ui stop >/dev/null 2>&1 || true; pkill -f 'hermes-start|hermes-web-ui|hermes dashboard|dist/server/index|vite --host --port $Script:Port' || true; fuser -k $Script:Port/tcp >/dev/null 2>&1 || true" -IgnoreExitCode | Out-Null
    Start-Sleep -Seconds 2
    Start-WindowsHermesHelper

    $ready = Wait-HttpReady -Url $targetUrl
    if (-not $ready) {
        Invoke-WslCommand -Command "tail -n 50 /var/log/hermes-start.log || true; tail -n 50 /var/log/hermes/webui.log || true; tail -n 50 /root/.hermes-web-ui/server.log || true" -IgnoreExitCode | Out-Null
        throw "Hermes did not become reachable at $targetUrl"
    }

    Write-Step "Hermes is reachable at $targetUrl" "ok"
}

function Save-State {
    param([string]$Url)

    if (-not (Test-Path $Script:StateDir)) {
        New-Item -ItemType Directory -Path $Script:StateDir -Force | Out-Null
    }

    $state = [PSCustomObject]@{
        distro = $Script:WslDistro
        port   = $Script:Port
        url    = $Url
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

    $loginUrl = Get-WebUiLoginUrl
    Save-State -Url $loginUrl
    Write-Step "Install completed successfully." "ok"
    Write-Step "Open URL: $loginUrl" "info"
    if (-not $Unattended) {
        Start-Process $loginUrl
    }

    if (-not $Unattended) {
        Write-ConsoleLine -Text ""
        Write-ConsoleLine -Text "Open: $loginUrl" -Color Cyan
        Write-ConsoleLine -Text "Press Enter to exit."
        [void](Read-Host)
    }
}

try {
    Import-ReleaseConfig
    Main
} catch {
    $errMsg = $_.Exception.Message
    $errStack = $_.ScriptStackTrace
    Append-LogLine -Text "$(Get-Date -Format HH:mm:ss) [ERR] $errMsg"
    if ($errStack) {
        Append-LogLine -Text "$errStack"
    }
    Write-ConsoleLine -Text "$(Get-Date -Format HH:mm:ss) [ERR] $errMsg" -Color Red
    Write-ConsoleLine -Text "$errStack" -Color Red
    Write-ConsoleLine -Text ""
    Write-ConsoleLine -Text "Install failed. See log: $LogPath" -Color Red
    if (-not $Unattended) {
        Read-Host "Press Enter to exit. Log saved to $LogPath"
    }
    exit 1
}
