Option Explicit
Dim shell, fso, pwsh, app, command, root
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

' Kurulum kokunu kendi konumundan turet: bu dosya her zaman kok klasordedir,
' boylece uygulama hangi klasore kurulduysa oradan calisir.
root = fso.GetParentFolderName(WScript.ScriptFullName)

' Kuruluma gomulu PowerShell 7; yoksa PATH uzerindeki pwsh denenir.
pwsh = root & "\runtime\pwsh\pwsh.exe"
If Not fso.FileExists(pwsh) Then
  pwsh = "pwsh.exe"
End If

app = root & "\qwen-desktop.ps1"
command = """" & pwsh & """ -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & app & """"
shell.Run command, 0, False
