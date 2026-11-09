"""WPF XAML compilation support for the C# compile action.

WPF `.xaml` files are compiled in two steps by tasks from the SDK's
`PresentationBuildTasks.dll`:

  * `MarkupCompilePass1` parses each `.xaml` file against the target's reference
    assemblies and emits a partial class `.g.cs` file (`InitializeComponent` and
    `IComponentConnector.Connect`) plus a binary `.baml` stream.

  * `ResourcesGenerator` packs all generated `.baml` streams (keyed as lowercase
    `<package-relative-path>.baml`) into `<AssemblyName>.g.resources`, which is
    embedded into the assembly as a manifest resource.
"""

load("//dotnet/private/rules/csharp/actions:razor.bzl", "target_path")

_OUTPUT_TYPES = {
    "library": "Library",
    "exe": "Exe",
    "winexe": "WinExe",
}

def wpf_xaml_action(
        actions,
        label,
        out_dir,
        assembly_name,
        root_namespace,
        target,
        xaml_srcs,
        refs,
        framework_files,
        tool,
        toolchain):
    """Compiles WPF `.xaml` files into `.g.cs` sources and a `.g.resources` bundle.

    Args:
      actions: The rule's `ctx.actions`.
      label: The label of the target being compiled.
      out_dir: The target's output directory prefix.
      assembly_name: The target's assembly name.
      root_namespace: The assembly's root namespace.
      target: The compiler target kind (`library`, `exe`, or `winexe`).
      xaml_srcs: The `.xaml` source files.
      refs: Depset of reference assemblies from dependencies.
      framework_files: Depset of reference assemblies from the targeting pack.
      tool: The `wpf_xaml` tool target.
      toolchain: The resolved .NET toolchain.

    Returns:
      A struct with `srcs` (list of generated `.g.cs` files) and `resources`
      (the generated `<AssemblyName>.g.resources` file).
    """
    wpf_tasks = toolchain.wpf_tasks
    task_files = wpf_tasks.files.to_list() if wpf_tasks else []
    if not task_files:
        fail(
            "%s has XAML sources, but the resolved .NET toolchain provides no " % label +
            "PresentationBuildTasks.dll.",
        )

    files = []
    generated_srcs = []
    seen = {}
    for src in xaml_srcs:
        relative_path = target_path(src.short_path, label)
        if relative_path in seen:
            fail(
                "two XAML sources in %s both map to %r: %s and %s." % (
                    label,
                    relative_path,
                    seen[relative_path],
                    src.short_path,
                ),
            )
        seen[relative_path] = src.short_path

        stem = relative_path[:-len(".xaml")]
        generated_cs = actions.declare_file("{}/wpf/{}.g.cs".format(out_dir, stem))
        generated_srcs.append(generated_cs)

        files.append(struct(
            relativePath = relative_path,
            source = src.path,
            generatedCs = generated_cs.path,
        ))

    output_resources = actions.declare_file("{}/manifest_resources/{}.g.resources".format(
        out_dir,
        assembly_name,
    ))

    all_refs = depset(transitive = [refs, framework_files]).to_list()

    request = actions.declare_file("{}/wpf_xaml_request.json".format(out_dir))
    actions.write(
        output = request,
        content = json.encode(struct(
            tasksAssemblies = [f.path for f in task_files],
            assemblyName = assembly_name,
            rootNamespace = root_namespace,
            outputType = _OUTPUT_TYPES.get(target, "Library"),
            outputResources = output_resources.path,
            references = [r.path for r in all_refs],
            files = files,
        )),
    )

    args = actions.args()
    args.add(request)

    actions.run(
        mnemonic = "WpfXaml",
        progress_message = "Compiling WPF XAML for " + label.name,
        executable = tool.files_to_run,
        arguments = [args],
        inputs = depset(
            direct = xaml_srcs + [request],
            transitive = [refs, framework_files, wpf_tasks.files],
        ),
        outputs = generated_srcs + [output_resources],
    )

    return struct(
        srcs = generated_srcs,
        resources = output_resources,
    )
