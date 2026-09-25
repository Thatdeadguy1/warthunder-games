@echo off
rem Starts Dashboard without a console window. Bypass applies to this process only.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0Dashboard.ps1"
