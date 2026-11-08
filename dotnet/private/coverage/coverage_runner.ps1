# Coverage runner for .Net tests on Windows.
#
# The batch launcher is a thin shim around this script. Everything that involves
# building a command line lives here because cmd re-parses quoted strings and
# mangles backslashes -- the coverage tool's --targetargs is a single string
# holding two absolute Windows paths, which is exactly the case cmd handles
# worst. PowerShell invokes with an argument array, so no quoting is involved.
#
# All inputs arrive in a params file written at analysis time, so the only paths
# that pass through cmd are this script and that file.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $RunfilesManifest,
    [Parameter(Mandatory = $true)][string] $Params,
    # The test's own arguments (e.g. Bazel's --test_filter), forwarded by the launcher.
    [Parameter(ValueFromRemainingArguments = $true)][string[]] $TestArgs = @()
)

$ErrorActionPreference = 'Stop'

# --- runfiles ---------------------------------------------------------------
# The manifest maps "<rlocation path> <absolute path>", one per line. Paths are
# forward-slashed; .Net accepts those, and nothing here shells out to a cmd
# builtin, so they are used as-is.
$runfiles = @{}
foreach ($line in [System.IO.File]::ReadAllLines($RunfilesManifest)) {
    if ($line.Length -eq 0) { continue }
    $split = $line.IndexOf(' ')
    if ($split -lt 0) { continue }
    $runfiles[$line.Substring(0, $split)] = $line.Substring($split + 1)
}

function Resolve-Runfile([string] $rlocationPath) {
    if (-not $runfiles.ContainsKey($rlocationPath)) {
        throw "coverage: '$rlocationPath' is not in the runfiles manifest"
    }
    return $runfiles[$rlocationPath]
}

# --- params -----------------------------------------------------------------
# N <dotnet>  E <test dll>  T <tool>  X <0|1 needs dotnet exec>
# A <extra tool arg>  F <file to stage>  D <staged dir for --include-directory>
$dotnetRl = $null; $testDllRl = $null; $toolRl = $null
$needsDotnetExec = $false
$extraArgs = New-Object System.Collections.Generic.List[string]
$stageFiles = New-Object System.Collections.Generic.List[string]
$includeDirs = New-Object System.Collections.Generic.List[string]

foreach ($line in [System.IO.File]::ReadAllLines($Params)) {
    if ($line.Length -lt 2) { continue }
    $kind = $line.Substring(0, 1)
    $value = $line.Substring(2)
    switch ($kind) {
        'N' { $dotnetRl = $value }
        'E' { $testDllRl = $value }
        'T' { $toolRl = $value }
        'X' { $needsDotnetExec = ($value -eq '1') }
        'A' { $extraArgs.Add($value) }
        'F' { $stageFiles.Add($value) }
        'D' { $includeDirs.Add($value) }
    }
}

$dotnet = Resolve-Runfile $dotnetRl
$testDll = Resolve-Runfile $testDllRl
$tool = Resolve-Runfile $toolRl

$env:DOTNET_ROOT = Split-Path -Parent $dotnet
$env:DOTNET_MULTILEVEL_LOOKUP = 'false'
$env:DOTNET_NOLOGO = '1'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'

# --- staging ----------------------------------------------------------------
# The coverage tool rewrites assembly IL in place, so it must not be pointed at
# the runfiles tree. Copy the assemblies into a private tree laid out by
# rlocation path; --additionalprobingpath then makes the runtime prefer these
# instrumented copies, because generate_depsjson() keys each dependency by its
# rlocation path and CLI probe paths are consulted before runtimeconfig ones.
$testTmpDir = $env:TEST_TMPDIR
if ([string]::IsNullOrEmpty($testTmpDir)) { $testTmpDir = $env:TEMP }
$stage = Join-Path $testTmpDir '_rules_dotnet_coverage_stage'
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null

$staged = 0
$stagedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
foreach ($rl in $stageFiles) {
    $src = Resolve-Runfile $rl
    if (-not (Test-Path -LiteralPath $src)) {
        throw "coverage: staged file '$rl' resolved to '$src', which does not exist"
    }
    $dest = Join-Path $stage $rl
    New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
    Copy-Item -LiteralPath $src -Destination $dest -Force
    # Runfiles are often read-only; the tool rewrites the assembly in place.
    Set-ItemProperty -LiteralPath $dest -Name IsReadOnly -Value $false
    [void] $stagedSet.Add($rl)
    $staged++
}

# Under --noenable_runfiles there is no .runfiles tree to probe; rewrite
# unstaged rlocation entries in a temporary deps.json so dotnet exec can
# locate dependencies directly from their manifest targets while still loading
# instrumented assemblies from $stage first.
$runfilesTree = $null
if ($RunfilesManifest.EndsWith('_manifest')) {
    $candidateTree = $RunfilesManifest.Substring(0, $RunfilesManifest.Length - 9)
    if (Test-Path -LiteralPath $candidateTree) { $runfilesTree = $candidateTree }
}

$manifestDepsFile = $null
$manifestProbeDirs = New-Object System.Collections.Generic.List[string]
if ($null -eq $runfilesTree) {
    $origDepsFile = [System.IO.Path]::ChangeExtension($testDll, '.deps.json')
    if (Test-Path -LiteralPath $origDepsFile) {
        Add-Type -AssemblyName System.Web.Extensions
        $jsonSerializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $jsonSerializer.MaxJsonLength = [int]::MaxValue
        $depsDoc = $jsonSerializer.DeserializeObject([System.IO.File]::ReadAllText($origDepsFile))
        $targetsDict = if ($null -ne $depsDoc -and $depsDoc.ContainsKey('targets')) { $depsDoc['targets'] } else { $null }
        if ($null -ne $targetsDict) {
            $commonDirs = @{}
            $resolvedMap = @{}
            foreach ($tKey in $targetsDict.Keys) {
                $libsDict = $targetsDict[$tKey]
                if ($null -eq $libsDict) { continue }
                foreach ($libKey in $libsDict.Keys) {
                    $libDict = $libsDict[$libKey]
                    if ($null -eq $libDict) { continue }
                    foreach ($sec in @('runtime', 'resources', 'native')) {
                        if (-not $libDict.ContainsKey($sec) -or $null -eq $libDict[$sec]) { continue }
                        $secDict = $libDict[$sec]
                        foreach ($rk in $secDict.Keys) {
                            if ($stagedSet.Contains($rk) -or $resolvedMap.ContainsKey($rk)) { continue }
                            if (-not $runfiles.ContainsKey($rk)) { continue }
                            $full = [System.IO.Path]::GetFullPath(($runfiles[$rk] -replace '/', '\'))
                            $dir = [System.IO.Path]::GetDirectoryName($full)
                            if ([string]::IsNullOrEmpty($dir)) { continue }
                            $rootKey = ([System.IO.Path]::GetPathRoot($full)).ToUpperInvariant()
                            $resolvedMap[$rk] = @{ Root = $rootKey; Full = $full }
                            if (-not $commonDirs.ContainsKey($rootKey)) {
                                $commonDirs[$rootKey] = $dir
                            } else {
                                $cur = $commonDirs[$rootKey].TrimEnd('\')
                                $oth = $dir.TrimEnd('\')
                                while ($cur.Length -gt $rootKey.Length) {
                                    if ($oth.Equals($cur, [System.StringComparison]::OrdinalIgnoreCase) -or
                                        ($oth.StartsWith($cur, [System.StringComparison]::OrdinalIgnoreCase) -and $oth.Length -gt $cur.Length -and $oth[$cur.Length] -eq '\')) {
                                        break
                                    }
                                    $parent = [System.IO.Path]::GetDirectoryName($cur)
                                    if ([string]::IsNullOrEmpty($parent)) { $cur = $rootKey; break }
                                    $cur = $parent.TrimEnd('\')
                                }
                                if ([string]::IsNullOrEmpty($cur)) { $cur = $rootKey }
                                $commonDirs[$rootKey] = $cur
                            }
                        }
                    }
                }
            }
            if ($resolvedMap.Count -gt 0) {
                foreach ($tKey in @($targetsDict.Keys)) {
                    $libsDict = $targetsDict[$tKey]
                    if ($null -eq $libsDict) { continue }
                    foreach ($libKey in @($libsDict.Keys)) {
                        $libDict = $libsDict[$libKey]
                        if ($null -eq $libDict) { continue }
                        foreach ($sec in @('runtime', 'resources', 'native')) {
                            if (-not $libDict.ContainsKey($sec) -or $null -eq $libDict[$sec] -or $libDict[$sec].Count -eq 0) { continue }
                            $secDict = $libDict[$sec]
                            $newSec = New-Object 'System.Collections.Generic.Dictionary[string,object]'
                            foreach ($ak in $secDict.Keys) {
                                $nk = $ak
                                if ($resolvedMap.ContainsKey($nk)) {
                                    $entry = $resolvedMap[$nk]
                                    $basePrefix = $commonDirs[$entry.Root].TrimEnd('\') + '\'
                                    $nk = $entry.Full.Substring($basePrefix.Length) -replace '\\', '/'
                                }
                                $newSec[$nk] = $secDict[$ak]
                            }
                            $libDict[$sec] = $newSec
                        }
                    }
                }
                foreach ($rk in $commonDirs.Keys) {
                    $pd = $commonDirs[$rk]
                    if ($pd.EndsWith('\')) { $pd = $pd + '.' }
                    $manifestProbeDirs.Add($pd)
                }
                $manifestAppDir = Join-Path $testTmpDir '_rules_dotnet_app'
                New-Item -ItemType Directory -Path $manifestAppDir -Force | Out-Null
                $srcAppDir = [System.IO.Path]::GetDirectoryName($testDll)
                $fullDepsJson = [System.IO.Path]::GetFullPath($depsJsonPath)
                if (-not [string]::IsNullOrEmpty($srcAppDir) -and [System.IO.Directory]::Exists($srcAppDir)) {
                    $srcPrefix = $srcAppDir.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
                    $dirStack = New-Object System.Collections.Generic.Stack[string]
                    $dirStack.Push($srcAppDir)
                    while ($dirStack.Count -gt 0) {
                        $curDir = $dirStack.Pop()
                        foreach ($sf in [System.IO.Directory]::GetFiles($curDir)) {
                            $fullSf = [System.IO.Path]::GetFullPath($sf)
                            if ([string]::Equals($fullSf, $fullDepsJson, [System.StringComparison]::OrdinalIgnoreCase) -or
                                $sf.EndsWith('.runfiles_manifest', [System.StringComparison]::OrdinalIgnoreCase) -or
                                $sf.EndsWith('.launch.json', [System.StringComparison]::OrdinalIgnoreCase)) {
                                continue
                            }
                            $relSf = $fullSf.Substring($srcPrefix.Length)
                            $dstSf = Join-Path $manifestAppDir $relSf
                            $dstParent = [System.IO.Path]::GetDirectoryName($dstSf)
                            if (-not [string]::IsNullOrEmpty($dstParent)) {
                                [System.IO.Directory]::CreateDirectory($dstParent) | Out-Null
                            }
                            try { [System.IO.File]::Copy($sf, $dstSf, $true) } catch {}
                        }
                        foreach ($sd in [System.IO.Directory]::GetDirectories($curDir)) {
                            if (-not $sd.EndsWith('.runfiles', [System.StringComparison]::OrdinalIgnoreCase)) {
                                $dirStack.Push($sd)
                            }
                        }
                    }
                }
                $manifestDepsFile = Join-Path $manifestAppDir ([System.IO.Path]::GetFileName($depsJsonPath))
                $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
                [System.IO.File]::WriteAllText($manifestDepsFile, $jsonSerializer.Serialize($depsDoc), $utf8NoBom)
            }
        }
    }
}

$testAppDir = [System.IO.Path]::GetDirectoryName($testDll)

# Nothing to instrument (a test with no first-party library deps). Run the test
# plainly rather than handing the host a probing path it would ignore.
if ($staged -eq 0) {
    $plainArgs = New-Object System.Collections.Generic.List[string]
    $plainArgs.Add('exec')
    if ($null -ne $manifestDepsFile) {
        $plainArgs.Add('--depsfile')
        $plainArgs.Add($manifestDepsFile)
        foreach ($pd in $manifestProbeDirs) {
            $plainArgs.Add('--additionalprobingpath')
            $plainArgs.Add($pd)
        }
    } elseif ($null -ne $runfilesTree) {
        $plainArgs.Add('--additionalprobingpath')
        $plainArgs.Add($runfilesTree)
    }
    if (-not [string]::IsNullOrEmpty($testAppDir)) {
        $plainArgs.Add('--additionalprobingpath')
        $plainArgs.Add($testAppDir)
    }
    $plainArgs.Add($testDll)
    foreach ($ta in $TestArgs) { $plainArgs.Add($ta) }
    & $dotnet @plainArgs
    exit $LASTEXITCODE
}

# --- invoke -----------------------------------------------------------------
# Write into COVERAGE_DIR, not COVERAGE_OUTPUT_FILE: Bazel's LCOV merger reads
# COVERAGE_DIR and writes COVERAGE_OUTPUT_FILE, so producing only the latter
# means the merger finds no input and overwrites it with an empty report. The
# ".dat" extension is what the merger looks for.
$rawLcov = Join-Path $env:COVERAGE_DIR 'coverlet.dat'
New-Item -ItemType Directory -Path $env:COVERAGE_DIR -Force | Out-Null

# --targetargs is a single string that the coverage tool re-parses into an
# argument list, so the paths inside it have to be quoted.
$targetArgs = 'exec'
if ($null -ne $manifestDepsFile) {
    $targetArgs += ' --depsfile "{0}"' -f $manifestDepsFile
}
$targetArgs += ' --additionalprobingpath "{0}"' -f $stage
if ($null -ne $runfilesTree) {
    $targetArgs += ' --additionalprobingpath "{0}"' -f $runfilesTree
} else {
    foreach ($pd in $manifestProbeDirs) {
        $targetArgs += ' --additionalprobingpath "{0}"' -f $pd
    }
}
if (-not [string]::IsNullOrEmpty($testAppDir)) {
    $targetArgs += ' --additionalprobingpath "{0}"' -f $testAppDir
}
$targetArgs += ' "{0}"' -f $testDll
foreach ($arg in $TestArgs) {
    $targetArgs += ' "{0}"' -f ($arg -replace '"', '\"')
}

$toolArgs = New-Object System.Collections.Generic.List[string]
if ($needsDotnetExec) { $toolArgs.Add('exec'); $toolArgs.Add($tool) }
$toolArgs.Add($testDll)
foreach ($dir in $includeDirs) {
    $toolArgs.Add('--include-directory')
    $toolArgs.Add((Join-Path $stage $dir))
}
$toolArgs.AddRange([string[]]@(
    '--target', $dotnet,
    '--targetargs', $targetArgs,
    '--format', 'lcov',
    '--output', $rawLcov,
    # Without this the default heuristic drops every module whose PDB documents
    # do not resolve on disk. rules_dotnet does not stage srcs into runfiles, so
    # that would be all of them -- silently, at verbose log level only.
    '--exclude-assemblies-without-sources', 'None'
))
foreach ($extra in $extraArgs) { $toolArgs.Add($extra) }

# Windows PowerShell does not escape embedded double quotes when it builds a
# native command line, so passing --targetargs through its argument handling
# splits it into separate arguments. Build the command line here instead and
# hand it to ProcessStartInfo verbatim. (.Net Framework has no ArgumentList,
# which would do this for us; that is .Net Core only.)
function Format-NativeArg([string] $value) {
    if ($value.Length -gt 0 -and $value -notmatch '[ \t"]') { return $value }

    $sb = New-Object System.Text.StringBuilder
    [void] $sb.Append('"')
    $backslashes = 0
    foreach ($ch in $value.ToCharArray()) {
        if ($ch -eq '\') {
            $backslashes++
        } elseif ($ch -eq '"') {
            # Backslashes before a quote are doubled, then the quote is escaped.
            [void] $sb.Append('\' * ($backslashes * 2 + 1))
            [void] $sb.Append('"')
            $backslashes = 0
        } else {
            if ($backslashes -gt 0) { [void] $sb.Append('\' * $backslashes) }
            [void] $sb.Append($ch)
            $backslashes = 0
        }
    }
    # Backslashes before the closing quote are doubled so they stay literal.
    if ($backslashes -gt 0) { [void] $sb.Append('\' * ($backslashes * 2)) }
    [void] $sb.Append('"')
    return $sb.ToString()
}

if ($needsDotnetExec) { $exe = $dotnet } else { $exe = $tool }
$commandLine = (($toolArgs | ForEach-Object { Format-NativeArg $_ }) -join ' ')

if (-not [string]::IsNullOrEmpty($env:VERBOSE_COVERAGE)) {
    Write-Host "coverage: $exe $commandLine"
}

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $exe
$psi.Arguments = $commandLine
$psi.UseShellExecute = $false
$process = [System.Diagnostics.Process]::Start($psi)
$process.WaitForExit()
$status = $process.ExitCode
if ($status -ne 0) { exit $status }

if (-not (Test-Path -LiteralPath $rawLcov)) {
    Write-Error "coverage: the coverage tool did not produce an LCOV report at $rawLcov"
    exit 1
}

# --- normalize --------------------------------------------------------------
# Keep the unmodified report: Bazel deletes COVERAGE_DIR after the run, and if
# the rewriting below does not match what the tool emitted the result is an
# empty-but-successful report with no way to see why.
if (-not [string]::IsNullOrEmpty($env:TEST_UNDECLARED_OUTPUTS_DIR)) {
    New-Item -ItemType Directory -Path $env:TEST_UNDECLARED_OUTPUTS_DIR -Force | Out-Null
    Copy-Item -LiteralPath $rawLcov -Destination (Join-Path $env:TEST_UNDECLARED_OUTPUTS_DIR 'coverlet.raw.dat') -Force
}

# 1. compiler_wrapper.bat pathmaps against a backslash %cd%, so PDB documents --
#    and therefore SF: lines -- are workspace relative with a leading ".\".
# 2. Bazel's coverage manifest holds forward-slash exec paths and matches by
#    exact string, so separators have to be flipped. SF: lines only.
# 3. FN:/FNDA: records are keyed by the full method signature, which contains
#    commas; Bazel's LcovParser splits on "," and rejects them. Replace commas
#    inside the method name with spaces so function coverage is preserved.
$normalized = foreach ($line in [System.IO.File]::ReadAllLines($rawLcov)) {
    if ($line -match '^(FN(?:DA)?:\d+,)(.*)$') {
        $Matches[1] + ($Matches[2] -replace ',', ' ')
    } elseif ($line.StartsWith('SF:')) {
        (($line -replace '^SF:.*[/\\]execroot[/\\][^/\\]+[/\\]', 'SF:') -replace '^SF:\.[\\/]', 'SF:') -replace '\\', '/'
    } else {
        $line
    }
}
[System.IO.File]::WriteAllLines($rawLcov, [string[]]$normalized)

if (-not ($normalized | Where-Object { $_.StartsWith('SF:') })) {
    Write-Warning 'the coverage report contains no source files after normalization.'
    Write-Warning 'the unnormalized report was saved as coverlet.raw.dat in the test outputs.'
}
exit 0
