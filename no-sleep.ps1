param(
    [int]$IdleThresholdSeconds = 30,
    [int]$SafetyMarginMs = 150,
    [int]$PostSendSleepMs = 250,
    [int]$MovePixels = 1,

    # Logging / diagnostics
    [switch]$EnableLog,
    [switch]$VerboseLoop,
    [switch]$VerboseWhenSendingOnly,
    [switch]$MoveOnePixelAndBack,
    [switch]$VerboseTicks
)

# How to run
# powershell -ExecutionPolicy Bypass -File .\no-sleep.ps1 -IdleThresholdSeconds 30
#
# Quick test (with logging)
# powershell -ExecutionPolicy Bypass -File .\no-sleep.ps1 -IdleThresholdSeconds 2 -EnableLog -VerboseLoop -VerboseTicks

# Default behavior: move cursor out-and-back is ON unless you explicitly disable it.
if (-not $PSBoundParameters.ContainsKey('MoveOnePixelAndBack')) {
    $MoveOnePixelAndBack = $true
}

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

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT
    {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT lpPoint);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int nIndex);

    [DllImport("kernel32.dll")]
    public static extern uint GetTickCount();

    private const int INPUT_MOUSE = 0;

    private const uint MOUSEEVENTF_MOVE = 0x0001;
    private const uint MOUSEEVENTF_ABSOLUTE = 0x8000;
    private const uint MOUSEEVENTF_VIRTUALDESK = 0x4000;

    private const int SM_XVIRTUALSCREEN = 76;
    private const int SM_YVIRTUALSCREEN = 77;
    private const int SM_CXVIRTUALSCREEN = 78;
    private const int SM_CYVIRTUALSCREEN = 79;

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT
    {
        public uint type;
        public InputUnion U;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct InputUnion
    {
        [FieldOffset(0)]
        public MOUSEINPUT mi;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    private static int ToAbsolute(int pixel, int origin, int size)
    {
        // Map [origin .. origin+size-1] to [0 .. 65535]
        // Clamp to avoid overflow/invalid values.
        if (size <= 1) return 0;
        long v = ((long)(pixel - origin) * 65535L) / (long)(size - 1);
        if (v < 0) v = 0;
        if (v > 65535) v = 65535;
        return (int)v;
    }

    public static bool NudgeMouseAtCurrentPos(bool moveOnePixelAndBack = false)
    {
        POINT p;
        if (!GetCursorPos(out p)) return false;

        int vx = GetSystemMetrics(SM_XVIRTUALSCREEN);
        int vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
        int vw = GetSystemMetrics(SM_CXVIRTUALSCREEN);
        int vh = GetSystemMetrics(SM_CYVIRTUALSCREEN);

        int ax = ToAbsolute(p.X, vx, vw);
        int ay = ToAbsolute(p.Y, vy, vh);

        if (!moveOnePixelAndBack)
        {
            var inputs = new INPUT[1];
            inputs[0].type = INPUT_MOUSE;
            inputs[0].U.mi = new MOUSEINPUT
            {
                dx = ax,
                dy = ay,
                mouseData = 0,
                dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK,
                time = 0,
                dwExtraInfo = IntPtr.Zero
            };

            return SendInput(1, inputs, Marshal.SizeOf(typeof(INPUT))) == 1;
        }
        else
        {
            // Move by +1 px (if possible) and then back, ending at the original position.
            int p2x = p.X + 1;
            int p2y = p.Y;
            int ax2 = ToAbsolute(p2x, vx, vw);
            int ay2 = ToAbsolute(p2y, vy, vh);

            var inputs = new INPUT[2];

            inputs[0].type = INPUT_MOUSE;
            inputs[0].U.mi = new MOUSEINPUT
            {
                dx = ax2,
                dy = ay2,
                mouseData = 0,
                dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK,
                time = 0,
                dwExtraInfo = IntPtr.Zero
            };

            inputs[1].type = INPUT_MOUSE;
            inputs[1].U.mi = new MOUSEINPUT
            {
                dx = ax,
                dy = ay,
                mouseData = 0,
                dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK,
                time = 0,
                dwExtraInfo = IntPtr.Zero
            };

            return SendInput(2, inputs, Marshal.SizeOf(typeof(INPUT))) == 2;
        }
    }

    public static bool NudgeMouseRelative(int dx, int dy)
    {
        var inputs = new INPUT[1];
        inputs[0].type = INPUT_MOUSE;
        inputs[0].U.mi = new MOUSEINPUT
        {
            dx = dx,
            dy = dy,
            mouseData = 0,
            dwFlags = MOUSEEVENTF_MOVE,
            time = 0,
            dwExtraInfo = IntPtr.Zero
        };

        return SendInput(1, inputs, Marshal.SizeOf(typeof(INPUT))) == 1;
    }
}
"@

function Get-IdleInfo {
    # Returns: Ok, IdleMs, IdleSeconds, TickNow32, LastInputTick32, LastError
    $info = New-Object NativeMethods+LASTINPUTINFO
    $info.cbSize = [uint32][Runtime.InteropServices.Marshal]::SizeOf($info)

    $ok = [NativeMethods]::GetLastInputInfo([ref]$info)
    $lastError = if ($ok) { 0 } else { [Runtime.InteropServices.Marshal]::GetLastWin32Error() }

    # Use WinAPI tick counter to match LASTINPUTINFO.dwTime exactly.
    $tickNow32 = [uint32][NativeMethods]::GetTickCount()
    $lastInputTick32 = [uint32]$info.dwTime

    # Wrap-safe delta in the 0..(2^32-1) range.
    $delta = [int64]$tickNow32 - [int64]$lastInputTick32
    if ($delta -lt 0) { $delta += 4294967296 }

    $idleMs = [uint64]$delta
    $idleSeconds = [double]$idleMs / 1000.0

    [pscustomobject]@{
        Ok = $ok
        IdleMs = $idleMs
        IdleSeconds = $idleSeconds
        TickNow32 = $tickNow32
        LastInputTick32 = $lastInputTick32
        LastError = $lastError
    }
}

$iteration = 0
$start = Get-Date

$thresholdMs = [int64]$IdleThresholdSeconds * 1000
if ($thresholdMs -lt 0) { $thresholdMs = 0 }

while ($true) {
    $iteration++
    $idle = Get-IdleInfo

    $shouldSend = ($idle.Ok -and ($idle.IdleMs -ge [uint64]$thresholdMs))

    $cursorBefore = $null
    $cursorAfter = $null
    $sendOk = $null
    $sendLastError = 0

    if ($shouldSend) {
        $cursorBefore = New-Object NativeMethods+POINT
        [void][NativeMethods]::GetCursorPos([ref]$cursorBefore)

        # If the cursor hasn't moved for IdleThresholdSeconds, nudge it and move it back (default).
        if ($MoveOnePixelAndBack) {
            $sendOk = [NativeMethods]::NudgeMouseAtCurrentPos($true)
        } else {
            $sendOk = [NativeMethods]::NudgeMouseRelative($MovePixels, 0)
        }
        $sendLastError = if ($sendOk) { 0 } else { [Runtime.InteropServices.Marshal]::GetLastWin32Error() }

        $cursorAfter = New-Object NativeMethods+POINT
        [void][NativeMethods]::GetCursorPos([ref]$cursorAfter)
    }

    $now = Get-Date
    $uptime = [math]::Round((New-TimeSpan -Start $start -End $now).TotalSeconds, 1)

    if ($EnableLog -and $VerboseLoop -and (-not $VerboseWhenSendingOnly -or $shouldSend)) {
        $cursorPart = ""
        if ($shouldSend) {
            $cursorPart = " Cursor: ($($cursorBefore.X),$($cursorBefore.Y)) -> ($($cursorAfter.X),$($cursorAfter.Y))"
        }

        $actionPart = "Action: none"
        if (-not $idle.Ok) {
            $actionPart = "Action: none (GetLastInputInfo FAILED)"
        } elseif ($shouldSend) {
            $actionPart = "Action: SendInput(mouse) ok=$sendOk"
            if ($MoveOnePixelAndBack) { $actionPart += " (move+back)" } else { $actionPart += " (relative dx=$MovePixels)" }
            if (-not $sendOk -or $sendLastError -ne 0) { $actionPart += " sendLastError=$sendLastError" }
        }

        $tickPart = ""
        if ($VerboseTicks) {
            $tickPart = " tickNow32=$($idle.TickNow32) lastInputTick32=$($idle.LastInputTick32)"
        }

        $gliErrorPart = ""
        if (-not $idle.Ok) {
            $gliErrorPart = " getLastInputInfoLastError=$($idle.LastError)"
        }

        Write-Host ("{0}  iter={1} up={2}s idle={3:n3}s ({4}ms) thr={5}s ok={6}{7}{8}  {9}{10}{11}" -f `
            $now.ToString('HH:mm:ss'), $iteration, $uptime, $idle.IdleSeconds, $idle.IdleMs, $IdleThresholdSeconds, $idle.Ok, $gliErrorPart, $tickPart, $actionPart, $cursorPart, "")
    }

    # Scheduling:
    # - If we just sent input, wait a bit so we don't spam SendInput.
    # - Otherwise, sleep until close to threshold (with a small safety margin),
    #   then poll more frequently near the threshold.
    if ($shouldSend) {
        Start-Sleep -Milliseconds $PostSendSleepMs
        continue
    }

    # How long until we hit the threshold?
    $remainingMs = [int64]$thresholdMs - [int64]$idle.IdleMs

    # If we're far from the threshold, sleep most of the remaining time.
    if ($remainingMs -gt ($SafetyMarginMs + 50)) {
        $sleepMs = $remainingMs - $SafetyMarginMs
        if ($sleepMs -gt 60000) { $sleepMs = 60000 } # cap to 60s for responsiveness
        if ($sleepMs -lt 50) { $sleepMs = 50 }
        Start-Sleep -Milliseconds $sleepMs
    } else {
        # Near the threshold: poll more often.
        Start-Sleep -Milliseconds 100
    }
}
