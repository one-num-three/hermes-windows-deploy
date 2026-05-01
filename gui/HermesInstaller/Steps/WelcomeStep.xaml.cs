using System.Windows;
using System.Windows.Controls;

namespace HermesInstaller.Steps;

public partial class WelcomeStep : UserControl
{
    public event EventHandler<bool>? AgreementChanged;

    public WelcomeStep()
    {
        InitializeComponent();
    }

    private void AgreeCheck_Changed(object sender, RoutedEventArgs e)
    {
        AgreementChanged?.Invoke(this, AgreeCheck.IsChecked == true);
    }
}
