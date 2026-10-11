' Open Dictar PC 3C in the background with a normal Tkinter window.
' Wispr Flow remains a separate, unmodified Windows application.
Option Explicit
Dim shell, fso, folder, filename, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
folder = fso.GetParentFolderName(WScript.ScriptFullName)
filename = folder & "\DictarPC3C-Wispr.py"
If Not fso.FileExists(filename) Then
  MsgBox "Falta DictarPC3C-Wispr.py en la carpeta scripts.", vbExclamation
  WScript.Quit 1
End If
command = "cmd.exe /c pyw -3 """ & filename & """"
shell.Run command, 0, False
