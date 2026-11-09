// Runs the .NET SDK's own WPF XAML tasks (`MarkupCompilePass1` and
// `ResourcesGenerator`) as a Bazel action.
//
// WPF XAML compilation is implemented in `PresentationBuildTasks.dll` inside
// `Microsoft.NET.Sdk.WindowsDesktop`:
//   1. `MarkupCompilePass1` parses each `.xaml` file against the target's
//      reference assemblies and emits a partial class `.g.cs` file plus a
//      binary `.baml` stream.
//   2. `ResourcesGenerator` packs all generated `.baml` streams (keyed as
//      lowercase `<package-relative-path>.baml`) into `<AssemblyName>.g.resources`,
//      which `csc` embeds into the assembly.

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Resources;
using System.Text.Json;
using System.Xml;
using Microsoft.Build.Framework;
using Microsoft.Build.Utilities;

internal sealed class Request
{
    public List<string> TasksAssemblies { get; set; } = new();
    public string AssemblyName { get; set; } = "";
    public string RootNamespace { get; set; } = "";
    public string OutputType { get; set; } = "Library";
    public string OutputResources { get; set; } = "";
    public List<string> References { get; set; } = new();
    public List<WpfXamlFile> Files { get; set; } = new();
}

internal sealed class WpfXamlFile
{
    public string RelativePath { get; set; } = "";
    public string Source { get; set; } = "";
    public string GeneratedCs { get; set; } = "";
}

internal static class Program
{
    private const string WpfNamespace = "http://schemas.microsoft.com/winfx/2006/xaml/presentation";

    private static int Main(string[] args)
    {
        if (args.Length != 1)
        {
            Console.Error.WriteLine("usage: wpf_xaml <request.json>");
            return 1;
        }

        var options = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };
        var request = JsonSerializer.Deserialize<Request>(File.ReadAllText(args[0]), options)!;

        var tasks = LoadPresentationBuildTasks(request.TasksAssemblies);
        var engine = new StubBuildEngine();

        var outputResourcesFullPath = Path.GetFullPath(request.OutputResources);
        var referenceItems = request.References
            .Where(r => !IsNativeEnterpriseServicesWrapper(r))
            .Select(r => (ITaskItem)new TaskItem(Path.GetFullPath(r)))
            .ToArray();

        var resolvedFiles = request.Files
            .Select(f => (
                RelativeWinPath: f.RelativePath.Replace('/', Path.DirectorySeparatorChar),
                SourceFullPath: Path.GetFullPath(f.Source),
                GeneratedCsFullPath: Path.GetFullPath(f.GeneratedCs)))
            .ToList();

        var origDir = Directory.GetCurrentDirectory();
        var workDir = Path.Combine(Path.GetTempPath(), "rules_dotnet_wpf_" + Guid.NewGuid().ToString("N"));
        var srcDir = Path.Combine(workDir, "src");
        var outDir = Path.Combine(workDir, "out");
        Directory.CreateDirectory(srcDir);
        Directory.CreateDirectory(outDir);

        try
        {
            var pageMarkup = new List<ITaskItem>();
            var applicationMarkup = new List<ITaskItem>();

            foreach (var file in resolvedFiles)
            {
                var stagedPath = Path.Combine(srcDir, file.RelativeWinPath);
                Directory.CreateDirectory(Path.GetDirectoryName(stagedPath)!);
                File.Copy(file.SourceFullPath, stagedPath, overwrite: true);

                var item = new TaskItem(file.RelativeWinPath);
                if (IsApplicationDefinition(file.SourceFullPath))
                {
                    applicationMarkup.Add(item);
                }
                else
                {
                    pageMarkup.Add(item);
                }
            }

            // `MarkupCompilePass1` computes each XAML file's BAML resource key
            // and `#pragma checksum` / `#line` path relative to the current
            // working directory, so running from `srcDir` keeps both `.g.cs`
            // and `.g.resources` package-relative and deterministic.
            Directory.SetCurrentDirectory(srcDir);

            var pass1 = Tasks.Create(tasks, engine, "Microsoft.Build.Tasks.Windows.MarkupCompilePass1");
            Tasks.Set(pass1, "Language", "C#");
            Tasks.Set(pass1, "AssemblyName", request.AssemblyName);
            Tasks.Set(pass1, "RootNamespace", request.RootNamespace);
            Tasks.Set(pass1, "OutputPath", outDir + Path.DirectorySeparatorChar);
            Tasks.Set(pass1, "OutputType", request.OutputType);
            Tasks.Set(pass1, "References", referenceItems);
            if (pageMarkup.Count > 0)
            {
                Tasks.Set(pass1, "PageMarkup", pageMarkup.ToArray());
            }

            if (applicationMarkup.Count > 0)
            {
                Tasks.Set(pass1, "ApplicationMarkup", applicationMarkup.ToArray());
            }

            Tasks.Run(pass1, "MarkupCompilePass1");

            foreach (var file in resolvedFiles)
            {
                var gcsPath = Path.Combine(outDir, Path.ChangeExtension(file.RelativeWinPath, ".g.cs"));
                if (!File.Exists(gcsPath))
                {
                    gcsPath = Path.Combine(outDir, Path.ChangeExtension(file.RelativeWinPath, ".g.i.cs"));
                }

                if (!File.Exists(gcsPath))
                {
                    throw new InvalidOperationException(
                        $"MarkupCompilePass1 did not generate code for {file.RelativeWinPath}");
                }

                Directory.CreateDirectory(Path.GetDirectoryName(file.GeneratedCsFullPath)!);
                File.Copy(gcsPath, file.GeneratedCsFullPath, overwrite: true);
            }

            var allGenerated = Tasks.Get<ITaskItem[]>(pass1, "AllGeneratedFiles") ?? Array.Empty<ITaskItem>();
            var bamlItems = allGenerated
                .Where(item => item.ItemSpec.EndsWith(".baml", StringComparison.OrdinalIgnoreCase))
                .ToArray();

            Directory.CreateDirectory(Path.GetDirectoryName(outputResourcesFullPath)!);
            if (bamlItems.Length > 0)
            {
                var resGen = Tasks.Create(tasks, engine, "Microsoft.Build.Tasks.Windows.ResourcesGenerator");
                Tasks.Set(resGen, "ResourceFiles", bamlItems);
                Tasks.Set(resGen, "OutputPath", outDir + Path.DirectorySeparatorChar);
                Tasks.Set(resGen, "OutputResourcesFile", new ITaskItem[] { new TaskItem(outputResourcesFullPath) });
                Tasks.Run(resGen, "ResourcesGenerator");
            }
            else
            {
                using var writer = new ResourceWriter(outputResourcesFullPath);
                writer.Generate();
            }

            return 0;
        }
        finally
        {
            Directory.SetCurrentDirectory(origDir);
            try
            {
                Directory.Delete(workDir, recursive: true);
            }
            catch
            {
                // Best-effort cleanup of temp directory.
            }
        }
    }

    private static Assembly LoadPresentationBuildTasks(List<string> paths)
    {
        Assembly? presentationBuildTasks = null;
        foreach (var path in paths.OrderBy(p => p.EndsWith("PresentationBuildTasks.dll", StringComparison.OrdinalIgnoreCase) ? 1 : 0))
        {
            var loaded = Tasks.Load(path);
            if (path.EndsWith("PresentationBuildTasks.dll", StringComparison.OrdinalIgnoreCase))
            {
                presentationBuildTasks = loaded;
            }
        }

        return presentationBuildTasks
            ?? throw new InvalidOperationException("PresentationBuildTasks.dll was not provided in tasksAssemblies");
    }

    // See https://github.com/bazel-contrib/rules_dotnet/issues/405:
    // These two DLLs in the .NET Framework targeting pack are native PE images
    // without CLI metadata, which causes MetadataLoadContext in
    // MarkupCompilePass1 to fail with "This PE image is not a managed executable."
    private static bool IsNativeEnterpriseServicesWrapper(string path) =>
        path.EndsWith("System.EnterpriseServices.Thunk.dll", StringComparison.OrdinalIgnoreCase) ||
        path.EndsWith("System.EnterpriseServices.Wrapper.dll", StringComparison.OrdinalIgnoreCase);

    private static bool IsApplicationDefinition(string xamlPath)
    {
        try
        {
            using var reader = XmlReader.Create(xamlPath);
            while (reader.Read())
            {
                if (reader.NodeType == XmlNodeType.Element)
                {
                    return reader.LocalName == "Application" && reader.NamespaceURI == WpfNamespace;
                }
            }
        }
        catch
        {
            // Fall through and let MarkupCompilePass1 report any malformed XML.
        }

        return false;
    }
}
