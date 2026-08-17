' Hidden keepalive. Task Scheduler must run this via wscript, not a .bat.
Option Explicit
Dim fso, sh, dir, logs, svc, q, n
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
logs = dir & "\Logs"
If fso.FileExists(logs & "\user-stopped.flag") Then WScript.Quit 0

Set svc = GetObject("winmgmts:\\.\root\cimv2")
If fso.FileExists(logs & "\session-complete.flag") Then
  Set q = svc.ExecQuery("Select ProcessId from Win32_Process Where Name='FlightSimulator2024.exe' OR Name='FlightSimulator.exe'")
  n = 0
  Dim p
  For Each p In q
    n = n + 1
  Next
  If n = 0 Then WScript.Quit 0
End If

Set q = svc.ExecQuery("Select ProcessId from Win32_Process Where Name='MSFSGuard.exe'")
n = 0
For Each p In q
  n = n + 1
Next
If n > 0 Then WScript.Quit 0

sh.CurrentDirectory = dir
sh.Run """" & dir & "\MSFSGuard.exe"" --silent", 0, False
