@echo off
rem Double-click me to install. Uses -ExecutionPolicy Bypass because a freshly
rem downloaded install.ps1 may carry the "mark of the web".
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
