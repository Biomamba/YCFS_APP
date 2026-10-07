@echo off
REM ===========================================================================
REM  Windows launcher for the Biomamba analysis app
REM ===========================================================================
REM  Double-click this file. It starts a local server and opens the browser.
REM
REM  ---- V13.2 item 1: where R comes from ------------------------------------
REM
REM  OLD BEHAVIOUR (the complaint): this file did `where Rscript` and used
REM  whatever R happened to be in PATH. If the user had no R -- or had it at
REM  a path that was not in PATH -- the app simply did not start, and the fix
REM  was "edit this file and hard-code C:\Program Files\R\R-4.4.2\...".
REM  That is not something you can ask a user to do.
REM
REM  NEW BEHAVIOUR: if .\runtime\R\bin\Rscript.exe exists (it ships with the
REM  distribution, see desktop/build_windows_bundle.sh), that is used and the
REM  machine needs NO R installed at all. Only when it is missing do we fall
REM  back to a system Rscript, and only when THAT is missing do we stop.
REM
REM  NOTE: this file is deliberately ASCII-only. cmd.exe reads .bat files using
REM  the OEM code page, so Chinese text here turns into mojibake on most
REM  machines (and chcp 65001 inside the file does not fix already-parsed
REM  lines). All user-facing Chinese comes from run_local.R instead.
REM ===========================================================================
setlocal
cd /d "%~dp0"

set "LOCAL_R=%~dp0runtime\R\bin\Rscript.exe"
set "LOCAL_R_EXE=%~dp0runtime\R\bin\x64\R.exe"
if not exist "%LOCAL_R_EXE%" set "LOCAL_R_EXE=%~dp0runtime\R\bin\R.exe"

if exist "%LOCAL_R%" (
  set "DSAPP_BUNDLED_R=1"
  "%LOCAL_R%" run_local.R %*
  goto :done
)

REM ---- no bundled runtime: fall back to a system R -------------------------
where Rscript >nul 2>nul
if errorlevel 1 (
  echo.
  echo   [ERROR] No R runtime found.
  echo.
  echo   This copy is missing its bundled runtime folder:
  echo       %~dp0runtime\R\bin\Rscript.exe
  echo.
  echo   Unzip the distribution again and keep the folder structure intact.
  echo   If you only copied run_app.bat somewhere, that will not work --
  echo   the whole folder is needed.
  echo.
  echo   Alternatively install R from https://cran.r-project.org/bin/windows/base/
  echo   and keep the default option that adds R to PATH.
  echo.
  pause
  exit /b 1
)

Rscript run_local.R %*
goto :done

:done
if errorlevel 1 (
  echo.
  echo   [ERROR] The app exited with an error. See the message above.
  echo.
  pause
  exit /b 1
)

endlocal
