@echo off
REM claude-statusline — cmd.exe entry point.
REM Batch cannot parse JSON, so this forwards stdin to the PowerShell script.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0statusline.ps1"
