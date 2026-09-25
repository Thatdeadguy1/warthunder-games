@echo off
rem Starts CyberDeck without a console window. Bypass applies to this process only.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0CyberDeck.ps1"
