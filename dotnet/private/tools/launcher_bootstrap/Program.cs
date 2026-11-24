#nullable enable

using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace RulesDotnet.LauncherBootstrap;

internal static class Program
{
    [DllImport("libc", EntryPoint = "execve", SetLastError = true)]
    private static extern int PosixExecve(IntPtr pathname, IntPtr[] argv, IntPtr[] envp);

    public static int Main(string[] args)
    {
        if (args.Length < 1)
        {
            Console.Error.WriteLine("ERROR: launcher_bootstrap requires a launch configuration path.");
            return 1;
        }

        LaunchConfig config;
        try
        {
            config = LaunchConfig.Load(args[0]);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"ERROR: Failed to read launch configuration '{args[0]}': {ex.Message}");
            return 1;
        }

        var comparer = OperatingSystem.IsWindows()
            ? StringComparer.OrdinalIgnoreCase
            : StringComparer.Ordinal;
        var env = new Dictionary<string, string>(comparer);
        foreach (DictionaryEntry entry in Environment.GetEnvironmentVariables())
        {
            if (entry.Key is string key && entry.Value is string value)
            {
                env[key] = value;
            }
        }

        env.TryGetValue("RUNFILES_MANIFEST_FILE", out var manifestFile);
        if (!env.TryGetValue("RUNFILES_DIR", out var runfilesDir) || string.IsNullOrEmpty(runfilesDir))
        {
            env.TryGetValue("JAVA_RUNFILES", out runfilesDir);
        }

        if (!string.IsNullOrEmpty(manifestFile))
        {
            manifestFile = Path.GetFullPath(NormalizeSeparators(manifestFile));
        }

        // On Windows, hermetic_launcher prefers RUNFILES_MANIFEST_FILE and omits
        // RUNFILES_DIR from the child environment even when Bazel materialized a
        // runfiles tree alongside the manifest. Recover the adjacent tree when
        // present so `--additionalprobingpath` can still probe the runfiles tree.
        if (string.IsNullOrEmpty(runfilesDir) && !string.IsNullOrEmpty(manifestFile))
        {
            if (manifestFile.EndsWith("_manifest", StringComparison.Ordinal))
            {
                runfilesDir = manifestFile[..^"_manifest".Length];
            }
            else if (string.Equals(Path.GetFileName(manifestFile), "MANIFEST", StringComparison.Ordinal))
            {
                runfilesDir = Path.GetDirectoryName(manifestFile);
            }
        }

        if (!string.IsNullOrEmpty(runfilesDir))
        {
            runfilesDir = Path.GetFullPath(NormalizeSeparators(runfilesDir))
                .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            var assemblyInTree = Path.Combine(
                runfilesDir,
                config.Assembly.Replace('/', Path.DirectorySeparatorChar));
            if (!Directory.Exists(runfilesDir) || !File.Exists(assemblyInTree))
            {
                runfilesDir = null;
            }
        }

        if (runfilesDir != null && string.IsNullOrEmpty(manifestFile))
        {
            var siblingManifest = runfilesDir + "_manifest";
            var nestedManifest = Path.Combine(runfilesDir, "MANIFEST");
            if (File.Exists(siblingManifest))
            {
                manifestFile = siblingManifest;
            }
            else if (File.Exists(nestedManifest))
            {
                manifestFile = nestedManifest;
            }
        }

        // On Windows, prefer manifest resolution when available (matching
        // hermetic_launcher and rules_dotnet's historical Windows launcher):
        // manifest entries point directly to the underlying files in bazel-out/
        // and external/ instead of doubling path lengths through .runfiles symlinks.
        var preferManifest = OperatingSystem.IsWindows() && !string.IsNullOrEmpty(manifestFile);
        Dictionary<string, string>? manifest = null;

        string? TryLookupManifest(string rpath)
        {
            if (string.IsNullOrEmpty(manifestFile))
            {
                return null;
            }

            manifest ??= LoadManifest(manifestFile);
            if (manifest.TryGetValue(rpath, out var target))
            {
                return NormalizeSeparators(target);
            }

            var prefix = rpath + "/";
            foreach (var kv in manifest)
            {
                if (kv.Key.StartsWith(prefix, StringComparison.Ordinal) &&
                    kv.Value.Length > kv.Key.Length - rpath.Length)
                {
                    var dirTarget = kv.Value[..^(kv.Key.Length - rpath.Length)];
                    return NormalizeSeparators(dirTarget);
                }
            }

            return null;
        }

        string? TryLookupDirectory(string rpath)
        {
            if (runfilesDir == null)
            {
                return null;
            }

            var candidate = Path.Combine(runfilesDir, rpath.Replace('/', Path.DirectorySeparatorChar));
            return File.Exists(candidate) || Directory.Exists(candidate) ? candidate : null;
        }

        string Rlocation(string rpath)
        {
            var resolved = preferManifest
                ? TryLookupManifest(rpath) ?? TryLookupDirectory(rpath)
                : TryLookupDirectory(rpath) ?? TryLookupManifest(rpath);
            if (resolved != null)
            {
                return resolved;
            }

            if (!preferManifest && runfilesDir != null)
            {
                return Path.Combine(runfilesDir, rpath.Replace('/', Path.DirectorySeparatorChar));
            }

            throw new FileNotFoundException($"Runfile '{rpath}' was not found.");
        }

        string dotnetPath;
        string assemblyPath;
        try
        {
            dotnetPath = !string.IsNullOrEmpty(Environment.ProcessPath) && File.Exists(Environment.ProcessPath)
                ? Environment.ProcessPath
                : Rlocation(config.Dotnet);
            assemblyPath = Rlocation(config.Assembly);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"ERROR: {ex.Message}");
            return 1;
        }

        env["DOTNET_MULTILEVEL_LOOKUP"] = "0";
        env["DOTNET_NOLOGO"] = "1";
        env["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1";
        env["DOTNET_ROOT"] = Path.GetDirectoryName(dotnetPath)!;

        // Bazel leaves windir out of test and action environments, and WPF fails to start without it.
        if (OperatingSystem.IsWindows() &&
            (!env.TryGetValue("windir", out var existingWindir) || string.IsNullOrEmpty(existingWindir)) &&
            env.TryGetValue("SystemRoot", out var systemRoot) &&
            !string.IsNullOrEmpty(systemRoot))
        {
            env["windir"] = systemRoot;
        }

        if (!string.IsNullOrEmpty(config.RollForward) &&
            (!env.TryGetValue("DOTNET_ROLL_FORWARD", out var existingRollForward) || string.IsNullOrEmpty(existingRollForward)))
        {
            env["DOTNET_ROLL_FORWARD"] = config.RollForward;
        }

        if (preferManifest)
        {
            env["RUNFILES_MANIFEST_FILE"] = manifestFile!;
            env["RUNFILES_MANIFEST_ONLY"] = "1";
            env.Remove("RUNFILES_DIR");
            env.Remove("JAVA_RUNFILES");
        }
        else if (runfilesDir != null)
        {
            env["RUNFILES_DIR"] = runfilesDir;
            env["JAVA_RUNFILES"] = runfilesDir;
            env.Remove("RUNFILES_MANIFEST_ONLY");
            if (!string.IsNullOrEmpty(manifestFile))
            {
                env["RUNFILES_MANIFEST_FILE"] = manifestFile;
            }
        }
        else if (!string.IsNullOrEmpty(manifestFile))
        {
            env["RUNFILES_MANIFEST_FILE"] = manifestFile;
            env["RUNFILES_MANIFEST_ONLY"] = "1";
        }

        if (config.InvariantGlobalization)
        {
            if (!env.TryGetValue("DOTNET_SYSTEM_GLOBALIZATION_INVARIANT", out var existing) ||
                string.IsNullOrEmpty(existing))
            {
                env["DOTNET_SYSTEM_GLOBALIZATION_INVARIANT"] = "1";
            }
        }

        if (!string.IsNullOrEmpty(config.IcuLib))
        {
            var icuLibrary = Rlocation(config.IcuLib);
            var icuDir = Path.GetDirectoryName(icuLibrary)!;
            env["LD_LIBRARY_PATH"] = env.TryGetValue("LD_LIBRARY_PATH", out var ldLibraryPath) &&
                                     !string.IsNullOrEmpty(ldLibraryPath)
                ? $"{icuDir}:{ldLibraryPath}"
                : icuDir;
            env["DOTNET_ICU_VERSION_OVERRIDE"] = config.IcuVersion;
            env["CLR_ICU_VERSION_OVERRIDE"] = config.IcuVersion;
        }

        string? workingDirectory = null;
        if (config.UseBuildWorkingDirectory &&
            env.TryGetValue("BUILD_WORKING_DIRECTORY", out var bwd) &&
            !string.IsNullOrEmpty(bwd))
        {
            workingDirectory = bwd;
        }

        var execArgs = new List<string>(args.Length + 14) { "exec" };
        string? tempManifestAppDir = null;
        if (config.ProbeRunfiles)
        {
            var appDir = Path.GetDirectoryName(assemblyPath);
            if (runfilesDir != null)
            {
                execArgs.Add("--additionalprobingpath");
                execArgs.Add(runfilesDir);
                if (!string.IsNullOrEmpty(appDir))
                {
                    execArgs.Add("--additionalprobingpath");
                    execArgs.Add(appDir);
                }
            }
            else if (!string.IsNullOrEmpty(manifestFile))
            {
                env.TryGetValue("TEST_TMPDIR", out var testTmpDir);
                var tempDepsFile = TryCreateManifestDepsFile(
                    assemblyPath,
                    TryLookupManifest,
                    testTmpDir,
                    out tempManifestAppDir,
                    out var manifestProbingPaths);
                if (tempDepsFile != null)
                {
                    execArgs.Add("--depsfile");
                    execArgs.Add(tempDepsFile);
                    foreach (var probePath in manifestProbingPaths)
                    {
                        execArgs.Add("--additionalprobingpath");
                        execArgs.Add(probePath);
                    }
                }

                if (!string.IsNullOrEmpty(appDir))
                {
                    execArgs.Add("--additionalprobingpath");
                    execArgs.Add(appDir);
                }
            }
        }

        execArgs.Add(assemblyPath);

        if (!string.IsNullOrEmpty(config.Application))
        {
            execArgs.Add("--applicationpath");
            execArgs.Add(Rlocation(config.Application));
        }

        if (!string.IsNullOrEmpty(config.WwwRoot))
        {
            execArgs.Add("--contentroot");
            execArgs.Add(Path.GetDirectoryName(Rlocation(config.WwwRoot))!);
        }

        for (var i = 1; i < args.Length; i++)
        {
            execArgs.Add(args[i]);
        }

        if (!OperatingSystem.IsWindows() && tempManifestAppDir == null)
        {
            TryExecve(dotnetPath, execArgs, env, workingDirectory);
        }

        try
        {
            return RunSubprocess(dotnetPath, execArgs, env, workingDirectory);
        }
        finally
        {
            if (tempManifestAppDir != null)
            {
                try
                {
                    Directory.Delete(tempManifestAppDir, recursive: true);
                }
                catch
                {
                    // Best-effort cleanup of temporary manifest app directory.
                }
            }
        }
    }

    private static string? TryCreateManifestDepsFile(
        string assemblyPath,
        Func<string, string?> tryResolve,
        string? preferredTempDir,
        out string? tempAppDir,
        out List<string> probingPaths)
    {
        tempAppDir = null;
        probingPaths = new List<string>();
        var depsJsonPath = Path.ChangeExtension(assemblyPath, ".deps.json");
        if (!File.Exists(depsJsonPath))
        {
            return null;
        }

        byte[] rawBytes;
        try
        {
            rawBytes = File.ReadAllBytes(depsJsonPath);
        }
        catch
        {
            return null;
        }

        using var doc = JsonDocument.Parse(rawBytes);
        var root = doc.RootElement;
        if (root.ValueKind != JsonValueKind.Object ||
            !root.TryGetProperty("targets", out var targetsEl) ||
            targetsEl.ValueKind != JsonValueKind.Object)
        {
            return null;
        }

        var rootComparer = OperatingSystem.IsWindows()
            ? StringComparer.OrdinalIgnoreCase
            : StringComparer.Ordinal;
        var commonDirsByRoot = new Dictionary<string, string>(rootComparer);
        var resolvedByRpath = new Dictionary<string, (string RootKey, string FullPath)>(StringComparer.Ordinal);
        var assetSections = new[] { "runtime", "resources", "native" };

        foreach (var targetProp in targetsEl.EnumerateObject())
        {
            if (targetProp.Value.ValueKind != JsonValueKind.Object)
            {
                continue;
            }

            foreach (var libProp in targetProp.Value.EnumerateObject())
            {
                if (libProp.Value.ValueKind != JsonValueKind.Object)
                {
                    continue;
                }

                foreach (var section in assetSections)
                {
                    if (!libProp.Value.TryGetProperty(section, out var secEl) ||
                        secEl.ValueKind != JsonValueKind.Object)
                    {
                        continue;
                    }

                    foreach (var assetProp in secEl.EnumerateObject())
                    {
                        var rpath = assetProp.Name;
                        if (resolvedByRpath.ContainsKey(rpath))
                        {
                            continue;
                        }

                        var resolved = tryResolve(rpath);
                        if (string.IsNullOrEmpty(resolved))
                        {
                            continue;
                        }

                        var fullPath = Path.GetFullPath(resolved);
                        var dir = Path.GetDirectoryName(fullPath);
                        if (string.IsNullOrEmpty(dir))
                        {
                            continue;
                        }

                        var rootKey = Path.GetPathRoot(fullPath) ?? "";
                        resolvedByRpath[rpath] = (rootKey, fullPath);
                        commonDirsByRoot[rootKey] = commonDirsByRoot.TryGetValue(rootKey, out var existingCommon)
                            ? CommonDirectoryPrefix(existingCommon, dir, rootKey)
                            : dir;
                    }
                }
            }
        }

        if (resolvedByRpath.Count == 0)
        {
            return null;
        }

        foreach (var kv in commonDirsByRoot)
        {
            var probeDir = kv.Value;
            if (string.Equals(probeDir, kv.Key, OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal) &&
                probeDir.EndsWith(Path.DirectorySeparatorChar))
            {
                probeDir += ".";
            }

            probingPaths.Add(probeDir);
        }

        var tempDir = !string.IsNullOrEmpty(preferredTempDir) && Directory.Exists(preferredTempDir)
            ? preferredTempDir
            : Path.GetTempPath();
        tempAppDir = Path.Combine(tempDir, $"dotnet-manifest-{Guid.NewGuid():N}");
        Directory.CreateDirectory(tempAppDir);

        // .NET hostpolicy derives AppContext.BaseDirectory from the --depsfile directory,
        // so mirror staged files (content_files, appsettings, runtimes/) from appDir.
        var sourceAppDir = Path.GetDirectoryName(assemblyPath);
        if (!string.IsNullOrEmpty(sourceAppDir) && Directory.Exists(sourceAppDir))
        {
            MirrorAppDirectory(sourceAppDir, tempAppDir, Path.GetFullPath(depsJsonPath));
        }

        var tempPath = Path.Combine(tempAppDir, Path.GetFileName(depsJsonPath));

        using (var fs = File.Create(tempPath))
        using (var writer = new Utf8JsonWriter(fs))
        {
            writer.WriteStartObject();
            foreach (var topProp in root.EnumerateObject())
            {
                if (topProp.NameEquals("targets") && topProp.Value.ValueKind == JsonValueKind.Object)
                {
                    writer.WritePropertyName("targets");
                    writer.WriteStartObject();
                    foreach (var targetProp in topProp.Value.EnumerateObject())
                    {
                        writer.WritePropertyName(targetProp.Name);
                        if (targetProp.Value.ValueKind != JsonValueKind.Object)
                        {
                            targetProp.Value.WriteTo(writer);
                            continue;
                        }

                        writer.WriteStartObject();
                        foreach (var libProp in targetProp.Value.EnumerateObject())
                        {
                            writer.WritePropertyName(libProp.Name);
                            if (libProp.Value.ValueKind != JsonValueKind.Object)
                            {
                                libProp.Value.WriteTo(writer);
                                continue;
                            }

                            writer.WriteStartObject();
                            foreach (var memberProp in libProp.Value.EnumerateObject())
                            {
                                writer.WritePropertyName(memberProp.Name);
                                if (memberProp.Value.ValueKind == JsonValueKind.Object &&
                                    (memberProp.NameEquals("runtime") ||
                                     memberProp.NameEquals("resources") ||
                                     memberProp.NameEquals("native")))
                                {
                                    writer.WriteStartObject();
                                    foreach (var assetProp in memberProp.Value.EnumerateObject())
                                    {
                                        var newKey = assetProp.Name;
                                        if (resolvedByRpath.TryGetValue(assetProp.Name, out var info) &&
                                            commonDirsByRoot.TryGetValue(info.RootKey, out var commonDir))
                                        {
                                            newKey = Path.GetRelativePath(commonDir, info.FullPath).Replace('\\', '/');
                                        }

                                        writer.WritePropertyName(newKey);
                                        assetProp.Value.WriteTo(writer);
                                    }

                                    writer.WriteEndObject();
                                }
                                else
                                {
                                    memberProp.Value.WriteTo(writer);
                                }
                            }

                            writer.WriteEndObject();
                        }

                        writer.WriteEndObject();
                    }

                    writer.WriteEndObject();
                }
                else
                {
                    topProp.WriteTo(writer);
                }
            }

            writer.WriteEndObject();
        }

        return tempPath;
    }

    private static void MirrorAppDirectory(string sourceDir, string destDir, string skipDepsFullPath)
    {
        var pathComparison = OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase
            : StringComparison.Ordinal;

        MirrorDirectoryEntries(sourceDir, sourceDir, destDir, skipDepsFullPath, pathComparison);
    }

    private static void MirrorDirectoryEntries(
        string rootDir,
        string currentDir,
        string destRootDir,
        string skipDepsFullPath,
        StringComparison pathComparison)
    {
        foreach (var srcFile in Directory.EnumerateFiles(currentDir))
        {
            var fullSrc = Path.GetFullPath(srcFile);
            if (string.Equals(fullSrc, skipDepsFullPath, pathComparison) ||
                srcFile.EndsWith(".runfiles_manifest", pathComparison) ||
                srcFile.EndsWith(".launch.json", pathComparison))
            {
                continue;
            }

            var relPath = Path.GetRelativePath(rootDir, srcFile);
            var dstFile = Path.Combine(destRootDir, relPath);
            var dstParent = Path.GetDirectoryName(dstFile);
            if (!string.IsNullOrEmpty(dstParent))
            {
                Directory.CreateDirectory(dstParent);
            }

            try
            {
                File.Copy(srcFile, dstFile, overwrite: true);
            }
            catch
            {
                // Ignore dangling symlinks or transient lock artifacts in appDir.
            }
        }

        foreach (var subDir in Directory.EnumerateDirectories(currentDir))
        {
            if (subDir.EndsWith(".runfiles", pathComparison))
            {
                continue;
            }

            MirrorDirectoryEntries(rootDir, subDir, destRootDir, skipDepsFullPath, pathComparison);
        }
    }

    private static string CommonDirectoryPrefix(string dirA, string dirB, string root)
    {
        var comparison = OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase
            : StringComparison.Ordinal;
        var current = Path.TrimEndingDirectorySeparator(dirA);
        var other = Path.TrimEndingDirectorySeparator(dirB);
        var sep = Path.DirectorySeparatorChar;

        while (current.Length > root.Length)
        {
            if (string.Equals(current, other, comparison) ||
                (other.StartsWith(current, comparison) &&
                 other.Length > current.Length &&
                 other[current.Length] == sep))
            {
                return current;
            }

            var parent = Path.GetDirectoryName(current);
            if (string.IsNullOrEmpty(parent) || string.Equals(parent, current, comparison))
            {
                return root;
            }

            current = Path.TrimEndingDirectorySeparator(parent);
        }

        return string.IsNullOrEmpty(current) ? root : current;
    }

    private static void TryExecve(
        string dotnetPath,
        IReadOnlyList<string> execArgs,
        IReadOnlyDictionary<string, string> env,
        string? workingDirectory)
    {
        var previousDirectory = workingDirectory != null ? Directory.GetCurrentDirectory() : null;
        if (workingDirectory != null)
        {
            Directory.SetCurrentDirectory(workingDirectory);
        }

        var pathPtr = Marshal.StringToCoTaskMemUTF8(dotnetPath);
        var argvPtrs = new IntPtr[execArgs.Count + 2];
        argvPtrs[0] = pathPtr;
        for (var i = 0; i < execArgs.Count; i++)
        {
            argvPtrs[i + 1] = Marshal.StringToCoTaskMemUTF8(execArgs[i]);
        }

        argvPtrs[^1] = IntPtr.Zero;

        var envpPtrs = new IntPtr[env.Count + 1];
        var envIndex = 0;
        foreach (var kv in env)
        {
            envpPtrs[envIndex++] = Marshal.StringToCoTaskMemUTF8($"{kv.Key}={kv.Value}");
        }

        envpPtrs[^1] = IntPtr.Zero;

        try
        {
            _ = PosixExecve(pathPtr, argvPtrs, envpPtrs);
        }
        catch (Exception ex) when (ex is DllNotFoundException or EntryPointNotFoundException)
        {
        }

        // Only reached if execve failed; restore state, free buffers, and fall back to Process.Start.
        if (previousDirectory != null)
        {
            Directory.SetCurrentDirectory(previousDirectory);
        }

        for (var i = 0; i < argvPtrs.Length - 1; i++)
        {
            Marshal.FreeCoTaskMem(argvPtrs[i]);
        }

        for (var i = 0; i < envpPtrs.Length - 1; i++)
        {
            Marshal.FreeCoTaskMem(envpPtrs[i]);
        }
    }

    private static int RunSubprocess(
        string dotnetPath,
        IReadOnlyList<string> execArgs,
        IReadOnlyDictionary<string, string> env,
        string? workingDirectory)
    {
        var psi = new ProcessStartInfo(dotnetPath)
        {
            UseShellExecute = false,
        };
        if (workingDirectory != null)
        {
            psi.WorkingDirectory = workingDirectory;
        }

        foreach (var arg in execArgs)
        {
            psi.ArgumentList.Add(arg);
        }

        psi.Environment.Clear();
        foreach (var kv in env)
        {
            psi.Environment[kv.Key] = kv.Value;
        }

        Console.CancelKeyPress += static (_, e) => e.Cancel = true;

        using var process = Process.Start(psi);
        if (process == null)
        {
            Console.Error.WriteLine($"ERROR: Failed to start '{dotnetPath}'.");
            return 1;
        }

        process.WaitForExit();
        return process.ExitCode;
    }

    private static string NormalizeSeparators(string path) =>
        OperatingSystem.IsWindows() ? path.Replace('/', '\\') : path;

    private static Dictionary<string, string> LoadManifest(string manifestFile)
    {
        var map = new Dictionary<string, string>(StringComparer.Ordinal);
        var normalized = NormalizeSeparators(manifestFile);
        if (!File.Exists(normalized))
        {
            return map;
        }

        foreach (var line in File.ReadLines(normalized))
        {
            if (line.Length == 0)
            {
                continue;
            }

            if (line[0] == ' ')
            {
                var sep = line.IndexOf(' ', 1);
                if (sep > 1)
                {
                    var key = UnescapeManifest(line.AsSpan(1, sep - 1));
                    var value = UnescapeManifest(line.AsSpan(sep + 1));
                    map[key] = value;
                }
            }
            else
            {
                var sep = line.IndexOf(' ');
                if (sep > 0)
                {
                    map[line[..sep]] = line[(sep + 1)..];
                }
            }
        }

        return map;
    }

    private static string UnescapeManifest(ReadOnlySpan<char> text)
    {
        if (text.IndexOf('\\') < 0)
        {
            return text.ToString();
        }

        var sb = new StringBuilder(text.Length);
        for (var i = 0; i < text.Length; i++)
        {
            if (text[i] == '\\' && i + 1 < text.Length)
            {
                i++;
                sb.Append(text[i] switch
                {
                    's' => ' ',
                    'n' => '\n',
                    'b' => '\\',
                    var other => other,
                });
            }
            else
            {
                sb.Append(text[i]);
            }
        }

        return sb.ToString();
    }

    private sealed class LaunchConfig
    {
        public string Dotnet { get; init; } = "";
        public string Assembly { get; init; } = "";
        public bool ProbeRunfiles { get; init; }
        public bool UseBuildWorkingDirectory { get; init; }
        public string RollForward { get; init; } = "";
        public bool InvariantGlobalization { get; init; }
        public string IcuLib { get; init; } = "";
        public string IcuVersion { get; init; } = "";
        public string Application { get; init; } = "";
        public string WwwRoot { get; init; } = "";

        public static LaunchConfig Load(string path)
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(NormalizeSeparators(path)));
            var root = doc.RootElement;
            return new LaunchConfig
            {
                Dotnet = GetString(root, "dotnet"),
                Assembly = GetString(root, "assembly"),
                ProbeRunfiles = GetBool(root, "probe_runfiles"),
                UseBuildWorkingDirectory = GetBool(root, "use_build_working_directory"),
                RollForward = GetString(root, "roll_forward"),
                InvariantGlobalization = GetBool(root, "invariant_globalization"),
                IcuLib = GetString(root, "icu_lib"),
                IcuVersion = GetString(root, "icu_version"),
                Application = GetString(root, "application"),
                WwwRoot = GetString(root, "wwwroot"),
            };
        }

        private static string GetString(JsonElement root, string name) =>
            root.TryGetProperty(name, out var prop) && prop.ValueKind == JsonValueKind.String
                ? prop.GetString() ?? ""
                : "";

        private static bool GetBool(JsonElement root, string name) =>
            root.TryGetProperty(name, out var prop) && prop.ValueKind == JsonValueKind.True;
    }
}
