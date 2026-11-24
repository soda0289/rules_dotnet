"""Rule that allows running .NET command-line tools hermetically within Bazel."""

load("@bazel_skylib//lib:dicts.bzl", "dicts")
load("//dotnet/private:common.bzl", "get_nearest_compatible_target_framework", "get_toolchain")
load("//dotnet/private:launcher.bzl", "LAUNCHER_ATTRS", "LAUNCHER_TOOLCHAINS", "create_launcher")
load("//dotnet/private/icu:settings.bzl", "icu_files")

DotnetToolInfo = provider(
    doc = "Provider for grouping .NET tools by target framework.",
    fields = {
        "files_by_tfm": "A dict mapping target frameworks to tool filegroups.",
    },
)

def _tool_executable(files, entrypoint):
    """Finds the assembly a tool's settings file names.

    `entrypoint` is a bare file name, resolved against the folder holding the
    `DotnetToolSettings.xml` that named it. The folder cannot be rebuilt from
    the framework: a package names it with whatever spelling of the framework it
    shipped, which is not always the one the tool resolved to.

    Args:
      files: The files the package ships for the resolved framework.
      entrypoint: The file name the settings file names.

    Returns:
      The entrypoint File, or None when it is not shipped.
    """
    directory = None

    for file in files:
        if file.basename == "DotnetToolSettings.xml":
            directory = file.dirname
            break

    for file in files:
        if file.dirname == directory and file.basename == entrypoint:
            return file

    return None

def _dotnet_tool_impl(ctx):
    toolchain = get_toolchain(ctx)

    runtime = toolchain.runtime
    dotnet_info = toolchain.dotnetinfo

    framework = get_nearest_compatible_target_framework(dotnet_info.runtime_tfm, ctx.attr.target_frameworks)
    if framework == None:
        fail("The current .NET runtime ({}) does not support any of the target frameworks specified for this tool: {}".format(dotnet_info.runtime_tfm, ctx.attr.target_frameworks))

    entrypoint = ctx.attr.entrypoint.get(framework)
    runner = ctx.attr.runner.get(framework)

    if entrypoint == None or runner == None:
        fail("The tool does not support the target framework: {}".format(framework))
    if runner != "dotnet":
        fail("Unsupported runner '{}' for target framework '{}'. Currently, only 'dotnet' is supported.".format(runner, framework))

    filegroup = ctx.attr.deps[DotnetToolInfo].files_by_tfm.get(framework)
    if filegroup == None:
        fail("Tool {} does not provide files for the target framework: {}".format(ctx.attr.name, framework))

    executable = _tool_executable(filegroup[DefaultInfo].files.to_list(), entrypoint)
    if executable == None:
        fail("Tool {} does not ship its entrypoint '{}' for the target framework: {}".format(ctx.attr.name, entrypoint, framework))

    compiled_launcher = create_launcher(
        ctx,
        output_stem = "{}/{}".format(ctx.label.name, ctx.label.name),
        config_name = "{}/launch.json".format(ctx.label.name),
        dotnet = runtime.files_to_run.executable,
        assembly = executable,
        toolchain = toolchain,
        use_build_working_directory = True,
        roll_forward = "Major",
    )

    runfiles = ctx.runfiles(transitive_files = depset(
        transitive = [filegroup[DefaultInfo].files, dotnet_info.runtime_files, icu_files(toolchain)],
    )).merge(compiled_launcher.runfiles)

    return [
        DefaultInfo(
            executable = compiled_launcher.executable,
            runfiles = runfiles,
        ),
    ]

dotnet_tool = rule(
    implementation = _dotnet_tool_impl,
    executable = True,
    doc = """Runs a .NET command-line tool from a NuGet package with the hermetic .NET runtime.

`bazel run` runs the tool in the directory it was invoked from.

The tool runs on the one .NET runtime the toolchain carries, for the newest of
its frameworks that is no newer than that runtime. A tool for an older major
release rolls forward onto the runtime, as `dotnet tool install
--allow-roll-forward` lets it (`DOTNET_ROLL_FORWARD=Major`), unless
`DOTNET_ROLL_FORWARD` is already set in the environment.

Prefer adding the tool to `paket.dependencies`: every dotnet tool in a
dependency group is then available as `@paket.<group>//<package>/tools:<command>`
without declaring this rule.
""",
    attrs = dicts.add(LAUNCHER_ATTRS, {
        "target_frameworks": attr.string_list(
            doc = "The frameworks the package ships the tool for. The newest one no newer than the toolchain's runtime is used.",
            mandatory = True,
        ),
        "entrypoint": attr.string_dict(
            mandatory = True,
            doc = "The file name of the assembly to run, keyed by target framework, as the package's `DotnetToolSettings.xml` names it.",
        ),
        "runner": attr.string_dict(
            mandatory = True,
            doc = "How to run the entrypoint, keyed by target framework. Only `dotnet` is supported.",
        ),
        "deps": attr.label(
            mandatory = True,
            providers = [DotnetToolInfo],
            doc = "The `tools` target of the package's `nuget_archive`.",
        ),
    }),
    toolchains = ["//dotnet/toolchain:toolchain_type"] + LAUNCHER_TOOLCHAINS,
)
