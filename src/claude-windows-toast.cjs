#!/usr/bin/env node
// ============================================================================
// claude-windows-toast - Claude Code Windows Toast 通知 Hook
// ============================================================================
// 通过 BurntToast 模块发送 Windows Toast 通知
// 支持点击通知按钮跳转回 Windows Terminal
//
// 用法:
//   node claude-windows-toast.cjs --ask       # 🔴 需要输入通知(配 PreToolUse:AskUserQuestion)
//   node claude-windows-toast.cjs --mark-ask  # 标记 ask 时间
//   node claude-windows-toast.cjs --stop      # Stop 通知
// ============================================================================

const { spawnSync } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

// ---- 常量 ----

// SESSION_ID 与 STATE_FILE 在运行时（见文件末尾 require.main 守卫内）计算，
// 此处先声明，供 getState/writeState 等模块级函数引用。
let SESSION_ID = '';
let STATE_FILE = '';

/**
 * 清洗会话标识为安全的文件名片段
 * 白名单仅保留字母、数字、_.-，防止分隔符导致状态文件逃逸 temp 目录
 */
function sanitizeSessionId(raw) {
  return String(raw).replace(/[^A-Za-z0-9_.-]/g, '_').slice(0, 120);
}

/**
 * 解析稳定的会话标识（状态文件名 key）
 *
 * 优先级：hook stdin 的 session_id > $CLAUDE_SESSION_ID > $CLAUDE_CONVERSATION_ID > ppid 兜底
 *
 * 为何不能用 ppid：Claude Code 执行 command hook（shell form，无 args）时经 sh -c，
 * node 的 ppid 是临时 shell 的 PID，每次 spawn 都不同。会导致 --mark-ask 写的状态文件
 * 与 --stop 读的不是同一个，⏳「等待输入」永不出现、Stop 永远发绿色 ✅。
 * session_id 由 Claude Code 通过 stdin JSON 注入，同一会话内所有 hook 都相同，是稳定 key。
 *
 * @param {object} input - hook stdin 解析出的 JSON（含 session_id）
 * @param {object} env - 进程环境变量
 * @param {number|string} ppid - 进程父 PID，最后兜底
 * @returns {string} 清洗后的会话标识
 */
function resolveSessionId(input, env, ppid) {
  const stdinSid = input && typeof input.session_id === 'string' && input.session_id.trim();
  if (stdinSid) return sanitizeSessionId(input.session_id);
  const envSid = env && typeof env.CLAUDE_SESSION_ID === 'string' && env.CLAUDE_SESSION_ID.trim();
  if (envSid) return sanitizeSessionId(env.CLAUDE_SESSION_ID);
  const convSid = env && typeof env.CLAUDE_CONVERSATION_ID === 'string' && env.CLAUDE_CONVERSATION_ID.trim();
  if (convSid) return sanitizeSessionId(env.CLAUDE_CONVERSATION_ID);
  return sanitizeSessionId(ppid);
}
const SETUP_MARKER = path.join(os.tmpdir(), 'claude-wt-protocol-setup.json');
const BUTTON_TEXT = '跳转到终端';
const PROTOCOL_NAME = 'claudewt';
const DEPLOY_DIR_NAME = 'claude-code';
const ASK_EXPIRY_MS = 60000; // 60 秒内检测为"最近 ask"
// 注册表校验的 TTL：marker 在此时限内只校验文件存在（廉价），跳过 spawn powershell 查注册表（昂贵）
// 避免 --mark-ask 等高频 hook 每次都多一次 PowerShell 冷启动
const REGISTRY_CHECK_TTL_MS = 24 * 60 * 60 * 1000; // 24 小时
const DEBUG = process.env.CLAUDE_WINDOWS_TOAST_DEBUG === '1';

// ---- 平台适配 ----
// 区分两种运行环境（Claude Code 未提供专用环境变量，靠 process.platform 判定）：
//   · 'linux' → Claude Code 跑在 WSL，本进程是 Linux Node，访问 Windows 文件需经 /mnt/c
//   · 'win32' → Claude Code 跑在 Windows 原生，本进程是 Windows Node，直接用 C:\ 路径
const IS_NATIVE_WINDOWS = process.platform === 'win32';

// ---- 调试日志 ----

function debugLog(msg) {
  if (!DEBUG) return;
  const logFile = path.join(os.tmpdir(), 'claude-windows-toast.log');
  try {
    const ts = new Date().toISOString();
    fs.appendFileSync(logFile, `[${ts}] ${msg}\n`);
  } catch {}
}

// ---- 状态管理 ----

/** 读取 ask 状态文件 */
function getState() {
  try {
    return JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
  } catch {
    return { askCount: 0, lastCwd: '' };
  }
}

/** 写入 ask 状态文件 */
function writeState(state) {
  try {
    fs.writeFileSync(STATE_FILE, JSON.stringify(state), 'utf8');
  } catch {}
}

/** 清除 ask 状态文件 */
function clearState() {
  try {
    fs.unlinkSync(STATE_FILE);
  } catch {}
}

// ---- 工具函数 ----

/**
 * 安全转义字符串用于 PowerShell 单引号字符串
 * 处理单引号、换行符、控制字符等
 */
function psEscape(s) {
  return String(s)
    .replace(/'/g, "''")
    .replace(/[\r\n]/g, ' ')
    .replace(/[\x00-\x08\x0b\x0c\x0e-\x1f]/g, '');
}

/** 截断过长文本 */
function truncate(s, maxLen) {
  if (!s) return '';
  return s.length > maxLen ? s.substring(0, maxLen) + '...' : s;
}

/** 获取当前工作目录名称 */
function getCwdName() {
  try {
    return path.basename(process.cwd()) || process.cwd();
  } catch {
    return 'unknown';
  }
}

// ---- 协议注册 ----

/**
 * 获取 Windows APPDATA 路径（WSL 与 Windows 原生双环境）
 *
 * 返回 { win, fsBase }：
 *   - win:    Windows 风格路径（C:\Users\...\Roaming），始终用于注册表与 VBS 内容
 *   - fsBase: 本进程 fs 操作用的基础路径
 *             · WSL：/mnt/c/Users/.../Roaming（Node 在 Linux，经 /mnt/c 访问 Windows 文件）
 *             · Windows 原生：C:\Users\...\Roaming（Node 本就在 Windows，原样使用）
 *
 * Windows 原生下直接读 process.env.APPDATA，免去一次 spawn powershell（更快）；
 * WSL 下 Node 没有 APPDATA 环境变量，仍需 spawn powershell.exe 获取。
 *
 * @returns {{ win: string, fsBase: string } | null}
 */
function getWindowsAppData() {
  if (IS_NATIVE_WINDOWS) {
    const win = (process.env.APPDATA || '').trim();
    if (!win || !win.match(/^[A-Z]:\\/i)) return null;
    return { win, fsBase: win };
  }

  const result = spawnSync('powershell.exe', [
    '-ExecutionPolicy', 'Bypass', '-NoProfile', '-WindowStyle', 'Hidden',
    '-Command', 'Write-Output $env:APPDATA'
  ], { windowsHide: true, encoding: 'utf8' });

  const win = (result.stdout || '').trim();
  if (!win || !win.match(/^[A-Z]:\\/i)) return null;

  const drive = win[0].toLowerCase();
  const relPath = win.substring(3).replace(/\\/g, '/');
  return { win, fsBase: `/mnt/${drive}/${relPath}` };
}

/**
 * 返回 activate-wt.ps1 脚本内容
 * 使用 Win32 API (SetForegroundWindow + ShowWindow + keybd_event)
 * 将 Windows Terminal 窗口带到前台
 */
function getActivationScriptContent() {
  return [
    '# activate-wt.ps1 - 将 Windows Terminal 窗口带到前台',
    '# 由 claude-windows-toast hook 自动部署',
    '# 通过 claudewt:// 自定义协议激活',
    '',
    '$ErrorActionPreference = \'SilentlyContinue\'',
    '',
    '# 定义 Win32 API',
    '$code = @"',
    'using System;',
    'using System.Runtime.InteropServices;',
    'public class WinAPI {',
    '    [DllImport("user32.dll")]',
    '    public static extern bool SetForegroundWindow(IntPtr hWnd);',
    '    [DllImport("user32.dll")]',
    '    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);',
    '    [DllImport("user32.dll")]',
    '    public static extern bool IsIconic(IntPtr hWnd);',
    '    [DllImport("user32.dll")]',
    '    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);',
    '}',
    '"@',
    '',
    'try {',
    '    Add-Type -TypeDefinition $code -Language CSharp -ErrorAction SilentlyContinue',
    '} catch {}',
    '',
    '# 查找 Windows Terminal 进程',
    '$wt = Get-Process -Name WindowsTerminal -ErrorAction SilentlyContinue | Select-Object -First 1',
    '',
    'if ($wt -and $wt.MainWindowHandle -ne [IntPtr]::Zero) {',
    '    $hwnd = $wt.MainWindowHandle',
    '',
    '    # 如果窗口最小化，先恢复',
    '    if ([WinAPI]::IsIconic($hwnd)) {',
    '        [WinAPI]::ShowWindow($hwnd, 9)  # SW_RESTORE',
    '        Start-Sleep -Milliseconds 100',
    '    }',
    '',
    '    # 模拟 Alt 键按下以绕过 SetForegroundWindow 的前台锁定限制',
    '    [WinAPI]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)   # VK_ALT down',
    '    [WinAPI]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)   # VK_ALT up',
    '',
    '    # 将窗口带到前台',
    '    [WinAPI]::SetForegroundWindow($hwnd)',
    '',
    '    # 确保窗口可见',
    '    [WinAPI]::ShowWindow($hwnd, 5)  # SW_SHOW',
    '}',
    ''
  ].join('\n');
}

/**
 * 生成 VBS 包装器内容
 * 使用 wscript.exe 运行，确保不弹出任何窗口
 * @param {string} ps1WinPath - activate-wt.ps1 的 Windows 路径
 */
function getVbsWrapperContent(ps1WinPath) {
  // VBS 注释使用单引号前缀，在 JS 中作为普通字符串写入
  return [
    "' activate-wt.vbs - 无窗口启动 activate-wt.ps1",
    "' 由 claude-windows-toast hook 自动部署",
    'Set objShell = CreateObject("WScript.Shell")',
    `objShell.Run "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File ""${ps1WinPath}""", 0, False`,
    ''
  ].join('\r\n');
}

/**
 * 验证协议注册是否仍然有效
 * 检查注册表和部署文件是否都存在
 */
function validateProtocolSetup(marker) {
  if (!marker || !marker.ok) return false;

  // 1. 每次都检查部署文件是否存在（廉价，无进程启动）
  //    fsPs1Path/fsVbsPath 是本进程可用的 fs 路径（WSL=/mnt/c...，原生=C:\...）。
  //    字段缺失说明是旧版 marker（wslPs1Path 时代），强制重注册刷新到新结构。
  try {
    if (!marker.fsPs1Path || !marker.fsVbsPath) return false;
    if (!fs.existsSync(marker.fsPs1Path)) return false;
    if (!fs.existsSync(marker.fsVbsPath)) return false;
  } catch {
    return false;
  }

  // 2. 注册表校验昂贵（需 spawn powershell），用 marker.ts 做 TTL 缓存：
  //    最近校验过就跳过，超过 TTL 才真正查注册表（由 ensureProtocolSetup 刷新 ts）
  if (marker.ts && (Date.now() - marker.ts) < REGISTRY_CHECK_TTL_MS) {
    return true;
  }

  // 3. 查注册表：claudewt 协议的 open command 仍须指向自家 activate-wt.vbs
  // （防止 marker 显示 ok，但协议已被其他程序/用户覆盖的情况）
  try {
    const reg = spawnSync('powershell.exe', [
      '-ExecutionPolicy', 'Bypass', '-NoProfile', '-WindowStyle', 'Hidden',
      '-Command', "(Get-ItemProperty 'HKCU:\\Software\\Classes\\claudewt\\shell\\open\\command' -ErrorAction SilentlyContinue).'(default)'"
    ], { windowsHide: true, encoding: 'utf8' });
    // Windows 路径大小写不敏感，统一小写比较（避免等价路径被误判失效导致重复注册）
    const cmd = (reg.stdout || '').trim().toLowerCase();
    if (!cmd || !cmd.includes('activate-wt.vbs')) return false;
    if (marker.vbsPath && !cmd.includes(marker.vbsPath.toLowerCase())) return false;
  } catch {
    return false;
  }

  return true;
}

/**
 * 注册 claudewt:// 自定义协议
 *
 * 完整流程：
 * 1. 检查 marker → 如已注册且有效则跳过
 * 2. 获取 APPDATA 路径
 * 3. 部署 activate-wt.ps1 激活脚本
 * 4. 生成 activate-wt.vbs 无窗口包装器
 * 5. 注册 claudewt:// 协议到 HKCU 注册表（使用 wscript.exe 调用 VBS）
 * 6. 清理临时注册脚本
 * 7. 写入 marker 文件
 *
 * @returns {boolean} 协议是否就绪
 */
function ensureProtocolSetup() {
  // 1. 检查 marker（含验证）
  try {
    const marker = JSON.parse(fs.readFileSync(SETUP_MARKER, 'utf8'));
    if (validateProtocolSetup(marker)) {
      // 注册表校验有 TTL：若本次是"过期重校验"通过的，刷新 ts 避免下次重复 spawn powershell
      if (!marker.ts || (Date.now() - marker.ts) >= REGISTRY_CHECK_TTL_MS) {
        try {
          fs.writeFileSync(SETUP_MARKER, JSON.stringify({ ...marker, ts: Date.now() }), 'utf8');
        } catch {}
      }
      debugLog('Protocol already registered and valid');
      return true;
    }
    debugLog('Marker exists but invalid, re-registering');
  } catch {}

  // 2. 获取 APPDATA 路径
  const appData = getWindowsAppData();
  if (!appData) {
    debugLog('Failed to get APPDATA path');
    return false;
  }

  // fsBase: 本进程 fs 用（WSL=/mnt/c...，原生=C:\...）；win: 注册表/VBS 内容用（始终 Windows 路径）
  const dirFs = path.join(appData.fsBase, DEPLOY_DIR_NAME);
  const ps1Fs = path.join(dirFs, 'activate-wt.ps1');
  const vbsFs = path.join(dirFs, 'activate-wt.vbs');
  const ps1Win = `${appData.win}\\${DEPLOY_DIR_NAME}\\activate-wt.ps1`;
  const vbsWin = `${appData.win}\\${DEPLOY_DIR_NAME}\\activate-wt.vbs`;

  // 3. 部署激活脚本
  try {
    fs.mkdirSync(dirFs, { recursive: true });
    fs.writeFileSync(ps1Fs, getActivationScriptContent(), 'utf8');
    debugLog(`Deployed PS1: ${ps1Fs}`);
  } catch (e) {
    debugLog(`Failed to deploy PS1: ${e.message}`);
    return false;
  }

  // 4. 生成 VBS 包装器
  try {
    fs.writeFileSync(vbsFs, getVbsWrapperContent(ps1Win), 'utf8');
    debugLog(`Deployed VBS: ${vbsFs}`);
  } catch (e) {
    debugLog(`Failed to deploy VBS: ${e.message}`);
    return false;
  }

  // 5. 注册协议（使用临时 PS1 文件避免转义问题）
  //    regScriptFs 在 WSL 下是 /mnt/c/...（WSL 互操作会自动转成 C:\ 传给 powershell.exe）；
  //    Windows 原生下就是 C:\...，直接执行。两种平台统一 -File regScriptFs 即可。
  const regScriptFs = path.join(dirFs, 'register-protocol.ps1');
  const regScriptContent = [
    "$k = 'HKCU:\\Software\\Classes\\" + PROTOCOL_NAME + "'",
    "if (-not (Test-Path $k)) {",
    "  New-Item -Path $k -Force | Out-Null",
    "  Set-ItemProperty -Path $k -Name '(Default)' -Value 'URL:Claude Code Terminal'",
    "  Set-ItemProperty -Path $k -Name 'URL Protocol' -Value ''",
    '}',
    // 子键创建无条件执行：-Force 幂等，并能修复"根键存在但 shell\open\command 缺失"的半注册状态
    'New-Item -Path "$k\\shell\\open\\command" -Force | Out-Null',
    "$cmd = 'wscript.exe \"" + psEscape(vbsWin) + "\"'",
    'Set-ItemProperty -Path "$k\\shell\\open\\command" -Name \'(Default)\' -Value $cmd',
  ].join('\n');

  try {
    fs.writeFileSync(regScriptFs, regScriptContent, 'utf8');
  } catch (e) {
    debugLog(`Failed to write reg script: ${e.message}`);
    return false;
  }

  const regResult = spawnSync('powershell.exe', [
    '-ExecutionPolicy', 'Bypass', '-NoProfile', '-WindowStyle', 'Hidden',
    '-File', regScriptFs
  ], { windowsHide: true, encoding: 'utf8' });

  if (regResult.status !== 0) {
    debugLog(`Registry registration failed: status=${regResult.status}`);
    return false;
  }

  // 6. 清理临时注册脚本
  try {
    fs.unlinkSync(regScriptFs);
  } catch {}

  // 7. 写入 marker
  //    fsPs1Path/fsVbsPath: 本进程 fs 路径（validateProtocolSetup 用）；
  //    ps1Path/vbsPath:     Windows 路径（vbsPath 用于注册表校验比较）。
  try {
    fs.writeFileSync(SETUP_MARKER, JSON.stringify({
      ok: true,
      ps1Path: ps1Win,
      vbsPath: vbsWin,
      fsPs1Path: ps1Fs,
      fsVbsPath: vbsFs,
      ts: Date.now()
    }));
  } catch {}

  debugLog('Protocol registered successfully');
  return true;
}

// ---- Toast 通知 ----

/** 协议就绪状态（首次运行时自动注册）；在 require.main 守卫内赋值，避免被 require 时 spawn powershell */
let protocolReady = false;

/**
 * 构造权限确认通知的文本行（🔴 需要授权）
 * 用于 Notification(permission_prompt) 事件：Claude Code 弹出命令权限确认框时触发。
 *
 * @param {string} message - Notification stdin 的 message 字段（Claude 给的权限原因），可空
 * @param {string} cwd - 当前目录名（由 getCwdName() 提供）
 * @returns {string[]} toast 文本行（恒 3 行；message 为空时第 2 行为 ''，由 sendToast 过滤）
 */
function buildPermissionLines(message, cwd) {
  const msg = (typeof message === 'string') ? message.trim() : '';
  return [
    '🔴 Claude Code - 需要你的授权',
    msg ? truncate(msg, 150) : '',
    `目录: ${cwd}`
  ];
}

/**
 * 发送 Windows Toast 通知
 * 如果 claudewt:// 协议注册成功，通知包含"跳转到终端"按钮
 *
 * @param {string[]} lines - 通知文本行
 */
function sendToast(lines) {
  // 安全处理通知文本，过滤控制字符
  const safeTextParams = lines
    .filter(l => l)
    .map(l => `'${psEscape(truncate(l, 150))}'`)
    .join(', ');

  let script;
  if (protocolReady) {
    // 带按钮：点击可跳转到终端
    script = [
      "Import-Module BurntToast -ErrorAction SilentlyContinue;",
      "$btn = New-BTButton -Content '" + BUTTON_TEXT + "' -Arguments '" + PROTOCOL_NAME + "://' -ActivationType Protocol;",
      "New-BurntToastNotification -Text " + safeTextParams + " -Sound Default -Button $btn;"
    ].join(' ');
  } else {
    // 降级：不带按钮
    script = [
      "Import-Module BurntToast -ErrorAction SilentlyContinue;",
      "New-BurntToastNotification -Text " + safeTextParams + " -Sound Default;"
    ].join(' ');
  }

  const result = spawnSync('powershell.exe', [
    '-ExecutionPolicy', 'Bypass',
    '-NoProfile',
    '-WindowStyle', 'Hidden',
    '-Command', script
  ], { windowsHide: true, encoding: 'utf8' });

  if (result.status !== 0) {
    debugLog(`sendToast failed: status=${result.status} stderr=${(result.stderr || '').substring(0, 200)}`);
  }
}

// ---- 运行时入口 ----
// 仅直接执行（如 `node claude-windows-toast.cjs --stop`）时运行；
// 被单元测试 require 时跳过整段副作用逻辑（sendToast / process.exit）。
if (require.main === module) {

// 首次运行注册 claudewt:// 协议（可能 spawn powershell，故只在直接运行时做，避免 require 时副作用）
try {
  protocolReady = ensureProtocolSetup();
} catch (e) {
  debugLog(`Protocol setup error: ${e.message}`);
}

// 读取 Claude Code 经 stdin 注入的 hook JSON（含稳定 session_id）
// 仅在非 TTY（管道/重定向，即真实 hook 或 `echo | node` 调试）时读取；
// 手动在交互终端运行（stdin 是 TTY）时 readFileSync(0) 会阻塞等 EOF，故跳过。
let _stdinInput = {};
if (!process.stdin.isTTY) {
  try {
    const _stdinData = fs.readFileSync(0, 'utf8'); // fd 0 = stdin
    if (_stdinData && _stdinData.trim()) _stdinInput = JSON.parse(_stdinData);
  } catch {
    // stdin 为空或非 JSON 时静默回退到 env/ppid
  }
}

// 计算本会话的状态文件路径：保证 --mark-ask 写 与 --stop 读 同一文件
SESSION_ID = resolveSessionId(_stdinInput, process.env, process.ppid);
STATE_FILE = path.join(
  process.env.TEMP || process.env.TMP || '/tmp',
  `claude-cc-ask-marker-${SESSION_ID}.json`
);

// ---- Hook 处理器 ----

// --ask: AskUserQuestion 需要输入通知（🔴）
// 配在 PreToolUse(AskUserQuestion) hook 下；PermissionRequest 在 bypassPermissions 等模式下不触发，勿用
if (process.argv.includes('--ask')) {
  const prompt = process.env.CLAUDE_PERMISSION_PROMPT || '';
  const task = process.env.CLAUDE_TASK || '';
  const cwd = getCwdName();

  sendToast([
    '🔴 Claude Code - 需要你的输入',
    task ? `任务: ${task}` : '',
    prompt ? `问题: ${prompt}` : '',
    `目录: ${cwd}`
  ]);
  process.exit(0);
}

// --mark-ask: PreToolUse Hook
// 记录 AskUserQuestion 调用的时间戳，用于 Stop 时判断场景
if (process.argv.includes('--mark-ask')) {
  const state = getState();
  state.askCount += 1;
  state.askTime = Date.now();
  state.lastCwd = getCwdName();
  writeState(state);
  process.exit(0);
}

// --stop: Stop Hook
// Claude Code 停止时调用，根据最近是否有 ask 选择通知类型
if (process.argv.includes('--stop')) {
  const state = getState();
  const now = Date.now();
  const recent = state.askTime && (now - state.askTime) < ASK_EXPIRY_MS;
  const task = process.env.CLAUDE_TASK || '';
  const cwd = getCwdName();

  if (recent) {
    clearState();
    sendToast([
      '⏳ Claude Code - 等待输入',
      task ? `任务: ${task}` : '',
      `目录: ${cwd}`
    ]);
  } else {
    clearState();
    sendToast([
      '✅ Claude Code - 任务完成',
      task ? `任务: ${task}` : '',
      `目录: ${cwd}`
    ]);
  }
  process.exit(0);
}

// ---- 默认行为（无参数时） ----
const defaultTask = process.env.CLAUDE_TASK || '';
const defaultCwd = getCwdName();
sendToast(['Claude Code', defaultTask || 'Notification', `目录: ${defaultCwd}`]);
process.exit(0);

} // end if (require.main === module)

// 导出纯函数供单元测试使用（不含 sendToast 等副作用）
module.exports = { resolveSessionId, sanitizeSessionId, buildPermissionLines };
