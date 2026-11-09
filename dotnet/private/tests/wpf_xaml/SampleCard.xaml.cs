using System.Windows.Controls;

namespace WpfXamlTest;

public partial class SampleCard : UserControl
{
    public SampleCard()
    {
        InitializeComponent();
    }

    public string CurrentTitle => TitleText.Text;
    public string ButtonLabel => (string)ActionButton.Content;
}
