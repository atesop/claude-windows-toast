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
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")]
    public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("user32.dll")]
    public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
}
"@

try {
    Add-Type -TypeDefinition $code -Language CSharp -ErrorAction SilentlyContinue
} catch {}

# 查找 Windows Terminal 进程
$wt = Get-Process -Name WindowsTerminal -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not ($wt -and $wt.MainWindowHandle -ne [IntPtr]::Zero)) { exit }

$hwnd = $wt.MainWindowHandle

# 主方法：AttachThreadInput 借用前台线程的前台权限，再激活 WT
# 顺序关键：必须先附着到「当前前台线程」(用户工作窗口，尚未被搅乱) 借到权限，
# 再 ShowWindow/SetForegroundWindow。若先 ShowWindow(RESTORE) 恢复 WT，会把它短暂弹到前台，
# 导致后续 GetForegroundWindow 拿到 WT 自己、附着到错误线程，SetForegroundWindow 无法保持。
# 注意：GetWindowThreadProcessId 的「返回值=线程ID」，「out 参数=进程ID」；AttachThreadInput 需线程ID。
$activated = $false
for ($i = 0; $i -lt 3 -and -not $activated; $i++) {
    try {
        $fgHwnd = [WinAPI]::GetForegroundWindow()
        $fgProcId = [UInt32]0
        $fgThreadId = [WinAPI]::GetWindowThreadProcessId($fgHwnd, [ref]$fgProcId)
        $myThreadId = [WinAPI]::GetCurrentThreadId()
        if ($fgThreadId -ne 0 -and $fgThreadId -ne $myThreadId) {
            $attached = $false
            try {
                [void][WinAPI]::AttachThreadInput($myThreadId, $fgThreadId, $true)
                $attached = $true
                if ([WinAPI]::IsIconic($hwnd)) { [void][WinAPI]::ShowWindow($hwnd, 9) }  # SW_RESTORE
                [void][WinAPI]::SetForegroundWindow($hwnd)
                [void][WinAPI]::BringWindowToTop($hwnd)
                [void][WinAPI]::ShowWindow($hwnd, 5)  # SW_SHOW
            } finally {
                # 仅在 attach 成功时分离：窗口操作若抛异常，finally 仍保证 detach，
                # 避免输入队列在本进程存活期(重试/回退)长期附着。
                if ($attached) { [void][WinAPI]::AttachThreadInput($myThreadId, $fgThreadId, $false) }
            }
        }
    } catch {}
    Start-Sleep -Milliseconds 150
    if ([WinAPI]::GetForegroundWindow() -eq $hwnd) { $activated = $true }
}

# 回退：模拟 Alt 键（绕过前台锁定的旧手法，兜底）
if (-not $activated) {
    if ([WinAPI]::IsIconic($hwnd)) { [void][WinAPI]::ShowWindow($hwnd, 9) }  # SW_RESTORE
    [WinAPI]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)   # VK_ALT down
    [WinAPI]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)   # VK_ALT up
    [void][WinAPI]::SetForegroundWindow($hwnd)
    [void][WinAPI]::ShowWindow($hwnd, 5)  # SW_SHOW
}
