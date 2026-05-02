using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using HermesInstaller.Steps;

namespace HermesInstaller;

public partial class MainWindow : Window
{
    private int _currentStep = 0;
    private readonly List<UserControl> _steps;
    private readonly InstallContext _context;

    // 保存事件处理器引用以便注销
    private readonly EventHandler<bool> _onEnvironmentChecked;
    private readonly EventHandler<bool> _onAgreementChanged;
    private readonly EventHandler<bool> _onInstallationCompleted;

    public MainWindow()
    {
        InitializeComponent();

        _context = new InstallContext();
        _steps = new List<UserControl> { WelcomePage, CheckPage, InstallPage, FinishPage };

        // CheckStep 完成后自动通知
        _onEnvironmentChecked = (_, passed) =>
        {
            if (passed)
            {
                _context.CanProceed = true;
                NextButton.IsEnabled = true;
            }
        };
        CheckPage.EnvironmentChecked += _onEnvironmentChecked;

        // WelcomeStep 同意复选框控制「下一步」按钮
        _onAgreementChanged = (_, agreed) =>
        {
            NextButton.IsEnabled = agreed;
        };
        WelcomePage.AgreementChanged += _onAgreementChanged;

        // InstallStep 安装完成通知
        _onInstallationCompleted = (_, success) =>
        {
            NextButton.IsEnabled = true;
            if (success)
            {
                NextButton.Content = "完成 ✓";
            }
        };
        InstallPage.InstallationCompleted += _onInstallationCompleted;

        // 窗口关闭时注销事件
        Closed += (_, _) =>
        {
            CheckPage.EnvironmentChecked -= _onEnvironmentChecked;
            WelcomePage.AgreementChanged -= _onAgreementChanged;
            InstallPage.InstallationCompleted -= _onInstallationCompleted;
        };

        ShowStep(0);
    }

    private void ShowStep(int index)
    {
        foreach (var step in _steps)
            step.Visibility = Visibility.Collapsed;

        _steps[index].Visibility = Visibility.Visible;
        _currentStep = index;

        // 更新按钮状态
        BackButton.Visibility = index > 0 && index < 3 ? Visibility.Visible : Visibility.Collapsed;
        NextButton.Visibility = index < 3 ? Visibility.Visible : Visibility.Collapsed;

        NextButton.Content = index switch
        {
            0 => "开始安装 →",
            1 => "下一步 →",
            2 => "安装中...",
            _ => "完成"
        };

        // 步骤 0 不需要上一步
        if (index == 0) BackButton.Visibility = Visibility.Collapsed;
        // 步骤 2 (安装页) 禁用按钮直到完成
        if (index == 2)
        {
            NextButton.IsEnabled = false;
            CancelButton.IsEnabled = false;
        }
    }

    private void NextButton_Click(object sender, RoutedEventArgs e)
    {
        switch (_currentStep)
        {
            case 0: // 欢迎 → 环境检测
                ShowStep(1);
                CheckPage.StartCheck();
                break;

            case 1: // 检测 → 安装
                if (_context.CanProceed)
                {
                    ShowStep(2);
                    InstallPage.StartInstallation(_context);
                }
                break;

            case 2: // 安装完成
                ShowStep(3);
                break;

            case 3: // 完成 → 退出
                Application.Current.Shutdown();
                break;
        }
    }

    private void BackButton_Click(object sender, RoutedEventArgs e)
    {
        if (_currentStep > 0)
            ShowStep(_currentStep - 1);
    }

    private void CancelButton_Click(object sender, RoutedEventArgs e)
    {
        if (_currentStep == 2) return; // 安装中不允许取消

        var result = MessageBox.Show("确定要取消安装吗？", "Hermes 安装向导",
            MessageBoxButton.YesNo, MessageBoxImage.Question);
        if (result == MessageBoxResult.Yes)
            Application.Current.Shutdown();
    }

    private void CloseButton_Click(object sender, RoutedEventArgs e)
    {
        Application.Current.Shutdown();
    }

    private void TitleBar_MouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton == MouseButton.Left)
        {
            try { DragMove(); }
            catch (InvalidOperationException) { /* 鼠标状态异常，忽略 */ }
        }
    }
}
