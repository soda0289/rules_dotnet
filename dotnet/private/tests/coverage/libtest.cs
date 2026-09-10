using NUnit.Framework;

namespace Coverage;

public class LibTest
{
    [Test]
    public void TripleThenDouble()
    {
        Assert.That(Lib.TripleThenDouble(1), Is.EqualTo(6));
    }
}
