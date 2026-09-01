using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

internal static class Program
{
    private const uint RecvQuit = 3;
    private const uint RecvEvent = 4;
    private const uint RecvEventFrame = 7;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateEvent(IntPtr attr, bool manual, bool initial, string name);

    [DllImport("kernel32.dll")]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("SimConnect.dll", CallingConvention = CallingConvention.StdCall, CharSet = CharSet.Ansi)]
    private static extern int SimConnect_Open(out IntPtr phSimConnect, string name, IntPtr hwnd, uint userEvent, IntPtr hEvent, uint configIndex);

    [DllImport("SimConnect.dll", CallingConvention = CallingConvention.StdCall)]
    private static extern int SimConnect_Close(IntPtr hSimConnect);

    [DllImport("SimConnect.dll", CallingConvention = CallingConvention.StdCall, CharSet = CharSet.Ansi)]
    private static extern int SimConnect_SubscribeToSystemEvent(IntPtr hSimConnect, uint eventId, string name);

    [DllImport("SimConnect.dll", CallingConvention = CallingConvention.StdCall)]
    private static extern int SimConnect_GetNextDispatch(IntPtr hSimConnect, out IntPtr data, out uint size);

    private static int Main(string[] args)
    {
        string jsonPath = null;
        string csvPath = null;
        int parent = 0;
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--json" && i + 1 < args.Length) jsonPath = args[++i];
            else if (args[i] == "--csv" && i + 1 < args.Length) csvPath = args[++i];
            else if (args[i] == "--parent" && i + 1 < args.Length) int.TryParse(args[++i], out parent);
        }
        if (string.IsNullOrEmpty(jsonPath)) return 2;

        IntPtr hEvent = CreateEvent(IntPtr.Zero, false, false, null);
        if (hEvent == IntPtr.Zero) return 3;

        IntPtr hSim = IntPtr.Zero;
        DateTime giveUp = DateTime.UtcNow.AddMinutes(25);
        while (hSim == IntPtr.Zero)
        {
            if (ParentDead(parent) || DateTime.UtcNow > giveUp)
            {
                CloseHandle(hEvent);
                return 4;
            }
            IntPtr tmp;
            int hr = SimConnect_Open(out tmp, "MSFS Guard FPS", IntPtr.Zero, 0, hEvent, 0);
            if (hr != 0)
                hr = SimConnect_Open(out tmp, "MSFS Guard FPS", IntPtr.Zero, 0, hEvent, unchecked((uint)(-1)));
            if (hr == 0 && tmp != IntPtr.Zero)
            {
                hSim = tmp;
                break;
            }
            Thread.Sleep(1500);
        }

        SimConnect_SubscribeToSystemEvent(hSim, 1, "Frame");
        SimConnect_SubscribeToSystemEvent(hSim, 2, "Sim");
        SimConnect_SubscribeToSystemEvent(hSim, 3, "Pause");
        if (!string.IsNullOrEmpty(csvPath))
        {
            try { File.WriteAllText(csvPath, "At,Fps,SimSpeed,Sim,Paused\r\n"); }
            catch { }
        }

        double sum = 0, min = 9999, max = 0, lastFps = 0, lastSpeed = 1;
        double playSum = 0, playMin = 9999, playMax = 0;
        int n = 0, playN = 0;
        int simRunning = 0, paused = 0;
        DateTime lastWrite = DateTime.MinValue;
        DateTime lastCsv = DateTime.MinValue;
        bool quit = false;
        var inv = CultureInfo.InvariantCulture;

        while (!quit)
        {
            if (ParentDead(parent)) break;
            WaitForSingleObject(hEvent, 400);
            IntPtr pData;
            uint cb;
            while (SimConnect_GetNextDispatch(hSim, out pData, out cb) == 0 && pData != IntPtr.Zero)
            {
                if (cb < 12) continue;
                uint id = (uint)Marshal.ReadInt32(pData, 8);
                if (id == RecvQuit)
                {
                    quit = true;
                    break;
                }
                if (id == RecvEvent && cb >= 24)
                {
                    uint ev = (uint)Marshal.ReadInt32(pData, 16);
                    uint data = (uint)Marshal.ReadInt32(pData, 20);
                    if (ev == 2) simRunning = data != 0 ? 1 : 0;
                    else if (ev == 3) paused = data != 0 ? 1 : 0;
                    continue;
                }
                if (id == RecvEventFrame && cb >= 32)
                {
                    float fps = ReadFloat(pData, 24);
                    float spd = ReadFloat(pData, 28);
                    if (fps > 1f && fps < 500f)
                    {
                        lastFps = fps;
                        lastSpeed = spd;
                        sum += fps;
                        n++;
                        if (fps < min) min = fps;
                        if (fps > max) max = fps;
                        bool inFlight = simRunning == 1 && paused == 0;
                        if (inFlight)
                        {
                            playSum += fps;
                            playN++;
                            if (fps < playMin) playMin = fps;
                            if (fps > playMax) playMax = fps;
                        }
                        DateTime now = DateTime.UtcNow;
                        if (!string.IsNullOrEmpty(csvPath) && (now - lastCsv).TotalMilliseconds >= 250)
                        {
                            lastCsv = now;
                            try
                            {
                                File.AppendAllText(csvPath,
                                    DateTime.Now.ToString("HH:mm:ss.fff") + "," +
                                    fps.ToString("0.0", inv) + "," +
                                    spd.ToString("0.00", inv) + "," +
                                    simRunning.ToString(inv) + "," +
                                    paused.ToString(inv) + "\r\n");
                            }
                            catch { }
                        }
                    }
                }
            }
            if (n > 0 && (DateTime.UtcNow - lastWrite).TotalMilliseconds >= 400)
            {
                lastWrite = DateTime.UtcNow;
                WriteJson(jsonPath, lastFps, lastSpeed, n, sum / n, min, max,
                    playN, playN > 0 ? playSum / playN : 0, playN > 0 ? playMin : 0, playN > 0 ? playMax : 0,
                    simRunning, paused, inv);
            }
        }

        if (n > 0)
        {
            WriteJson(jsonPath, lastFps, lastSpeed, n, sum / n, min, max,
                playN, playN > 0 ? playSum / playN : 0, playN > 0 ? playMin : 0, playN > 0 ? playMax : 0,
                simRunning, paused, inv);
        }
        try { SimConnect_Close(hSim); } catch { }
        try { CloseHandle(hEvent); } catch { }
        return 0;
    }

    private static float ReadFloat(IntPtr p, int offset)
    {
        byte[] b = new byte[4];
        Marshal.Copy(IntPtr.Add(p, offset), b, 0, 4);
        return BitConverter.ToSingle(b, 0);
    }

    private static bool ParentDead(int pid)
    {
        if (pid <= 0) return false;
        try { return Process.GetProcessById(pid).HasExited; }
        catch { return true; }
    }

    private static void WriteJson(string path, double fps, double speed, int n, double avg, double min, double max,
        int playN, double playAvg, double playMin, double playMax, int simRunning, int paused, CultureInfo inv)
    {
        string json = "{\"source\":\"simconnect\",\"fps\":" + fps.ToString("0.0", inv) +
            ",\"simSpeed\":" + speed.ToString("0.00", inv) +
            ",\"count\":" + n +
            ",\"avg\":" + avg.ToString("0.0", inv) +
            ",\"min\":" + min.ToString("0.0", inv) +
            ",\"max\":" + max.ToString("0.0", inv) +
            ",\"gameplayCount\":" + playN +
            ",\"gameplayAvg\":" + playAvg.ToString("0.0", inv) +
            ",\"gameplayMin\":" + playMin.ToString("0.0", inv) +
            ",\"gameplayMax\":" + playMax.ToString("0.0", inv) +
            ",\"simRunning\":" + simRunning +
            ",\"paused\":" + paused +
            ",\"at\":\"" + DateTime.Now.ToString("o") + "\"}\r\n";
        try
        {
            string tmp = path + ".tmp";
            File.WriteAllText(tmp, json);
            if (File.Exists(path)) File.Delete(path);
            File.Move(tmp, path);
        }
        catch
        {
            try { File.WriteAllText(path, json); }
            catch { }
        }
    }
}
