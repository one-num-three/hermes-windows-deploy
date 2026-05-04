param(
    [string]$Version = "0.2.0",
    [ValidateSet("offline", "cdn")]
    [string]$Bundle = "offline",
    [switch]$SkipDownloads,
    [switch]$Clean
)

$ErrorActionPreference = "Stop"

$Script:ProjectRoot = Split-Path $PSScriptRoot -Parent
$Script:CacheDir = Join-Path $Script:ProjectRoot "scripts\_cache"
$Script:ReleaseRoot = Join-Path $Script:ProjectRoot "release"
$bundleLabel = if ($Bundle -eq "cdn") { "CDN" } else { "Offline" }
$Script:StageDir = Join-Path $Script:ReleaseRoot "HermesAgent-$bundleLabel-v$Version"
$Script:ZipPath = Join-Path $Script:ReleaseRoot "HermesAgent-$bundleLabel-v$Version.zip"
$Script:ConfigDir = Join-Path $Script:ProjectRoot "config"
$Script:ConfigPath = Join-Path $Script:ConfigDir "release.$Bundle.json"
$Script:DefaultConfigPath = Join-Path $Script:ConfigDir "release.json"
$Script:GuiProject = Join-Path $Script:ProjectRoot "gui\HermesInstaller\HermesInstaller.csproj"
$Script:GuiPublishDir = Join-Path $Script:ReleaseRoot ".gui-publish\$Bundle-$Version"

$assets = @(
    @{ Name = "hermes-agent.tar.gz"; Url = "http://121.40.165.216/hermes-cdn/files/hermes-agent.tar.gz" },
    @{ Name = "hermes-web-ui.tgz"; Url = "http://121.40.165.216/hermes-cdn/files/hermes-web-ui.tgz" },
    @{ Name = "wsl.2.6.3.0.x64.msi"; Url = "http://121.40.165.216/hermes-cdn/files/wsl.2.6.3.0.x64.msi" },
    @{ Name = "wsl_update_x64.msi"; Url = "http://121.40.165.216/hermes-cdn/files/wsl_update_x64.msi" },
    @{ Name = "ubuntu-noble-wsl-amd64.wsl"; Url = "http://121.40.165.216/hermes-cdn/files/ubuntu-noble-wsl-amd64.wsl" },
    @{ Name = "setup-node23.x"; Url = "https://deb.nodesource.com/setup_23.x" }
)

function Write-Step {
    param(
        [string]$Message,
        [ValidateSet("start", "ok", "warn", "error", "skip", "info")]
        [string]$Status = "info"
    )

    $prefix = switch ($Status) {
        "start" { "[...]" }
        "ok" { "[OK ]" }
        "warn" { "[ ! ]" }
        "error" { "[ERR]" }
        "skip" { "[ ->]" }
        default { "[   ]" }
    }

    $color = switch ($Status) {
        "ok" { "Green" }
        "warn" { "Yellow" }
        "error" { "Red" }
        "skip" { "DarkGray" }
        default { "White" }
    }

    Write-Host "$prefix $Message" -ForegroundColor $color
}

function Invoke-Download {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $parent = Split-Path $Destination -Parent
    if (-not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $temp = "$Destination.download"
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
        $fileStream = [System.IO.File]::Open($temp, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)

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
                    $lastPercent = $percent
                }
            }
        }

        Write-Progress -Activity $Label -Completed
        Move-Item $temp $Destination -Force
    } finally {
        if ($fileStream) { $fileStream.Dispose() }
        if ($responseStream) { $responseStream.Dispose() }
        if ($response) { $response.Dispose() }
        if ($client) { $client.Dispose() }
        Remove-Item $temp -Force -ErrorAction SilentlyContinue
    }
}

function Build-Launcher {
    Write-Step "Publishing HermesInstaller.exe..." "start"

    if (Test-Path $Script:GuiPublishDir) {
        Remove-Item $Script:GuiPublishDir -Recurse -Force
    }

    $arguments = @(
        "publish",
        $Script:GuiProject,
        "-c", "Release",
        "-r", "win-x64",
        "--self-contained", "true",
        "-p:PublishSingleFile=true",
        "-p:IncludeNativeLibrariesForSelfExtract=true",
        "-o", $Script:GuiPublishDir
    )

    & dotnet @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to publish HermesInstaller.exe"
    }

    $exePath = Join-Path $Script:GuiPublishDir "HermesInstaller.exe"
    if (-not (Test-Path $exePath)) {
        throw "HermesInstaller.exe was not created"
    }

    $sizeMb = [math]::Round((Get-Item $exePath).Length / 1MB, 1)
    Write-Step "HermesInstaller.exe published (${sizeMb} MB)." "ok"
}

function Ensure-Asset {
    param([hashtable]$Asset)

    $destination = Join-Path $Script:CacheDir $Asset.Name
    if (Test-Path $destination) {
        $sizeMb = [math]::Round((Get-Item $destination).Length / 1MB, 1)
        Write-Step "$($Asset.Name) already cached (${sizeMb} MB)." "skip"
        return
    }

    if ($SkipDownloads) {
        throw "Missing cached asset: $($Asset.Name)"
    }

    Write-Step "Downloading $($Asset.Name)..." "start"
    Invoke-Download -Url $Asset.Url -Destination $destination -Label "Downloading $($Asset.Name)"
    $sizeMb = [math]::Round((Get-Item $destination).Length / 1MB, 1)
    Write-Step "$($Asset.Name) downloaded (${sizeMb} MB)." "ok"
}

function New-ReleaseConfig {
    if (-not (Test-Path $Script:ConfigDir)) {
        New-Item -ItemType Directory -Path $Script:ConfigDir -Force | Out-Null
    }

    $notes = if ($Bundle -eq "offline") {
        @(
            "Offline release bundle for Windows 10/11 simulator testing.",
            "Installer prefers local cache first and only falls back to network when a local asset is missing."
        )
    } else {
        @(
            "CDN release bundle for Windows 10/11 installer distribution.",
            "Installer fetches runtime assets from the configured CDN base."
        )
    }

    $config = [ordered]@{
        mode = $Bundle
        cdnBase = "http://121.40.165.216/hermes-cdn/files"
        distro = "Ubuntu-24.04"
        port = 8648
        cache = if ($Bundle -eq "offline") {
            [ordered]@{
                hermesArchive = "scripts/_cache/hermes-agent.tar.gz"
                webUiArchive = "scripts/_cache/hermes-web-ui.tgz"
                wslMsi = "scripts/_cache/wsl.2.6.3.0.x64.msi"
                wslKernelMsi = "scripts/_cache/wsl_update_x64.msi"
                ubuntuImage = "scripts/_cache/ubuntu-noble-wsl-amd64.wsl"
                nodeSetup = "scripts/_cache/setup-node23.x"
            }
        } else {
            [ordered]@{
                hermesArchive = ""
                webUiArchive = ""
                wslMsi = ""
                wslKernelMsi = ""
                ubuntuImage = ""
                nodeSetup = ""
            }
        }
        notes = $notes
    }

    $json = $config | ConvertTo-Json -Depth 5
    $json | Set-Content -Path $Script:ConfigPath -Encoding UTF8
    $json | Set-Content -Path $Script:DefaultConfigPath -Encoding UTF8
    Write-Step "Wrote release config: $Script:ConfigPath" "ok"
}

function Copy-ReleaseFiles {
    if (Test-Path $Script:StageDir) {
        Remove-Item $Script:StageDir -Recurse -Force
    }

    New-Item -ItemType Directory -Path $Script:StageDir -Force | Out-Null

    $pathsToCopy = @("scripts", "docs", "desktop", "config", "README.md", ".gitattributes")
    foreach ($path in $pathsToCopy) {
        $source = Join-Path $Script:ProjectRoot $path
        if (Test-Path $source) {
            $destination = Join-Path $Script:StageDir $path
            Copy-Item $source $destination -Recurse -Force
        }
    }

    $launcherPath = Join-Path $Script:GuiPublishDir "HermesInstaller.exe"
    if (Test-Path $launcherPath) {
        Copy-Item $launcherPath (Join-Path $Script:StageDir "HermesInstaller.exe") -Force
    }

    if ($Bundle -eq "cdn") {
        $cachePath = Join-Path $Script:StageDir "scripts\_cache"
        if (Test-Path $cachePath) {
            Remove-Item $cachePath -Recurse -Force
        }
    }

    Write-Step "Copied release payload into staging directory." "ok"
}

function New-Checksums {
    $cacheRoot = Join-Path $Script:StageDir "scripts\_cache"
    if (-not (Test-Path $cacheRoot)) {
        return
    }

    $files = Get-ChildItem -Path $cacheRoot -File
    $output = @()
    foreach ($file in $files) {
        $hash = (Get-FileHash -Path $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $relative = $file.FullName.Substring($Script:StageDir.Length + 1).Replace("\", "/")
        $output += "$hash  $relative"
    }

    $checksumPath = Join-Path $Script:StageDir "files.sha256"
    $output | Set-Content -Path $checksumPath -Encoding ascii
    Write-Step "Generated checksum manifest." "ok"
}

function New-ReleaseReadme {
    $content = @'
# Hermes Agent BUNDLE Release v$Version

## What is included

- `scripts/install-hermes.ps1`: main installer entry
- `config/release.BUNDLE.json`: bundled environment config
- `docs/`: project docs
- `desktop/`: desktop integration helpers
EXTRA_ASSETS

## Simulator test steps

1. Extract this zip to a local folder.
2. Open PowerShell as Administrator.
3. Run:

```powershell
cd .\HermesAgent-BUNDLE-vVERSION
.\scripts\install-hermes.ps1
```

4. After install completes, open the URL printed by the script.

## Notes

- In `offline` bundles, the installer prefers local cache assets first.
- In `cdn` bundles, the installer downloads runtime assets from `cdnBase`.
'@
    $extraAssets = if ($Bundle -eq "offline") {
@'
- `scripts/_cache/hermes-agent.tar.gz`: Hermes core package
- `scripts/_cache/hermes-web-ui.tgz`: Hermes Web UI package
- `scripts/_cache/wsl.2.6.3.0.x64.msi`: WSL installer
- `scripts/_cache/wsl_update_x64.msi`: WSL kernel update
- `scripts/_cache/ubuntu-noble-wsl-amd64.wsl`: Ubuntu 24.04 image
- `scripts/_cache/setup-node23.x`: NodeSource bootstrap script
- `files.sha256`: asset checksum list
'@
    } else {
@'
- No bundled large runtime archives
- Uses your CDN resources from `cdnBase`
'@
    }
    $content = $content.Replace('v$Version', "v$Version").Replace("vVERSION", "v$Version").Replace("BUNDLE", $bundleLabel).Replace("EXTRA_ASSETS", $extraAssets)

    Set-Content -Path (Join-Path $Script:StageDir "RELEASE-NOTES.md") -Value $content -Encoding UTF8
    Write-Step "Wrote release notes." "ok"
}

function New-ReleaseZip {
    if (Test-Path $Script:ZipPath) {
        Remove-Item $Script:ZipPath -Force
    }

    Compress-Archive -Path (Join-Path $Script:StageDir "*") -DestinationPath $Script:ZipPath -CompressionLevel Optimal
    Write-Step "Created release zip: $Script:ZipPath" "ok"
}

function Main {
    if ($Clean) {
        Remove-Item $Script:ReleaseRoot -Recurse -Force -ErrorAction SilentlyContinue
        Write-Step "Cleaned release directory." "ok"
        return
    }

    if (-not (Test-Path $Script:CacheDir)) {
        New-Item -ItemType Directory -Path $Script:CacheDir -Force | Out-Null
    }
    if (-not (Test-Path $Script:ReleaseRoot)) {
        New-Item -ItemType Directory -Path $Script:ReleaseRoot -Force | Out-Null
    }

    Build-Launcher

    if ($Bundle -eq "offline") {
        foreach ($asset in $assets) {
            Ensure-Asset -Asset $asset
        }
    }

    New-ReleaseConfig
    Copy-ReleaseFiles
    New-Checksums
    New-ReleaseReadme
    New-ReleaseZip

    Write-Host ""
    Write-Step "Offline release is ready." "ok"
    Write-Host "Stage: $Script:StageDir"
    Write-Host "Zip:   $Script:ZipPath"
}

Main
