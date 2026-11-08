"""
Base rule for building .Net binaries
"""

load("@bazel_lib//lib:expand_make_vars.bzl", "expand_locations", "expand_variables")
load("@bazel_skylib//lib:shell.bzl", "shell")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load(
    "//dotnet/private:common.bzl",
    "check_windows_frameworks",
    "collect_transitive_content_files",
    "collect_transitive_runfiles",
    "generate_depsjson",
    "generate_runtimeconfig",
    "is_netframework",
    "is_standard_framework",
    "runtime_frameworks",
    "shared_framework_version",
    "targets_windows",
    "to_rlocation_path",
)
load("//dotnet/private:providers.bzl", "DotnetApphostPackInfo", "DotnetAssemblyRuntimeInfo", "DotnetBinaryInfo", "DotnetCoverageInfo", "DotnetNativeToolsInfo", "DotnetRuntimePackInfo", "DotnetTargetingPackInfo")
load("//dotnet/private/icu:settings.bzl", "icu_files", "icu_launcher_environment")
load("//dotnet/private/rules/common:netfx.bzl", "satellite_path", "stage_netfx_application")
load(
    "//dotnet/private/rules/common:static_web_assets.bzl",
    "WEB_ROOT",
    "collect_static_web_assets",
    "endpoints_manifest_action",
    "plan_static_web_assets",
)
load("//dotnet/private/rules/nuget:dotnet_tool.bzl", "DotnetToolEntrypointInfo")
load("//dotnet/private/rules/ready_to_run:ready_to_run.bzl", "with_ready_to_run_images")
load("//dotnet/private/sdk:packs.bzl", "resolve_framework_references")

def _use_coverage(ctx, is_netfx = False):
    """Whether this target should be built with coverage instrumentation.

    True only during `bazel coverage` (`--collect_code_coverage`) on a .NET
    (Core) test rule that has a coverage tool configured via
    `--@rules_dotnet//dotnet/settings:coverage_tool`. Outside of that, targets are
    built exactly as they are today, so a plain `bazel build`/`bazel test` pays
    nothing for this feature.

    Args:
        ctx: Bazel build ctx.
        is_netfx: Whether the target runs on .NET Framework rather than the .NET host.

    Returns:
        True if a coverage-collecting launcher should be produced.
    """
    if is_netfx:
        return False
    if not hasattr(ctx.attr, "_coverage_tool"):
        return False
    if not ctx.configuration.coverage_enabled:
        return False

    # The default is an empty sentinel filegroup, meaning "no tool configured".
    return len(ctx.attr._coverage_tool[DefaultInfo].files.to_list()) > 0

def _coverage_instrumented_assemblies(ctx, transitive_runtime_deps):
    """The assemblies the coverage tool should instrument, plus their PDBs.

    Coverlet rewrites assembly IL and needs each assembly's PDB beside it, so
    both are returned. Only assemblies that carry a PDB and match Bazel's
    `--instrumentation_filter` (collected via `DotnetCoverageInfo`) are
    included, which limits the set to filtered first-party targets and skips
    unselected targets as well as NuGet-imported assemblies.

    The test's own assembly is deliberately excluded. Coverlet does not
    instrument the test assembly unless --include-test-assembly is passed, which
    matches Bazel's --instrument_test_targets defaulting to false. The practical
    consequence for users is that code under test has to live in a
    csharp_library/fsharp_library rather than in the test target's own srcs.

    Args:
        ctx: Bazel build ctx.
        transitive_runtime_deps: List of transitive DotnetAssemblyRuntimeInfo providers.

    Returns:
        A list of DLL and PDB files, deduplicated by assembly file name.
    """
    coverage_depsets = [
        dep[DotnetCoverageInfo].files
        for dep in getattr(ctx.attr, "deps", [])
        if DotnetCoverageInfo in dep
    ]
    if coverage_depsets:
        candidates = depset(transitive = coverage_depsets).to_list()
    else:
        candidates = [
            f
            for info in transitive_runtime_deps
            if info.pdbs
            for f in info.libs + info.pdbs
        ] if not any([DotnetCoverageInfo in dep for dep in getattr(ctx.attr, "deps", [])]) else []

    files = []

    # Coverlet deduplicates coverable modules by file name, so two same-named
    # assemblies in different staged directories would silently collapse to
    # whichever it saw first. Dedupe here instead, so the staging tree matches
    # what the tool will actually instrument.
    seen = {}
    for f in candidates:
        if f.basename in seen:
            continue
        seen[f.basename] = True
        files.append(f)
    return files

def _coverage_tool_invocation(ctx):
    """How to locate and invoke the configured coverage tool.

    Two target shapes are accepted:

      * an executable target (e.g. rules_dotnet's own `dotnet_tool`), which is
        invoked directly, and
      * a target whose files contain exactly one DLL, which is invoked via
        `dotnet exec`.

    Args:
        ctx: Bazel build ctx.

    Returns:
        A tuple of (rlocation path of the tool, POSIX command prefix that invokes
        it, whether it needs to be run via `dotnet exec`). The prefix is only used
        by the shell launcher, which resolves the rlocation path into a variable
        of its own first; the Windows runner takes the path and the flag instead
        and builds an argument array.
    """

    # A dotnet_tool's launcher escapes the arguments it forwards, which corrupts
    # the coverage tool's --targetargs. Run its entry point directly instead.
    if DotnetToolEntrypointInfo in ctx.attr._coverage_tool:
        return ctx.attr._coverage_tool[DotnetToolEntrypointInfo].entrypoint, "\"$dotnet\" exec \"$coverage_tool\"", True

    tool = ctx.attr._coverage_tool[DefaultInfo]

    # Bazel populates files_to_run.executable for any rule with a single output,
    # so "has an executable" is not enough to tell a real launcher from a
    # filegroup wrapping one DLL. A managed assembly always has to go through
    # `dotnet exec`, so treat a .dll as the DLL case regardless.
    executable = tool.files_to_run.executable if tool.files_to_run else None

    if executable and executable.extension != "dll":
        tool_file = executable
        needs_dotnet_exec = False
    else:
        dlls = [f for f in tool.files.to_list() if f.extension == "dll"]
        if len(dlls) != 1:
            fail(
                "The target passed to --@rules_dotnet//dotnet/settings:coverage_tool ({}) is not usable. ".format(ctx.attr._coverage_tool.label) +
                "Pass either an executable target (such as a `dotnet_tool`) or a target whose files " +
                "contain exactly one DLL, but this one is not executable and provides {} DLLs.".format(len(dlls)),
            )
        tool_file = dlls[0]
        needs_dotnet_exec = True

    invocation = "\"$dotnet\" exec \"$coverage_tool\"" if needs_dotnet_exec else "\"$coverage_tool\""

    return to_rlocation_path(ctx, tool_file), invocation, needs_dotnet_exec

def _create_launcher(ctx, is_windows, executable, toolchain, tfm, coverage_runfiles, transitive_runtime_deps):
    launcher = ctx.actions.declare_file("{}.{}".format(executable.basename, "bat" if is_windows else "sh"), sibling = executable)

    if is_netframework(tfm):
        # No .NET host. Outside Windows the launcher reports it cannot run.
        ctx.actions.expand_template(
            template = ctx.file._launcher_netfx_bat if is_windows else ctx.file._launcher_netfx_sh,
            output = launcher,
            substitutions = {
                "TEMPLATED_executable": to_rlocation_path(ctx, executable),
                "TEMPLATED_label": str(ctx.label),
                "TEMPLATED_target_framework": tfm,
            },
            is_executable = True,
        )
        return launcher

    runtime = toolchain.runtime

    substitutions = {
        "TEMPLATED_dotnet": to_rlocation_path(ctx, runtime.files_to_run.executable),
        "TEMPLATED_executable": to_rlocation_path(ctx, executable),
        "TEMPLATED_environment": icu_launcher_environment(ctx, toolchain, is_windows),
    }

    use_coverage = _use_coverage(ctx, is_netfx = False)

    if use_coverage:
        instrumented = _coverage_instrumented_assemblies(ctx, transitive_runtime_deps)

        coverage_tool_path, coverage_invocation, needs_dotnet_exec = _coverage_tool_invocation(ctx)
        extra_args = ctx.attr._coverage_tool_args[BuildSettingInfo].value

        # Everything the launchers need, computed here rather than discovered at
        # test time:
        #
        #   N <rlocation path>   the dotnet host
        #   E <rlocation path>   the test assembly
        #   T <rlocation path>   the coverage tool
        #   X <0|1>              whether the tool runs via `dotnet exec`
        #   A <arg>              an extra argument for the tool
        #   F <rlocation path>   a file to stage (an assembly or its PDB)
        #   D <relative dir>     a staged directory for --include-directory
        #
        # The Windows runner takes all of it from this file so that no path has to
        # survive cmd quoting. The POSIX launcher gets N/E/T/A by template
        # substitution and reads only the F and D lines, ignoring the rest.
        # Directories are deduplicated here so neither launcher has to do it.
        lines = [
            "N {}".format(to_rlocation_path(ctx, runtime.files_to_run.executable)),
            "E {}".format(to_rlocation_path(ctx, executable)),
            "T {}".format(coverage_tool_path),
            "X {}".format("1" if needs_dotnet_exec else "0"),
        ] + ["A {}".format(arg) for arg in extra_args]
        seen_dirs = {}
        for f in instrumented:
            rlocation_path = to_rlocation_path(ctx, f)
            lines.append("F {}".format(rlocation_path))

            if f.extension != "dll":
                continue
            directory = rlocation_path.rsplit("/", 1)[0]
            if directory in seen_dirs:
                continue
            seen_dirs[directory] = True
            lines.append("D {}".format(directory))

        instrument_manifest = ctx.actions.declare_file(
            "{}.instrumented_assemblies".format(executable.basename),
            sibling = executable,
        )
        ctx.actions.write(
            output = instrument_manifest,
            content = "\n".join(lines) + "\n",
        )

        substitutions["TEMPLATED_instrument_manifest"] = to_rlocation_path(ctx, instrument_manifest)

        if is_windows:
            substitutions["TEMPLATED_coverage_runner"] = to_rlocation_path(ctx, ctx.file._coverage_runner_ps1)
            coverage_runfiles.append(ctx.file._coverage_runner_ps1)
        else:
            substitutions["TEMPLATED_coverage_tool"] = coverage_tool_path
            substitutions["TEMPLATED_coverage_invocation"] = coverage_invocation
            substitutions["TEMPLATED_coverage_extra_args"] = " ".join([shell.quote(arg) for arg in extra_args])

        coverage_runfiles.append(instrument_manifest)
        coverage_runfiles.extend(instrumented)

    if is_windows:
        template = ctx.file._coverage_launcher_bat if use_coverage else ctx.file._launcher_bat
    else:
        template = ctx.file._coverage_launcher_sh if use_coverage else ctx.file._launcher_sh

    # expand_template does plain, unordered string replacement, so one placeholder
    # being a prefix of another silently corrupts the longer one.
    for key in substitutions:
        for other in substitutions:
            if key != other and other.startswith(key):
                fail("Launcher placeholder '{}' is a prefix of '{}'; rename one of them.".format(key, other))

    ctx.actions.expand_template(
        template = template,
        output = launcher,
        substitutions = substitutions,
        is_executable = True,
    )

    return launcher

# Appended to the documentation of every rule that `build_binary` implements.
BINARY_OUTPUT_GROUPS_DOC = """

### Output groups

| Name | Contents |
| --- | --- |
| `deps_json` | The `.deps.json` the binary runs with. |
| `runtimeconfig_json` | The `.runtimeconfig.json` the binary runs with. |

Both are runfiles of the binary rather than default outputs, so a tool that has
to be handed them - one that loads the assembly from its build output, such as
the Swashbuckle CLI - selects them with a `filegroup`:

```starlark
filegroup(
    name = "app_deps_json",
    srcs = [":app"],
    output_group = "deps_json",
)
```

Both groups are empty for a target framework that has no such files
(.NET Framework).

These files describe the runfiles layout: the paths in the `.deps.json` are
relative to the runfiles root and the `.runtimeconfig.json` probes the runfiles
tree. They are only valid next to the binary inside its runfiles, so do not copy
them into a package or a container image - `publish_binary` writes the ones a
deployed application needs.
"""

def _native_tools(ctx, native_tools):
    """The binary in the branch a ReadyToRun or NativeAOT publish reaches it for the compiler.

    It compiles nothing, but an executable rule has to create its executable.
    """
    executable = ctx.actions.declare_file("{}/native_tools/{}".format(ctx.label.name, ctx.label.name))
    ctx.actions.write(executable, "", is_executable = True)

    return [DefaultInfo(executable = executable), native_tools]

def _stage_inherited_content_files(ctx, out_dir, inherited_content_files):
    """Links the dependencies' content files next to the binary.

    A library's content files are staged next to the library, but the app looks
    for them under its own `AppContext.BaseDirectory`.

    Returns:
        The staged Files.
    """
    staged = []
    for entry in inherited_content_files:
        link = ctx.actions.declare_file("{}/{}".format(out_dir, entry.dest))
        ctx.actions.symlink(output = link, target_file = entry.file)
        staged.append(link)
    return staged

def _reserved_paths(dll, runtime_provider, appsetting_files, inherited_content_files):
    """The paths a binary writes in its output directory itself.

    Returns:
        A dict of each path, lower-cased as Windows compares them, to what it is.
    """
    reserved = {dll.basename: "the application's own assembly"}
    for file in runtime_provider.pdbs + runtime_provider.xml_docs:
        reserved[file.basename] = "an output of the application itself"
    for file in appsetting_files:
        reserved[file.basename] = "one of its `appsetting_files`"
    for entry in list(runtime_provider.content_files) + inherited_content_files:
        reserved[entry.dest] = "the content file {}".format(entry.src.short_path)
    for file in runtime_provider.resource_assemblies:
        reserved[satellite_path(file)] = "a satellite assembly of the application"
    return {path.lower(): owner for (path, owner) in reserved.items()}

def _stage_app_config(ctx, out_dir, dll, reserved):
    """Links `app_config` beside a .NET assembly, where MSBuild puts it for `ConfigurationManager`.

    Returns:
        The staged File, or None without `app_config`.
    """
    if not ctx.file.app_config:
        return None

    name = dll.basename + ".config"
    owner = reserved.get(name.lower())
    if owner:
        fail("{}: `app_config` would be staged as {}, but that is already {}.".format(ctx.label, name, owner))

    staged = ctx.actions.declare_file("{}/{}".format(out_dir, name))
    ctx.actions.symlink(output = staged, target_file = ctx.file.app_config)
    return staged

def _netfx_application(ctx, out_dir, tfm, dll, runtime_provider, transitive_runtime_deps, appsetting_files, inherited_content_files, reserved):
    """Stages what a .NET Framework executable runs with beside it, and lays out its publish.

    Returns:
        A struct of the staged `files`, and the `publish_layout`: the
        `(path, File)` pairs a publish ships, without PDBs.
    """
    staged = stage_netfx_application(
        ctx,
        executable = dll,
        out_dir = out_dir,
        target_framework = tfm,
        transitive_runtime_deps = transitive_runtime_deps,
        reserved = reserved,
        framework_files = ctx.attr._targeting_pack[0][DotnetTargetingPackInfo].framework_files_depset,
        app_config = ctx.file.app_config,
        auto_generate_binding_redirects = ctx.attr.auto_generate_binding_redirects,
    )

    publish_layout = (
        [(dll.basename, dll)] +
        [(file.basename, file) for file in appsetting_files] +
        [(entry.dest, entry.file) for entry in list(runtime_provider.content_files) + inherited_content_files] +
        [(satellite_path(file), file) for file in runtime_provider.resource_assemblies] +
        staged.publish_layout
    )

    return struct(files = staged.files, publish_layout = publish_layout)

# deps.json lists each assembly by its runfiles path, which the host resolves
# against its working directory: under `bazel run` and `bazel test` that is the
# main repository's directory in the runfiles tree, so `../` is the root of the
# tree. When the binary is the tool of an action, the launcher passes the
# runfiles root instead, as only it knows where that is.
_RUNFILES_PROBING_PATHS = ["./", "./external", "../", "../external"]

def _write_runtime_files(ctx, out_dir, assembly_name, tfm, toolchain, runtime_provider, transitive_runtime_deps, frameworks):
    """Writes the runtimeconfig.json and deps.json the binary runs from its runfiles with.

    Returns:
        A struct of the `runtimeconfig` and `deps_json` Files, and the
        `framework_version` of the shared frameworks the binary asks for.
    """
    framework_version = shared_framework_version(tfm, toolchain.dotnetinfo.runtime_version)

    runtimeconfig_struct = generate_runtimeconfig(
        target_framework = tfm,
        frameworks = frameworks,
        is_self_contained = False,
        roll_forward_behavior = ctx.attr.roll_forward_behavior,
        framework_version = framework_version,
    )
    runtimeconfig_struct["runtimeOptions"]["additionalProbingPaths"] = _RUNFILES_PROBING_PATHS
    runtimeconfig = ctx.actions.declare_file("{}/{}.runtimeconfig.json".format(out_dir, assembly_name))
    ctx.actions.write(
        output = runtimeconfig,
        content = json.encode(runtimeconfig_struct),
    )

    deps_json = ctx.actions.declare_file("{}/{}.deps.json".format(out_dir, assembly_name))
    ctx.actions.write(
        output = deps_json,
        content = json.encode(generate_depsjson(
            ctx,
            target_framework = tfm,
            is_self_contained = False,
            target_assembly_runtime_info = runtime_provider,
            transitive_runtime_deps = transitive_runtime_deps,
            use_relative_paths = True,
        )),
    )

    return struct(
        runtimeconfig = runtimeconfig,
        deps_json = deps_json,
        framework_version = framework_version,
    )

def _stage_native_libraries(ctx, out_dir, runtime_provider, transitive_runtime_deps):
    """Links every native library under `runtimes/<rid>/native/` next to the binary, where the host loads it from.

    Returns:
        The staged Files.
    """
    by_rid = {}
    for info in [runtime_provider] + transitive_runtime_deps:
        for file in info.native:
            by_rid.setdefault(file.dirname.split("/")[-2], {})[file] = None

    staged = []
    for (rid, files) in by_rid.items():
        for file in files:
            link = ctx.actions.declare_file("{}/runtimes/{}/native/{}".format(out_dir, rid, file.basename))
            ctx.actions.symlink(output = link, target_file = file)
            staged.append(link)
    return staged

def _stage_static_web_assets(ctx, out_dir, assembly_name, generated_assets):
    """Lays out the servable tree next to the binary, so `bazel run` serves what a publish would.

    Returns:
        A pair of the `StaticWebAssetsInfo` and the staged files, as structs of
        a `file` and the `publish_path` it takes inside a publish directory.
    """
    static_web_assets_info = collect_static_web_assets(
        label = ctx.label,
        assembly_name = assembly_name,
        files = ctx.files.static_web_assets,
        deps = ctx.attr.deps,
        is_application = True,
        generated = generated_assets,
    )
    static_web_assets = plan_static_web_assets(
        ctx.actions,
        label = ctx.label,
        out_dir = out_dir,
        assets_info = static_web_assets_info,
    )
    if not static_web_assets:
        return (static_web_assets_info, [])

    # `MapStaticAssets` serves from this manifest rather than from disk, so the
    # tree and the manifest describing it are written together.
    described = endpoints_manifest_action(
        ctx.actions,
        label = ctx.label,
        out_dir = out_dir,
        assembly_name = assembly_name,
        assets = static_web_assets,
        tool = ctx.attr._static_web_assets_tool,
    )

    static_web_files = [
        struct(file = asset.file, publish_path = "{}/{}".format(WEB_ROOT, asset.route))
        for asset in static_web_assets + described.compressed
    ] + [struct(file = described.manifest, publish_path = described.manifest.basename)]

    return (static_web_assets_info, static_web_files)

def build_binary(ctx, compile_action, toolchain, runtime_toolchain = None, winexe = False):
    """Builds a .Net binary from a compilation action

    Args:
        ctx: Bazel build ctx.
        compile_action: A function taking (ctx, tfm, toolchain) that compiles the srcs
            and returns a (DotnetAssemblyCompileInfo, DotnetAssemblyRuntimeInfo,
            generated static web assets) tuple.
        toolchain: The .Net toolchain to build with.
        runtime_toolchain: The .Net toolchain whose runtime the binary runs on,
            if not `toolchain`'s.
        winexe: Whether the binary is a Windows GUI executable. Only the
            binary rules set it: a test is always a console one.
    Returns:
        The binary's providers.
    """
    runtime_toolchain = runtime_toolchain or toolchain
    if DotnetNativeToolsInfo in ctx.attr._native_tools:
        return _native_tools(ctx, ctx.attr._native_tools[DotnetNativeToolsInfo])

    tfm = ctx.attr._target_framework[BuildSettingInfo].value

    if is_standard_framework(tfm):
        fail("It doesn't make sense to build an executable for " + tfm)

    (compile_provider, runtime_provider, generated_assets) = compile_action(ctx, tfm, toolchain)
    runtime_provider = with_ready_to_run_images(ctx, runtime_provider)
    coverage_info = DotnetCoverageInfo(
        files = depset(
            runtime_provider.libs + runtime_provider.pdbs if ctx.coverage_instrumented() and runtime_provider.pdbs else [],
            transitive = [
                dep[DotnetCoverageInfo].files
                for dep in getattr(ctx.attr, "deps", [])
                if DotnetCoverageInfo in dep
            ],
        ),
    )
    transitive_runtime_deps = runtime_provider.deps.to_list()

    is_netfx = is_netframework(tfm)
    is_windows = targets_windows(ctx)
    dll = runtime_provider.libs[0]
    assembly_name = runtime_provider.name
    out_dir = "{}/{}".format(ctx.label.name, tfm)
    coverage_runfiles = []
    launcher = _create_launcher(ctx, is_windows, dll, runtime_toolchain, tfm, coverage_runfiles, transitive_runtime_deps)

    # Everything staged next to the assembly is a runfile as well as an output,
    # so that it is there when the binary runs from an isolated runfiles tree.
    appsetting_files = runtime_provider.appsetting_files.to_list()
    inherited_content_files = collect_transitive_content_files(
        ctx.label,
        runtime_provider,
        transitive_runtime_deps,
        reserved = [dll.basename] + [f.basename for f in appsetting_files] + [
            assembly_name + ".runtimeconfig.json",
            assembly_name + ".deps.json",
        ],
    )
    staged = appsetting_files + [entry.file for entry in runtime_provider.content_files]
    staged += _stage_inherited_content_files(ctx, out_dir, inherited_content_files)

    # A dependency can bring in Windows Forms or WPF.
    binary_frameworks = runtime_frameworks(runtime_provider, transitive_runtime_deps)
    check_windows_frameworks(ctx.label, tfm, binary_frameworks, transitively = True)
    reserved = _reserved_paths(dll, runtime_provider, appsetting_files, inherited_content_files)

    # .NET runs the assembly through its host, from the runfiles; .NET
    # Framework runs the executable, with its dependencies beside it.
    runtime_files = None
    app_config = None
    netfx = None
    if is_netfx:
        netfx = _netfx_application(ctx, out_dir, tfm, dll, runtime_provider, transitive_runtime_deps, appsetting_files, inherited_content_files, reserved)
        staged += netfx.files
    else:
        runtime_files = _write_runtime_files(ctx, out_dir, assembly_name, tfm, toolchain, runtime_provider, transitive_runtime_deps, binary_frameworks)
        app_config = _stage_app_config(ctx, out_dir, dll, reserved)
        staged += [app_config] if app_config else []

    # .NET Framework loads native libraries from beside the executable, where
    # they are staged with the rest.
    native_libraries = [] if is_netfx else _stage_native_libraries(ctx, out_dir, runtime_provider, transitive_runtime_deps)
    (static_web_assets_info, static_web_files) = _stage_static_web_assets(ctx, out_dir, assembly_name, generated_assets)
    served = [entry.file for entry in static_web_files]

    # Assemblies a tool of ours compiles against from the toolchain rather than
    # from `deps` (`include_host_model_dll`, `include_msbuild_dlls`) are loaded
    # at run time as well.
    from_toolchain = (
        ([toolchain.host_model] if getattr(ctx.attr, "include_host_model_dll", False) else []) +
        (toolchain.msbuild_dlls if getattr(ctx.attr, "include_msbuild_dlls", False) else [])
    )

    # .NET Framework runs on the framework installed in Windows, and its
    # launcher needs no Bash runfiles library.
    runtime = [] if is_netfx else [runtime_toolchain.dotnetinfo.runtime_files, icu_files(runtime_toolchain)]
    extra_runfiles_objs = []
    if not is_windows and not is_netfx:
        extra_runfiles_objs.append(ctx.attr._bash_runfiles[DefaultInfo].default_runfiles)
    if _use_coverage(ctx, is_netfx = is_netfx):
        # The coverage tool runs from inside the test's runfiles tree, so it needs
        # its own support assemblies and runtimeconfig staged there too.
        extra_runfiles_objs.append(ctx.attr._coverage_tool[DefaultInfo].default_runfiles)

    runfiles = collect_transitive_runfiles(ctx, runtime_provider, ctx.attr.deps).merge_all([
        ctx.runfiles(
            files = staged + coverage_runfiles + ([runtime_files.runtimeconfig, runtime_files.deps_json] if runtime_files else []),
            transitive_files = depset(transitive = runtime),
        ),
        ctx.runfiles(files = [lib for dep in from_toolchain for lib in dep[DotnetAssemblyRuntimeInfo].libs]),
        ctx.runfiles(files = native_libraries + served),
    ] + extra_runfiles_objs)

    return [
        DefaultInfo(
            executable = launcher,
            runfiles = runfiles,
            files = depset([dll] + runtime_provider.xml_docs + staged + native_libraries + served),
        ),
        DotnetBinaryInfo(
            dll = dll,
            deps_json = runtime_files.deps_json if runtime_files else None,
            runtimeconfig_json = runtime_files.runtimeconfig if runtime_files else None,
            static_web_files = static_web_files,
            transitive_runtime_deps = transitive_runtime_deps,
            # None for rules_dotnet's own tools, which are never published.
            apphost_pack_info = ctx.attr._apphost_pack[0][DotnetApphostPackInfo] if ctx.attr._apphost_pack else None,
            runtime_pack_info = ctx.attr._runtime_pack[0][DotnetRuntimePackInfo] if ctx.attr._runtime_pack else None,
            framework_version = runtime_files.framework_version if runtime_files else None,
            runtime_frameworks = binary_frameworks,
            own_frameworks = resolve_framework_references(ctx.attr.project_sdk, getattr(ctx.attr, "framework_references", [])).keys(),
            winexe = winexe,
            app_config = app_config,
            netfx_layout = netfx.publish_layout if netfx else None,
        ),
        # The runtime files are runfiles, not default outputs, so these groups
        # are how a `filegroup` selects them. See BINARY_OUTPUT_GROUPS_DOC.
        OutputGroupInfo(
            deps_json = depset([runtime_files.deps_json] if runtime_files else []),
            runtimeconfig_json = depset([runtime_files.runtimeconfig] if runtime_files else []),
        ),
        compile_provider,
        runtime_provider,
        static_web_assets_info,
        coverage_info,
        coverage_common.instrumented_files_info(
            ctx,
            source_attributes = ["srcs"],
            dependency_attributes = ["deps", "data"],
        ),
        RunEnvironmentInfo(
            environment = {
                key: expand_variables(ctx, expand_locations(ctx, value, ctx.attr.data))
                for key, value in ctx.attr.envs.items()
            },
            inherited_environment = ctx.attr.env_inherit,
        ),
    ]
