"""
Base rule for building .Net binaries
"""

load("@bazel_lib//lib:expand_make_vars.bzl", "expand_locations", "expand_variables")
load("@bazel_skylib//lib:shell.bzl", "shell")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load(
    "//dotnet/private:common.bzl",
    "collect_transitive_runfiles",
    "generate_depsjson",
    "generate_runtimeconfig",
    "get_toolchain",
    "is_core_framework",
    "is_standard_framework",
    "to_rlocation_path",
)
load("//dotnet/private:providers.bzl", "DotnetApphostPackInfo", "DotnetAssemblyRuntimeInfo", "DotnetBinaryInfo", "DotnetRuntimePackInfo")

def _collect_native_dlls(assembly_runtime_info, deps):
    """Collect the native DLLs of target and its dependencies.

    Args:
        assembly_runtime_info: The DotnetAssemblyRuntimeInfo provider for the target.
        deps: Dependencies of the target.

    Returns:
        A list of native DLL files that includes the transitive dependencies of the target
    """
    native_dlls = assembly_runtime_info.native

    for dep in deps:
        native_dlls.extend(dep[DotnetAssemblyRuntimeInfo].native)
        for transitive_dep in dep[DotnetAssemblyRuntimeInfo].deps.to_list():
            native_dlls.extend(transitive_dep.native)

    # Create a dict where the key is the RID and the value is the list of native DLLs for that RID
    result = {}
    for dll in native_dlls:
        rid = dll.dirname.split("/")[-2]
        if rid not in result:
            result[rid] = []
        result[rid].append(dll)

    return result

def _use_coverage(ctx):
    """Whether this target should be built with coverage instrumentation.

    True only during `bazel coverage` (`--collect_code_coverage`) on a test rule
    that has a coverage tool configured via
    `--@rules_dotnet//dotnet/settings:coverage_tool`. Outside of that, targets are
    built exactly as they are today, so a plain `bazel build`/`bazel test` pays
    nothing for this feature.

    Args:
        ctx: Bazel build ctx.

    Returns:
        True if a coverage-collecting launcher should be produced.
    """
    if not hasattr(ctx.attr, "_coverage_tool"):
        return False
    if not ctx.configuration.coverage_enabled:
        return False

    # The default is an empty sentinel filegroup, meaning "no tool configured".
    return len(ctx.attr._coverage_tool[DefaultInfo].files.to_list()) > 0

def _coverage_instrumented_assemblies(transitive_runtime_deps):
    """The assemblies the coverage tool should instrument, plus their PDBs.

    Coverlet rewrites assembly IL and needs each assembly's PDB beside it, so
    both are returned. Only assemblies that carry a PDB are included, which
    limits the set to code rules_dotnet built from source and skips
    NuGet-imported assemblies.

    The test's own assembly is deliberately excluded. Coverlet does not
    instrument the test assembly unless --include-test-assembly is passed, which
    matches Bazel's --instrument_test_targets defaulting to false. The practical
    consequence for users is that code under test has to live in a
    csharp_library/fsharp_library rather than in the test target's own srcs.

    Args:
        transitive_runtime_deps: List of transitive DotnetAssemblyRuntimeInfo providers.

    Returns:
        A list of DLL and PDB files, deduplicated by assembly file name.
    """
    files = []

    # Coverlet deduplicates coverable modules by file name, so two same-named
    # assemblies in different staged directories would silently collapse to
    # whichever it saw first. Dedupe here instead, so the staging tree matches
    # what the tool will actually instrument.
    seen = {}
    for info in transitive_runtime_deps:
        if not info.pdbs:
            continue
        for f in info.libs + info.pdbs:
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

def _create_launcher(ctx, runfiles, executable, runtime_provider = None, transitive_runtime_deps = None):
    runtime = get_toolchain(ctx).runtime
    windows_constraint = ctx.attr._windows_constraint[platform_common.ConstraintValueInfo]
    is_windows = ctx.target_platform_has_constraint(windows_constraint)

    launcher = ctx.actions.declare_file("{}.{}".format(executable.basename, "bat" if is_windows else "sh"), sibling = executable)

    substitutions = {
        "TEMPLATED_dotnet": to_rlocation_path(ctx, runtime.files_to_run.executable),
        "TEMPLATED_executable": to_rlocation_path(ctx, executable),
    }

    use_coverage = _use_coverage(ctx)

    if use_coverage:
        instrumented = _coverage_instrumented_assemblies(transitive_runtime_deps)

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
            runfiles.append(ctx.file._coverage_runner_ps1)
        else:
            substitutions["TEMPLATED_coverage_tool"] = coverage_tool_path
            substitutions["TEMPLATED_coverage_invocation"] = coverage_invocation
            substitutions["TEMPLATED_coverage_extra_args"] = " ".join([shell.quote(arg) for arg in extra_args])

        runfiles.append(instrument_manifest)
        runfiles.extend(instrumented)

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

    runfiles.extend(get_toolchain(ctx).dotnetinfo.runtime_files)

    return launcher

def build_binary(ctx, compile_action):
    """Builds a .Net binary from a compilation action

    Args:
        ctx: Bazel build ctx.
        compile_action: A compilation function
            Args:
                ctx: Bazel build ctx.
                tfm: Target framework string
            Returns:
                An DotnetAssemblyInfo provider
    Returns:
        A collection of the references, runfiles and native dlls.
    """
    tfm = ctx.attr._target_framework[BuildSettingInfo].value

    if is_standard_framework(tfm):
        fail("It doesn't make sense to build an executable for " + tfm)

    (compile_provider, runtime_provider) = compile_action(ctx, tfm)
    dll = runtime_provider.libs[0]
    default_info_files = [dll] + runtime_provider.xml_docs + runtime_provider.appsetting_files.to_list()

    # appsetting_files must be in runfiles (not just DefaultInfo) so they're present when the target runs from an isolated runfiles tree (RBE/sandbox).
    additional_runfiles = runtime_provider.appsetting_files.to_list()

    transitive_runtime_deps = runtime_provider.deps.to_list()

    launcher = _create_launcher(ctx, additional_runfiles, dll, runtime_provider, transitive_runtime_deps)

    runtimeconfig = None
    depsjson = None

    if is_core_framework(tfm):
        # Create the runtimeconfig.json for the binary
        runtimeconfig = ctx.actions.declare_file("%s/%s/%s.runtimeconfig.json" % (ctx.label.name, tfm, ctx.attr.out or ctx.attr.name))
        runtimeconfig_struct = generate_runtimeconfig(
            target_framework = tfm,
            project_sdk = ctx.attr.project_sdk,
            is_self_contained = False,
            roll_forward_behavior = ctx.attr.roll_forward_behavior,
        )

        # Add additional lookup paths so that we can avoid copying all DLLs
        # into the output directory. The deps.json file will then contain
        # paths that are relative to the workspace root
        runtimeconfig_struct["runtimeOptions"]["additionalProbingPaths"] = [
            "./",
            "./external",
            "../",
            "../external",
            # This one is for when the binary target is used as an tool in e.g. a custom rule
            "{}.runfiles".format(launcher.path),
        ]
        ctx.actions.write(
            output = runtimeconfig,
            content = json.encode_indent(runtimeconfig_struct),
        )

        depsjson = ctx.actions.declare_file("%s/%s/%s.deps.json" % (ctx.label.name, tfm, ctx.attr.out or ctx.attr.name))
        depsjson_struct = generate_depsjson(
            ctx,
            target_framework = tfm,
            is_self_contained = False,
            target_assembly_runtime_info = runtime_provider,
            transitive_runtime_deps = transitive_runtime_deps,
            use_relative_paths = True,
        )

        ctx.actions.write(
            output = depsjson,
            content = json.encode_indent(depsjson_struct),
        )

    if runtimeconfig != None:
        additional_runfiles.append(runtimeconfig)

    if depsjson != None:
        additional_runfiles.append(depsjson)

    runfiles = collect_transitive_runfiles(ctx, runtime_provider, ctx.attr.deps).merge(ctx.runfiles(files = additional_runfiles))

    if _use_coverage(ctx):
        # The coverage tool runs from inside the test's runfiles tree, so it needs
        # its own support assemblies and runtimeconfig staged there too.
        runfiles = runfiles.merge(ctx.attr._coverage_tool[DefaultInfo].default_runfiles)

    # Due to how the .Net runtime loads native DLLs we need make the native
    # DLLs available in the application root directory with the folder structure:
    # runtimes/{rid}/native/{dlls}
    native_dlls = _collect_native_dlls(runtime_provider, ctx.attr.deps)
    for (rid, native_files) in native_dlls.items():
        for file in native_files:
            output_path = "{}/{}/runtimes/{}/native/{}".format(ctx.label.name, tfm, rid, file.basename)
            output = ctx.actions.declare_file(output_path)
            ctx.actions.symlink(
                output = output,
                target_file = file,
            )
            default_info_files.append(output)
            runfiles = runfiles.merge(ctx.runfiles(files = [output]))

    if not ctx.target_platform_has_constraint(ctx.attr._windows_constraint[platform_common.ConstraintValueInfo]):
        runfiles = runfiles.merge(ctx.attr._bash_runfiles[DefaultInfo].default_runfiles)
    default_info = DefaultInfo(
        executable = launcher,
        runfiles = runfiles,
        files = depset(default_info_files),
    )

    dotnet_binary_info = DotnetBinaryInfo(
        dll = dll,
        transitive_runtime_deps = transitive_runtime_deps,
        apphost_pack_info = ctx.attr._apphost_pack[0][DotnetApphostPackInfo],
        runtime_pack_info = ctx.attr._runtime_pack[0][DotnetRuntimePackInfo],
    )

    return [default_info, dotnet_binary_info, compile_provider, runtime_provider, coverage_common.instrumented_files_info(
        ctx,
        source_attributes = ["srcs"],
        dependency_attributes = ["deps", "data"],
    ), RunEnvironmentInfo(environment = {key: expand_variables(ctx, expand_locations(ctx, value, ctx.attr.data)) for key, value in ctx.attr.envs.items()}, inherited_environment = ctx.attr.env_inherit)]
