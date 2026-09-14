@echo off
REM Short entry point for the mascot, so day-to-day use is one word:
REM
REM   mascot          지금 내 마스코트
REM   mascot roll     오늘의 마스코트 뽑기 (하루 한 번)
REM   mascot help     도움말
REM
REM Everything here just forwards to statusline.ps1, which does the real work.
setlocal
set "LINE=%~dp0statusline.ps1"
set "ARG=%~1"
if "%ARG%"=="" set "ARG=today"
if /i "%ARG%"=="r" set "ARG=roll"
if /i "%ARG%"=="t" set "ARG=today"
if /i "%ARG%"=="v" set "ARG=version"
if /i "%ARG%"=="roll" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%LINE%" -Roll
) else if /i "%ARG%"=="today" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%LINE%" -Today
) else if /i "%ARG%"=="version" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%LINE%" -Version
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%LINE%" -Help
)
