Set shell = CreateObject("WScript.Shell")
base = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
script = base & "\RcloneDriveManager.ps1"
extra = ""
For i = 0 To WScript.Arguments.Count - 1
    If LCase(WScript.Arguments(i)) = "-automount" Then extra = " -AutoMount"
Next
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & script & """" & extra, 0, False
