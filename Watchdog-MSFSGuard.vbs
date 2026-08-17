' Hidden backup check. Starts Guard only if Flight Simulator is already running.
Option Explicit
Dim fso, sh, svc, dir, logs, exe, q, p, n, msfs, guard, listen
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
Set svc = GetObject("winmgmts:\\.\root\cimv2")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
logs = dir & "\Logs"
exe = dir & "\MSFSGuard.exe"
If fso.FileExists(logs & "\user-stopped.flag") Then WScript.Quit 0

msfs = 0
Set q = svc.ExecQuery("Select ProcessId from Win32_Process Where Name='FlightSimulator2024.exe' OR Name='FlightSimulator.exe'")
For Each p In q
  msfs = msfs + 1
Next

guard = 0
Set q = svc.ExecQuery("Select ProcessId from Win32_Process Where Name='MSFSGuard.exe'")
For Each p In q
  guard = guard + 1
Next

If msfs > 0 And guard = 0 And fso.FileExists(exe) Then
  sh.CurrentDirectory = dir
  sh.Run """" & exe & """ --silent", 0, False
  WScript.Quit 0
End If

' Keep the listener alive if auto-start is installed.
listen = 0
Set q = svc.ExecQuery("Select CommandLine from Win32_Process Where Name='wscript.exe' OR Name='cscript.exe'")
For Each p In q
  If Not IsNull(p.CommandLine) Then
    If InStr(LCase(p.CommandLine), "listen-msfsguard.vbs") > 0 Then listen = listen + 1
  End If
Next
If listen = 0 And fso.FileExists(dir & "\Listen-MSFSGuard.vbs") Then
  sh.Run "wscript.exe //B //Nologo """ & dir & "\Listen-MSFSGuard.vbs""", 0, False
End If
