namespace HermesInstaller;

/// <summary>
/// 安装上下文，在各步骤间传递状态
/// </summary>
public class InstallContext
{
    public bool CanProceed { get; set; }
    public bool WslOk { get; set; }
    public bool VirtualizationOk { get; set; }
    public bool DiskSpaceOk { get; set; }
    public bool MemoryOk { get; set; }
    public bool NetworkOk { get; set; }
    public string Port { get; set; } = "8648";
    public string DistroName { get; set; } = "Ubuntu-24.04";
    public string WslPath { get; set; } = "";
    public List<string> InstallLog { get; set; } = new();
    public bool HasError { get; set; }
    public string ErrorMessage { get; set; } = "";
}
