' Hidden backup check. Restarts the elevated listener task if it died.
' Never launches MSFSGuard.exe or Listen-MSFSGuard.vbs directly: that would
' drop admin rights and create a second listener.
Option Explicit
Dim fso, sh, svc, dir, logs, q, p, n, msfs, guard, listen, pidFile, pidTxt

Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
Set svc = GetObject("winmgmts:\\.\root\cimv2")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
logs = dir & "\Logs"
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

listen = 0
pidFile = logs & "\listener.pid"
If fso.FileExists(pidFile) Then
  On Error Resume Next
  pidTxt = Trim(fso.OpenTextFile(pidFile, 1).ReadAll)
  On Error GoTo 0
  If IsNumeric(pidTxt) Then
    Set q = svc.ExecQuery("Select ProcessId from Win32_Process Where ProcessId=" & CLng(pidTxt))
    For Each p In q
      listen = listen + 1
    Next
  End If
End If

If listen = 0 Then
  Set q = svc.ExecQuery("Select ProcessId, CommandLine from Win32_Process Where Name='wscript.exe' OR Name='cscript.exe'")
  For Each p In q
    If Not IsNull(p.CommandLine) Then
      If InStr(LCase(p.CommandLine), "listen-msfsguard.vbs") > 0 Then listen = listen + 1
    End If
  Next
End If

If (listen = 0) Or (msfs > 0 And guard = 0 And listen = 0) Then
  sh.Run "schtasks.exe /Run /TN ""MSFS-Guard-Listener""", 0, False
End If
