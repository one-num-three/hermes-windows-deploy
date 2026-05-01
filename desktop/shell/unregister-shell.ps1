# =============================================================================
# Hermes 右键菜单注销脚本
# 用法: .\unregister-shell.ps1
# =============================================================================

Write-Host "=== 移除 Hermes 右键菜单 ===" -ForegroundColor Yellow

$keysToRemove = @(
    "HKCR:\*\shell\HermesAgent",
    "HKCR:\Directory\shell\HermesAgent",
    "HKCR:\Directory\Background\shell\HermesAgent"
)

foreach ($key in $keysToRemove) {
    if (Test-Path $key) {
        Remove-Item -Path $key -Recurse -Force
        Write-Host "  已移除: $key" -ForegroundColor Green
    } else {
        Write-Host "  不存在: $key" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "右键菜单已清除" -ForegroundColor Green
Write-Host "需要重启资源管理器才能看到效果" -ForegroundColor DarkGray
