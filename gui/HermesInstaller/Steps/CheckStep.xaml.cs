using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace HermesInstaller.Steps;

public partial class CheckStep : UserControl
{
    public event EventHandler<bool>? EnvironmentChecked;
    private readonly ObservableCollection<CheckItem> _items = new();

    public CheckStep()
    {
        InitializeComponent();
        CheckItems.ItemsSource = _items;
    }

    public async void StartCheck()
    {
        try
        {
            _items.Clear();
            CheckProgress.IsIndeterminate = true;

        var checks = new[]
        {
            new { Icon = "⊞", Label = "Windows 版本检查" },
            new { Icon = "💻", Label = "CPU 虚拟化支持" },
            new { Icon = "💾", Label = "磁盘空间检查 (>20GB)" },
            new { Icon = "🧠", Label = "内存检查 (>8GB)" },
            new { Icon = "🐧", Label = "WSL 状态检查" },
            new { Icon = "🌐", Label = "网络连通性检查" },
        };

        bool allPassed = true;

        foreach (var check in checks)
        {
            var item = new CheckItem
            {
                Icon = check.Icon,
                Label = check.Label,
                Status = "检测中...",
                StatusColor = new SolidColorBrush(Color.FromRgb(0x99, 0x99, 0x99))
            };
            _items.Add(item);

            // 模拟检测（实际应调用 test-env.ps1）
            await Task.Delay(800);

            var (passed, detail) = await RunCheck(check.Label);
            item.Status = passed ? "✓" : "✗";
            item.StatusColor = passed
                ? new SolidColorBrush(Color.FromRgb(0x27, 0xAE, 0x60))
                : new SolidColorBrush(Color.FromRgb(0xE7, 0x4C, 0x3C));
            item.Detail = detail;

            if (!passed) allPassed = false;
        }

        CheckProgress.IsIndeterminate = false;

        if (allPassed)
        {
            ResultText.Text = "✓ 所有检测通过，可以继续安装";
            ResultText.Foreground = new SolidColorBrush(Color.FromRgb(0x27, 0xAE, 0x60));
        }
        else
        {
            ResultText.Text = "⚠ 部分检测未通过，请解决后重试";
            ResultText.Foreground = new SolidColorBrush(Color.FromRgb(0xE7, 0x4C, 0x3C));
        }

        EnvironmentChecked?.Invoke(this, allPassed);
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"[CheckStep] 环境检测崩溃: {ex}");
            ResultText.Text = "⚠ 检测过程出错，请重试";
            ResultText.Foreground = new SolidColorBrush(Color.FromRgb(0xE7, 0x4C, 0x3C));
            EnvironmentChecked?.Invoke(this, false);
        }
    }

    private async Task<(bool passed, string detail)> RunCheck(string label)
    {
        try
        {
            var runner = new PowerShellRunner();
            var scriptPath = System.IO.Path.Combine(
                AppDomain.CurrentDomain.BaseDirectory, "scripts", "utils", "test-env.ps1");
            // 实际环境调用 PowerShell
            if (System.IO.File.Exists(scriptPath))
            {
                var result = await runner.RunScript(scriptPath);
                return (result.ExitCode == 0, result.Output);
            }
            // 脚本不存在时不应假阳性通过
            return (false, "检测脚本缺失 (test-env.ps1)");
        }
        catch (Exception ex)
        {
            // 记录异常详情，方便排查
            System.Diagnostics.Debug.WriteLine($"[CheckStep] 检测失败 ({label}): {ex.Message}");
            return (false, $"检测异常: {ex.Message}");
        }
    }
}

public class CheckItem : INotifyPropertyChanged
{
    private string _icon = "";
    public string Icon { get => _icon; set { _icon = value; OnPropertyChanged(); } }
    
    private string _label = "";
    public string Label { get => _label; set { _label = value; OnPropertyChanged(); } }
    
    private string _status = "";
    public string Status { get => _status; set { _status = value; OnPropertyChanged(); } }
    
    private string _detail = "";
    public string Detail { get => _detail; set { _detail = value; OnPropertyChanged(); } }

    private Brush _statusColor = Brushes.Gray;
    public Brush StatusColor
    {
        get => _statusColor;
        set { _statusColor = value; OnPropertyChanged(); }
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    protected void OnPropertyChanged([CallerMemberName] string? name = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
