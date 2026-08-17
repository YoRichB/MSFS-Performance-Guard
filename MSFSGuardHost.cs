using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        string dir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string ps1 = Path.Combine(dir, "MSFSGuard.ps1");
        string ps = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
        if (!File.Exists(ps1))
        {
            return;
        }
        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName = ps;
        psi.Arguments = "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + ps1 + "\"";
        psi.WorkingDirectory = dir;
        psi.WindowStyle = ProcessWindowStyle.Hidden;
        psi.CreateNoWindow = true;
        psi.UseShellExecute = false;
        Process.Start(psi);
    }
}
