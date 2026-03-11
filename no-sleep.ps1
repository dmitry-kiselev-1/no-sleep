# How to run
# powershell -ExecutionPolicy Bypass -File .\no-sleep.ps1

# Settings
$CheckIntervalSeconds = 60
$IdleThresholdSeconds = 120
$MovePixels = 1

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class NativeMethods
{
    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO
    {
        public uint cbSize;
        public uint dwTime;
    }

    [DllImport("user32.dll")]
    public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int X, int Y);
}
"@

function Get-IdleSeconds {
    $info = New-Object NativeMethods+LASTINPUTINFO
    $info.cbSize = [uint32][Runtime.InteropServices.Marshal]::SizeOf($info)
    [void][NativeMethods]::GetLastInputInfo([ref]$info)

    $now = [Environment]::TickCount64
    $idleMs = $now - $info.dwTime
    return [math]::Floor($idleMs / 1000)
}

Add-Type -AssemblyName System.Windows.Forms

while ($true) {
    $idleSeconds = Get-IdleSeconds

    if ($idleSeconds -ge $IdleThresholdSeconds) {
        $p = [System.Windows.Forms.Cursor]::Position
        [void][NativeMethods]::SetCursorPos($p.X + $MovePixels, $p.Y)
        Start-Sleep -Milliseconds 50
        [void][NativeMethods]::SetCursorPos($p.X, $p.Y)

        Write-Host "$(Get-Date -Format 'HH:mm:ss')  Mouse moved"
    }

    Start-Sleep -Seconds $CheckIntervalSeconds
}