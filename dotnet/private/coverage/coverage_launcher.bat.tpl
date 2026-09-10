@echo off
SETLOCAL ENABLEEXTENSIONS
SETLOCAL ENABLEDELAYEDEXPANSION

rem Launcher for a .Net test target built with a coverage tool configured.
rem
rem This is deliberately a thin shim. The coverage work -- staging assemblies,
rem invoking the coverage tool and normalizing its LCOV -- lives in
rem coverage_runner.ps1, because the tool's --targetargs is a single string
rem holding two absolute Windows paths, and cmd re-parses such strings and
rem mangles backslashes. PowerShell invokes with an argument array, so no
rem quoting is involved. The only paths crossing cmd are the runner script and
rem the params file; everything else is resolved inside PowerShell.

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
rem whatever the previous call set it to, so a miss would silently resolve to the
rem previously looked-up path.
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

rem Not a coverage run: behave exactly like the plain launcher. COVERAGE_DIR is
rem checked too because it is where the report has to land for Bazel's LCOV
rem merger to find it.
if not defined COVERAGE goto :run_plain
if not defined COVERAGE_DIR goto :run_plain

call :rlocation "TEMPLATED_coverage_runner" coverage_runner
call :rlocation "TEMPLATED_instrument_manifest" coverage_params

powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "!coverage_runner!" -RunfilesManifest "%MF%" -Params "!coverage_params!"
exit /b !errorlevel!

:run_plain
set args=%*
rem Escape \ and * in args before passsing it with double quote
if defined args (
  set args=!args:\=\\\\!
  set args=!args:"=\"!
)
"!dotnet_executable!" exec "!test_dll!" !args!
