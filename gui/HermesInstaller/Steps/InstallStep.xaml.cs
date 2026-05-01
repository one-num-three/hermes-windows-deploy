using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace HermesInstaller.Steps;

public partial class InstallStep : UserControl
{
    public event EventHandler<bool>? InstallationCompleted;
    private readonly ObservableCollection<InstallStepItem> _stepItems = new();
    private bool _logVisible;

    public InstallStep()
    {
        InitializeComponent();
        StepList.ItemsSource = _stepItems;
    }

    public async void StartInstallation(InstallContext context)
    {
        try
        {
            _stepItems.Clear();
            LogOutput.Text = "";

        var steps = new[]
        {
            ("[1/6]", "安装 WSL2"),
            ("[2/6]", "安装 Ubuntu 24.04"),
            ("[3/6]", "配置国内镜像源"),
            ("[4/6]", "安装 Hermes Agent"),
            ("[5/6]", "安装 Web UI 面板"),
            ("[6/6]", "配置开机自启"),
        };

        for (int i = 0; i < steps.Length; i++)
        {
            var (num, label) = steps[i];
            var item = new InstallStepItem
            {
                Icon = num,
                Label = label,
                Color = new SolidColorBrush(Color.FromRgb(0x66, 0x66, 0x66))
            };
            _stepItems.Add(item);

            // 执行安装步骤
            CurrentStepLabel.Text = $"正在执行: {label}...";
            InstallProgress.Value = (i * 100.0) / steps.Length;
            ToggleLogButton.Visibility = Visibility.Visible;

            try
            {
                await RunInstallStep(i, context);
                item.Icon = "✓";
                item.Color = new SolidColorBrush(Color.FromRgb(0x27, 0xAE, 0x60));
            }
            catch (Exception ex)
            {
                item.Icon = "✗";
                item.Color = new SolidColorBrush(Color.FromRgb(0xE7, 0x4C, 0x3C));
                LogOutput.Text += $"\n[错误] {label}: {ex.Message}";
                context.HasError = true;
                context.ErrorMessage = ex.Message;
                break;
            }
        }

        InstallProgress.Value = 100;
        CurrentStepLabel.Text = context.HasError ? "安装遇到错误" : "安装完成！";

        InstallationCompleted?.Invoke(this, !context.HasError);
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"[InstallStep] 安装崩溃: {ex}");
            CurrentStepLabel.Text = "安装过程发生意外错误";
            context.HasError = true;
            context.ErrorMessage = ex.Message;
            InstallationCompleted?.Invoke(this, false);
        }
    }

    private async Task RunInstallStep(int stepIndex, InstallContext context)
    {
        var runner = new PowerShellRunner();
        var baseDir = AppDomain.CurrentDomain.BaseDirectory;
        var scriptsDir = System.IO.Path.Combine(baseDir, "scripts");

        LogOutput.Text += $"\n> 执行步骤 {stepIndex + 1}...";

        try
        {
            switch (stepIndex)
            {
                case 0: // [1/6] 安装 WSL2
                    {
                        var result = await runner.RunScript(
                            System.IO.Path.Combine(scriptsDir, "install-hermes.ps1"),
                            $"-Step wsl -DistroName \"{context.DistroName}\" -Unattended",
                            requireAdmin: true);
                        LogOutput.Text += $"\n{result.Output}";
                        LogOutput.Text += $"\n> 步骤 1 完成 ✓ (WSL2)";
                        if (!result.Success)
                            throw new Exception($"WSL2 安装失败: {result.Error}");
                        break;
                    }
                case 1: // [2/6] 安装 Ubuntu 24.04
                    {
                        var result = await runner.RunScript(
                            System.IO.Path.Combine(scriptsDir, "install-hermes.ps1"),
                            $"-Step distro -DistroName \"{context.DistroName}\" -Unattended");
                        LogOutput.Text += $"\n{result.Output}";
                        LogOutput.Text += $"\n> 步骤 2 完成 ✓ (Ubuntu)";
                        if (!result.Success)
                            throw new Exception($"Ubuntu 安装失败: {result.Error}");
                        break;
                    }
                case 2: // [3/6] 配置国内镜像源
                    {
                        var mirrorScript = System.IO.Path.Combine(scriptsDir, "setup-mirrors.sh");
                        if (System.IO.File.Exists(mirrorScript))
                        {
                            var wslPath = mirrorScript.Replace('\\', '/');
                            var result = await runner.RunInWsl(context.DistroName,
                                $"bash \"$(wslpath -a '{wslPath}' 2>/dev/null || echo '{wslPath}')\"");
                            LogOutput.Text += $"\n{result.Output}";
                            if (!result.Success)
                                LogOutput.Text += $"\n[警告] 镜像源配置失败，使用默认源: {result.Error}";
                        }
                        else
                        {
                            LogOutput.Text += "\n[信息] setup-mirrors.sh 未找到，跳过镜像源配置";
                        }
                        LogOutput.Text += $"\n> 步骤 3 完成 ✓ (镜像源)";
                        break;
                    }
                case 3: // [4/6] 安装 Hermes Agent
                    {
                        var bootstrapScript = System.IO.Path.Combine(scriptsDir, "wsl-bootstrap.sh");
                        if (System.IO.File.Exists(bootstrapScript))
                        {
                            var wslPath = bootstrapScript.Replace('\\', '/');
                            var result = await runner.RunInWsl(context.DistroName,
                                $"bash \"$(wslpath -a '{wslPath}' 2>/dev/null || echo '{wslPath}')\"");
                            LogOutput.Text += $"\n{result.Output}";
                            if (!result.Success)
                                throw new Exception($"Hermes Agent 安装失败: {result.Error}");
                        }
                        else
                        {
                            // 回退：使用 install-hermes.ps1
                            var result = await runner.RunScript(
                                System.IO.Path.Combine(scriptsDir, "install-hermes.ps1"),
                                $"-Step hermes -Unattended");
                            LogOutput.Text += $"\n{result.Output}";
                            if (!result.Success)
                                throw new Exception($"Hermes Agent 安装失败: {result.Error}");
                        }
                        LogOutput.Text += $"\n> 步骤 4 完成 ✓ (Hermes Agent)";
                        break;
                    }
                case 4: // [5/6] 安装 Web UI 面板
                    {
                        var postInstallScript = System.IO.Path.Combine(scriptsDir, "post-install.ps1");
                        if (System.IO.File.Exists(postInstallScript))
                        {
                            var result = await runner.RunScript(postInstallScript, $"-Port {context.Port}");
                            LogOutput.Text += $"\n{result.Output}";
                            if (!result.Success)
                                throw new Exception($"Web UI 安装失败: {result.Error}");
                        }
                        else
                        {
                            LogOutput.Text += "\n[信息] post-install.ps1 未找到，跳过 Web UI 面板配置";
                        }
                        LogOutput.Text += $"\n> 步骤 5 完成 ✓ (Web UI)";
                        break;
                    }
                case 5: // [6/6] 配置开机自启
                    {
                        var setupSystemdScript = System.IO.Path.Combine(scriptsDir, "setup-systemd.sh");
                        if (System.IO.File.Exists(setupSystemdScript))
                        {
                            var wslPath = setupSystemdScript.Replace('\\', '/');
                            var result = await runner.RunInWsl(context.DistroName,
                                $"bash \"$(wslpath -a '{wslPath}' 2>/dev/null || echo '{wslPath}')\"");
                            LogOutput.Text += $"\n{result.Output}";
                            if (!result.Success)
                                LogOutput.Text += $"\n[警告] 开机自启配置失败: {result.Error}";
                        }
                        else
                        {
                            // 内置 systemd 配置
                            var result = await runner.RunInWsl(context.DistroName,
                                "sudo systemctl enable hermes-agent 2>/dev/null && " +
                                "echo 'Hermes Agent 已配置开机自启' || " +
                                "echo '警告: systemd 配置失败，请手动设置'");
                            LogOutput.Text += $"\n{result.Output}";
                        }
                        LogOutput.Text += $"\n> 步骤 6 完成 ✓ (开机自启)";
                        break;
                    }
            }
        }
        catch (Exception ex)
        {
            LogOutput.Text += $"\n[异常] 步骤 {stepIndex + 1}: {ex.Message}";
            throw; // 重新抛出，让 StartInstallation 处理
        }
    }

    private void ToggleLog_Click(object sender, RoutedEventArgs e)
    {
        _logVisible = !_logVisible;
        LogScroller.Visibility = _logVisible ? Visibility.Visible : Visibility.Collapsed;
        ToggleLogButton.Content = _logVisible ? "▲ 收起日志" : "▼ 展开日志";
    }
}

public class InstallStepItem : INotifyPropertyChanged
{
    private string _icon = "";
    public string Icon { get => _icon; set { _icon = value; OnPropertyChanged(); } }
    
    private string _label = "";
    public string Label { get => _label; set { _label = value; OnPropertyChanged(); } }

    private Brush _color = Brushes.Gray;
    public Brush Color
    {
        get => _color;
        set { _color = value; OnPropertyChanged(); }
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    protected void OnPropertyChanged([CallerMemberName] string? name = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
