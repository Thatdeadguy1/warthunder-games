@echo off
rem Starts the dashboard without a console window. Bypass applies to this process only.
if not exist "%~dp0Dashboard.ps1" (
  echo Dashboard.ps1 was not found next to this file.
  echo.
  echo Extract the whole zip first ^(right-click the zip, Extract All^),
  echo then double-click Launch-Dashboard.bat inside the extracted folder.
  echo.
  pause
  exit /b 1
)
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0Dashboard.ps1"
