"""Tests that an analyzer shipped by both the targeting pack and a NuGet dependency is only passed to the compiler once.

`System.Text.Json` ships the `System.Text.Json.SourceGeneration` source generator and so does the
`Microsoft.NETCore.App.Ref` targeting pack. The NuGet package (7.0.3) is newer than the minimum
version that the net7.0 targeting pack records for it in `PackageOverride.txt` (7.0.0), so the
package is kept and the very same source generator used to reach the compiler from both sources.
A source generator that is passed to the compiler twice runs twice and emits its generated types
twice, which fails the compilation.
See https://github.com/bazel-contrib/rules_dotnet/issues/467.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//dotnet:defs.bzl", "csharp_library")

_ANALYZER_ARG_PREFIX = "/analyzer:"

_DUPLICATED_ANALYZER = "System.Text.Json.SourceGeneration.dll"

_TARGETING_PACK_REPO = "microsoft.netcore.app.ref"

_NUGET_PACKAGE_REPO = "system.text.json"

def _analyzer_paths(env, mnemonic):
    action_under_test = None
    for action in analysistest.target_actions(env):
        if action.mnemonic == mnemonic:
            if action_under_test != None:
                fail("Multiple actions with mnemonic: {}".format(mnemonic))
            action_under_test = action

    if action_under_test == None:
        fail("No action with mnemonic: {}".format(mnemonic))

    return [
        arg[len(_ANALYZER_ARG_PREFIX):]
        for arg in action_under_test.argv
        if arg.startswith(_ANALYZER_ARG_PREFIX)
    ]

def _analyzer_args_test_impl(ctx):
    env = analysistest.begin(ctx)

    analyzer_paths = _analyzer_paths(env, "CSharpCompile")

    # An analyzer that is passed to the compiler more than once runs more than once.
    seen = {}
    for analyzer_path in analyzer_paths:
        file_name = analyzer_path.rpartition("/")[-1]
        asserts.false(
            env,
            file_name in seen,
            "Analyzer passed to the compiler more than once: {}. Analyzers: {}".format(file_name, analyzer_paths),
        )
        seen[file_name] = None

    matches = [
        analyzer_path
        for analyzer_path in analyzer_paths
        if analyzer_path.endswith("/" + _DUPLICATED_ANALYZER)
    ]
    asserts.equals(
        env,
        1,
        len(matches),
        "Expected {} to be passed to the compiler exactly once. Analyzers: {}".format(_DUPLICATED_ANALYZER, analyzer_paths),
    )

    if matches:
        asserts.true(
            env,
            ctx.attr.expected_analyzer_repo in matches[0],
            "Expected {} to come from {} but it came from {}".format(
                _DUPLICATED_ANALYZER,
                ctx.attr.expected_analyzer_repo,
                matches[0],
            ),
        )

    return analysistest.end(env)

analyzer_args_test = analysistest.make(
    _analyzer_args_test_impl,
    doc = "Asserts that no analyzer is passed to the C# compiler twice and that {} comes from the expected repository.".format(_DUPLICATED_ANALYZER),
    attrs = {
        "expected_analyzer_repo": attr.string(
            doc = "Substring of the repository name that the surviving {} is expected to be read from.".format(_DUPLICATED_ANALYZER),
            mandatory = True,
        ),
    },
)

# buildifier: disable=function-docstring
# buildifier: disable=unnamed-macro
def csharp_duplicate_analyzers():
    csharp_library(
        name = "library_without_nuget_analyzer",
        srcs = ["duplicate_analyzers.cs"],
        target_frameworks = ["net7.0"],
        tags = ["manual"],
    )

    analyzer_args_test(
        name = "targeting_pack_provides_the_analyzer_test",
        target_under_test = ":library_without_nuget_analyzer",
        expected_analyzer_repo = _TARGETING_PACK_REPO,
    )

    csharp_library(
        name = "library_with_nuget_analyzer",
        srcs = ["duplicate_analyzers.cs"],
        target_frameworks = ["net7.0"],
        tags = ["manual"],
        deps = ["@paket.rules_dotnet_dev_nuget_packages//system.text.json"],
    )

    analyzer_args_test(
        name = "nuget_analyzer_supersedes_targeting_pack_analyzer_test",
        target_under_test = ":library_with_nuget_analyzer",
        expected_analyzer_repo = _NUGET_PACKAGE_REPO,
    )
