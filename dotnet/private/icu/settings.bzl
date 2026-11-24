"""Applying the globalization settings to the .Net processes the rules start.

On Linux the runtime loads ICU from shared libraries, which the machine may not
have. `//dotnet/settings:invariant_globalization` makes the runtime do without
culture data; `//dotnet/settings:icu` names an ICU for the build to carry, such
as the one this package builds. Either setting has to reach the compilers and
the tools of a build as well as the binaries and tests it produces.
See docs/README.md#globalization-and-icu.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//dotnet/private:common.bzl", "to_rlocation_path")

# The runtime reads this to decide whether to load ICU at all. See
# https://learn.microsoft.com/dotnet/core/runtime-config/globalization#invariant-mode
INVARIANT_GLOBALIZATION_VARIABLE = "DOTNET_SYSTEM_GLOBALIZATION_INVARIANT"

# The version of ICU the runtime is to look for. It reads the first; the second
# is its name before .NET 10. See
# https://learn.microsoft.com/dotnet/core/extensions/globalization-icu#load-specific-icu-version-on-linux
ICU_VERSION_VARIABLES = ["DOTNET_ICU_VERSION_OVERRIDE", "CLR_ICU_VERSION_OVERRIDE"]

_ICUUC_PREFIX = "libicuuc.so."

def _icu_library(icu):
    """The `libicuuc.so.<version>` of an ICU the build carries, or None.

    The runtime looks that one up first, by the version in its name, and takes
    `libicui18n` and `libicudata` from beside it, so it stands for the set.

    Args:
        icu: The toolchain's `icu` or `exec_icu`.
    """

    for file in icu[DefaultInfo].files.to_list():
        if file.basename.startswith(_ICUUC_PREFIX):
            return file
    return None

def _icu_version(library):
    """The major version in the name of a `libicuuc.so.<version>`."""

    return library.basename[len(_ICUUC_PREFIX):].split(".")[0]

def icu_files(toolchain):
    """The shared libraries of the ICU `//dotnet/settings:icu` names.

    They are built for the platform the toolchain's binaries run on. The
    compilers run on the execution platform instead, and take theirs from
    `globalization_env` and `icu_wrapper_arguments`.

    Args:
        toolchain: The resolved .Net toolchain, which carries the flag.

    Returns:
        A depset of files, empty when the runtime is to use the machine's own.
    """

    return toolchain.icu[DefaultInfo].files

def globalization_env(toolchain):
    """The environment that applies the globalization settings to a .Net process.

    An action runs with the environment the rules give it rather than the
    client's, so `--action_env` cannot carry these. Without the ICU version the
    runtime takes the highest it finds, which could be the machine's rather than
    the one the build carries. An action runs on the execution platform, so the
    version is that of the ICU built for it.

    Args:
        toolchain: The resolved .Net toolchain, which carries the settings.

    Returns:
        A dict of environment variables, empty unless a setting applies.
    """

    env = {}
    if toolchain.invariant_globalization[BuildSettingInfo].value:
        env[INVARIANT_GLOBALIZATION_VARIABLE] = "1"

    library = _icu_library(toolchain.exec_icu)
    if library != None:
        for variable in ICU_VERSION_VARIABLES:
            env[variable] = _icu_version(library)

    return env

def icu_wrapper_arguments(actions, toolchain):
    """The leading arguments and tools that tell the compiler wrapper about the ICU.

    The ICU is the one built for the execution platform, where the compiler
    runs. An `Args` rather than a plain string, so that path mapping rewrites
    the path along with the rest of the compile. See docs/README.md#path-mapping.

    Args:
        actions: The rule's `actions`.
        toolchain: The resolved .Net toolchain.

    Returns:
        An (arguments, tools) pair, both empty when the build carries no ICU.
    """

    library = _icu_library(toolchain.exec_icu)
    if library == None:
        return [], []

    arguments = actions.args()
    arguments.add(library, format = "--icu=%s")
    return [arguments], [toolchain.exec_icu[DefaultInfo].files]

def icu_launcher_config(ctx, toolchain, is_windows):
    """Globalization settings written into a target's launcher configuration.

    A launcher starts the binaries and tests as well as the tools of a build.
    The invariant setting only supplies a default, so a value already in the
    environment, such as one from `envs` or `--test_env`, wins. Only Linux loads
    ICU from shared libraries, so Windows launchers carry no ICU library.

    Args:
        ctx: The rule context, for the runfiles path of the libraries.
        toolchain: The resolved .Net toolchain.
        is_windows: Whether the launcher targets Windows.

    Returns:
        A struct of `invariant_globalization`, `icu_lib`, and `icu_version`.
    """
    library = None if is_windows else _icu_library(toolchain.icu)
    return struct(
        invariant_globalization = toolchain.invariant_globalization[BuildSettingInfo].value,
        icu_lib = to_rlocation_path(ctx, library) if library != None else "",
        icu_version = _icu_version(library) if library != None else "",
    )
