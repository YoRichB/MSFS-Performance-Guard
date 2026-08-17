using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        string dir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        AppDomain.CurrentDomain.UnhandledException += delegate(object sender, UnhandledExceptionEventArgs e)
        {
            HostLog.Write(dir, "UNHANDLED " + e.ExceptionObject);
        };
        Application.ThreadException += delegate(object sender, ThreadExceptionEventArgs e)
        {
            HostLog.Write(dir, "THREAD " + e.Exception);
        };
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);

        bool created;
        using (Mutex mutex = new Mutex(true, "Local\\MSFSPerformanceGuardHost", out created))
        {
            if (!created)
            {
                try
                {
                    EventWaitHandle show = EventWaitHandle.OpenExisting("Local\\MSFSPerformanceGuard-Show");
                    show.Set();
                }
                catch { }
                HostLog.Write(dir, "Second instance - signaled existing host");
                return;
            }

            try
            {
                string logs = Path.Combine(dir, "Logs");
                Directory.CreateDirectory(logs);
                string stopFlag = Path.Combine(logs, "user-stopped.flag");
                string doneFlag = Path.Combine(logs, "session-complete.flag");
                if (File.Exists(stopFlag)) File.Delete(stopFlag);
                if (File.Exists(doneFlag)) File.Delete(doneFlag);
            }
            catch { }

            HostLog.Write(dir, "Host starting pid=" + Process.GetCurrentProcess().Id);
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new HostContext(dir));
            HostLog.Write(dir, "Host Application.Run returned");
        }
    }
}

internal static class HostLog
{
    public static void Write(string dir, string message)
    {
        try
        {
            string logDir = Path.Combine(dir, "Logs");
            Directory.CreateDirectory(logDir);
            string line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + message + Environment.NewLine;
            File.AppendAllText(Path.Combine(logDir, "host.log"), line);
        }
        catch { }
    }
}

internal sealed class HostContext : ApplicationContext
{
    private readonly string dir;
    private readonly string ps1;
    private readonly string powershell;
    private readonly NotifyIcon tray;
    private readonly Form panel;
    private Label status;
    private readonly System.Windows.Forms.Timer watch;
    private readonly System.Windows.Forms.Timer hideSplash;
    private Icon icon;
    private EventWaitHandle sessionDone;

    public HostContext(string dir)
    {
        this.dir = dir;
        ps1 = Path.Combine(dir, "MSFSGuard.ps1");
        powershell = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");

        icon = LoadIcon();
        panel = BuildPanel();
        tray = BuildTray();
        tray.Visible = false;
        EnsureEngine();

        try
        {
            sessionDone = new EventWaitHandle(false, EventResetMode.AutoReset, "Local\\MSFSPerformanceGuard-SessionDone");
            sessionDone.Reset();
        }
        catch { }

        watch = new System.Windows.Forms.Timer();
        watch.Interval = 1000;
        watch.Tick += delegate
        {
            try
            {
                File.WriteAllText(Path.Combine(dir, @"Logs\host-heartbeat.txt"), DateTime.Now.ToString("o"));
            }
            catch { }
            try
            {
                if (sessionDone != null && sessionDone.WaitOne(0))
                {
                    HostLog.Write(dir, "Session done - closing after report");
                    Shutdown(false);
                    return;
                }
            }
            catch { }
            EnsureEngine();
            RefreshStatus();
        };
        watch.Start();

        panel.Show();
        PlacePanel();
        RefreshStatus();

        hideSplash = new System.Windows.Forms.Timer();
        hideSplash.Interval = 3500;
        hideSplash.Tick += delegate
        {
            hideSplash.Stop();
            panel.WindowState = FormWindowState.Minimized;
            HostLog.Write(dir, "Startup toast hidden; taskbar icon remains");
        };
        hideSplash.Start();
        HostLog.Write(dir, "Host UI up (toast by taskbar)");
    }

    private Icon LoadIcon()
    {
        string ico = Path.Combine(dir, @"Icons\guard-idle.ico");
        if (File.Exists(ico))
        {
            return new Icon(ico);
        }
        return SystemIcons.Application;
    }

    private Form BuildPanel()
    {
        Form f = new Form();
        f.Text = "MSFS Guard";
        f.FormBorderStyle = FormBorderStyle.None;
        f.MaximizeBox = false;
        f.MinimizeBox = true;
        f.StartPosition = FormStartPosition.Manual;
        f.ClientSize = new Size(280, 72);
        f.BackColor = Color.FromArgb(28, 28, 34);
        f.ForeColor = Color.FromArgb(244, 244, 248);
        f.TopMost = true;
        f.ShowInTaskbar = true;
        f.Icon = icon;
        f.FormClosing += delegate(object sender, FormClosingEventArgs e)
        {
            if (e.CloseReason == CloseReason.UserClosing)
            {
                e.Cancel = true;
                f.WindowState = FormWindowState.Minimized;
            }
        };

        Panel stripe = new Panel();
        stripe.BackColor = Color.FromArgb(80, 168, 232);
        stripe.Dock = DockStyle.Left;
        stripe.Width = 8;
        f.Controls.Add(stripe);

        Label title = new Label();
        title.Text = "MSFS Guard is ON";
        title.Font = new Font("Segoe UI Semibold", 12f);
        title.ForeColor = Color.FromArgb(244, 244, 248);
        title.Location = new Point(18, 10);
        title.AutoSize = true;
        f.Controls.Add(title);

        status = new Label();
        status.Text = "Starting monitor...";
        status.Font = new Font("Segoe UI", 9f);
        status.ForeColor = Color.FromArgb(168, 170, 178);
        status.Location = new Point(18, 36);
        status.Size = new Size(250, 28);
        f.Controls.Add(status);

        f.Click += delegate { ShowPanel(); };
        title.Click += delegate { ShowPanel(); };
        status.Click += delegate { ShowPanel(); };
        return f;
    }

    private NotifyIcon BuildTray()
    {
        ContextMenuStrip menu = new ContextMenuStrip();
        menu.Items.Add("Show MSFS Guard window", null, delegate { ShowPanel(); });
        menu.Items.Add("Open dashboard", null, delegate { OpenDashboard(); });
        menu.Items.Add("-");
        menu.Items.Add("Exit", null, delegate { Shutdown(); });

        NotifyIcon n = new NotifyIcon();
        n.Icon = icon;
        n.Text = "MSFS Guard is running";
        n.Visible = true;
        n.ContextMenuStrip = menu;
        n.MouseUp += delegate(object sender, MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left)
            {
                ShowPanel();
            }
        };
        return n;
    }

    private void PlacePanel()
    {
        Rectangle wa = Screen.PrimaryScreen.WorkingArea;
        panel.Left = wa.Right - panel.Width - 16;
        panel.Top = wa.Bottom - panel.Height - 8;
    }

    private void ShowPanel()
    {
        panel.Show();
        panel.WindowState = FormWindowState.Normal;
        PlacePanel();
        panel.BringToFront();
        panel.Activate();
    }

    private void OpenDashboard()
    {
        try
        {
            EventWaitHandle show = EventWaitHandle.OpenExisting("Local\\MSFSPerformanceGuard-Show");
            show.Set();
        }
        catch
        {
            EnsureEngine();
        }
        ShowPanel();
    }

    private bool EngineRunning()
    {
        try
        {
            Mutex m = Mutex.OpenExisting("Local\\MSFSPerformanceGuard");
            m.Dispose();
            return true;
        }
        catch
        {
            return false;
        }
    }

    private bool MsfsRunning()
    {
        return Process.GetProcessesByName("FlightSimulator2024").Length > 0
            || Process.GetProcessesByName("FlightSimulator").Length > 0;
    }

    private void EnsureEngine()
    {
        if (EngineRunning() || !File.Exists(ps1))
        {
            return;
        }
        HostLog.Write(dir, "Starting monitor engine (detached)");
        string args = "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + ps1 + "\"";
        // cmd start detaches from any job object so the monitor is not killed
        // when a parent automation command exits.
        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName = Path.Combine(Environment.SystemDirectory, "cmd.exe");
        psi.Arguments = "/c start \"MSFSGuardEngine\" /min \"" + powershell + "\" " + args;
        psi.WorkingDirectory = dir;
        psi.UseShellExecute = true;
        psi.WindowStyle = ProcessWindowStyle.Hidden;
        Process.Start(psi);
    }

    private void RefreshStatus()
    {
        bool engine = EngineRunning();
        bool sim = MsfsRunning();
        bool admin = true;
        try
        {
            string st = Path.Combine(dir, @"Logs\runtime-status.json");
            if (File.Exists(st))
            {
                string json = File.ReadAllText(st);
                if (json.IndexOf("\"Admin\":false", StringComparison.OrdinalIgnoreCase) >= 0
                    || json.IndexOf("\"Admin\": false", StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    admin = false;
                }
            }
        }
        catch { }
        if (!engine)
        {
            status.Text = "Monitor starting...";
        }
        else if (sim)
        {
            status.Text = admin
                ? "Flight Simulator is running."
                : "Sim running. Sleep may need Install.bat (admin).";
        }
        else
        {
            status.Text = admin
                ? "Watching. Waiting for MSFS."
                : "Waiting for MSFS. Run Install.bat for admin Sleep.";
        }
        tray.Text = "MSFS Guard";
        panel.Text = "MSFS Guard";
    }

    private void Shutdown()
    {
        Shutdown(true);
    }

    private void Shutdown(bool userExit)
    {
        HostLog.Write(dir, userExit ? "User chose Exit" : "Session complete shutdown");
        if (userExit)
        {
            try
            {
                Directory.CreateDirectory(Path.Combine(dir, "Logs"));
                File.WriteAllText(Path.Combine(dir, @"Logs\user-stopped.flag"), DateTime.Now.ToString("o"));
            }
            catch { }
        }
        try
        {
            EventWaitHandle stop = EventWaitHandle.OpenExisting("Local\\MSFSPerformanceGuard-Stop");
            stop.Set();
        }
        catch { }
        try { if (hideSplash != null) hideSplash.Stop(); } catch { }
        watch.Stop();
        tray.Visible = false;
        tray.Dispose();
        ExitThread();
    }
}
