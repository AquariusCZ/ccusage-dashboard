' AI Usage Ledger - silent launcher
Dim shell, fso, scriptDir, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
command = "powershell -NoProfile -ExecutionPolicy RemoteSigned -File """ & scriptDir & "\Generate-ClaudeReport.ps1"""
shell.Run command, 0, False
