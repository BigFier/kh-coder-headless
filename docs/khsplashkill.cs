
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

class KhSplashKill
{
    [DllImport("user32.dll")]
    static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
    delegate bool EnumWindowsProc(IntPtr h, IntPtr l);

    [DllImport("user32.dll")]
    static extern bool IsWindowVisible(IntPtr h);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);

    [DllImport("user32.dll")]
    static extern bool GetWindowRect(IntPtr h, out RECT r);

    [DllImport("user32.dll")]
    static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);

    [DllImport("user32.dll")]
    static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);

    [DllImport("user32.dll")]
    static extern bool ShowWindow(IntPtr h, int cmd);

    [DllImport("user32.dll")]
    static extern bool DestroyWindow(IntPtr h);

    [StructLayout(LayoutKind.Sequential)]
    struct RECT { public int L, T, R, B; }

    const uint WM_CLOSE = 0x0010;
    const int SW_HIDE = 0;

    // Only windows owned by this executable are touched. Cached per pid.
    static System.Collections.Generic.Dictionary<uint, bool> ownerCache =
        new System.Collections.Generic.Dictionary<uint, bool>();

    static bool BelongsToKhCoder(uint pid)
    {
        bool ok;
        if (ownerCache.TryGetValue(pid, out ok)) return ok;
        ok = false;
        try
        {
            var p = Process.GetProcessById((int)pid);
            string name = p.ProcessName;
            ok = string.Equals(name, "kh_coder", StringComparison.OrdinalIgnoreCase);
        }
        catch { ok = false; }
        ownerCache[pid] = ok;
        return ok;
    }

    static int KillOnce(bool verbose)
    {
        int n = 0;
        EnumWindows(delegate(IntPtr h, IntPtr l)
        {
            try
            {
                if (!IsWindowVisible(h)) return true;

                var sb = new StringBuilder(512);
                int tl = GetWindowTextW(h, sb, 512);
                if (tl > 0) return true;              // the splash has no caption

                RECT r;
                if (!GetWindowRect(h, out r)) return true;
                int w = r.R - r.L;
                int ht = r.B - r.T;
                if (Math.Abs(w - 400) > 6 || Math.Abs(ht - 122) > 6) return true;

                uint pid;
                GetWindowThreadProcessId(h, out pid);
                if (!BelongsToKhCoder(pid)) return true;   // never touch other apps

                ShowWindow(h, SW_HIDE);
                bool destroyed = DestroyWindow(h);
                PostMessageW(h, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
                n++;
                if (verbose)
                    Console.WriteLine("hit " + w + "x" + ht + " at " + r.L + "," + r.T
                                      + " pid=" + pid + " destroyed=" + destroyed);
            }
            catch { }
            return true;
        }, IntPtr.Zero);
        return n;
    }

    static int Main(string[] a)
    {
        int seconds = 0;
        if (a.Length >= 2 && a[0] == "--loop")
        {
            int.TryParse(a[1], out seconds);
        }

        if (seconds <= 0)
        {
            int n = KillOnce(true);
            return n > 0 ? 0 : 1;
        }

        var end = DateTime.Now.AddSeconds(seconds);
        int total = 0;
        while (DateTime.Now < end)
        {
            total += KillOnce(true);
            Thread.Sleep(80);
        }
        return total > 0 ? 0 : 1;
    }
}
