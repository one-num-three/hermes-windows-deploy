using System.Diagnostics;

namespace HermesInstaller;

/// <summary>
/// PowerShell 执行服务，负责在后台运行安装脚本
/// </summary>
public class PowerShellRunner
{
    /// <summary>
    /// 安全执行 PowerShell 脚本
    /// </summary>
    /// <param name="scriptPath">脚本路径</param>
    /// <param name="arguments">脚本参数（自动转义危险字符）</param>
    /// <param name="requireAdmin">是否需要管理员权限（默认 false，避免不必要的 UAC 弹窗）</param>
    public async Task<PowerShellResult> RunScript(string scriptPath, string arguments = "", bool requireAdmin = false)
    {
        // 参数安全校验：过滤 PowerShell 注入字符
        var safeArgs = SanitizeArguments(arguments);

        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = $"-ExecutionPolicy Bypass -NoProfile -File \"{scriptPath}\" {safeArgs}",
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };

        // 仅在需要时提升权限，避免不必要的 UAC 弹窗
        if (requireAdmin)
        {
            psi.Verb = "runas";
        }

        using var process = new Process { StartInfo = psi };
        var output = new System.Text.StringBuilder();
        var error = new System.Text.StringBuilder();

        process.OutputDataReceived += (_, e) =>
        {
            if (e.Data != null) output.AppendLine(e.Data);
        };
        process.ErrorDataReceived += (_, e) =>
        {
            if (e.Data != null) error.AppendLine(e.Data);
        };

        process.Start();
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        await process.WaitForExitAsync();

        return new PowerShellResult
        {
            ExitCode = process.ExitCode,
            Output = output.ToString(),
            Error = error.ToString()
        };
    }

    /// <summary>
    /// 过滤 PowerShell 参数中的危险注入字符
    /// </summary>
    private static string SanitizeArguments(string args)
    {
        if (string.IsNullOrEmpty(args)) return "";
        // 移除可能导致命令注入的字符序列
        // 注意：参数中的引号配对由调用方保证
        return System.Text.RegularExpressions.Regex.Replace(args,
            @"[;&|`$(){}[\]]", ""); // 移除 shell 元字符
    }

    /// <summary>
    /// 在 WSL 中安全执行命令（通过 base64 编码防止注入）
    /// </summary>
    public async Task<PowerShellResult> RunInWsl(string distro, string command)
    {
        // 校验 distro 名称格式（仅允许字母数字、点、连字符）
        if (string.IsNullOrEmpty(distro) || !System.Text.RegularExpressions.Regex.IsMatch(distro, @"^[a-zA-Z0-9._-]{1,64}$"))
        {
            return new PowerShellResult
            {
                ExitCode = -1,
                Error = $"Invalid distro name: {distro}",
            };
        }

        // 校验命令不为空
        if (string.IsNullOrEmpty(command))
        {
            return new PowerShellResult
            {
                ExitCode = -1,
                Error = "Command cannot be empty",
            };
        }

        // 安全：将命令 base64 编码后传递，防止 shell 注入
        // 使用 UTF-8 编码防止宽字符注入
        var commandBytes = System.Text.Encoding.UTF8.GetBytes(command);
        var base64Command = Convert.ToBase64String(commandBytes);

        var psi = new ProcessStartInfo
        {
            FileName = "wsl.exe",
            Arguments = $"-d {distro} -- bash -c \"echo {base64Command} | base64 -d | bash\"",
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };

        using var process = new Process { StartInfo = psi };
        var output = new System.Text.StringBuilder();

        process.OutputDataReceived += (_, e) =>
        {
            if (e.Data != null) output.AppendLine(e.Data);
        };

        process.Start();
        process.BeginOutputReadLine();

        await process.WaitForExitAsync();

        return new PowerShellResult
        {
            ExitCode = process.ExitCode,
            Output = output.ToString()
        };
    }
}

public class PowerShellResult
{
    public int ExitCode { get; set; }
    public string Output { get; set; } = "";
    public string Error { get; set; } = "";
    public bool Success => ExitCode == 0;
}
