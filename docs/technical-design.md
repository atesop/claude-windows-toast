# claude-windows-toast 技术设计文档

> 版本: 1.0.0 | 最后更新: 2025-06-09

---

## 1. 概述

### 1.1 项目定位

`claude-windows-toast` 是 [Claude Code](https://claude.ai/code) 的一个 Hook 扩展，运行在 WSL2 环境中，通过 Windows [BurntToast](https://github.com/Windos/BurntToast) PowerShell 模块发送系统 Toast 通知。

### 1.2 核心价值

- **不被遗忘**：Claude Code 长时间运行时，用户可以切换到其他工作，通过通知感知 Claude Code 的状态
- **一键回归**：点击通知按钮直接跳转回 Windows Terminal，无需手动切换窗口
- **零配置**：首次运行自动完成所有部署和注册

### 1.3 技术栈

| 组件 | 技术 | 说明 |
|------|------|------|
| Hook 运行时 | Node.js (CommonJS) | Claude Code Hook 标准 |
| 通知引擎 | BurntToast 1.1.0 | PowerShell Toast 模块 |
| 窗口激活 | Win32 API (user32.dll) | SetForegroundWindow 等 |
| 协议激活 | 自定义 URI Scheme | `claudewt://` → HKCU 注册表 |
| 无窗口包装 | VBScript (wscript.exe) | 避免 PowerShell 弹窗 |
| 跨系统桥接 | WSL2 ↔ Windows | 路径转换、进程调用 |

---

## 2. 架构设计

### 2.1 系统架构图

```
┌─────────────────────────────────────────────────────────────┐
│                    Claude Code (WSL2)                       │
│                                                             │
│  ┌──────────┐    触发 Hook     ┌─────────────────────────┐ │
│  │ Claude   │ ───────────────→ │ claude-windows-toast   │ │
│  │ Code CLI │                  │ .cjs                    │ │
│  └──────────┘                  │                         │ │
│                                │ 1. 状态管理              │ │
│                                │ 2. 协议自动注册           │ │
│                                │ 3. 构建通知              │ │
│                                └──────────┬──────────────┘ │ │
│                                           │                │
└───────────────────────────────────────────┼────────────────┘
                                            │ spawnSync()
                                            ▼
┌─────────────────────────────────────────────────────────────┐
│                    Windows                                   │
│                                                             │
│  ┌──────────────────────┐    Import-Module    ┌──────────┐ │
│  │ powershell.exe       │ ─────────────────→  │BurntToast│ │
│  │ (Hidden, NoProfile)  │                     │  1.1.0   │ │
│  │                      │ ←────────────────── │          │ │
│  │                      │    Toast Notification│          │ │
│  └──────────┬───────────┘                     └──────────┘ │
│             │                                               │
│             ▼                                               │
│  ┌──────────────────────┐                                  │
│  │ Windows Toast        │   用户点击 "跳转到终端"            │
│  │ Notification Center  │ ──────────────────────────┐      │
│  └──────────────────────┘                            │      │
│                                                      ▼      │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ 协议激活链: claudewt://                               │  │
│  │                                                      │  │
│  │  wscript.exe                                         │  │
│  │    └→ activate-wt.vbs (无窗口)                       │  │
│  │        └→ powershell.exe -WindowStyle Hidden         │  │
│  │            └→ activate-wt.ps1                        │  │
│  │                ├→ Add-Type (Win32 API)                │  │
│  │                ├→ Get-Process WindowsTerminal         │  │
│  │                ├→ ShowWindow(SW_RESTORE) ← 最小化?    │  │
│  │                ├→ keybd_event(VK_ALT)  ← 绕过锁定    │  │
│  │                └→ SetForegroundWindow() ← 带到前台    │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 文件部署架构

```
WSL 侧:
~/.claude/
├── hooks/
│   └── claude-windows-toast.cjs     # 主 Hook 脚本
└── settings.json                     # Hook 配置

Windows 侧:
%APPDATA%\claude-code\
├── activate-wt.ps1                   # WT 激活脚本
├── activate-wt.vbs                   # VBS 无窗口包装器
└── register-protocol.ps1             # 协议注册脚本（一次性）

HKCU 注册表:
Software\Classes\claudewt\
├── (Default) = "URL:Claude Code Terminal"
├── URL Protocol = ""
└── shell\open\command\
    └── (Default) = 'wscript.exe "...\activate-wt.vbs"'

临时文件:
/tmp/claude-cc-ask-marker-${SESSION_ID}.json    # Ask 状态（按会话隔离）
/tmp/claude-wt-protocol-setup.json              # 协议注册 marker
```

---

## 3. 核心机制详解

### 3.1 Claude Code Hook 集成

Claude Code Hooks 是一种事件驱动的扩展机制。本 Hook 注册了三个事件：

#### 3.1.1 Hook 事件映射

| 事件 | Matcher | 参数 | 功能 |
|------|---------|------|------|
| `PermissionRequest` | `AskUserQuestion` | `--ask` | 发送"需要输入"通知 |
| `PreToolUse` | `AskUserQuestion` | `--mark-ask` | 记录 ask 时间戳 |
| `Stop` | `""`（所有） | `--stop` | 发送"等待输入"或"完成"通知 |

#### 3.1.2 通知场景判断逻辑

```
Stop 事件触发
      │
      ├── 读取状态文件 (claude-cc-ask-marker-${SESSION_ID}.json)
      │
      ├── 检查 askTime
      │     │
      │     ├── 存在且距今 < 60s → "等待输入"通知
      │     │
      │     └── 不存在或距今 >= 60s → "任务完成"通知
      │
      └── 清除状态文件
```

**状态文件格式**：
```json
{
  "askCount": 3,
  "askTime": 1749456789012,
  "lastCwd": "my-project"
}
```

#### 3.1.3 环境变量

Claude Code 在触发 Hook 时提供以下环境变量：

| 变量 | 说明 | 示例 |
|------|------|------|
| `CLAUDE_TASK` | 当前任务描述 | "重构用户认证模块" |
| `CLAUDE_PERMISSION_PROMPT` | 权限提示内容 | "是否删除旧文件？" |

### 3.2 BurntToast 通知集成

#### 3.2.1 通知构建

使用 `New-BurntToastNotification` + `New-BTButton` 构建带按钮的 Toast 通知：

```powershell
Import-Module BurntToast -ErrorAction SilentlyContinue
$btn = New-BTButton -Content '跳转到终端' -Arguments 'claudewt://' -ActivationType Protocol
New-BurntToastNotification -Text '标题', '正文' -Sound Default -Button $btn
```

**关键参数**：
- `-ActivationType Protocol`：按钮点击后通过 URI 协议激活，而非 PowerShell 事件
- `-Arguments 'claudewt://'`：激活的自定义协议 URI
- `-Sound Default`：播放默认通知音

#### 3.2.2 降级策略

当协议注册失败时，自动降级为不带按钮的基础通知：

```javascript
if (protocolReady) {
  // 带按钮版本
  script = `... -Button $btn;`;
} else {
  // 基础版本
  script = `... -Sound Default;`;
}
```

#### 3.2.3 PowerShell 调用参数

```javascript
spawnSync('powershell.exe', [
  '-ExecutionPolicy', 'Bypass',    // 绕过脚本执行策略
  '-NoProfile',                    // 不加载用户配置（加速启动）
  '-WindowStyle', 'Hidden',        // 隐藏 PowerShell 窗口
  '-Command', script               // 执行的命令
], { windowsHide: true, encoding: 'utf8' });
```

### 3.3 自定义协议注册 (`claudewt://`)

#### 3.3.1 注册表结构

```
HKEY_CURRENT_USER\Software\Classes\claudewt\
├── (Default) = "URL:Claude Code Terminal"
├── URL Protocol = ""
└── shell\open\command\
    └── (Default) = 'wscript.exe "C:\...\activate-wt.vbs"'
```

**字段说明**：
- `(Default)`：协议的显示名称
- `URL Protocol`：空字符串，标记这是一个 URI 协议
- `shell\open\command\(Default)`：协议激活时执行的命令

#### 3.3.2 自动注册流程

```javascript
ensureProtocolSetup() {
  // 1. 检查 marker 文件 → 已注册则直接返回 true
  // 2. 获取 Windows APPDATA 路径
  //    → powershell.exe -Command "Write-Output $env:APPDATA"
  // 3. WSL 路径转换
  //    → C:\Users\xxx\AppData\Roaming → /mnt/c/Users/xxx/AppData/Roaming
  // 4. 部署 activate-wt.ps1（通过 Node.js fs）
  // 5. 生成 activate-wt.vbs（动态注入 PS1 路径）
  // 6. 生成 register-protocol.ps1（临时注册脚本）
  // 7. 执行注册：powershell.exe -File register-protocol.ps1
  // 8. 写入 marker 文件（避免重复注册）
}
```

**为什么用临时 PS1 文件注册？**

直接在 JavaScript 中构建 PowerShell 命令会面临 JavaScript → Shell → PowerShell 三层嵌套转义，极易出错。写入临时 PS1 文件后通过 `-File` 执行，只需处理 JavaScript → 文件内容一层转义。

### 3.4 窗口激活机制

#### 3.4.1 Win32 API 调用链

```powershell
# 1. P/Invoke 声明
Add-Type -TypeDefinition @"
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
"@

# 2. 查找 Windows Terminal 进程
$wt = Get-Process -Name WindowsTerminal | Select-Object -First 1

# 3. 激活窗口
if ($wt.MainWindowHandle -ne [IntPtr]::Zero) {
    # 3a. 如果最小化，先恢复
    if ([WinAPI]::IsIconic($hwnd)) {
        [WinAPI]::ShowWindow($hwnd, 9)  # SW_RESTORE
    }
    # 3b. 模拟 Alt 键绕过前台锁定
    [WinAPI]::keybd_event(0x12, 0, 0, ...)  # VK_ALT down
    [WinAPI]::keybd_event(0x12, 0, 2, ...)  # VK_ALT up
    # 3c. 带到前台
    [WinAPI]::SetForegroundWindow($hwnd)
    # 3d. 确保可见
    [WinAPI]::ShowWindow($hwnd, 5)  # SW_SHOW
}
```

#### 3.4.2 前台锁定限制与绕过

Windows 有一个安全机制：**只有前台进程或被前台进程启动的进程才能调用 `SetForegroundWindow` 成功**。

从协议激活的上下文来看：
- 用户点击通知 → Windows Shell 激活协议 → 启动新进程
- 这个新进程**不是**前台进程启动的，所以 `SetForegroundWindow` 可能失败

**绕过方案**：使用 `keybd_event` 模拟 Alt 键按下/释放。Windows 会认为用户正在操作键盘，临时允许前台切换。

```csharp
// VK_ALT = 0x12
keybd_event(0x12, 0, 0, UIntPtr.Zero);   // Alt down
keybd_event(0x12, 0, 2, UIntPtr.Zero);   // Alt up (KEYEVENTF_KEYUP = 2)
```

#### 3.4.3 ShowWindow 参数值

| 值 | 常量 | 含义 |
|----|------|------|
| 5 | SW_SHOW | 激活窗口并显示当前大小位置 |
| 9 | SW_RESTORE | 激活并恢复最小化窗口 |

### 3.5 VBS 无窗口包装器

#### 3.5.1 为什么需要 VBS？

直接注册 `powershell.exe -WindowStyle Hidden` 作为协议处理器存在两个问题：

1. **闪窗问题**：Windows Shell 激活协议时，`-WindowStyle Hidden` 不够可靠，可能短暂闪现 PowerShell 窗口
2. **控制台窗口**：协议激活通过 `cmd.exe` 中转，会创建控制台窗口

#### 3.5.2 VBS 包装器实现

```vbs
Set objShell = CreateObject("WScript.Shell")
objShell.Run "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File ""path\to\activate-wt.ps1""", 0, False
```

**`objShell.Run` 第二个参数 `0`**：`0 = vbHide`，完全隐藏被启动进程的窗口。这是最可靠的隐藏方式。

**注册表命令**：
```
wscript.exe "C:\...\activate-wt.vbs"
```

`wscript.exe` 是 Windows Script Host 的 GUI 版本，默认不创建控制台窗口。

---

## 4. 跨系统交互

### 4.1 WSL → Windows 路径转换

```javascript
// Windows: C:\Users\Administrator\AppData\Roaming
// WSL:     /mnt/c/Users/Administrator/AppData/Roaming

const drive = winPath[0].toLowerCase();         // 'c'
const relPath = winPath.substring(3).replace(/\\/g, '/');
const wslPath = `/mnt/${drive}/${relPath}`;
```

### 4.2 进程调用链

```
Node.js (WSL)                    Windows
─────────────                    ──────
spawnSync('powershell.exe', ...)
        │
        └────→ powershell.exe
                    │
                    ├── Import-Module BurntToast
                    ├── New-BTButton
                    └── New-BurntToastNotification
                              │
                              └──→ Windows Toast Notification
```

### 4.3 注意事项

1. **WSL 路径互操作**：`powershell.exe` 可以从 WSL 直接调用（`/mnt/c/...` 路径自动转换）
2. **文件系统访问**：WSL 可以直接读写 Windows 文件系统（`/mnt/c/...`），用于部署脚本
3. **进程可见性**：WSL 中 `spawnSync` 启动的 Windows 进程与直接在 Windows 中启动的行为一致

---

## 5. 安全性设计

### 5.1 注册表范围

- 仅修改 `HKCU\Software\Classes\`（当前用户），**不需要管理员权限**
- 不影响系统全局设置
- 其他用户的 Windows 会话不受影响

### 5.2 脚本执行

- 所有 PowerShell 调用使用 `-ExecutionPolicy Bypass` 仅作用于当前进程
- `-NoProfile` 避免加载用户配置文件中的潜在恶意代码
- 激活脚本使用 `$ErrorActionPreference = 'SilentlyContinue'` 避免敏感信息泄露

### 5.3 协议安全

- `claudewt://` 协议仅激活 Windows Terminal，不执行任意命令
- 协议处理器路径固定为已部署的脚本，不接收外部参数
- VBS 包装器硬编码 PS1 脚本路径

---

## 6. 错误处理与降级

### 6.1 降级层级

```
Level 0: 完整功能
  ├── Toast 通知 + 跳转按钮
  └── 协议注册成功

Level 1: 基础通知
  ├── Toast 通知（无按钮）
  └── 协议注册失败（降级）

Level 2: 静默失败
  ├── 无通知
  └── BurntToast 模块未安装
```

### 6.2 错误场景处理

| 场景 | 处理方式 |
|------|---------|
| BurntToast 未安装 | `Import-Module -ErrorAction SilentlyContinue` → 静默失败 |
| APPDATA 路径获取失败 | `protocolReady = false` → 发送基础通知 |
| 目录创建失败 | `return false` → 降级 |
| 注册表写入失败 | `regResult.status !== 0` → 降级 |
| VBS 生成失败 | `return false` → 降级 |
| 状态文件损坏 | `JSON.parse` 异常 → 返回默认状态 |

---

## 7. 性能考量

### 7.1 开销分析

| 操作 | 耗时 | 频率 |
|------|------|------|
| Marker 文件检查 | < 1ms | 每次触发 |
| 协议自动注册 | ~500ms | 仅首次 |
| 部署激活脚本 | ~50ms | 仅首次 |
| 发送 Toast 通知 | ~300ms | 每次触发 |
| PowerShell 启动 | ~200ms | 每次触发 |

### 7.2 优化措施

1. **Marker 文件 + 24h TTL**：避免每次触发都执行注册检查；注册表校验有 24 小时缓存（marker 未过期时只查文件存在、跳过 PowerShell 查询），避免高频 hook（如 `--mark-ask`）的额外开销
2. **`-NoProfile`**：跳过 PowerShell 配置文件加载，节省 ~100ms
3. **`spawnSync`**：同步执行，Hook 完成后 Claude Code 才继续
4. **`windowsHide: true`**：减少窗口创建开销

---

## 8. 兼容性

### 8.1 支持环境

| 环境 | 版本 | 状态 |
|------|------|------|
| Windows 10 | 1903+ | ✅ 支持（Toast 通知 API） |
| Windows 11 | 全版本 | ✅ 支持 |
| PowerShell | 5.1+ | ✅ 支持 |
| BurntToast | 1.0+ | ✅ 支持 |
| Node.js | 12+ | ✅ 支持 |
| WSL2 | Ubuntu 22.04+ | ✅ 测试通过 |

### 8.2 已知限制

1. **窗口/Tab 级别定位**：只能激活第一个枚举到的 WindowsTerminal 进程，无法定位到具体窗口或 Tab
   - 多个 WT 窗口时，可能激活到非 Claude Code 所在的窗口（best-effort）
   - 单窗口多 Tab 时，会激活窗口但不保证选中 Claude Code 所在的 Tab
2. **前台锁定**：某些极端场景下 `keybd_event` 绕过可能失效
3. **远程桌面**：通过 RDP 连接时，`SetForegroundWindow` 行为可能不同
4. **BurntToast 1.1.0**：不支持 `New-BurntToastButton`（较新的简化 API），需使用 `New-BTButton`

---

## 9. 未来优化方向

| 方向 | 描述 | 难度 |
|------|------|------|
| Tab 级定位 | 通过 WT 的 `focus-tab` 命令或 IPC 定位到具体 Tab | 中 |
| 通知正文点击 | 使用 `New-BTContent -Launch` 设置正文点击行为 | 低 |
| 配置化 | 允许用户自定义通知文本、按钮名称、声音等 | 低 |
| 多终端支持 | 支持 ConEmu、Fluent Terminal 等其他终端 | 中 |
| 纯 Windows 原生 | 使用 C# 或 Rust 编写激活工具，避免 PowerShell 启动开销 | 高 |
