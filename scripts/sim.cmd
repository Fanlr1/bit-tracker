@echo off
REM Questa simulation launcher (double-clickable / command-line friendly).
REM
REM WHY A .cmd: the system PowerShell execution policy forbids running .ps1
REM files, so this wrapper calls PowerShell with -ExecutionPolicy Bypass for
REM THIS PROCESS ONLY (no system setting is changed).
REM
REM USAGE:  quote each list, separate entries with spaces
REM   sim.cmd TOP "file1 file2 ..." "prim1 prim2 ..."
REM
REM   sim.cmd tb_counter "counter.v tb_counter.v"
REM   sim.cmd tb_alpha_blend "alpha_blend.v tb_alpha_blend.v" "C:\Efinity\2026.1\sim_models\verilog\efx_dsp48.v"
REM
REM Each list is passed as ONE quoted string and split inside sim.ps1, because
REM PowerShell does NOT collect multiple bare arguments into an array parameter
REM under -File -- it binds only the first and turns the rest into positional
REM arguments. That bug once pushed a source file into -Work and broke the run.
REM
REM WHY NOT A COMMA-SEPARATED LIST: cmd.exe treats ',' ';' and '=' as ARGUMENT
REM SEPARATORS, so "a.v,b.v" would already be split before we ever see it.
REM Spaces inside quotes avoid the whole problem.
REM
REM NOTE: keep this file pure ASCII. cmd.exe decodes it as ANSI, so any
REM non-ASCII character in a comment corrupts the surrounding lines.

setlocal
set SCRIPT=%~dp0sim.ps1

if "%~1"=="" (
  echo usage: sim.cmd TOP "file1 file2 ..." "prim1 prim2 ..."
  echo example: sim.cmd tb_counter "counter.v tb_counter.v"
  exit /b 2
)

REM Prefer PowerShell 7 when present; Windows PowerShell always works as fallback.
set PSEXE=powershell
where pwsh >nul 2>&1 && set PSEXE=pwsh

if "%~3"=="" (
  %PSEXE% -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Top "%~1" -Files "%~2"
) else (
  %PSEXE% -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Top "%~1" -Files "%~2" -PrimLibs "%~3"
)
exit /b %ERRORLEVEL%
