using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text.Json;
using System.Threading.Tasks;
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
    private readonly DispatcherTimer _heartbeatTimer;
    private Process? _installProcess;
    private long _logReadPosition;
    private bool _isRefreshingLog;
    private bool _installProcessExitHandled;
    private DateTime _lastLogUpdateUtc = DateTime.MinValue;

    private const int MaxLogChars = 200000;
    private const int MaxChunkChars = 24000;

    private static readonly SolidColorBrush BrushIdle = new(Color.FromRgb(0x10, 0xB9, 0x81));
    private static readonly SolidColorBrush BrushRunning = new(Color.FromRgb(0xF5, 0x9E, 0x0B));
    private static readonly SolidColorBrush BrushError = new(Color.FromRgb(0xEF, 0x44, 0x44));

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

        var version = Assembly.GetExecutingAssembly().GetName().Version;
        var versionText = version is null
            ? "v0.2.9"
            : $"v{version.Major}.{version.Minor}.{version.Build}";
        VersionBadgeText.Text = versionText;
        FooterVersionText.Text = $"Hermes Community · {versionText}";

        _logTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(1200) };
        _logTimer.Tick += (_, _) => RefreshLog();

        _heartbeatTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
        _heartbeatTimer.Tick += (_, _) => UpdateRunningState();
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

            try
            {
                if (File.Exists(_logPath))
                {
                    File.Delete(_logPath);
                }
            }
            catch
            {
                // Ignore stale log cleanup failures.
            }

            _logReadPosition = 0;
            _installProcessExitHandled = false;
            _lastLogUpdateUtc = DateTime.UtcNow;
            LogTextBox.Clear();

            var startInfo = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = $"-ExecutionPolicy Bypass -NonInteractive -NoProfile -File \"{_scriptPath}\" -Unattended",
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = _baseDirectory
            };

            _installProcess = Process.Start(startInfo);
            if (_installProcess is null)
            {
                throw new InvalidOperationException("无法启动安装进程。");
            }

            _installProcess.EnableRaisingEvents = true;
            _installProcess.Exited += InstallProcess_Exited;

            StartButton.IsEnabled = false;
            OpenUiButton.IsEnabled = false;
            StatusDot.Fill = BrushRunning;
            StatusText.Text = "正在安装...";
            DetailText.Text = "安装进程已经启动，日志会实时显示在下方。请勿关闭此窗口。";
            InstallProgressBar.Visibility = Visibility.Visible;
            InstallProgressBar.IsIndeterminate = true;

            _logTimer.Start();
            _heartbeatTimer.Start();
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "Hermes Installer", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void InstallProcess_Exited(object? sender, EventArgs e)
    {
        Dispatcher.BeginInvoke(CompleteInstallProcess);
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

    private async void RefreshLog()
    {
        if (_isRefreshingLog || !File.Exists(_logPath))
        {
            return;
        }

        _isRefreshingLog = true;
        try
        {
            var snapshot = await Task.Run(() =>
            {
                using var stream = new FileStream(_logPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
                if (stream.Length <= _logReadPosition)
                {
                    return (Text: string.Empty, NewPosition: _logReadPosition);
                }

                stream.Seek(_logReadPosition, SeekOrigin.Begin);
                using var reader = new StreamReader(stream);
                var newText = reader.ReadToEnd();
                var newPosition = stream.Length;

                if (newText.Length > MaxChunkChars)
                {
                    newText = "[... log chunk truncated ...]" + Environment.NewLine + newText[^MaxChunkChars..];
                }

                return (Text: newText, NewPosition: newPosition);
            });

            _logReadPosition = snapshot.NewPosition;
            if (!string.IsNullOrEmpty(snapshot.Text))
            {
                _lastLogUpdateUtc = DateTime.UtcNow;
                TrimLogIfNeeded(snapshot.Text.Length);
                LogTextBox.AppendText(snapshot.Text);

                if (LogTextBox.IsKeyboardFocusWithin || LogTextBox.SelectionLength > 0)
                {
                    return;
                }

                LogTextBox.ScrollToEnd();
            }
        }
        catch
        {
            // Ignore transient read issues while the installer is appending.
        }
        finally
        {
            _isRefreshingLog = false;
        }
    }

    private void UpdateRunningState()
    {
        if (_installProcess is null)
        {
            return;
        }

        if (_installProcess.HasExited)
        {
            CompleteInstallProcess();
            return;
        }

        var idleSeconds = (int)(DateTime.UtcNow - _lastLogUpdateUtc).TotalSeconds;
        if (idleSeconds < 8)
        {
            return;
        }

        DetailText.Text = $"安装仍在进行中，最近 {idleSeconds} 秒没有新的日志。这通常发生在 WSL 启动、系统功能启用或大文件下载阶段，请稍候。";
    }

    private void CompleteInstallProcess()
    {
        if (_installProcessExitHandled)
        {
            return;
        }

        _installProcessExitHandled = true;
        _logTimer.Stop();
        _heartbeatTimer.Stop();
        RefreshLog();
        InstallProgressBar.IsIndeterminate = false;

        var exitCode = _installProcess?.ExitCode ?? -1;
        if (exitCode == 0)
        {
            StatusDot.Fill = BrushIdle;
            StatusText.Text = "安装完成";
            DetailText.Text = "Hermes 已安装并启动完成，点击“打开 Web UI”即可访问。";
            InstallProgressBar.Value = 100;
            OpenUiButton.IsEnabled = true;
        }
        else
        {
            StatusDot.Fill = BrushError;
            StatusText.Text = "安装失败";
            DetailText.Text = $"安装进程退出码：{exitCode}。请查看下方日志，或把日志文件发给技术支持。";
            InstallProgressBar.Visibility = Visibility.Collapsed;
        }

        StartButton.IsEnabled = true;
        _installProcess?.Dispose();
        _installProcess = null;
    }

    private void TrimLogIfNeeded(int incomingLength)
    {
        var overflow = (LogTextBox.Text.Length + incomingLength) - MaxLogChars;
        if (overflow <= 0)
        {
            return;
        }

        var trimLength = Math.Min(LogTextBox.Text.Length, overflow + (MaxLogChars / 4));
        LogTextBox.Text = LogTextBox.Text[trimLength..];
    }

    private string GetUiUrl()
    {
        if (!File.Exists(_statePath))
        {
            return "http://localhost:8648";
        }

        try
        {
            using var stream = File.OpenRead(_statePath);
            using var document = JsonDocument.Parse(stream);
            if (document.RootElement.TryGetProperty("url", out var urlElement))
            {
                var url = urlElement.GetString();
                if (!string.IsNullOrWhiteSpace(url))
                {
                    return url;
                }
            }
        }
        catch
        {
            // Fall back to default localhost URL.
        }

        return "http://localhost:8648";
    }
}
