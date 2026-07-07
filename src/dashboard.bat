@echo off
rem Fallback launcher (shows a brief console window).
rem The primary, no-window launcher is dashboard.vbs.
title Claude Usage Dashboard
powershell -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0Generate-ClaudeReport.ps1" -KeepFile
