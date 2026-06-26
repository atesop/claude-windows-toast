# Notification 权限确认通知 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: 用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 按任务逐个实现本计划。步骤用 `- [ ]` 复选框跟踪。

**Goal:** 新增 `Notification(permission_prompt)` hook，让 Claude Code 弹出命令权限确认框时发送 Windows toast 通知。

**Architecture:** 新增 `--permission` 标志分支，从 Notification stdin 读 `message` 构造通知行；install.ps1 追加一条 `Notification(permission_prompt)` exec-form hook；现有 `--ask`/`--mark-ask`/`--stop` 完全不动，零回归。

**Tech Stack:** Node.js（CommonJS .cjs，无框架，原生 assert 测试）、PowerShell 5.1（install.ps1/uninstall.ps1，exec-form hooks）、BurntToast（Windows toast）。

## Global Constraints

- **语言**：文档与代码注释用中文，标识符（变量/函数名）用英文（CLAUDE.md 语言规范）。
- **Node 测试约定**：放 `tests/test-{topic}.cjs`，用原生 `assert` + 自定义 `check(name, fn)` helper，`node tests/xxx.cjs` 直跑，末尾打印通过数。新测试照此风格。
- **PowerShell 测试约定**：测试脚本纯 ASCII（PS 5.1 用系统 GBK 读无 BOM 的 UTF-8 会破坏中文字符串解析）；用 `[System.Management.Automation.Language.Parser]` 从真实 install.ps1 提取函数执行，测的是磁盘真实代码。
- **hook 形态**：保持 exec form（`command:"node"` + `args:[脚本绝对路径, 标志]`），与 #1 修复一致。
- **零回归**：不动现有 `--ask`、`--mark-ask`、`--stop` 三个分支及其 install/uninstall 配置逻辑。
- **依赖不变**：不新增 npm/PS 模块依赖；toast 降级复用现有 `sendToast`（BurntToast 缺失或协议未注册时自动降级为无按钮通知）。

---

## File Structure

| 文件 | 改动 | 责任 |
| --- | --- | --- |
| `src/claude-windows-toast.cjs` | Modify | 新增纯函数 `buildPermissionLines(message, cwd)` + `--permission` 分支 + 加入 `module.exports` + 文件头注释 |
| `install.ps1` | Modify | `Remove-ProjectHooks` 事件范围加 `Notification`；新增 `Add-HookEntry 'Notification' 'permission_prompt'` |
| `uninstall.ps1` | 预计不改 | 清理逻辑是事件无关的通用逐 hook 遍历，Notification hook 会被自动清理；Task 3 审查确认 |
| `tests/test-permission-lines.cjs` | Create | `buildPermissionLines` 单测（空/非空/null/超长截断/行数） |
| `tests/test-install-hooks.ps1` | Create | install 的 AST 测试：Notification entry 写入正确、三事件共存、重装幂等 |

---

### Task 1: src 新增 `buildPermissionLines` 纯函数（TDD）

**Files:**
- Create: `tests/test-permission-lines.cjs`
- Modify: `src/claude-windows-toast.cjs`（在 `sendToast` 函数定义之前插入新函数；改 `module.exports`）

**Interfaces:**
- Consumes: 现有 `truncate(s, maxLen)`（src 第 124 行，超长返回 `s.substring(0,maxLen)+'...'`）
- Produces: `buildPermissionLines(message: string, cwd: string): string[]` —— 恒返回 3 元素数组：`['🔴 Claude Code - 需要你的授权', message截断或'', '目录: {cwd}']`；空行由 `sendToast` 的 `filter(l=>l)` 过滤

- [ ] **Step 1: 写失败测试**

Create `tests/test-permission-lines.cjs`：

```js
// tests/test-permission-lines.cjs
// 验证 buildPermissionLines：构造 Notification(permission_prompt) 权限确认通知的文本行
//
// 运行：node tests/test-permission-lines.cjs

const assert = require('assert');
const { buildPermissionLines } = require('../src/claude-windows-toast.cjs');

let passed = 0;
function check(name, fn) { fn(); passed++; console.log('  ✓ ' + name); }

console.log('test-permission-lines: buildPermissionLines');

check('非空 message：标题 + message + 目录 三行', () => {
  const lines = buildPermissionLines('Claude needs your permission', 'myproj');
  assert.strictEqual(lines[0], '🔴 Claude Code - 需要你的授权');
  assert.strictEqual(lines[1], 'Claude needs your permission');
  assert.strictEqual(lines[2], '目录: myproj');
});

check('空 message：message 行为空字符串（由 sendToast 过滤）', () => {
  const lines = buildPermissionLines('', 'myproj');
  assert.strictEqual(lines[0], '🔴 Claude Code - 需要你的授权');
  assert.strictEqual(lines[1], '');
  assert.strictEqual(lines[2], '目录: myproj');
});

check('null/undefined message 视为空', () => {
  assert.strictEqual(buildPermissionLines(null, 'p')[1], '');
  assert.strictEqual(buildPermissionLines(undefined, 'p')[1], '');
});

check('前后空白 message 被 trim 为空', () => {
  assert.strictEqual(buildPermissionLines('   ', 'p')[1], '');
});

check('超长 message 截断到 150 字符 + ...', () => {
  const long = 'x'.repeat(200);
  const line = buildPermissionLines(long, 'p')[1];
  assert.strictEqual(line.length, 153); // 150 + '...'
  assert.ok(line.endsWith('...'));
});

check('行数恒为 3', () => {
  assert.strictEqual(buildPermissionLines('m', 'c').length, 3);
  assert.strictEqual(buildPermissionLines('', 'c').length, 3);
});

console.log('\n✅ 全部 ' + passed + ' 个用例通过');
```

- [ ] **Step 2: 跑测试确认失败**

Run: `node tests/test-permission-lines.cjs`
Expected: FAIL —— `TypeError: buildPermissionLines is not a function`（尚未导出）

- [ ] **Step 3: 实现 `buildPermissionLines` 并导出**

在 `src/claude-windows-toast.cjs` 的 `// ---- Toast 通知 ----` 区、`sendToast` 函数定义之前插入：

```js
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
```

改文件末尾的 `module.exports`（原行：`module.exports = { resolveSessionId, sanitizeSessionId };`）：

```js
// 导出纯函数供单元测试使用（不含 sendToast 等副作用）
module.exports = { resolveSessionId, sanitizeSessionId, buildPermissionLines };
```

- [ ] **Step 4: 跑测试确认通过**

Run: `node tests/test-permission-lines.cjs`
Expected: PASS —— `✅ 全部 6 个用例通过`

- [ ] **Step 5: 跑现有测试确认无回归**

Run: `node tests/test-session-id.cjs`
Expected: PASS（原有用例全过，证明 `module.exports` 改动未破坏现有导出）

- [ ] **Step 6: Commit**

```bash
git add tests/test-permission-lines.cjs src/claude-windows-toast.cjs
git commit -m "feat(toast): 新增 buildPermissionLines 纯函数（权限确认通知文本构造）

为 Notification(permission_prompt) 事件准备通知文本构造逻辑，
纯函数 + 单测覆盖空/非空/null/截断/行数。"
```

---

### Task 2: src 新增 `--permission` 分支（接线 + 文件头注释）

**Files:**
- Modify: `src/claude-windows-toast.cjs`（文件头注释 + 新增 `--permission` 分支）

**Interfaces:**
- Consumes: Task 1 的 `buildPermissionLines`、现有 `sendToast(lines)`、现有 `_stdinInput`（已解析的 stdin JSON）、现有 `getCwdName()`
- Produces: `node claude-windows-toast.cjs --permission` 入口——读 stdin `message`，发 toast，`exit(0)`

- [ ] **Step 1: 文件头注释补 `--permission` 用法**

在 `src/claude-windows-toast.cjs` 文件头注释的用法区（`--stop` 那行之后）追加一行：

```js
//   node claude-windows-toast.cjs --permission # 🔴 权限确认通知(配 Notification:permission_prompt)
```

- [ ] **Step 2: 新增 `--permission` 分支**

在 `--ask` 分支（`if (process.argv.includes('--ask')) { ... }`）之后、`--mark-ask` 分支之前插入：

```js
// --permission: Notification(permission_prompt) 权限确认通知（🔴）
// Claude Code 弹出"命令需要批准"权限框时触发；message 来自 Notification stdin。
// 仅匹配 permission_prompt（不覆盖 idle_prompt），与现有 PreToolUse(AskUserQuestion) 互不干扰。
if (process.argv.includes('--permission')) {
  const message = (_stdinInput && typeof _stdinInput.message === 'string')
    ? _stdinInput.message : '';
  sendToast(buildPermissionLines(message, getCwdName()));
  process.exit(0);
}
```

- [ ] **Step 3: 手工验证接线不崩溃**

Run:
```bash
echo '{"message":"Claude needs your permission","notification_type":"permission_prompt","session_id":"test-1"}' | node src/claude-windows-toast.cjs --permission; echo "exit=$?"
```
Expected: `exit=0`（WSL 下会 spawn powershell.exe 调 BurntToast；模块未装时 sendToast 内部 debugLog 失败但不抛异常，进程仍 exit 0）。通知文本构造由 Task 1 单测保证，此处只验证分支接线与 stdin 读取不崩溃。

- [ ] **Step 4: 跑全部 Node 测试确认无回归**

Run: `node tests/test-session-id.cjs && node tests/test-permission-lines.cjs`
Expected: 两个文件均 PASS

- [ ] **Step 5: Commit**

```bash
git add src/claude-windows-toast.cjs
git commit -m "feat(toast): 新增 --permission 分支处理 Notification(permission_prompt)

权限确认框出现时发 🔴 通知；message 取自 Notification stdin。
现有 --ask/--mark-ask/--stop 不动。"
```

---

### Task 3: install.ps1 新增 Notification hook 配置 + uninstall 审查

**Files:**
- Create: `tests/test-install-hooks.ps1`
- Modify: `install.ps1`（`Remove-ProjectHooks` 事件范围 + 新增 `Add-HookEntry` 调用）
- Review: `uninstall.ps1`（预计不改，审查确认）

**Interfaces:**
- Consumes: install 现有 `Remove-ProjectHooks($Settings, $EventNames)`、`Add-HookEntry($Settings, $EventName, $Matcher, $ScriptPath, $Flag)`、`$hookScriptPath`（install 内已算出的脚本绝对路径）、`$settings`（已解析对象）—— 均已存在，本任务只改调用
- Produces: settings.json 多出 `Notification[permission_prompt]` entry，与 `PreToolUse[AskUserQuestion]`、`Stop` 三者共存

- [ ] **Step 1: 写 AST 测试（Part A 函数行为 + Part B 源码含调用）**

Create `tests/test-install-hooks.ps1`（**纯 ASCII**，PS 5.1 编码要求）：

```powershell
# tests/test-install-hooks.ps1
# Verify install.ps1 configures Notification(permission_prompt) hook.
# Part A: behavior of Add-HookEntry/Remove-ProjectHooks on Notification event
#         (functions extracted from REAL install.ps1 via AST)
# Part B: install.ps1 source actually contains the Notification calls (TDD closure)
#
# Run: powershell.exe -ExecutionPolicy Bypass -NoProfile -File tests\test-install-hooks.ps1

$ErrorActionPreference = 'Stop'
$installPath = Join-Path $PSScriptRoot '..\install.ps1'
$src = Get-Content -Raw $installPath
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { Write-Host 'PARSE ERRORS'; $errors | ForEach-Object { Write-Host "  $_" }; exit 2 }

# Stub helpers that Add-HookEntry calls internally
function Write-Info($m) {}
function Write-Ok($m) {}

foreach ($fn in 'Remove-ProjectHooks', 'Add-HookEntry') {
    $fa = $ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fn
    }, $true) | Select-Object -First 1
    if (-not $fa) { Write-Host "$fn not found"; exit 2 }
    . ([scriptblock]::Create($fa.ToString()))
}

$pass = 0; $fail = 0
function Check($n, $c) {
    if ($c) { Write-Host "  [PASS] $n" -ForegroundColor Green; $script:pass++ }
    else    { Write-Host "  [FAIL] $n" -ForegroundColor Red;   $script:fail++ }
}

$cjs = '/home/u/.claude/hooks/claude-windows-toast.cjs'

Write-Host 'Part A: hook functions on Notification event'
$s = [PSCustomObject]@{ hooks = [PSCustomObject]@{} }
Remove-ProjectHooks $s @('PreToolUse', 'Notification', 'Stop')
Add-HookEntry $s 'PreToolUse' 'AskUserQuestion' $cjs '--mark-ask'
Add-HookEntry $s 'PreToolUse' 'AskUserQuestion' $cjs '--ask'
Add-HookEntry $s 'Notification' 'permission_prompt' $cjs '--permission'
Add-HookEntry $s 'Stop' '' $cjs '--stop'

$notif = @($s.hooks.Notification)
Check 'A1 Notification event exists (1 entry)' ($notif.Count -eq 1)
Check 'A2 Notification matcher = permission_prompt' ("$($notif[0].matcher)" -eq 'permission_prompt')
$nh = @($notif[0].hooks)
Check 'A3 Notification hook command = node' ("$($nh[0].command)" -eq 'node')
Check 'A4 Notification hook args = [cjs, --permission]' ("$($nh[0].args[0])" -eq $cjs -and "$($nh[0].args[1])" -eq '--permission')
Check 'A5 PreToolUse coexists' ($null -ne $s.hooks.PSObject.Properties['PreToolUse'])
Check 'A6 Stop coexists' ($null -ne $s.hooks.PSObject.Properties['Stop'])

Remove-ProjectHooks $s @('PreToolUse', 'Notification', 'Stop')
Add-HookEntry $s 'Notification' 'permission_prompt' $cjs '--permission'
$notif2 = @($s.hooks.Notification)
Check 'A7 reinstall: Notification entry still 1 (idempotent)' ($notif2.Count -eq 1)
Check 'A8 reinstall: hook count still 1' (@($notif2[0].hooks).Count -eq 1)

Write-Host 'Part B: install.ps1 source contains Notification config'
Check 'B1 Add-HookEntry Notification permission_prompt call present' ($src -match "Add-HookEntry.*'Notification'.*'permission_prompt'.*'--permission'")
Check 'B2 Remove-ProjectHooks scope includes Notification' ($src -match "Remove-ProjectHooks.*'Notification'")

Write-Host ''
Write-Host "TOTAL: PASS=$pass FAIL=$fail"
if ($fail -gt 0) { exit 1 } else { exit 0 }
```

- [ ] **Step 2: 跑测试，确认 Part A 通过、Part B 失败（install 尚未加 Notification 调用）**

Run（WSL 下用 Windows 路径）:
```bash
powershell.exe -ExecutionPolicy Bypass -NoProfile -File 'D:\tools\gsd-burnttoast-notify\tests\test-install-hooks.ps1'
```
Expected: A1-A8 全 PASS；B1、B2 FAIL → `TOTAL: PASS=8 FAIL=2`、exit=1

- [ ] **Step 3: 改 install.ps1 —— 两处**

3a. 把 `Remove-ProjectHooks $settings @('PreToolUse','Stop')` 改为：

```powershell
Remove-ProjectHooks $settings @('PreToolUse','Notification','Stop')
```

3b. 在 `Add-HookEntry $settings 'Stop' '' $hookScriptPath '--stop'` 之后追加一行：

```powershell
# Notification(permission_prompt)：命令权限确认框出现时发 🔴 通知（补 AskUserQuestion 未覆盖的权限场景）
Add-HookEntry $settings 'Notification' 'permission_prompt' $hookScriptPath '--permission'
```

- [ ] **Step 4: 跑测试确认全通过**

Run:
```bash
powershell.exe -ExecutionPolicy Bypass -NoProfile -File 'D:\tools\gsd-burnttoast-notify\tests\test-install-hooks.ps1'
```
Expected: `TOTAL: PASS=10 FAIL=0`、exit=0

- [ ] **Step 5: 审查 uninstall.ps1 确认无需改动**

读 `uninstall.ps1` 的 settings 清理段（`foreach ($evt in $settings.hooks.PSObject.Properties)` 区块），确认：
- 遍历**所有事件节点**（非硬编码事件名）
- 逐 hook 过滤含 `claude-windows-toast` 的条目（command 或 args 命中 marker）
- 因此本项目 `Notification[permission_prompt]` hook 会被自动清理，**无需改动**

若确认事件无关 → 记录结论，跳过 commit；若发现需改 → 补改动并加单独 commit。**预期结论：零改动。**

- [ ] **Step 6: 跑 Node 测试确认无回归**

Run: `node tests/test-session-id.cjs && node tests/test-permission-lines.cjs`
Expected: 均全通过

- [ ] **Step 7: Commit（install.ps1 + 测试脚本）**

```bash
git add install.ps1 tests/test-install-hooks.ps1
git commit -m "feat(install): 新增 Notification(permission_prompt) hook 配置

权限确认框出现时触发 --permission 通知，补齐 AskUserQuestion 未覆盖的
命令授权场景。Remove-ProjectHooks 范围加 Notification 保证重装幂等。
uninstall 清理逻辑事件无关，无需改动。"
```

---

## 端到端手工验证（实现完成后，需用户在 Windows 实环境执行）

自动化测试覆盖不到真实 toast 弹出。三个 task 完成后，用户在 Windows（WSL 或原生）实环境验证：

1. 重装 hook：`powershell.exe -ExecutionPolicy Bypass -File install.ps1`（或 `-Target Windows`）
2. 用 Claude Code 执行一条需批准的命令（如未加入白名单的 `python3 -V`）
3. 权限框弹出时，观察是否收到 🔴 toast「Claude Code - 需要你的授权 / Claude needs your permission / 目录: ...」
4. 点 toast「跳转终端」按钮，确认能切回 Windows Terminal

---

## Self-Review

**1. Spec 覆盖**（对照 `2026-06-26-notification-permission-design.md`）
- §5.1 src `buildPermissionLines` + `--permission` + 注释 → Task 1 + Task 2 ✓
- §5.2 install 两处改动 → Task 3 Step 3 ✓
- §5.3 uninstall 预计零改动 → Task 3 Step 5 审查 ✓
- §6 数据流 → Task 2 Step 3 + 端到端验证 ✓
- §7 错误处理（空 message / sendToast 降级）→ Task 1 空 message 用例 + 复用现有 sendToast ✓
- §8 测试策略（单测 / AST 测试 / 端到端）→ Task 1 / Task 3 / 端到段落 ✓
- §9 向后兼容（重装幂等）→ Task 3 A7-A8 ✓
- §10 待实测（uninstall / message 内容 / 真实 toast）→ Task 3 Step 5 / 端到段落 ✓
- 无遗漏节。

**2. 占位符扫描**：无 TBD/TODO；每个 Step 含完整代码、精确命令、预期输出。

**3. 类型/命名一致性**：
- `buildPermissionLines(message: string, cwd: string): string[]` —— Task 1 定义、Task 2 调用一致
- `--permission` 标志、`'Notification'` 事件、`'permission_prompt'` matcher、`$hookScriptPath` 变量跨 Task 2/3 一致
- `module.exports` 增量导出 `buildPermissionLines`，与现有 `resolveSessionId/sanitizeSessionId` 共存一致

无问题，无需 inline 修复。

