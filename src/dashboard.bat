@echo off
chcp 65001 >nul
title AI Usage
echo 正在生成 Claude 和 Codex 用量快照，请稍候...
powershell -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0Generate-ClaudeReport.ps1" -KeepFile
exit
