"""Builds native launchers for .NET binaries, tests, tools, and devservers.

Each target compiles a small native stub from `@hermetic_launcher` that locates
Bazel runfiles and starts `dotnet exec` on `launcher_bootstrap.dll` with a
per-target JSON configuration file. Avoiding `.bat` and `.sh` wrappers removes
the `cmd.exe` 248-character path ceiling and delayed-expansion argument mangling
on Windows and the bash startup dependency on Unix.
"""

load("@hermetic_launcher//launcher:lib.bzl", "launcher")
load("//dotnet/private:common.bzl", "targets_windows", "to_rlocation_path")
load("//dotnet/private/icu:settings.bzl", "icu_launcher_config")
load("//dotnet/private/tools/launcher_bootstrap:rule.bzl", "LauncherBootstrapInfo")

LAUNCHER_TOOLCHAINS = [
    launcher.finalizer_toolchain_type,
    launcher.template_toolchain_type,
]

LAUNCHER_ATTRS = {
    "_launcher_bootstrap": attr.label(
        doc = "Managed stage-two launcher bootstrap assembly.",
        default = "//dotnet/private/tools/launcher_bootstrap",
        providers = [LauncherBootstrapInfo],
        cfg = "exec",
    ),
    "_windows_constraint": attr.label(
        default = "@platforms//os:windows",
    ),
}

def create_launcher(
        ctx,
        *,
        output_stem,
        config_name,
        dotnet,
        assembly,
        toolchain,
        sibling = None,
        probe_runfiles = False,
        use_build_working_directory = False,
        roll_forward = "",
        application = None,
        wwwroot = None):
    """Compiles a native launcher executable and its launch configuration.

    Args:
        ctx: The rule context, carrying `LAUNCHER_ATTRS` and `LAUNCHER_TOOLCHAINS`.
        output_stem: Path (or basename when `sibling` is given) of the launcher,
            without the `.exe` suffix added on Windows.
        config_name: Path of the `.launch.json` configuration file to declare.
        dotnet: The `dotnet` host `File` from the runtime toolchain.
        assembly: The managed `.dll` `File` to execute.
        toolchain: The resolved runtime `ToolchainInfo`, for globalization settings.
        sibling: Optional `File` whose directory `output_stem` is declared beside.
        probe_runfiles: Whether to pass `--additionalprobingpath <RUNFILES_DIR>`.
        use_build_working_directory: Whether to `cd` to `BUILD_WORKING_DIRECTORY`
            when set (for `dotnet_tool`).
        roll_forward: Optional default `DOTNET_ROLL_FORWARD` policy when unset in
            the caller's environment (for `dotnet_tool`).
        application: Optional application `.dll` `File` for `blazor_devserver`.
        wwwroot: Optional `wwwroot` directory `File` for `blazor_devserver`.

    Returns:
        A struct with `executable` (the compiled launcher `File`) and `runfiles`
        (a `runfiles` object carrying the config and `launcher_bootstrap`).
    """
    is_windows = targets_windows(ctx)
    launcher_name = output_stem + (".exe" if is_windows else "")
    output = (
        ctx.actions.declare_file(launcher_name, sibling = sibling) if sibling != None else ctx.actions.declare_file(launcher_name)
    )
    config_file = ctx.actions.declare_file(config_name)

    icu = icu_launcher_config(ctx, toolchain, is_windows)
    config = {
        "dotnet": to_rlocation_path(ctx, dotnet),
        "assembly": to_rlocation_path(ctx, assembly),
        "probe_runfiles": probe_runfiles,
        "use_build_working_directory": use_build_working_directory,
        "roll_forward": roll_forward,
        "invariant_globalization": icu.invariant_globalization,
        "icu_lib": icu.icu_lib,
        "icu_version": icu.icu_version,
        "application": to_rlocation_path(ctx, application) if application != None else "",
        "wwwroot": to_rlocation_path(ctx, wwwroot) if wwwroot != None else "",
    }
    ctx.actions.write(
        output = config_file,
        content = json.encode(config),
    )

    bootstrap = ctx.attr._launcher_bootstrap[LauncherBootstrapInfo]
    launcher.entrypoint(dotnet).embedded_args("exec").runfiles(
        bootstrap.dll,
        config_file,
    ).compile(
        ctx,
        output_file = output,
    )

    runfiles = ctx.runfiles(
        files = [config_file],
        transitive_files = bootstrap.files,
    )
    return struct(
        executable = output,
        runfiles = runfiles,
    )
