@echo off
SETLOCAL ENABLEEXTENSIONS
SETLOCAL ENABLEDELAYEDEXPANSION

rem Launcher for a .Net test target built with a coverage tool configured.
rem
rem Mirrors coverage_launcher.sh.tpl: stage the assemblies to instrument into a
rem private tree under TEST_TMPDIR, point the .Net host at it with
rem --additionalprobingpath so the instrumented copies win over the originals in
rem runfiles, then normalize the LCOV for Bazel's merger.

:: Start of rlocation
goto :rlocation_end
:rlocation
if "%~2" equ "" (
  echo>&2 ERROR: Expected two arguments for rlocation function.
  exit 1
)
if "%RUNFILES_MANIFEST_ONLY%" neq "1" (
  set %~2=%~1
  exit /b 0
)
if exist "%RUNFILES_DIR%" (
  set RUNFILES_MANIFEST_FILE=%RUNFILES_DIR%_manifest
)
if "%RUNFILES_MANIFEST_FILE%" equ "" (
  set RUNFILES_MANIFEST_FILE=%~f0.runfiles\MANIFEST
)
if not exist "%RUNFILES_MANIFEST_FILE%" (
  set RUNFILES_MANIFEST_FILE=%~f0.runfiles_manifest
)
set MF=%RUNFILES_MANIFEST_FILE:/=\%
if not exist "%MF%" (
  echo>&2 ERROR: Manifest file %MF% does not exist.
  exit 1
)
set runfile_path=%~1
rem Reset before the lookup. The upstream copy of this helper leaves abs_path at
rem whatever the previous call set it to, which is harmless when it is called once
rem but not here: the staging loop calls it per file, so a miss would silently
rem resolve to the previously looked-up path.
set "abs_path="
for /F "tokens=2* usebackq" %%i in (`%SYSTEMROOT%\system32\findstr.exe /l /c:"!runfile_path! " "%MF%"`) do (
  set abs_path=%%i
)
if "!abs_path!" equ "" (
  echo>&2 ERROR: !runfile_path! not found in runfiles manifest
  exit 1
)
set %~2=!abs_path!
exit /b 0
:rlocation_end
:: End of rlocation

set RUNFILES_MANIFEST_ONLY=1
set DOTNET_MULTILEVEL_LOOKUP="false"
set DOTNET_NOLOGO="1"
set DOTNET_CLI_TELEMETRY_OPTOUT="1"

call :rlocation "TEMPLATED_dotnet" dotnet_executable
for %%F in ("!dotnet_executable!") do set DOTNET_ROOT=%%~dpF

call :rlocation "TEMPLATED_executable" test_dll

set args=%*
rem Escape \ and * in args before passsing it with double quote
if defined args (
  set args=!args:\=\\\\!
  set args=!args:"=\"!
)

rem Not a coverage run: behave exactly like the plain launcher. COVERAGE_DIR is
rem checked too because it is where the report has to land for Bazel's LCOV
rem merger to find it.
if not defined COVERAGE goto :run_plain
if not defined COVERAGE_DIR goto :run_plain

rem Bazel's Windows runfiles manifest stores forward-slashed paths, and so does
rem TEST_TMPDIR. cmd's builtins (copy, md, move, rd, findstr) treat "/" as a
rem switch prefix rather than a separator and fail on such paths -- while "if
rem exist" accepts them, which makes the failure look like a missing file. Every
rem path handed to a builtin below is therefore backslash-normalized first.
if not defined TEST_TMPDIR set "TEST_TMPDIR=%TEMP%"
set "stage=%TEST_TMPDIR%\_rules_dotnet_coverage_stage"
set "stage=!stage:/=\!"
if exist "!stage!" rd /s /q "!stage!"
md "!stage!"

call :rlocation "TEMPLATED_instrument_manifest" instrument_manifest
set "instrument_manifest=!instrument_manifest:/=\!"
call :rlocation "TEMPLATED_coverage_tool" coverage_tool

set "include_dirs="
set "staged_any=0"
set "staging_failed=0"

rem The manifest holds "F <rlocation path>" lines for files to stage and
rem "D <relative dir>" lines for the directories to hand to --include-directory.
rem Both are computed at analysis time, so there is no scanning or deduplication
rem to do here.
for /F "usebackq tokens=1,* delims= " %%A in ("!instrument_manifest!") do (
  if "%%A"=="F" (
    call :stage_file "%%B"
  ) else if "%%A"=="D" (
    set "reldir=%%B"
    set "include_dirs=!include_dirs! --include-directory "!stage!\!reldir:/=\!""
  )
)

rem A partially staged tree would silently under-report coverage, so treat any
rem staging failure as fatal rather than falling through to an uninstrumented run
rem that passes with an empty report.
if "!staging_failed!"=="1" (
  echo>&2 ERROR: coverage staging failed; refusing to report partial coverage.
  exit /b 1
)

rem Nothing to instrument (e.g. a test with no first-party library deps). Run the
rem test normally rather than handing the host a probing path it would ignore.
if "!staged_any!"=="0" goto :run_plain

rem Write into COVERAGE_DIR rather than COVERAGE_OUTPUT_FILE: collect_coverage.sh
rem runs the LCOV merger over COVERAGE_DIR and writes its result to
rem COVERAGE_OUTPUT_FILE, so producing only the latter means the merger finds no
rem input and overwrites it with an empty report. The ".dat" extension is
rem required for the merger to pick the file up.
set "coverage_dir=%COVERAGE_DIR%"
set "coverage_dir=!coverage_dir:/=\!"
set "raw_lcov=!coverage_dir!\coverlet.dat"
if not exist "!coverage_dir!" md "!coverage_dir!"

rem --targetargs is a single string that the coverage tool re-parses. Quoting the
rem inner paths with \" does not survive cmd: a doubled backslash makes \\ a
rem literal backslash and the following quote closes the string early, so the
rem arguments arrive as separate tokens. Use 8.3 short paths instead -- they
rem contain no spaces, so no inner quoting is needed and there is only ever one
rem level of quoting to reason about. Where 8.3 names are disabled this yields the
rem long path unchanged, which is still fine for the space-free paths Bazel
rem generates.
for %%F in ("!stage!") do set "stage_short=%%~sF"
for %%F in ("!test_dll!") do set "test_dll_short=%%~sF"
set "targetargs=exec --additionalprobingpath !stage_short! !test_dll_short!"
if defined args set "targetargs=!targetargs! !args!"

TEMPLATED_coverage_invocation ^
  "!test_dll!"!include_dirs! ^
  --target "!dotnet_executable!" ^
  --targetargs "!targetargs!" ^
  --format lcov ^
  --output "!raw_lcov!" ^
  --exclude-assemblies-without-sources None ^
  TEMPLATED_coverage_extra_args
set "test_status=!errorlevel!"

if not "!test_status!"=="0" exit /b !test_status!

if not exist "!raw_lcov!" (
  echo>&2 ERROR: the coverage tool did not produce an LCOV report at !raw_lcov!
  exit /b 1
)

rem Keep the tool's report exactly as it came out, before any rewriting. Bazel
rem deletes COVERAGE_DIR after the run, and when the normalization below does not
rem match what the tool emitted the result is an empty-but-successful report --
rem so this copy is the only way to see what the SF: lines actually looked like.
if defined TEST_UNDECLARED_OUTPUTS_DIR (
  set "outputs_dir=%TEST_UNDECLARED_OUTPUTS_DIR%"
  set "outputs_dir=!outputs_dir:/=\!"
  copy /Y "!raw_lcov!" "!outputs_dir!\coverlet.raw.dat" >nul 2>&1
)

rem Three rewrites are needed before Bazel can consume this, and all of them are
rem silent failures if skipped -- the merger drops unmatched sources and still
rem exits 0:
rem
rem  1. compiler_wrapper.bat passes -pathmap:"%cd%=." and %cd% is a backslash
rem     path, so PDB documents come out as ".\pkg\lib.cs". Strip the leading
rem     ".\" (or "./").
rem  2. Bazel's coverage manifest holds forward-slash exec paths and matches by
rem     exact string, so the remaining separators have to be flipped to "/".
rem     Only SF: lines are touched; other records carry no paths.
rem  3. Coverlet writes FN:/FNDA: records keyed by the full method signature,
rem     which contains commas. Bazel's LcovParser splits those on "," and rejects
rem     any method with two or more parameters. Line and branch data are
rem     unaffected, so drop the function records.
rem
rem There is no sed on Windows, hence PowerShell. Paths go through the
rem environment to keep them out of the quoting.
set "LCOV_IN=!raw_lcov!"
set "LCOV_OUT=!raw_lcov!.tmp"
powershell -NoProfile -NonInteractive -Command ^
  "Get-Content -LiteralPath $env:LCOV_IN | Where-Object { $_ -notmatch '^FN(:|DA:|F:|H:)' } | ForEach-Object { if ($_ -like 'SF:*') { ($_ -replace '^SF:\.[\\/]', 'SF:') -replace '\\', '/' } else { $_ } } | Set-Content -LiteralPath $env:LCOV_OUT"
if not "!errorlevel!"=="0" (
  echo>&2 ERROR: failed to normalize the LCOV report at !raw_lcov!
  exit /b 1
)
move /Y "!LCOV_OUT!" "!LCOV_IN!" >nul

rem If nothing survived, say so. Bazel's merger drops sources it cannot match
rem against the coverage manifest and still exits 0, so without this the run looks
rem like a pass with no coverage in it.
findstr /b /c:"SF:" "!LCOV_IN!" >nul 2>&1
if errorlevel 1 (
  echo>&2 WARNING: the coverage report contains no source files after normalization.
  echo>&2 WARNING: the unnormalized report was saved as coverlet.raw.dat in the test outputs.
)
exit /b 0

:stage_file
rem Copy one runfile into the staging tree, preserving its rlocation-relative
rem layout so --additionalprobingpath resolves it the same way deps.json names it.
rem Failures here are reported rather than skipped: an unstaged assembly means a
rem silently empty coverage report, which is the failure mode this whole design
rem is trying to avoid.
set "rel=%~1"
call :rlocation "%rel%" src
if defined src set "src=!src:/=\!"
if not defined src (
  echo>&2 ERROR: coverage staging could not resolve %rel% in the runfiles manifest
  set "staging_failed=1"
  exit /b 0
)
if not exist "!src!" (
  echo>&2 ERROR: coverage staging resolved %rel% to "!src!" which does not exist
  set "staging_failed=1"
  exit /b 0
)
set "dest=%stage%\%rel:/=\%"
for %%F in ("!dest!") do set "destdir=%%~dpF"
rem %%~dp leaves a trailing backslash, and "dir\" inside quotes escapes the quote.
if "!destdir:~-1!"=="\" set "destdir=!destdir:~0,-1!"
if not exist "!destdir!" md "!destdir!"
copy /Y "!src!" "!dest!" >nul
if not exist "!dest!" (
  echo>&2 ERROR: coverage staging failed to copy "!src!" to "!dest!"
  set "staging_failed=1"
  exit /b 0
)
rem Runfiles can be read-only; coverlet rewrites the assembly in place.
attrib -r "!dest!" >nul 2>&1
set "staged_any=1"
exit /b 0

:run_plain
"!dotnet_executable!" exec "!test_dll!" !args!
