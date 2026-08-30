@echo off
setlocal DisableDelayedExpansion
set "ERRORLEVEL="
rem Double-click me to install. Uses -ExecutionPolicy Bypass because a freshly
rem downloaded install.ps1 may carry the "mark of the web".
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
set "AI_USAGE_EXIT_CODE=%errorlevel%"
if not "%AI_USAGE_EXIT_CODE%"=="0" pause
exit /b %AI_USAGE_EXIT_CODE%
