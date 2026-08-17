' Hidden listener. Started at sign-in when the user chose "start with MSFS".
' No console window. Starts MSFSGuard.exe --silent only when the sim is running.
Option Explicit
Dim fso, sh, svc, dir, exe, logs, q, p, n, mine

Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
Set svc = GetObject("winmgmts:\\.\root\cimv2")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
exe = dir & "\MSFSGuard.exe"
logs = dir & "\Logs"
If Not fso.FolderExists(logs) Then fso.CreateFolder logs

' Only one listener.
mine = 0
Set q = svc.ExecQuery("Select CommandLine from Win32_Process Where Name='wscript.exe' OR Name='cscript.exe'")
For Each p In q
  If Not IsNull(p.CommandLine) Then
    If InStr(LCase(p.CommandLine), "listen-msfsguard.vbs") > 0 Then mine = mine + 1
  End If
Next
If mine > 1 Then WScript.Quit 0

Do
  On Error Resume Next
  If fso.FileExists(logs & "\user-stopped.flag") Then
    WScript.Sleep 15000
  ElseIf Not fso.FileExists(exe) Then
    WScript.Sleep 15000
  ElseIf GuardRunning() Then
    WScript.Sleep 10000
  ElseIf MsfsRunning() Then
    sh.CurrentDirectory = dir
    sh.Run """" & exe & """ --silent", 0, False
    WScript.Sleep 15000
  Else
    WScript.Sleep 8000
  End If
  On Error GoTo 0
Loop

Function MsfsRunning()
  Dim r, c, x
  c = 0
  Set r = svc.ExecQuery("Select ProcessId from Win32_Process Where Name='FlightSimulator2024.exe' OR Name='FlightSimulator.exe'")
  For Each x In r
    c = c + 1
  Next
  MsfsRunning = (c > 0)
End Function

Function GuardRunning()
  Dim r, c, x
  c = 0
  Set r = svc.ExecQuery("Select ProcessId from Win32_Process Where Name='MSFSGuard.exe'")
  For Each x In r
    c = c + 1
  Next
  GuardRunning = (c > 0)
End Function
