@echo off
rem Starts WinOptimizer. It will ask for administrator rights (UAC prompt).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0WinOptimizer.ps1"
if errorlevel 1 pause
