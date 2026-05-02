# =============================================================================
# Hermes 右键发送桥接脚本
# 注册表右键菜单调用此脚本，将文件/文件夹信息发送到 Hermes Web UI
# =============================================================================
param(
    [Parameter(Mandatory=$true)]
    [string]$FilePath,

    [string]$Action = "analyze",
    [string]$Port = "8648"
)

# 安全校验：路径合法性
if ([string]::IsNullOrWhiteSpace($FilePath) -or $FilePath.Length -gt 260) {
    Write-Host "错误: 文件路径为空或超过 260 字符" -ForegroundColor Red
    exit 1
}
# 过滤路径中的不可打印字符
$FilePath = $FilePath -replace '[\x00-\x1f]', ''

$apiUrl = "http://localhost:$Port/api/chat"

# 根据 Action 构造提示语
$prompt = switch ($Action) {
    "analyze" {
        "请分析以下文件: $FilePath"
    }
    "explain" {
        "请详细解释这个文件的内容: $FilePath"
    }
    "analyze-project" {
        "请分析这个项目的目录结构和代码: $FilePath"
    }
    "open-chat" {
        # 仅打开聊天页面
        Start-Process "http://localhost:$Port/chat"
        exit 0
    }
    default {
        "处理文件: $FilePath"
    }
}

# 检查服务是否在运行
try {
    $null = Invoke-WebRequest -Uri "http://localhost:$Port" -TimeoutSec 3 -UseBasicParsing
} catch {
    # 服务未运行，尝试启动
    Start-Process "http://localhost:$Port" -ErrorAction SilentlyContinue
    Write-Host "Hermes 服务未响应，请在 Web UI 中手动输入: $prompt" -ForegroundColor Yellow
    exit 1
}

# 发送到 Hermes Chat API
try {
    $body = @{
        message = $prompt
        source = "shell-extension"
        filePath = $FilePath
    } | ConvertTo-Json

    $response = Invoke-RestMethod -Uri $apiUrl -Method Post -Body $body `
        -ContentType "application/json" -TimeoutSec 5

    # 打开浏览器到聊天页面
    Start-Process "http://localhost:$Port/chat"
} catch {
    Write-Host "发送失败: $_" -ForegroundColor Red
    # 打开聊天页面让用户手动处理
    Start-Process "http://localhost:$Port/chat"
}
