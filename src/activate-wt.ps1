# activate-wt.ps1 - 将 Windows Terminal 窗口带到前台
# 由 claude-windows-toast hook 自动部署
# 通过 claudewt:// 自定义协议激活

$ErrorActionPreference = 'SilentlyContinue'

# 定义 Win32 API
$code = @"
using System;
using System.Runtime.InteropServices;
public class WinAPI {
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
}
"@

try {
    Add-Type -TypeDefinition $code -Language CSharp -ErrorAction SilentlyContinue
} catch {}

# 查找 Windows Terminal 进程
$wt = Get-Process -Name WindowsTerminal -ErrorAction SilentlyContinue | Select-Object -First 1

if ($wt -and $wt.MainWindowHandle -ne [IntPtr]::Zero) {
    $hwnd = $wt.MainWindowHandle

    # 如果窗口最小化，先恢复
    if ([WinAPI]::IsIconic($hwnd)) {
        [WinAPI]::ShowWindow($hwnd, 9)  # SW_RESTORE
        Start-Sleep -Milliseconds 100
    }

    # 模拟 Alt 键按下以绕过 SetForegroundWindow 的前台锁定限制
    [WinAPI]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)   # VK_ALT down
    [WinAPI]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)   # VK_ALT up

    # 将窗口带到前台
    [WinAPI]::SetForegroundWindow($hwnd)

    # 确保窗口可见
    [WinAPI]::ShowWindow($hwnd, 5)  # SW_SHOW
}
