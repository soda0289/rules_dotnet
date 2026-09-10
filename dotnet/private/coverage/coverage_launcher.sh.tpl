#!/usr/bin/env bash
# Copyright 2017 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Launcher for a .Net test target built with a coverage tool configured.
#
# Under `bazel coverage`, Bazel's collect_coverage.sh sets COVERAGE=1 and runs the
# LCOV merger over COVERAGE_DIR afterwards, keeping only sources listed in
# COVERAGE_MANIFEST. Outside of that this behaves like the normal launcher.

# --- begin runfiles.bash initialization v3 ---
# Copy-pasted from the Bazel Bash runfiles library v3.
set -uo pipefail; set +e; f=bazel_tools/tools/bash/runfiles/runfiles.bash
source "${RUNFILES_DIR:-/dev/null}/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "${RUNFILES_MANIFEST_FILE:-/dev/null}" | cut -f2- -d' ')" 2>/dev/null || \
  source "$0.runfiles/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.exe.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  { echo>&2 "ERROR: cannot find $f"; exit 1; }; f=; set -e
# --- end runfiles.bash initialization v3 ---
runfiles_export_envvars

set -o pipefail -o errexit -o nounset

export DOTNET_MULTILEVEL_LOOKUP="false"
export DOTNET_NOLOGO="1"
export DOTNET_CLI_TELEMETRY_OPTOUT="1"

dotnet="$(rlocation TEMPLATED_dotnet)"
test_dll="$(rlocation TEMPLATED_executable)"
export DOTNET_ROOT="$(dirname "$dotnet")"

# Not a coverage run: behave exactly like the plain launcher. COVERAGE_DIR is
# checked too because it is where the report has to land for Bazel's LCOV merger
# to find it; without it there is nowhere to collect to.
if [ -z "${COVERAGE:-}" ] || [ -z "${COVERAGE_DIR:-}" ]; then
  exec "$dotnet" exec "$test_dll" "$@"
fi

# Coverlet instruments by rewriting assembly IL in place, so it must never be
# pointed at the runfiles tree: those entries are symlinks into the read-only
# output base, and File.Copy(overwrite: true) follows a symlink and writes
# straight through into bazel-out. Instead, copy the assemblies we want covered
# into a private staging tree under TEST_TMPDIR, laid out by rlocation path:
#
#   $stage/_main/some/pkg/lib/net9.0/lib.dll
#
# generate_depsjson() keys each dependency by its rlocation path, and the .Net
# host resolves an asset as "<probe dir>/<asset key>", so passing the staging
# root via --additionalprobingpath makes the runtime load the instrumented copies
# without regenerating deps.json. Host CLI probe paths are consulted before the
# runtimeconfig ones, so the staged copy wins over the original.
stage="${TEST_TMPDIR:-/tmp}/_rules_dotnet_coverage_stage"
rm -rf "$stage"
mkdir -p "$stage"

instrument_manifest="$(rlocation TEMPLATED_instrument_manifest)"
coverage_tool="$(rlocation TEMPLATED_coverage_tool)"

declare -a include_dirs=()
staged_any=0

# Coverlet scans the directory of the module it is given, plus each
# --include-directory, non-recursively. rules_dotnet gives every dependency its
# own runfiles directory, so each staged directory has to be listed. The flag is
# repeated rather than given a list: it is declared with
# AllowMultipleArgumentsPerToken, which would otherwise swallow the positional
# argument.
while read -r kind value || [ -n "${kind:-}" ]; do
  case "$kind" in
    F)
      src="$(rlocation "$value" || true)"
      if [ -z "$src" ] || [ ! -e "$src" ]; then
        continue
      fi

      dest="$stage/$value"
      mkdir -p "$(dirname "$dest")"
      # -L so a runfiles symlink is dereferenced into a real, writable file.
      cp -L "$src" "$dest"
      chmod u+w "$dest"
      staged_any=1
      ;;
    D)
      include_dirs+=("--include-directory" "$stage/$value")
      ;;
  esac
done < "$instrument_manifest"

# Nothing to instrument (e.g. a test with no first-party library deps). Run the
# test normally rather than handing the host a probing path it would ignore.
if [ "$staged_any" -eq 0 ]; then
  exec "$dotnet" exec "$test_dll" "$@"
fi

# Write into COVERAGE_DIR rather than COVERAGE_OUTPUT_FILE. collect_coverage.sh
# runs the LCOV merger over COVERAGE_DIR and writes its result to
# COVERAGE_OUTPUT_FILE; producing only the latter means the merger finds no input
# and overwrites it with an empty report. The ".dat" extension is required for
# the merger to pick the file up.
raw_lcov="${COVERAGE_DIR}/coverlet.dat"
mkdir -p "$COVERAGE_DIR"

# Paths are quoted because --targetargs is a single string that the coverage tool
# re-parses, and both TEST_TMPDIR and the workspace path can contain spaces.
targetargs="exec --additionalprobingpath \"$stage\" \"$test_dll\""
for arg in "$@"; do
  targetargs="$targetargs \"$arg\""
done

set +o errexit
TEMPLATED_coverage_invocation \
  "$test_dll" \
  ${include_dirs[@]+"${include_dirs[@]}"} \
  --target "$dotnet" \
  --targetargs "$targetargs" \
  --format lcov \
  --output "$raw_lcov" \
  --exclude-assemblies-without-sources None \
  TEMPLATED_coverage_extra_args
test_status=$?
set -o errexit

if [ $test_status -ne 0 ]; then
  exit $test_status
fi

if [ ! -f "$raw_lcov" ]; then
  echo >&2 "ERROR: the coverage tool did not produce an LCOV report at $raw_lcov"
  exit 1
fi

# Keep the tool's report exactly as it came out, before any rewriting. Bazel
# deletes COVERAGE_DIR after the run, and when the normalization below does not
# match what the tool emitted the result is an empty-but-successful report -- so
# this copy is the only way to see what the SF: lines actually looked like.
if [ -n "${TEST_UNDECLARED_OUTPUTS_DIR:-}" ]; then
  cp "$raw_lcov" "$TEST_UNDECLARED_OUTPUTS_DIR/coverlet.raw.dat" 2>/dev/null || true
fi

# Two rewrites are needed before Bazel can consume this:
#
#  1. rules_dotnet compiles with -pathmap:$PWD=. (see compiler_wrapper.sh), so
#     PDB documents -- and therefore coverlet's SF: lines -- are workspace
#     relative but carry a leading "./". Bazel's CoverageOutputGenerator matches
#     them against COVERAGE_MANIFEST exec paths with an exact string comparison,
#     so without stripping that prefix every source is dropped and the report
#     comes back empty but successful.
#  2. Coverlet writes FN:/FNDA: records keyed by the full Cecil method signature,
#     which contains commas. Bazel's LcovParser splits those lines on "," and
#     rejects any method with two or more parameters, logging a warning per line.
#     Line and branch data (DA:/BRDA:) are unaffected, so drop the function
#     records rather than emitting data Bazel cannot parse.
sed -e 's|^SF:\./|SF:|' -e '/^FN:/d' -e '/^FNDA:/d' -e '/^FNF:/d' -e '/^FNH:/d' \
  "$raw_lcov" > "$raw_lcov.tmp"
mv "$raw_lcov.tmp" "$raw_lcov"

# If nothing survived, say so. Bazel's merger drops sources it cannot match
# against the coverage manifest and still exits 0, so without this the run looks
# like a pass with no coverage in it.
if ! grep -q '^SF:' "$raw_lcov"; then
  echo >&2 "WARNING: the coverage report contains no source files after normalization."
  echo >&2 "WARNING: the unnormalized report was saved as coverlet.raw.dat in the test outputs."
fi
