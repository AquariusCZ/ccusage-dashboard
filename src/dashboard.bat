@echo off
chcp 65001 >nul
title AI Usage
if exist "%~dp0.install-pending" (
  echo AI Usage installation is incomplete. Run install.ps1 again.
  pause
  exit /b 1
)
echo 正在生成 Claude 和 Codex 用量快照，请稍候...
powershell -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0Generate-ClaudeReport.ps1" -KeepFile
exit
