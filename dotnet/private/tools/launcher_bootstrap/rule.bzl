"""Builds the managed bootstrap assembly invoked by hermetic_launcher stubs.

Unlike `bootstrap_tool_binary` and `compiler_worker_binary`, this produces no
launcher of its own: every executable rule's launcher invokes `dotnet exec` on
this assembly, so giving it a launcher would make it depend on itself.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load(
    "//dotnet/private:common.bzl",
    "default_csharp_lang_version",
    "generate_runtimeconfig",
    "get_compiler_wrapper",
    "is_debug",
    "targets_windows",
)
load("//dotnet/private:toolchains_repo.bzl", "BOOTSTRAP_TOOLCHAIN_TYPE")
load("//dotnet/private/rules/csharp/actions:csharp_assembly.bzl", "AssemblyAction")
load("//dotnet/private/sdk:packs.bzl", "BOOTSTRAP_PACKS")
load("//dotnet/private/sdk/targeting_packs:targeting_pack_transition.bzl", "targeting_pack_transition")
load("//dotnet/private/transitions:bootstrap_tool_transition.bzl", "bootstrap_tool_transition")

LauncherBootstrapInfo = provider(
    doc = "Carries the launcher bootstrap assembly and its runtimeconfig.json.",
    fields = {
        "dll": "The compiled launcher_bootstrap.dll File.",
        "files": "Depset of runtime files required to execute launcher_bootstrap.dll.",
    },
)

def _launcher_bootstrap_impl(ctx):
    toolchain = ctx.toolchains[BOOTSTRAP_TOOLCHAIN_TYPE]
    tfm = ctx.attr._target_framework[BuildSettingInfo].value

    (_, runtime_provider, _) = AssemblyAction(
        ctx.actions,
        get_compiler_wrapper(ctx),
        compiler_worker = None,
        label = ctx.label,
        additionalfiles = [],
        debug = is_debug(ctx),
        embed_sources = False,
        defines = [],
        deps = [],
        exports = [],
        targeting_pack = ctx.attr._targeting_pack[0],
        internals_visible_to = [],
        keyfile = None,
        langversion = default_csharp_lang_version(tfm, toolchain.dotnetinfo.csharp_default_version),
        resources = [],
        resx = None,
        srcs = ctx.files.srcs,
        data = [],
        appsetting_files = [],
        content_file_mappings = [],
        compile_data = [],
        out = "",
        target = "exe",
        target_name = ctx.attr.name,
        target_framework = tfm,
        version = "",
        toolchain = toolchain,
        strict_deps = True,
        generate_documentation_file = False,
        include_host_model_dll = False,
        include_msbuild_dlls = False,
        treat_warnings_as_errors = True,
        warnings_as_errors = [],
        warnings_not_as_errors = [],
        warning_level = 4,
        nowarn = ["CS1701", "CS1702"],
        project_sdk = "default",
        root_namespace = "",
        scoped_css_tool = ctx.attr._scoped_css_tool,
        allow_unsafe_blocks = False,
        nullable = "enable",
        run_analyzers = False,
        enable_net_analyzers = False,
        enforce_code_style_in_build = False,
        analysis_mode = "default",
        is_analyzer = False,
        is_language_specific_analyzer = False,
        analyzer_configs = [],
        compiler_options = [],
        interceptors_namespaces = [],
        excluded_analyzers = [],
        is_windows = targets_windows(ctx),
    )

    dll = runtime_provider.libs[0]
    runtimeconfig = ctx.actions.declare_file(
        "{}/{}/{}.runtimeconfig.json".format(ctx.label.name, tfm, ctx.label.name),
    )
    runtimeconfig_struct = generate_runtimeconfig(
        target_framework = tfm,
        frameworks = [],
        is_self_contained = False,
        roll_forward_behavior = "Major",
        framework_version = "6.0.0",
    )
    ctx.actions.write(
        output = runtimeconfig,
        content = json.encode(runtimeconfig_struct),
    )

    files = depset([dll, runtimeconfig])
    return [
        DefaultInfo(files = files),
        LauncherBootstrapInfo(
            dll = dll,
            files = files,
        ),
    ]

launcher_bootstrap_assembly = rule(
    implementation = _launcher_bootstrap_impl,
    doc = "Compiles the managed stage-two launcher bootstrap assembly.",
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".cs"],
            mandatory = True,
        ),
        "target_frameworks": attr.string_list(
            mandatory = True,
        ),
        "project_sdk": attr.string(
            default = "default",
        ),
        "_target_framework": attr.label(
            default = "//dotnet:target_framework",
        ),
        "_windows_constraint": attr.label(
            default = "@platforms//os:windows",
        ),
        "_compiler_wrapper_sh": attr.label(
            default = "//dotnet/private:compiler_wrapper.sh",
            executable = True,
            cfg = "exec",
            allow_single_file = True,
        ),
        "_compiler_wrapper_bat": attr.label(
            default = "//dotnet/private:compiler_wrapper.bat",
            executable = True,
            cfg = "exec",
            allow_single_file = True,
        ),
        "_scoped_css_tool": attr.label(
            default = "//dotnet/private:no_tool",
            cfg = "exec",
        ),
        "_pack_set": attr.string(
            default = BOOTSTRAP_PACKS,
        ),
        "_targeting_pack": attr.label(
            default = "//dotnet/private/sdk/targeting_packs:targeting_pack",
            cfg = targeting_pack_transition,
        ),
    },
    toolchains = [BOOTSTRAP_TOOLCHAIN_TYPE],
    cfg = bootstrap_tool_transition,
)
