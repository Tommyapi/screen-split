# Screen-Split daemon: route NEW top-level windows to the right screen, once, at creation.
#   * League of Legends family (WeGame launcher, TCLS/Launcher, Riot Client, LeagueClient*, anything whose
#     executable lives under one of -GameRoots) -> the big screen (default 2560x1440).
#   * Every other program -> the small screen (default 1920x1080).
#   * A window is only ever touched within the first few seconds after it appears. After that it is the
#     user's: whatever they drag anywhere stays there.
#   * The in-game match window ("League of Legends.exe") is never touched (it cannot be moved safely).
# Designed to run hidden in the user's session (e.g. a scheduled task at logon). Idle cost: one
# EnumWindows pass every 300 ms. Windows PowerShell 5.1+.
param(
    [switch]$DryRun,
    [string]$LogFile = (Join-Path $env:LOCALAPPDATA 'screen-split\screen-split.log'),
    [string[]]$GameRoots = @('C:\Program Files (x86)\WeGame\', 'C:\Riot Games\'),
    [int]$BigWidth = 2560, [int]$BigHeight = 1440,
    [int]$SmallWidth = 1920, [int]$SmallHeight = 1080
)

$ErrorActionPreference = 'SilentlyContinue'
$logFile = $LogFile
try { New-Item -ItemType Directory -Force -Path (Split-Path $logFile) | Out-Null } catch {}
$bigW = $BigWidth; $bigH = $BigHeight
$smallW = $SmallWidth; $smallH = $SmallHeight
$decideWithinSec = 4        # a window older than this is never touched
$lolRoots = $GameRoots
$lolNames = @('wegame', 'client', 'launcher', 'tcls_core', 'RiotClientServices', 'RiotClientUx', 'LeagueClient', 'LeagueClientUx', 'TASLogin', 'browser', 'minibrowser', 'Assistant')
$neverTouch = @('League of Legends')      # process names never moved
$skipClasses = @('Progman', 'WorkerW', 'Shell_TrayWnd', 'Shell_SecondaryTrayWnd', 'Windows.UI.Core.CoreWindow', 'tooltips_class32', 'Xaml_WindowedPopupClass', 'ForegroundStaging', 'Windows.Internal.Shell.TabProxyWindow', 'TaskListThumbnailWnd', 'DV2ControlHost', 'MultitaskingViewFrame', 'Shell_InputSwitchTopLevelWindow', 'NotifyIconOverflowWindow', 'PopupHost')

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$src = @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class SplitWin {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int hh, uint f);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int v, int size);
    public static List<IntPtr> TopLevel() {
        var list = new List<IntPtr>();
        EnumWindows((h, l) => {
            if (!IsWindowVisible(h)) return true;
            if (GetWindow(h, 4) != IntPtr.Zero) return true;            // GW_OWNER: skip owned dialogs
            if (GetWindowTextLength(h) == 0) return true;
            int ex = GetWindowLong(h, -20);
            if ((ex & 0x80) != 0) return true;                          // WS_EX_TOOLWINDOW
            int cloaked = 0; DwmGetWindowAttribute(h, 14, out cloaked, 4);
            if (cloaked != 0) return true;
            list.Add(h); return true;
        }, IntPtr.Zero);
        return list;
    }
    // Live monitor enumeration. System.Windows.Forms.Screen.AllScreens is cached per process and a windowless
    // daemon never receives WM_DISPLAYCHANGE, so it went stale after the primary display was switched (2026-09-03 bug).
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct MONITORINFOEX { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice; }
    public delegate bool MonProc(IntPtr hMon, IntPtr hdc, ref RECT r, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr hMon, ref MONITORINFOEX mi);
    public class Mon { public string Device; public RECT Bounds; public RECT Work; public bool Primary; }
    public static List<Mon> Monitors() {
        var list = new List<Mon>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr hm, IntPtr hdc, ref RECT r, IntPtr l) => {
            var mi = new MONITORINFOEX(); mi.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
            if (GetMonitorInfo(hm, ref mi)) list.Add(new Mon { Device = mi.szDevice, Bounds = mi.rcMonitor, Work = mi.rcWork, Primary = (mi.dwFlags & 1) != 0 });
            return true; }, IntPtr.Zero);
        return list;
    }
    public static string Cls(IntPtr h) { var sb = new StringBuilder(256); GetClassName(h, sb, 256); return sb.ToString(); }
    public static string Title(IntPtr h) { var sb = new StringBuilder(512); GetWindowText(h, sb, 512); return sb.ToString(); }
    public static uint Pid(IntPtr h) { uint p; GetWindowThreadProcessId(h, out p); return p; }
}
'@
try { Add-Type -TypeDefinition $src } catch {}
try { [SplitWin]::SetProcessDPIAware() | Out-Null } catch {}

function Log($msg) {
    try {
        if ((Test-Path $logFile) -and ((Get-Item $logFile).Length -gt 300KB)) { Clear-Content $logFile }
        Add-Content -Path $logFile -Value ("{0} {1}" -f (Get-Date -Format 'MM-dd HH:mm:ss.fff'), $msg)
    } catch {}
}
function Get-Screens {
    # live enumeration every pass (see SplitWin.Monitors comment); objects mimic System.Windows.Forms.Screen
    $all = [SplitWin]::Monitors() | ForEach-Object {
        [pscustomobject]@{
            DeviceName  = $_.Device
            Primary     = $_.Primary
            Bounds      = New-Object System.Drawing.Rectangle($_.Bounds.L, $_.Bounds.T, ($_.Bounds.R - $_.Bounds.L), ($_.Bounds.B - $_.Bounds.T))
            WorkingArea = New-Object System.Drawing.Rectangle($_.Work.L, $_.Work.T, ($_.Work.R - $_.Work.L), ($_.Work.B - $_.Work.T))
        }
    }
    $big = $all | Where-Object { $_.Bounds.Width -eq $bigW -and $_.Bounds.Height -eq $bigH } | Select-Object -First 1
    $small = $all | Where-Object { $_.Bounds.Width -eq $smallW -and $_.Bounds.Height -eq $smallH } | Select-Object -First 1
    if ($big -and $small) { return @{ Big = $big; Small = $small } } else { return $null }
}
function Test-OnScreen($r, $scr) {
    $cx = [int](($r.L + $r.R) / 2); $cy = [int](($r.T + $r.B) / 2)
    return $scr.Bounds.Contains($cx, $cy)
}
$procCache = @{}   # pid -> @{Name; Path; Lol}
function Get-ProcInfo([uint32]$procId) {
    if ($procCache.ContainsKey($procId)) { return $procCache[$procId] }
    $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
    $path = ''; $name = ''
    if ($p) { $name = $p.ProcessName; try { $path = $p.Path } catch {} }
    if (-not $path) { $path = (Get-CimInstance Win32_Process -Filter "ProcessId=$procId" | Select-Object -First 1).ExecutablePath }
    $lol = $false
    foreach ($root in $lolRoots) { if ($path -and $path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { $lol = $true } }
    if (-not $lol -and ($lolNames -contains $name) -and ($path -match 'WeGame|英雄联盟|Riot|League')) { $lol = $true }
    $info = @{ Name = $name; Path = $path; Lol = $lol }
    $procCache[$procId] = $info
    if ($procCache.Count -gt 2000) { $procCache = @{} }
    return $info
}
function Move-Window($h, $scr, $r, $label) {
    $w = $r.R - $r.L; $hgt = $r.B - $r.T
    $zoomed = [SplitWin]::IsZoomed($h)
    $x = $scr.WorkingArea.X + [Math]::Max(0, [int](($scr.WorkingArea.Width - $w) / 2))
    $y = $scr.WorkingArea.Y + [Math]::Max(0, [int](($scr.WorkingArea.Height - $hgt) / 2))
    if ($DryRun) { Log ("DRYRUN would move $label -> $($scr.DeviceName) $x,$y zoomed=$zoomed"); return $true }
    if ($zoomed) { [SplitWin]::ShowWindow($h, 9) | Out-Null; Start-Sleep -Milliseconds 60 }   # SW_RESTORE
    $flags = 0x4 -bor 0x10                                                                   # NOZORDER|NOACTIVATE
    if ($w -le $scr.WorkingArea.Width -and $hgt -le $scr.WorkingArea.Height) { $flags = $flags -bor 0x1 }   # NOSIZE when it fits
    $ok = [SplitWin]::SetWindowPos($h, [IntPtr]0, $x, $y, [Math]::Min($w, $scr.WorkingArea.Width), [Math]::Min($hgt, $scr.WorkingArea.Height), $flags)
    if ($zoomed) { Start-Sleep -Milliseconds 60; [SplitWin]::ShowWindow($h, 3) | Out-Null }   # SW_MAXIMIZE on the new screen
    Log ("MOVED ok=$ok $label -> $($scr.DeviceName) $x,$y zoomed=$zoomed")
    return $ok
}

$seen = @{}       # hwnd -> @{ First = datetime; Done = bool }
$first = $true
Log ("start DryRun=$($DryRun.IsPresent)")
while ($true) {
    try {
        $scr = Get-Screens
        $now = Get-Date
        $wins = [SplitWin]::TopLevel()
        $live = @{}
        foreach ($h in $wins) {
            $live[$h] = $true
            if (-not $seen.ContainsKey($h)) { $seen[$h] = @{ First = $now; Done = $first }; if ($first) { continue } }
            $e = $seen[$h]
            if ($e.Done) { continue }
            if (($now - $e.First).TotalSeconds -gt $decideWithinSec) { $e.Done = $true; continue }
            if (-not $scr) { continue }
            $cls = [SplitWin]::Cls($h)
            if ($skipClasses -contains $cls) { $e.Done = $true; continue }
            if ([SplitWin]::IsIconic($h)) { continue }
            $r = New-Object SplitWin+RECT; [SplitWin]::GetWindowRect($h, [ref]$r) | Out-Null
            if (($r.R - $r.L) -lt 150 -or ($r.B - $r.T) -lt 100) { continue }       # not sized yet, look again next pass
            $pi = Get-ProcInfo ([SplitWin]::Pid($h))
            if ($neverTouch -contains $pi.Name) { $e.Done = $true; continue }
            $target = if ($pi.Lol) { $scr.Big } else { $scr.Small }
            $label = "[$($pi.Name)] '$([SplitWin]::Title($h))' cls=$cls rect=($($r.L),$($r.T))-($($r.R),$($r.B))"
            if (Test-OnScreen $r $target) { $e.Done = $true; continue }
            Move-Window $h $target $r $label | Out-Null
            $e.Done = $true
        }
        # forget windows that no longer exist
        if ($seen.Count -gt 0) { foreach ($k in @($seen.Keys)) { if (-not $live.ContainsKey($k)) { $seen.Remove($k) } } }
        $first = $false
    } catch { Log ("ERR " + $_.Exception.Message) }
    Start-Sleep -Milliseconds 300
}
