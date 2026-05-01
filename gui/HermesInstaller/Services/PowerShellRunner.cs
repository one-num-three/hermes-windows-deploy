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
    /// <param name="requireAdmin">是否需要管理员权限（通过独立进程提权，默认 false）</param>
    public async Task<PowerShellResult> RunScript(string scriptPath, string arguments = "", bool requireAdmin = false)
    {
        // 参数安全校验：过滤 PowerShell 注入字符
        var safeArgs = SanitizeArguments(arguments);

        if (requireAdmin)
        {
            // 提权模式：UseShellExecute=true 与 Verb="runas" 兼容，
            // 但无法直接捕获输出 — 通过临时文件桥接
            return await RunScriptAsAdmin(scriptPath, safeArgs);
        }

        // 标准模式：可捕获输出
        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = $"-ExecutionPolicy Bypass -NoProfile -File \"{scriptPath}\" {safeArgs}",
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };

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
    /// 以管理员权限执行脚本（通过独立提权进程 + 临时文件桥接输出）
    /// </summary>
    private async Task<PowerShellResult> RunScriptAsAdmin(string scriptPath, string safeArgs)
    {
        var outputFile = Path.Combine(Path.GetTempPath(), $"hermes_out_{Guid.NewGuid():N}.txt");
        var errorFile = Path.Combine(Path.GetTempPath(), $"hermes_err_{Guid.NewGuid():N}.txt");
        var exitCodeFile = Path.Combine(Path.GetTempPath(), $"hermes_exit_{Guid.NewGuid():N}.txt");

        // 构造包装脚本：执行目标脚本并将输出写入临时文件
        var wrapperScript = Path.Combine(Path.GetTempPath(), $"hermes_wrapper_{Guid.NewGuid():N}.ps1");
        var wrapperContent = $@"
$ErrorActionPreference = 'Continue'
try {{
    & '{scriptPath.Replace("'", "''")}' {safeArgs} *> '{outputFile.Replace("'", "''")}'
    $LASTEXITCODE | Out-File -FilePath '{exitCodeFile.Replace("'", "''")}'
}} catch {{
    $_.Exception.Message | Out-File -FilePath '{errorFile.Replace("'", "''")}'
    1 | Out-File -FilePath '{exitCodeFile.Replace("'", "''")}'
}}
";
        await File.WriteAllTextAsync(wrapperScript, wrapperContent);

        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = $"-ExecutionPolicy Bypass -NoProfile -File \"{wrapperScript}\"",
            UseShellExecute = true,  // 必须为 true 才能使用 Verb="runas"
            Verb = "runas",
            WindowStyle = ProcessWindowStyle.Hidden,
        };

        try
        {
            using var process = Process.Start(psi);
            if (process == null)
            {
                return new PowerShellResult { ExitCode = -1, Error = "无法启动提权进程（用户可能拒绝了 UAC）" };
            }
            await process.WaitForExitAsync();

            // 从临时文件读取输出
            var output = File.Exists(outputFile) ? await File.ReadAllTextAsync(outputFile) : "";
            var error = File.Exists(errorFile) ? await File.ReadAllTextAsync(errorFile) : "";
            var exitCode = 0;
            if (File.Exists(exitCodeFile))
            {
                var codeText = (await File.ReadAllTextAsync(exitCodeFile)).Trim();
                int.TryParse(codeText, out exitCode);
            }

            return new PowerShellResult { ExitCode = exitCode, Output = output, Error = error };
        }
        catch (Exception ex)
        {
            return new PowerShellResult { ExitCode = -1, Error = $"提权执行失败: {ex.Message}" };
        }
        finally
        {
            // 清理临时文件
            SafeDelete(outputFile);
            SafeDelete(errorFile);
            SafeDelete(exitCodeFile);
            SafeDelete(wrapperScript);
        }
    }

    private static void SafeDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { /* 忽略清理失败 */ }
    }

    /// <summary>
    /// 过滤 PowerShell 参数中的危险注入字符
    /// </summary>
    private static string SanitizeArguments(string args)
    {
        if (string.IsNullOrEmpty(args)) return "";
        // 移除可能导致命令注入的字符序列
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
            // 使用 printf '%s' 替代 echo，防止 base64 数据中的转义序列被解释
            Arguments = $"-d {distro} -- bash -c \"printf '%s' {base64Command} | base64 -d | bash\"",
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
