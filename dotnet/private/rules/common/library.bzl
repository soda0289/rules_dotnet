"Common implementation for building .Net libraries"

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//dotnet/private:common.bzl", "collect_transitive_runfiles")
load("//dotnet/private:providers.bzl", "DotnetCoverageInfo")
load("//dotnet/private/rules/common:static_web_assets.bzl", "collect_static_web_assets")
load("//dotnet/private/rules/ready_to_run:ready_to_run.bzl", "with_ready_to_run_images")

def _collect_coverage_info(ctx, runtime_provider):
    own = (
        runtime_provider.libs + runtime_provider.pdbs if ctx.coverage_instrumented() and runtime_provider.pdbs else []
    )
    dep_attrs = getattr(ctx.attr, "deps", []) + getattr(ctx.attr, "exports", [])
    return DotnetCoverageInfo(
        files = depset(
            own,
            transitive = [
                dep[DotnetCoverageInfo].files
                for dep in dep_attrs
                if DotnetCoverageInfo in dep
            ],
        ),
    )

def build_library(ctx, compile_action, toolchain):
    """Builds a .Net library from a compilation action

    Args:
        ctx: Bazel build ctx.
        compile_action: A function taking (ctx, tfm, toolchain) that compiles the srcs
            and returns a (DotnetAssemblyCompileInfo, DotnetAssemblyRuntimeInfo,
            generated static web assets) tuple.
        toolchain: The .Net toolchain to compile with.
    Returns:
        A collection of the references, runfiles and native dlls.
    """
    tfm = ctx.attr._target_framework[BuildSettingInfo].value

    (compile_provider, runtime_provider, generated_assets) = compile_action(ctx, tfm, toolchain)
    runtime_provider = with_ready_to_run_images(ctx, runtime_provider)

    return [
        compile_provider,
        runtime_provider,
        collect_static_web_assets(
            label = ctx.label,
            assembly_name = runtime_provider.name,
            files = ctx.files.static_web_assets,
            deps = ctx.attr.deps,
            is_application = False,
            generated = generated_assets,
        ),
        # Libraries have to report their own sources and keep the walk going
        # through `deps` and `exports`, otherwise a test's coverage manifest would
        # contain only the test's own sources and every library source would be
        # filtered out of the merged report.
        _collect_coverage_info(ctx, runtime_provider),
        coverage_common.instrumented_files_info(
            ctx,
            source_attributes = ["srcs"],
            dependency_attributes = ["deps", "exports", "data"],
        ),
        DefaultInfo(
            files = depset(
                runtime_provider.libs + runtime_provider.xml_docs +
                [asset.file for asset in generated_assets],
            ),
            default_runfiles = collect_transitive_runfiles(
                ctx,
                runtime_provider,
                ctx.attr.deps,
            ),
        ),
    ]
