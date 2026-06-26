# Notification 权限确认通知 设计文档

> 日期：2026-06-26
> 状态：已批准（待 spec review）
> 关联分支：feat/windows-native

## 1. 背景与问题

当前项目的 `--ask` 通知（🔴 需要输入）只挂在 `PreToolUse(AskUserQuestion)`，仅覆盖 Claude 用 AskUserQuestion 工具主动提问的场景。

**命令权限确认走的是另一条路径**：当 Claude 要执行需批准的命令（如 `python3 …`）时，Claude Code 会弹出「This command requires approval」权限框，并触发 `Notification` 事件（`notification_type: "permission_prompt"`）。本项目未配置该事件 → **不触发 toast**。

用户在真实 Windows PowerShell 环境反馈：Claude 弹权限框等批准时，没有收到任何通知，离开屏幕就不知道 Claude 在等。

`install.ps1:356` 的注释记录了相关取舍：`--ask` 原本挂在 `PermissionRequest`，因 bypassPermissions 模式下不触发（AskUserQuestion 通知会丢）才挪到 `PreToolUse(AskUserQuestion)`——修好了 AskUserQuestion，却始终没覆盖权限确认。

## 2. 目标与非目标

**目标**
- 权限确认框出现时，发送 Windows toast 通知（与现有通知同风格，带"跳转终端"按钮）
- 零回归：现有 `--ask`（AskUserQuestion）、`--mark-ask`、`--stop`（Stop）行为完全不变

**非目标**
- 不接管 `idle_prompt` / AskUserQuestion（保持现有 `--ask` 机制，避免双重通知）
- 不改用 `PermissionRequest` 事件（存在每次权限检查都触发的已知问题 anthropics/claude-code#29212，且 `Notification` 语义更贴）

## 3. 方案概述：仅 permission_prompt（最稳）

新增一条独立通路，与现有机制并存：

- 新增 hook：`Notification` 事件，matcher = `permission_prompt`
- 新增标志：`claude-windows-toast.cjs --permission`
- 现有 `--ask` / `--mark-ask` / `--stop` 全部不动

matcher 限定 `permission_prompt` 是本方案的关键：即使 AskUserQuestion 触发了 `idle_prompt` 类通知，也不匹配本 hook，与现有 `PreToolUse(AskUserQuestion)` 互不干扰——天然规避了「AskUserQuestion 是否触发 Notification」这个官方文档未明说的不确定点。

## 4. 决策记录

| 决策 | 选项 | 理由 |
| --- | --- | --- |
| 覆盖范围 | **仅 permission_prompt**（备选：+idle_prompt / 全类型） | 零回归、与现有机制互不干扰、聚焦用户诉求；idle/auth/elicitation 留待将来 |
| 通知文案 | **中文标题 + Claude 的 message**（备选：纯固定文案 / 转发英文） | 与现有 🔴 风格一致，且包含 Claude 给的具体权限原因 |
| 标志设计 | **新增 `--permission`**（备选：复用 `--ask`） | `--ask` 读 `CLAUDE_PERMISSION_PROMPT` 环境变量（PreToolUse 语境），而 Notification 信息在 stdin JSON，输入源不同；新增避免破坏现有 `--ask` |

## 5. 详细设计

### 5.1 `src/claude-windows-toast.cjs`

**新增 `--permission` 分支**（置于 `--ask` 分支之后、`--mark-ask` 之前）：

```js
// --permission: Notification(permission_prompt) 权限确认通知（🔴）
// Claude Code 弹出"命令需要批准"框时触发；message 来自 Notification stdin
if (process.argv.includes('--permission')) {
  const message = (_stdinInput && typeof _stdinInput.message === 'string')
    ? _stdinInput.message.trim() : '';
  sendToast(buildPermissionLines(message, getCwdName()));
  process.exit(0);
}
```

**新增纯函数 `buildPermissionLines`**（供单测，加入 `module.exports`）：

```js
/**
 * 构造权限确认通知的文本行
 * @param {string} message - Notification stdin 的 message（Claude 给的权限原因）
 * @param {string} cwd - 当前目录名
 * @returns {string[]} toast 文本行（空行由 sendToast 过滤）
 */
function buildPermissionLines(message, cwd) {
  return [
    '🔴 Claude Code - 需要你的授权',
    message ? truncate(message, 150) : '',
    `目录: ${cwd}`
  ];
}
```

通知呈现：
```
🔴 Claude Code - 需要你的授权
Claude needs your permission       ← message，空则省略此行
目录: gsd-burnttoast-notify
```

文件头注释用法补一行 `--permission`。`buildPermissionLines` 与 `resolveSessionId`、`sanitizeSessionId` 一并导出。

### 5.2 `install.ps1`

两处改动：

```powershell
# 1. 迁移清理的事件范围加上 Notification（重装时清旧本项目 Notification hook）
Remove-ProjectHooks $settings @('PreToolUse', 'Notification', 'Stop')

# 2. 新增 Notification(permission_prompt) hook（exec form）
Add-HookEntry $settings 'Notification' 'permission_prompt' $hookScriptPath '--permission'
```

`Add-HookEntry` 函数本身无需修改——其 matcher 字段对 `Notification` 事件的语义是 notification_type，逻辑通用。

### 5.3 `uninstall.ps1`

**预计零改动**。其清理逻辑是 `foreach ($evt in $settings.hooks.PSObject.Properties)` 遍历**所有事件**、逐 hook 过滤含 `claude-windows-toast` 的条目，与事件名无关——新增的 `Notification` hook 会被自动清理。实现阶段确认即可。

## 6. 数据流

```
Claude 弹权限框
  └─ Claude Code 发 Notification(permission_prompt)
       └─ exec form: node claude-windows-toast.cjs --permission
            └─ stdin 注入 JSON {message, title, notification_type, session_id, ...}
                 └─ --permission 分支读 _stdinInput.message
                      └─ buildPermissionLines(...) → sendToast → exit 0
                           └─ BurntToast 弹 toast（协议就绪则带"跳转终端"按钮）
```

## 7. 错误处理与降级

| 场景 | 行为 |
| --- | --- |
| stdin 空 / 非 JSON | `_stdinInput` 回退 `{}`，message 行省略，仍发"需要授权"+目录（复用现有 `filter(l=>l)` 空行过滤） |
| BurntToast 未装 / 协议未注册 | 复用 `sendToast` 现有降级：不带按钮的纯 toast |
| node 缺失 | hook 非阻断失败（Notification 不能 block），Claude Code 仅记 hook error，不影响权限框本身 |

## 8. 测试策略

- **src 单测**：`buildPermissionLines` 纯函数——message 空/非空/超长截断、cwd 正常
- **install.ps1**：复用既有 AST 测试法（从真实 install.ps1 提取函数执行），验证：
  - `Notification(permission_prompt)` entry 正确写入
  - 与现有 `PreToolUse(AskUserQuestion)`、`Stop` 三者共存于各自事件
  - 重装幂等（Remove 清旧 + Add 加新，不重复、不误删用户 hook）
- **端到端（手工，需用户在 Windows 实环境验证）**：真实 Claude Code 触发权限框（执行需批准的命令），观察 toast 弹出。开发者环境无法触发真 toast，此环节依赖用户。

## 9. 向后兼容与迁移

- 首次安装：直接写入 `Notification(permission_prompt)` entry
- 升级重装：`Remove-ProjectHooks`（现已含 Notification 事件）清旧本项目 Notification hook，再 Add 新 → 幂等
- 老用户：`--ask` / `--mark-ask` / `--stop` 配置零影响

## 10. 待实测确认点

- `uninstall.ps1` 是否真的无需改动（实现阶段跑一次清理验证）
- 真实权限框触发时，Notification stdin 的 `message` 字段实际内容（用于确认文案截断长度 150 合理）
- 端到端 toast 在 Windows 原生 + WSL 两环境均能弹出
