"""Analysis tests for `bazel coverage` support."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//dotnet:defs.bzl", "csharp_library", "csharp_nunit_test")

# Everything here has to be analysed as if `bazel coverage` were running, with a
# coverage tool configured -- that is the only configuration in which the rules
# produce a coverage launcher and an instrumentation manifest.
# Build setting keys are resolved in the repo that defines analysistest, not this
# one, so they have to be spelled as canonical labels.
_COVERAGE_CONFIG = {
    "//command_line_option:collect_code_coverage": True,
    "//command_line_option:instrumentation_filter": ".*",
    str(Label("//dotnet/settings:coverage_tool")): str(Label("//dotnet/private/tests/coverage:fake_coverage_tool")),
}

def _instrumented_files(target):
    return [f.short_path for f in target[InstrumentedFilesInfo].instrumented_files.to_list()]

def _propagation_test_impl(ctx):
    """Sources have to be collected through the whole `deps` chain, not just the test."""
    env = analysistest.begin(ctx)
    files = _instrumented_files(analysistest.target_under_test(env))

    # The direct dependency.
    asserts.true(
        env,
        "dotnet/private/tests/coverage/lib.cs" in files,
        "expected the directly-depended-on library source in the instrumented files, got {}".format(files),
    )

    # The transitive one. This is the case that regresses if a library rule stops
    # returning InstrumentedFilesInfo: collection stops at the first rule that
    # does not provide it, so a one-level test would still pass.
    asserts.true(
        env,
        "dotnet/private/tests/coverage/lib2.cs" in files,
        "expected the transitively-depended-on library source in the instrumented files, got {}".format(files),
    )

    return analysistest.end(env)

_propagation_test = analysistest.make(
    _propagation_test_impl,
    config_settings = _COVERAGE_CONFIG,
)

def _manifest_action(env):
    for action in analysistest.target_actions(env):
        if action.mnemonic == "FileWrite" and action.outputs.to_list()[0].basename.endswith(".instrumented_assemblies"):
            return action
    return None

def _manifest_test_impl(ctx):
    """The instrumentation manifest lists first-party assemblies and their PDBs."""
    env = analysistest.begin(ctx)
    action = _manifest_action(env)

    asserts.true(env, action != None, "expected an instrumentation manifest to be written")
    if action == None:
        return analysistest.end(env)

    lines = [line for line in action.content.split("\n") if line]

    # "F <rlocation path>" for each file to stage.
    for expected in [
        "lib/netstandard2.0/lib.dll",
        "lib/netstandard2.0/lib.pdb",
        "lib2/netstandard2.0/lib2.dll",
        "lib2/netstandard2.0/lib2.pdb",
    ]:
        asserts.true(
            env,
            len([line for line in lines if line.startswith("F ") and line.endswith(expected)]) == 1,
            "expected exactly one staged-file entry ending in {}, got {}".format(expected, lines),
        )

    # "D <relative dir>" for each directory --include-directory has to be given,
    # deduplicated here so neither launcher has to do it -- one per assembly
    # directory, and none for the PDB-only entries.
    dirs = [line for line in lines if line.startswith("D ")]
    asserts.equals(env, 2, len(dirs), "expected one directory entry per assembly, got {}".format(dirs))
    for expected in ["lib/netstandard2.0", "lib2/netstandard2.0"]:
        asserts.true(
            env,
            len([line for line in dirs if line.endswith(expected)]) == 1,
            "expected exactly one directory entry ending in {}, got {}".format(expected, dirs),
        )

    # The test assembly itself is never instrumented -- coverlet excludes it
    # unless --include-test-assembly is passed, matching Bazel's
    # --instrument_test_targets default.
    asserts.true(
        env,
        len([line for line in lines if "coverage_test" in line]) == 0,
        "the test assembly should not be staged for instrumentation, got {}".format(lines),
    )

    # NUnit comes from NuGet and carries no rules_dotnet-produced PDB, so it must
    # not be staged.
    asserts.true(
        env,
        len([line for line in lines if "nunit" in line.lower()]) == 0,
        "NuGet assemblies should not be staged for instrumentation, got {}".format(lines),
    )

    return analysistest.end(env)

_manifest_test = analysistest.make(
    _manifest_test_impl,
    config_settings = _COVERAGE_CONFIG,
)

def _no_coverage_test_impl(ctx):
    """Without `--collect_code_coverage` nothing coverage-related is built."""
    env = analysistest.begin(ctx)
    asserts.true(
        env,
        _manifest_action(env) == None,
        "no instrumentation manifest should be written outside of a coverage build",
    )
    return analysistest.end(env)

_no_coverage_test = analysistest.make(_no_coverage_test_impl)

# buildifier: disable=unnamed-macro
def coverage_test_suite(name):
    csharp_library(
        name = "lib2",
        srcs = ["lib2.cs"],
        target_frameworks = ["netstandard2.0"],
        tags = ["manual"],
    )

    csharp_library(
        name = "lib",
        srcs = ["lib.cs"],
        target_frameworks = ["netstandard2.0"],
        tags = ["manual"],
        deps = [":lib2"],
    )

    csharp_nunit_test(
        name = "coverage_test",
        srcs = ["libtest.cs"],
        tags = ["manual"],
        target_frameworks = ["net8.0"],
        deps = [":lib"],
    )

    _propagation_test(
        name = "instrumented_files_propagate_through_deps",
        target_under_test = ":coverage_test",
    )

    _manifest_test(
        name = "instrumentation_manifest_lists_first_party_assemblies",
        target_under_test = ":coverage_test",
    )

    _no_coverage_test(
        name = "no_manifest_without_coverage",
        target_under_test = ":coverage_test",
    )

    native.test_suite(
        name = name,
        tests = [
            ":instrumented_files_propagate_through_deps",
            ":instrumentation_manifest_lists_first_party_assemblies",
            ":no_manifest_without_coverage",
        ],
    )
