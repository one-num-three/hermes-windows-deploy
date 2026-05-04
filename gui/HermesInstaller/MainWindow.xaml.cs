using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;

namespace HermesInstaller;

public partial class MainWindow : Window
{
    private readonly string _baseDirectory;
    private readonly string _scriptPath;
    private readonly string _logPath;
    private readonly string _statePath;
    private readonly DispatcherTimer _logTimer;
    private Process? _installProcess;
    private long _logReadPosition;

    private static readonly SolidColorBrush BrushIdle    = new(Color.FromRgb(0x10, 0xB9, 0x81)); // 绿
    private static readonly SolidColorBrush BrushRunning = new(Color.FromRgb(0xF5, 0x9E, 0x0B)); // 琥珀
    private static readonly SolidColorBrush BrushError   = new(Color.FromRgb(0xEF, 0x44, 0x44)); // 红

    public MainWindow()
    {
        InitializeComponent();

        _baseDirectory = AppDomain.CurrentDomain.BaseDirectory;
        _scriptPath = Path.Combine(_baseDirectory, "scripts", "install-hermes.ps1");
        _logPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            "hermes-install.log");
        _statePath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".hermes",
            "install-state.json");

        LogPathText.Text = _logPath;

        _logTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(600) };
        _logTimer.Tick += (_, _) => RefreshLog();
    }

    private void StartButton_Click(object sender, RoutedEventArgs e)
    {
        if (!File.Exists(_scriptPath))
        {
            MessageBox.Show(
                $"找不到安装脚本：\n{_scriptPath}",
                "Hermes Installer",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            return;
        }

        try
        {
            if (_installProcess is { HasExited: false })
            {
                RefreshLog();
                return;
            }

            // 清除上次日志，重置增量读取位置
            try { if (File.Exists(_logPath)) File.Delete(_logPath); } catch { }
            _logReadPosition = 0;

            // app.manifest 已确保以管理员身份运行，直接用 CreateProcess（避免 ShellExecuteEx 阻塞 UI）
            var startInfo = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = $"-ExecutionPolicy Bypass -NoProfile -File \"{_scriptPath}\" -Unattended",
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = _baseDirectory
            };

            _installProcess = Process.Start(startInfo);
            if (_installProcess is null)
                throw new InvalidOperationException("无法启动安装进程。");

            _installProcess.EnableRaisingEvents = true;
            _installProcess.Exited += InstallProcess_Exited;

            StartButton.IsEnabled = false;
            OpenUiButton.IsEnabled = false;
            StatusDot.Fill = BrushRunning;
            StatusText.Text = "正在安装…";
            DetailText.Text = "已启动安装进程，日志实时刷新在下方。请勿关闭此窗口。";
            InstallProgressBar.Visibility = Visibility.Visible;
            InstallProgressBar.IsIndeterminate = true;
            LogTextBox.Text = "";

            _logTimer.Start();
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "Hermes Installer", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void InstallProcess_Exited(object? sender, EventArgs e)
    {
        Dispatcher.Invoke(() =>
        {
            _logTimer.Stop();
            RefreshLog();

            InstallProgressBar.IsIndeterminate = false;

            var exitCode = _installProcess?.ExitCode ?? -1;
            if (exitCode == 0)
            {
                StatusDot.Fill = BrushIdle;
                StatusText.Text = "安装完成";
                DetailText.Text = "Hermes 已成功安装并启动，点击「打开 Web UI」访问。";
                InstallProgressBar.Value = 100;
                OpenUiButton.IsEnabled = true;
            }
            else
            {
                StatusDot.Fill = BrushError;
                StatusText.Text = "安装失败";
                DetailText.Text = $"安装进程退出码：{exitCode}。请查看下方日志，或将日志文件发给技术支持。";
                InstallProgressBar.Visibility = Visibility.Collapsed;
            }

            StartButton.IsEnabled = true;
            _installProcess?.Dispose();
            _installProcess = null;
        });
    }

    private void OpenUiButton_Click(object sender, RoutedEventArgs e)
    {
        var url = GetUiUrl();
        Process.Start(new ProcessStartInfo { FileName = url, UseShellExecute = true });
    }

    private void OpenFolderButton_Click(object sender, RoutedEventArgs e)
    {
        Process.Start(new ProcessStartInfo { FileName = _baseDirectory, UseShellExecute = true });
    }

    private void RefreshLog()
    {
        if (!File.Exists(_logPath)) return;
        try
        {
            using var stream = new FileStream(_logPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            if (stream.Length <= _logReadPosition) return;
            stream.Seek(_logReadPosition, SeekOrigin.Begin);
            using var reader = new StreamReader(stream);
            var newText = reader.ReadToEnd();
            _logReadPosition = stream.Length;
            if (!string.IsNullOrEmpty(newText))
            {
                LogTextBox.AppendText(newText);
                LogTextBox.ScrollToEnd();
            }
        }
        catch { }
    }

    private string GetUiUrl()
    {
        if (!File.Exists(_statePath)) return "http://localhost:8648";
        try
        {
            using var stream = File.OpenRead(_statePath);
            using var doc = JsonDocument.Parse(stream);
            if (doc.RootElement.TryGetProperty("url", out var urlEl))
            {
                var url = urlEl.GetString();
                if (!string.IsNullOrWhiteSpace(url)) return url;
            }
        }
        catch { }
        return "http://localhost:8648";
    }
}
