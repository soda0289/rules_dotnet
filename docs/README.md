# Getting started

## Design

### Dependency resolution

These rules try their best to follow the conventions that are used in the
project files that MSBuild uses. MSBuild is not used behind the scenes
but the compilers and tools that are part of the .Net toolchain are
used directly instead.

The biggest change compared to MSBuild out of the box is that by default
these rules do not propagate transitive dependencies to compilation actions.
This is similar to setting `<DisableTransitiveProjectReferences>true</DisableTransitiveProjectReferences>`
in MSBuild.

This behaviour can be overridden by using the following flag when invoking bazel:
```
--@rules_dotnet//dotnet/settings:strict_deps=false
```
You can add this flag to your `.bazelrc` file to make it the default.

### Debug/Release configurations
These rules follow the Bazel idiomatic way of handling compilation modes by reading the `--compilation_mode` flag.
If the flag is set to either `dbg` or `fastbuild` the rules will compile with relase optimizations disabled.
If the flag is set to `opt` the rules will compile with the release optimizations enabled.

By default Bazel sets the compilation mode to `fastbuild`.

If you want to e.g. enable optimizations in CI you can add `common --compilation_mode=opt` to your CI `.bazelrc` file.

## Unsupported workloads

The following workloads are not supported by these rules at this given time:

- VisualBasic
- Razor
- Blazor/WebAssembly
- Workloads that require Mono

Contributions to add the missing workloads are welcomed and the maintainers
will do their best to guide if needed.

## Usage

### Installation

The minimal supported Bazel version is 7.0.0 and bzlmod has to enabled.

From the release you wish to use: https://github.com/bazel-contrib/rules_dotnet/releases copy the WORKSPACE snippet into your WORKSPACE file.

If you are using Windows you need to make sure that symlinks and runfiles are enabled.
You can do that by adding the following snippet to your `.bazelrc` file:

```
startup --windows_enable_symlinks
build --enable_runfiles
```

More information on these flags can be found here:

[--windows_enable_symlinks](https://docs.bazel.build/versions/main/command-line-reference.html#flag--windows_enable_symlinks)

[--enable_runfiles](https://docs.bazel.build/versions/main/command-line-reference.html#flag--enable_runfiles)

Various examples of how each rule can be used are in the [examples](../examples) folder.

## IDE Support

Currently the rules do not support IDE support out of the box so for
proper IDE support the MSBuild project files need to be manually maintained.

## NuGet packages

NuGet packages are fully supported by the rules in two ways

### NuGet packages with Paket

[Paket](https://fsprojects.github.io/Paket/) is a great choice for managing dependencies in .Net
and one of the reasons for Paket being a great fit with Bazel is that it supports a lock file
out of the box.

See the [paket2bazel](../tools/paket2bazel/README.md) docs for instructions on how to set Paket up with Bazel.

## Remote execution

The rules support remote execution out of the box. The remote runners do need to have the required .Net
system dependencies installed though. A common missing system dependency in existing RBE images is `libicu`.

## Code coverage

`csharp_test` and `fsharp_test` support `bazel coverage`, producing LCOV that Bazel's
own coverage machinery merges and filters like any other language.

rules_dotnet does not bundle a coverage tool, so you have to point it at one. Any
[coverlet.console](https://github.com/coverlet-coverage/coverlet)-compatible tool
works; **coverlet 6.0.0 or newer is required** (earlier versions have no
`--include-directory`).

Add the package to your NuGet setup, then set the flag:

```
bazel coverage //... \
  --@rules_dotnet//dotnet/settings:coverage_tool=@paket.my_deps//coverlet.console/tools:coverlet
```

Putting it in `.bazelrc` is usually nicer:

```
coverage --@rules_dotnet//dotnet/settings:coverage_tool=@paket.my_deps//coverlet.console/tools:coverlet
```

Combine the per-test reports with `--combined_report=lcov`, which writes
`bazel-out/_coverage/_coverage_report.dat`.

With no `coverage_tool` configured, `bazel coverage` still runs the tests; it just
produces no coverage data. Nothing about a normal `bazel build` or `bazel test`
changes either way — the instrumentation plumbing is only built under
`--collect_code_coverage`.

### What the tool target has to provide

Either shape works:

- an **executable** target, which is invoked directly — this is what
  `dotnet_tool` produces, and is the easy path; or
- a target whose files contain **exactly one DLL**, which is invoked via
  `dotnet exec`.

Support assemblies and `runtimeconfig.json` have to be reachable through the
target's runfiles.

### Passing extra options to the tool

Use `//dotnet/settings:coverage_tool_args` for anything rules_dotnet does not set
itself, such as filters:

```
bazel coverage //... \
  --@rules_dotnet//dotnet/settings:coverage_tool_args=--exclude,'[*]MyApp.Migrations.*'
```

Do **not** pass `--threshold` this way. A threshold violation makes the tool exit
non-zero, which Bazel reports as a failing test rather than as a coverage
shortfall.

### Put the code under test in a library

Coverage is collected for the test target's *dependencies*, not for the test
assembly itself. This matches Bazel's `--instrument_test_targets` default (false)
and coverlet's `--include-test-assembly` default.

So this reports **no** coverage for `Calculator`:

```python
csharp_test(
    name = "calculator_test",
    srcs = ["CalculatorTest.cs", "Calculator.cs"],  # code under test in the test target
)
```

and this reports it correctly:

```python
csharp_library(
    name = "calculator",
    srcs = ["Calculator.cs"],
)

csharp_test(
    name = "calculator_test",
    srcs = ["CalculatorTest.cs"],
    deps = [":calculator"],
)
```

### Limitations

- **Windows is implemented but not yet verified.** The launcher does the same
  staging and instrumentation as on Linux/macOS, with one extra normalization
  step: `compiler_wrapper.bat` pathmaps against a backslash `%cd%`, so PDB
  documents come out as `.\pkg\lib.cs` and the separators are flipped to `/` to
  match Bazel's coverage manifest. Nobody has run it on Windows yet, and the CI
  coverage task deliberately covers Linux and macOS only. If you try it and the
  report comes back empty, the `SF:` lines are the first thing to look at.
- Function-level records (`FN:`/`FNDA:`) are dropped. Coverlet keys them by the
  full method signature, which contains commas that Bazel's LCOV parser cannot
  handle. Line and branch coverage are unaffected.
