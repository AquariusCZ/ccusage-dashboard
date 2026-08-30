' AI Usage - silent launcher
Dim shell, fso, scriptDir, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
If fso.FileExists(scriptDir & "\.install-pending") Then
  MsgBox "AI Usage installation is incomplete. Run install.ps1 again.", 48, "AI Usage"
  WScript.Quit 1
End If
command = "powershell -NoProfile -ExecutionPolicy RemoteSigned -File """ & scriptDir & "\Generate-ClaudeReport.ps1"""
shell.Run command, 0, False
