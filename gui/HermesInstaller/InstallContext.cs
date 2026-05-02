namespace HermesInstaller;

/// <summary>
/// 安装上下文，在各步骤间传递状态
/// </summary>
public class InstallContext
{
    private string _port = "8648";
    private string _distroName = "Ubuntu-24.04";
    private string _wslPath = "";

    public bool CanProceed { get; set; }
    public bool WslOk { get; set; }
    public bool VirtualizationOk { get; set; }
    public bool DiskSpaceOk { get; set; }
    public bool MemoryOk { get; set; }
    public bool NetworkOk { get; set; }

    /// <summary>端口号（仅允许 1-65535 的纯数字）</summary>
    public string Port
    {
        get => _port;
        set
        {
            if (string.IsNullOrEmpty(value) || !System.Text.RegularExpressions.Regex.IsMatch(value, @"^\d{1,5}$"))
                throw new ArgumentException($"Port must be a numeric string (1-65535), got: '{value}'");
            if (int.TryParse(value, out var portNum) && (portNum < 1 || portNum > 65535))
                throw new ArgumentException($"Port out of range (1-65535): {portNum}");
            _port = value;
        }
    }

    /// <summary>WSL 发行版名称（仅允许字母数字、点、连字符、下划线，1-64 字符）</summary>
    public string DistroName
    {
        get => _distroName;
        set
        {
            if (string.IsNullOrEmpty(value) || !System.Text.RegularExpressions.Regex.IsMatch(value, @"^[a-zA-Z0-9._-]{1,64}$"))
                throw new ArgumentException($"DistroName must match [a-zA-Z0-9._-]{{1,64}}, got: '{value}'");
            _distroName = value;
        }
    }

    public string WslPath
    {
        get => _wslPath;
        set
        {
            var v = value ?? "";
            if (v.Contains('\'') || v.Contains('"'))
                throw new ArgumentException("WslPath must not contain quote characters");
            _wslPath = v;
        }
    }

    public List<string> InstallLog { get; set; } = new();
    public bool HasError { get; set; }
    public string ErrorMessage { get; set; } = "";
}
