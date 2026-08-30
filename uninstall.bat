@echo off
setlocal DisableDelayedExpansion
set "ERRORLEVEL="
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1"
set "AI_USAGE_EXIT_CODE=%errorlevel%"
if not "%AI_USAGE_EXIT_CODE%"=="0" pause
exit /b %AI_USAGE_EXIT_CODE%
