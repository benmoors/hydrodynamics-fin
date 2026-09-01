# UI helper for driving SWD. Two traps had to be cleared before a single click landed.
#
# TRAP 1 - DPI. This display runs ~173% scaling. UI Automation reports PHYSICAL
# pixels (primary is 3200x2000) while a DPI-unaware process sees 1845x1111.
# SetProcessDPIAware() first, then UIA rects and cursor coordinates share one space.
#
# TRAP 2 - MULTI-MONITOR. SendInput with MOUSEEVENTF_ABSOLUTE normalises against the
# PRIMARY monitor unless MOUSEEVENTF_VIRTUALDESK is also set. This desktop spans two
# screens (virtual origin -3360,0, size 6560x2112), so every click was being mapped
# onto the wrong monitor and silently doing nothing. Measured: targeting (48,68) put
# the cursor at (-1227,1235). Normalise against the VIRTUAL desktop, not the primary.
Add-Type -AssemblyName System.Drawing, System.Windows.Forms, UIAutomationClient, UIAutomationTypes
Add-Type @"
using System;using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx,dy; public uint mouseData,dwFlags,time; public IntPtr ex; }
[StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk,wScan; public uint dwFlags,time; public IntPtr ex; }
[StructLayout(LayoutKind.Explicit)]   public struct IU { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
[StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public IU u; }
public class U {
  [DllImport("user32.dll",SetLastError=true)] public static extern uint SendInput(uint n, INPUT[] i, int cb);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out P p);
  public struct P { public int X,Y; }
  const uint MOVE=0x0001, LD=0x0002, LU=0x0004, ABS=0x8000, VDESK=0x4000;
  static void Norm(int x,int y,out int nx,out int ny){
    int vx=GetSystemMetrics(76), vy=GetSystemMetrics(77);
    int vw=GetSystemMetrics(78), vh=GetSystemMetrics(79);
    nx=(int)Math.Round(((double)(x-vx)*65535.0)/(vw-1));
    ny=(int)Math.Round(((double)(y-vy)*65535.0)/(vh-1));
  }
  public static string ClickAbs(int x,int y){
    int nx,ny; Norm(x,y,out nx,out ny);
    var a=new INPUT[3];
    a[0].type=0; a[0].u.mi=new MOUSEINPUT{dx=nx,dy=ny,dwFlags=MOVE|ABS|VDESK};
    a[1].type=0; a[1].u.mi=new MOUSEINPUT{dx=nx,dy=ny,dwFlags=LD|ABS|VDESK};
    a[2].type=0; a[2].u.mi=new MOUSEINPUT{dx=nx,dy=ny,dwFlags=LU|ABS|VDESK};
    uint sent=SendInput(3,a,Marshal.SizeOf(typeof(INPUT)));
    P p; GetCursorPos(out p);
    bool ok = Math.Abs(p.X-x)<=2 && Math.Abs(p.Y-y)<=2;
    return (ok?"OK":"MISS")+" target=("+x+","+y+") cursor=("+p.X+","+p.Y+") sent="+sent;
  }
  public static string MoveOnly(int x,int y){
    int nx,ny; Norm(x,y,out nx,out ny);
    var a=new INPUT[1];
    a[0].type=0; a[0].u.mi=new MOUSEINPUT{dx=nx,dy=ny,dwFlags=MOVE|ABS|VDESK};
    SendInput(1,a,Marshal.SizeOf(typeof(INPUT)));
    P p; GetCursorPos(out p);
    bool ok = Math.Abs(p.X-x)<=2 && Math.Abs(p.Y-y)<=2;
    return (ok?"OK":"MISS")+" target=("+x+","+y+") cursor=("+p.X+","+p.Y+")";
  }
}
"@
[void][U]::SetProcessDPIAware()

function Get-SwdMain {
    $p = Get-Process SurfHydrodynamics -ErrorAction Stop
    $root=[System.Windows.Automation.AutomationElement]::RootElement
    $c=New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty,$p.Id)
    return $root.FindFirst([System.Windows.Automation.TreeScope]::Children,$c)
}
function Focus-Swd {
    $p = Get-Process SurfHydrodynamics -ErrorAction Stop
    [void][U]::SetForegroundWindow($p.MainWindowHandle)
    Start-Sleep -Milliseconds 500
    return ([U]::GetForegroundWindow() -eq $p.MainWindowHandle)
}
function Find-Pane {
    param([Parameter(Mandatory)][string]$Like,[int]$Index=0)
    $main=Get-SwdMain
    $all=$main.FindAll([System.Windows.Automation.TreeScope]::Descendants,
      (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::IsControlElementProperty,$true)))
    $hits=@(); foreach($e in $all){ if($e.Current.Name -and $e.Current.Name -like $Like){$hits+=$e} }
    if($hits.Count -eq 0){ return $null }
    return $hits[$Index]
}
function Shoot {
    param([string]$Name,[int]$X=0,[int]$Y=0,[int]$W=0,[int]$H=0,[double]$Scale=1.0)
    if($W -le 0){ $W=[U]::GetSystemMetrics(0); $H=[U]::GetSystemMetrics(1) }
    $bmp=New-Object System.Drawing.Bitmap($W,$H)
    $g=[System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($X,$Y,0,0,$bmp.Size); $g.Dispose()
    $save=$bmp
    if($Scale -ne 1.0){ $save=New-Object System.Drawing.Bitmap($bmp,[System.Drawing.Size]::new([int]($W*$Scale),[int]($H*$Scale))) }
    $out=Join-Path $PSScriptRoot "$Name.png"
    $save.Save($out,[System.Drawing.Imaging.ImageFormat]::Png)
    if($save -ne $bmp){ $save.Dispose() }; $bmp.Dispose()
    return $out
}
function ClickAt { param([int]$X,[int]$Y,[int]$SettleMs=1500)
    [void](Focus-Swd)
    $r=[U]::ClickAbs($X,$Y); Start-Sleep -Milliseconds $SettleMs; return $r }
function ClickPane { param([Parameter(Mandatory)][string]$Like,[int]$Index=0,[int]$SettleMs=1500)
    $e=Find-Pane -Like $Like -Index $Index
    if(-not $e){ return "NOT FOUND: $Like" }
    $r=$e.Current.BoundingRectangle
    $cx=[int]($r.X+$r.Width/2); $cy=[int]($r.Y+$r.Height/2)
    $res=ClickAt -X $cx -Y $cy -SettleMs $SettleMs
    return "'$($e.Current.Name)' -> $res" }
