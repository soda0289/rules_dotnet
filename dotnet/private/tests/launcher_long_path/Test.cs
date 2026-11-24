using System;
using System.IO;
using Bazel;

class Test
{
    static int Main()
    {
        if (OperatingSystem.IsWindows())
        {
            var testSrcDir = Environment.GetEnvironmentVariable("TEST_SRCDIR") ?? "";
            var testWorkspace = Environment.GetEnvironmentVariable("TEST_WORKSPACE") ?? "";
            var testBinary = Environment.GetEnvironmentVariable("TEST_BINARY") ?? "";
            var runfilesTestBinary = Path.Combine(testSrcDir, testWorkspace, testBinary);
            if (runfilesTestBinary.Length <= 260)
            {
                Console.Error.WriteLine(
                    $"Expected Windows runfiles test binary path > 260 chars, got {runfilesTestBinary.Length}: {runfilesTestBinary}");
                return 1;
            }
        }

        var runfiles = Runfiles.Create();
        var dataPath = runfiles.Rlocation(
            "rules_dotnet/dotnet/private/tests/launcher_long_path/data.txt");
        var text = File.ReadAllText(dataPath).Trim();
        if (text != "long-path-ok")
        {
            Console.Error.WriteLine($"Unexpected data content: '{text}'");
            return 1;
        }

        return 0;
    }
}
