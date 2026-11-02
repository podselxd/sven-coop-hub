param([int]$Seconds = 25, [string]$Out)
# watch-windows.ps1 - prueba: detecta cualquier ventana de consola (PowerShell / terminal) que aparezca durante $Seconds segundos.
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class WW {
    public delegate bool EP(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EP cb, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
    public static List<string> Scan() {
        List<string> r = new List<string>();
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            if (!IsWindowVisible(h)) return true;
            StringBuilder c = new StringBuilder(256), t = new StringBuilder(256);
            GetClassName(h, c, 256); GetWindowText(h, t, 256);
            string cls = c.ToString(), title = t.ToString();
            int pid; GetWindowThreadProcessId(h, out pid);
            if (cls == "ConsoleWindowClass" || cls == "CASCADIA_HOSTING_WINDOW_CLASS" || title.IndexOf("powershell", StringComparison.OrdinalIgnoreCase) >= 0)
                r.Add(pid + "|" + cls + "|" + title);
            return true;
        }, IntPtr.Zero);
        return r;
    }
}
'@
$seen = @{}
$end = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $end) {
    foreach ($w in [WW]::Scan()) {
        $pid2 = [int]($w.Split('|')[0])
        # se ignoran las consolas de este mismo script y de la herramienta que lo lanza
        if ($pid2 -eq $PID) { continue }
        if (-not $seen.ContainsKey($w)) { $seen[$w] = (Get-Date).ToString('HH:mm:ss.fff') }
    }
    Start-Sleep -Milliseconds 25
}
$lines = @($seen.GetEnumerator() | ForEach-Object { "$($_.Value)  $($_.Key)" })
if ($Out) { Set-Content $Out $lines -Encoding UTF8 } else { $lines }
