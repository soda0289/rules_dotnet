using System.Collections;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Resources;
using System.Threading;
using NUnit.Framework;

namespace WpfXamlTest;

[TestFixture]
public sealed class WpfXamlTests
{
    [Test]
    public void CompiledAssembly_EmbedsBamlResourceUnderExpectedKey()
    {
        var assembly = typeof(SampleCard).Assembly;
        var resourceNames = assembly.GetManifestResourceNames();
        CollectionAssert.Contains(resourceNames, "sample_card_lib.g.resources");

        using var stream = assembly.GetManifestResourceStream("sample_card_lib.g.resources");
        Assert.IsNotNull(stream);

        using var reader = new ResourceReader(stream!);
        var keys = reader.Cast<DictionaryEntry>().Select(e => (string)e.Key).ToList();
        CollectionAssert.Contains(keys, "samplecard.baml");
    }

    [Test]
    public void SampleCard_InitializeComponent_LoadsXamlOnStaThread()
    {
        string? title = null;
        string? buttonLabel = null;
        double width = 0;

        var thread = new Thread(() =>
        {
            var card = new SampleCard();
            title = card.CurrentTitle;
            buttonLabel = card.ButtonLabel;
            width = card.Width;
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();

        Assert.AreEqual("Hello from WPF XAML!", title);
        Assert.AreEqual("Click me", buttonLabel);
        Assert.AreEqual(240.0, width);
    }
}
