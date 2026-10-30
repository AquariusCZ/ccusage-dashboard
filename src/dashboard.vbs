' AI Usage - silent launcher
Dim shell, fso, scriptDir, generator, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
If fso.FileExists(scriptDir & "\.install-pending") Then
  MsgBox "AI Usage installation is incomplete. Run install.ps1 again.", 48, "AI Usage"
  WScript.Quit 1
End If
' The root-level copies are the installed mirror, so a source checkout keeps the
' canonical runtime in src\ and can be newer than the mirror. Preferring the
' checkout removes the trap where an updated src\ silently runs an older mirror.
generator = scriptDir & "\Generate-ClaudeReport.ps1"
If fso.FileExists(scriptDir & "\src\Generate-ClaudeReport.ps1") Then
  generator = scriptDir & "\src\Generate-ClaudeReport.ps1"
End If
command = "powershell -NoProfile -ExecutionPolicy RemoteSigned -File """ & generator & """"
shell.Run command, 0, False
