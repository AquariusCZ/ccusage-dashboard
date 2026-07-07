' Claude Usage Dashboard - silent launcher (no console window)
' Runs the report generator (located in this script's own folder) hidden.
' Only the browser appears; no black console flashes.
Dim fso, here, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
cmd = "powershell -NoProfile -ExecutionPolicy RemoteSigned -File """ & here & "\Generate-ClaudeReport.ps1"""
CreateObject("WScript.Shell").Run cmd, 0, False
