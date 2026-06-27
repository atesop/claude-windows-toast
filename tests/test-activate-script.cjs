// tests/test-activate-script.cjs
// 验证 getActivationScriptContent：生成 activate-wt.ps1 激活脚本的内容
//
// 根因（实测隔离确认）：
//   activate-wt.ps1 原先仅用「模拟 Alt 键 + SetForegroundWindow」激活 Windows Terminal。
//   但点击通知经 claudewt:// 协议异步拉起的 powershell 进程缺少 Windows 前台权限，
//   SetForegroundWindow 被静默拒绝，又因 $ErrorActionPreference='SilentlyContinue' 吞掉错误，
//   表现为「点击通知毫无反应」。而直接调用 ps1（处于活跃前台进程链）却能成功。
//   实测证据：Start-Process "claudewt://" 后前台不变(FAIL)；直接 & activate-wt.ps1 前台切到 WT(SUCCESS)。
// 修复：
//   主方法改为 AttachThreadInput——把本线程输入队列附着到当前前台线程，借用其前台权限，
//   再 SetForegroundWindow + BringWindowToTop；保留「模拟 Alt 键」为回退，激活后用
//   GetForegroundWindow() -eq $hwnd 自检，失败则重试。
//
// 运行：node tests/test-activate-script.cjs

const assert = require('assert');
const { getActivationScriptContent } = require('../src/claude-windows-toast.cjs');

let passed = 0;
function check(name, fn) { fn(); passed++; console.log('  ✓ ' + name); }

console.log('test-activate-script: getActivationScriptContent');

let script;
check('函数已导出并返回非空字符串', () => {
  assert.strictEqual(typeof getActivationScriptContent, 'function');
  script = getActivationScriptContent();
  assert.ok(typeof script === 'string' && script.length > 0);
});

check('查找 WindowsTerminal 进程（保留）', () => {
  assert.ok(/Get-Process\s+-Name\s+WindowsTerminal/.test(script));
});

check('最小化先恢复：IsIconic + SW_RESTORE（保留）', () => {
  assert.ok(/IsIconic/.test(script));
  assert.ok(/ShowWindow\(\$hwnd,\s*9\)/.test(script)); // SW_RESTORE = 9
});

check('主方法 AttachThreadInput：声明所需 Win32 API', () => {
  assert.ok(/GetForegroundWindow/.test(script), '应有 GetForegroundWindow');
  assert.ok(/GetWindowThreadProcessId/.test(script), '应有 GetWindowThreadProcessId');
  assert.ok(/GetCurrentThreadId/.test(script), '应有 GetCurrentThreadId');
  assert.ok(/AttachThreadInput/.test(script), '应有 AttachThreadInput');
  assert.ok(/BringWindowToTop/.test(script), '应有 BringWindowToTop');
});

check('AttachThreadInput 成对调用：$true 附着 + $false 分离', () => {
  assert.ok(/AttachThreadInput\([^)]*\$true\)/.test(script), '应调用 AttachThreadInput(..., $true) 附着');
  assert.ok(/AttachThreadInput\([^)]*\$false\)/.test(script), '应调用 AttachThreadInput(..., $false) 分离');
});

check('AttachThreadInput 分离在 finally 块中（窗口操作异常也能 detach）', () => {
  // codex 评审 P2：若 attach 成功后窗口操作抛异常，原 catch{} 会跳过 $false 分离，
  // 导致输入队列在进程存活期(重试/回退)长期附着。用 try/finally + $attached 标志保证对称分离。
  const finallyIdx = script.search(/finally\s*\{/);
  const detachIdx = script.search(/AttachThreadInput\([^)]*\$false\)/);
  assert.notStrictEqual(finallyIdx, -1, '应有 finally 块');
  assert.ok(detachIdx > finallyIdx, 'AttachThreadInput($false) 应在 finally 块内');
  assert.ok(/\$attached/.test(script), '应用 $attached 标志仅在 attach 成功时 detach');
});

check('线程ID 取自 GetWindowThreadProcessId 返回值（非 out 进程ID）', () => {
  // 正确：$fgThreadId = [WinAPI]::GetWindowThreadProcessId(...)  取返回值(线程ID)
  // 错误：[void][WinAPI]::GetWindowThreadProcessId(..., [ref]$fgThreadId) 丢弃返回值、误用进程ID
  assert.ok(
    /\$fgThreadId\s*=\s*\[WinAPI\]::GetWindowThreadProcessId\(/.test(script),
    '线程ID 必须取自 GetWindowThreadProcessId 返回值，不能误用 out 进程ID'
  );
});

check('带重试循环，应对协议异步激活的时序', () => {
  assert.ok(/for\s*\(\s*\$i\s*=/.test(script), '应有重试循环');
});

check('顺序：AttachThreadInput 附着 必须早于 ShowWindow(RESTORE)', () => {
  // 根因：若先 ShowWindow(RESTORE) 恢复最小化的 WT，会把它短暂弹到前台，
  // 搅乱 GetForegroundWindow，导致附着到 WT 自己而非真正的前台窗口，激活无法保持。
  const attachIdx = script.search(/AttachThreadInput\([^)]*\$true\)/);
  const restoreIdx = script.search(/ShowWindow\(\$hwnd,\s*9\)/);
  assert.notStrictEqual(attachIdx, -1, '应有 AttachThreadInput(...$true)');
  assert.notStrictEqual(restoreIdx, -1, '应有 ShowWindow($hwnd, 9)');
  assert.ok(attachIdx < restoreIdx, 'AttachThreadInput 附着必须早于 ShowWindow(RESTORE)');
});

check('激活后自检：GetForegroundWindow() -eq $hwnd', () => {
  assert.ok(/GetForegroundWindow\(\)\s*-eq\s*\$hwnd/.test(script));
});

check('回退保留：模拟 Alt 键 keybd_event(0x12)', () => {
  assert.ok(/keybd_event/.test(script));
  assert.ok(/0x12/.test(script)); // VK_ALT
});

console.log('\n✅ 全部 ' + passed + ' 个用例通过');
