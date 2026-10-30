@echo off
chcp 65001 >nul
title AI Usage
if exist "%~dp0.install-pending" (
  echo AI Usage installation is incomplete. Run install.ps1 again.
  pause
  exit /b 1
)
rem Root-level copies are the installed mirror; a checkout keeps the canonical
rem runtime in src\ and can be newer, so the checkout wins when it exists.
set "AI_USAGE_GENERATOR=%~dp0Generate-ClaudeReport.ps1"
if exist "%~dp0src\Generate-ClaudeReport.ps1" set "AI_USAGE_GENERATOR=%~dp0src\Generate-ClaudeReport.ps1"
echo 正在生成 Claude、Codex 与 DeepSeek 用量快照，请稍候...
powershell -NoProfile -ExecutionPolicy RemoteSigned -File "%AI_USAGE_GENERATOR%" -KeepFile
exit
