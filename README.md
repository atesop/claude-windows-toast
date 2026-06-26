<div align="center">

# 🔔 claude-windows-toast

**Claude Code Windows Toast 通知 Hook**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: WSL](https://img.shields.io/badge/Platform-WSL2-blue.svg)]()
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1+-green.svg)]()

[English](#english) · [中文](#中文)

</div>

---

<a id="中文"></a>

## 📖 简介

`claude-windows-toast` 是一个 [Claude Code](https://claude.ai/code) Hook，通过 Windows [BurntToast](https://github.com/Windos/BurntToast) 模块发送 Toast 通知，**并支持点击通知一键跳转回 Windows Terminal**。

### ✨ 核心功能

| 功能 | 描述 |
|------|------|
| 🔔 智能通知 | 四种场景：需要输入 / 权限确认 / 等待输入 / 任务完成 |
| 🖱️ 点击跳转 | 点击通知按钮直接回到 Windows Terminal |
| 🔄 自动部署 | 首次运行自动注册协议、部署脚本 |
| 🛡️ 降级兼容 | 协议注册失败时仍发送基础通知 |
| 📡 协议激活 | `claudewt://` 自定义协议 + VBS 无窗口包装 |

### 📸 通知效果

```
┌──────────────────────────────────────┐
│ 🔴 Claude Code - 需要你的输入         │
│ 任务: 重构用户认证模块                 │
│ 问题: 是否删除旧的 session 表?         │
│ 目录: my-project                      │
│                                      │
│                      [跳转到终端]      │
└──────────────────────────────────────┘
```

---

## 📋 前置要求

| 依赖 | 版本 | 说明 |
|------|------|------|
| [Claude Code](https://claude.ai/code) | 最新版 | CLI 工具 |
| [Node.js](https://nodejs.org/) | 12+ | **必须装在 Claude Code 所在系统**：WSL 用户装 WSL 内的 Node，Windows 原生用户装 Windows 版 Node（`node.exe` 在 PATH） |
| [BurntToast](https://github.com/Windos/BurntToast) | 1.0+ | PowerShell Toast 模块（装在 Windows 侧） |
| Windows Terminal | 最新版 | 终端（跳转目标） |
| WSL2 | - | **可选**。仅在 WSL 里跑 Claude Code 时需要 |

> 💡 **两种环境任选其一**：Claude Code 可跑在 **WSL** 里，也可跑在 **Windows 原生**（PowerShell/CMD）。本工具两种都支持，安装时选择对应环境即可。

### 安装 BurntToast

```powershell
# 以管理员身份运行 PowerShell
Install-Module -Name BurntToast -Force -Scope CurrentUser
```

---

## 🚀 安装

### 方式一：自动安装（推荐）

```powershell
# 克隆仓库
git clone https://github.com/atesop/claude-windows-toast.git
cd claude-windows-toast

# 运行安装脚本（会询问 Claude Code 跑在 WSL 还是 Windows 原生）
powershell -ExecutionPolicy Bypass -File install.ps1
```

也可用 `-Target` 参数跳过询问（自动化场景）：

```powershell
# Claude Code 跑在 WSL
powershell -ExecutionPolicy Bypass -File install.ps1 -Target Wsl

# Claude Code 跑在 Windows 原生
powershell -ExecutionPolicy Bypass -File install.ps1 -Target Windows
```

> 安装脚本会按所选环境把 hook 部署到对应位置（WSL 的 `~/.claude/` 或 Windows 的 `%USERPROFILE%\.claude\`），并把绝对路径写进 settings.json。

### 方式二：手动安装

1. **部署 Hook 脚本**

WSL（bash）：
```bash
mkdir -p ~/.claude/hooks
cp src/claude-windows-toast.cjs ~/.claude/hooks/
```

Windows 原生（PowerShell）：
```powershell
$hooksDir = "$env:USERPROFILE\.claude\hooks"
New-Item -Path $hooksDir -ItemType Directory -Force | Out-Null
Copy-Item src\claude-windows-toast.cjs $hooksDir -Force
```

2. **配置 settings.json**

编辑 settings.json（WSL 的 `~/.claude/settings.json` 或 Windows 的 `%USERPROFILE%\.claude\settings.json`），添加以下 hooks 配置。

> 用 **exec form**（`command` + `args`）+ **绝对路径**，不依赖 `$HOME` 展开，在 WSL（`sh`）与 Windows 原生（Git Bash / PowerShell）下都可靠。把 `<HOOK路径>` 替换为实际绝对路径：
> - WSL：`/home/<用户名>/.claude/hooks/claude-windows-toast.cjs`
> - Windows 原生：`C:\\Users\\<用户名>\\.claude\\hooks\\claude-windows-toast.cjs`

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "AskUserQuestion",
        "hooks": [
          { "type": "command", "command": "node", "args": ["<HOOK路径>", "--mark-ask"] },
          { "type": "command", "command": "node", "args": ["<HOOK路径>", "--ask"] }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "node", "args": ["<HOOK路径>", "--stop"] }
        ]
      }
    ]
  }
}
```

3. **首次运行自动部署**

首次触发通知时，Hook 会自动完成：
- 部署激活脚本到 `%APPDATA%\claude-code\`
- 注册 `claudewt://` 自定义协议
- 生成 VBS 无窗口包装器

---

## 🔧 卸载

```powershell
powershell -ExecutionPolicy Bypass -File uninstall.ps1
```

或手动清理：

```powershell
# 删除协议注册
Remove-Item -Path 'HKCU:\Software\Classes\claudewt' -Recurse -Force

# 删除部署文件（只删本项目文件，避免误删 claude-code 目录下其他工具的文件）
$dir = "$env:APPDATA\claude-code"
Remove-Item "$dir\activate-wt.ps1", "$dir\activate-wt.vbs", "$dir\register-protocol.ps1", "$dir\activate-wt-debug.log" -Force -ErrorAction SilentlyContinue
if (-not (Get-ChildItem $dir -ErrorAction SilentlyContinue)) { Remove-Item $dir -Force -ErrorAction SilentlyContinue }

# 删除 Hook 脚本
# rm ~/.claude/hooks/claude-windows-toast.cjs
```

---

## ⚙️ 工作原理

### 通知触发流程

```
Claude Code 触发 Hook
         │
         ├── PreToolUse (AskUserQuestion) ──→ 🔴 需要输入通知 + 📝 记录 ask 时间戳
         │
         └── Stop ──→ 检查最近 60s 内是否有 ask？
                              │
                              ├── 是 ──→ ⏳ 等待输入通知
                              └── 否 ──→ ✅ 任务完成通知
```

### 点击跳转流程

```
用户点击 "跳转到终端" 按钮
         │
         ▼
Windows 激活 claudewt:// 协议
         │
         ▼
wscript.exe 运行 activate-wt.vbs (无窗口)
         │
         ▼
PowerShell 执行 activate-wt.ps1 (隐藏窗口)
         │
         ▼
Win32 API 激活 Windows Terminal 窗口
  ├── ShowWindow(SW_RESTORE)  ← 如果最小化
  ├── keybd_event(VK_ALT)     ← 绕过前台锁定
  └── SetForegroundWindow()   ← 带到前台
```

> 📖 详细技术文档见 [docs/technical-design.md](docs/technical-design.md)

---

## 🧪 测试

### 四种通知的触发方式

| 通知 | 含义 | 触发方式 | 对应 Hook |
|------|------|---------|-----------|
| 🔴 需要你的输入 | Claude **正在问**你 | Claude 调用 `AskUserQuestion` | PreToolUse(AskUserQuestion) → `--ask` |
| 🔴 需要你的授权 | Claude **等批准命令** | Claude Code 弹出命令权限确认框 | Notification(permission_prompt) → `--permission` |
| ⏳ 等待输入 | Claude **等你回答** | 上面那次提问所在回合结束 | Stop → `--stop`（读到最近 `askTime`） |
| ✅ 任务完成 | Claude **干完活了** | 普通回合结束（60s 内无 ask） | Stop → `--stop`（无最近 `askTime`） |

### ⚠️ 红色通知不能用手动 `--ask` 测

手动跑一条：

```bash
node src/claude-windows-toast.cjs --ask
```

确实会弹出红色 🔴 通知，但**会被紧接着的 Stop Hook 绿色「任务完成」覆盖**，表现为收到绿色 ✅ 而非红色。原因：

- `--ask` 只负责**发通知**，**不写 `askTime` 状态**（写状态的是另一个独立 Hook `--mark-ask`）。
- Stop Hook 靠 `askTime` 判断场景：60 秒内（`ASK_EXPIRY_MS`）有 ask → ⏳，否则 → ✅。
- 手动 `--ask` 没写 `askTime`，所以回复一结束，Stop Hook 读不到 ask，就发绿色 ✅ 把红色盖掉。

**正确测法**：让 Claude 真实调用一次 `AskUserQuestion`（例如问一个需要你确认的问题）。此时 PreToolUse 会**同时**跑 `--mark-ask`（写 `askTime`）和 `--ask`（发红色），随后回合结束触发 Stop Hook，读到 `askTime` 就发 ⏳「等待输入」而非绿色 ✅。这样 🔴 → ⏳ 两条通知都能正确送达。

> 💡 一句话区分四种通知：🔴（输入）= Claude **正在问**你；🔴（授权）= Claude **等批准命令**；⏳ = Claude **等你回答**；✅ = Claude **干完活了**。

---

## 🗂️ 项目结构

```
claude-windows-toast/
├── README.md                        # 项目说明（本文件）
├── LICENSE                          # MIT 许可证
├── CHANGELOG.md                     # 变更日志
├── install.ps1                      # 安装脚本
├── uninstall.ps1                    # 卸载脚本
├── src/
│   ├── claude-windows-toast.cjs    # 主 Hook 脚本
│   └── activate-wt.ps1              # WT 激活脚本模板
└── docs/
    └── technical-design.md          # 技术设计文档
```

---

## ❓ 常见问题

### 通知没有显示？

1. 确认 BurntToast 已安装：`Get-Module BurntToast -ListAvailable`
2. 确认 Windows 通知权限已开启
3. 检查 PowerShell 执行策略：`Get-ExecutionPolicy`

### 点击按钮没有跳转？

1. 检查协议是否注册：`Test-Path 'HKCU:\Software\Classes\claudewt'`
2. 重新运行安装脚本
3. 手动测试：在运行对话框（Win+R）输入 `claudewt://`

### 点击按钮偶尔没反应，或首次点击偏慢？

属 Windows 前台锁定（anti-focus-stealing）的已知现象，并非脚本故障：

1. **首次偏慢**：协议链路（`claudewt://` → wscript → PowerShell → 激活脚本）冷启动需短暂组装，首次触发可能延迟 1~2 秒或无反应，之后会明显变快
2. **偶发失败**：当前前台是一个活跃窗口（如正在弹消息的微信）时，Windows 可能拒绝置前请求，表现为任务栏图标闪烁而窗口没有真正置前
3. **解决**：再点一次通知按钮即可，或直接 Alt+Tab 切回；终端最小化等典型场景下实测成功率接近 100%

### 开了多个 Windows Terminal 窗口时会跳到错的窗口？

会。激活脚本只能定位到第一个枚举到的 WindowsTerminal 进程，无法识别 Claude Code 实际所在的窗口或标签页。若同时开了多个 WT 窗口，点击通知可能把另一个窗口带到前台。这是当前的 best-effort 限制；临时办法是只保留一个 WT 窗口，或点击后用 Alt+Tab 切到正确窗口。

### 弹出了 PowerShell 窗口？

这是 VBS 包装器未正确部署的表现。手动修复：

```powershell
# 检查 VBS 文件是否存在
Test-Path "$env:APPDATA\claude-code\activate-wt.vbs"

# 检查注册表是否指向 wscript.exe
Get-ItemProperty 'HKCU:\Software\Classes\claudewt\shell\open\command'
```

---

## 🤝 贡献

欢迎贡献！请提交 Issue 或 Pull Request。

## 📄 许可证

[MIT License](LICENSE)

---

<a id="english"></a>

## 📖 Introduction

`claude-windows-toast` is a [Claude Code](https://claude.ai/code) Hook that sends Windows Toast notifications via the [BurntToast](https://github.com/Windos/BurntToast) PowerShell module, **with click-to-navigate back to Windows Terminal**.

### ✨ Features

| Feature | Description |
|---------|-------------|
| 🔔 Smart Notifications | Four scenarios: Input Needed / Permission Needed / Waiting / Task Complete |
| 🖱️ Click-to-Navigate | Click notification button to return to Windows Terminal |
| 🔄 Auto-Deploy | Protocol registration & script deployment on first run |
| 🛡️ Graceful Fallback | Sends basic notifications if protocol setup fails |
| 📡 Protocol Activation | `claudewt://` custom protocol + VBS windowless wrapper |

## 📋 Prerequisites

- [Claude Code](https://claude.ai/code) CLI
- [Node.js](https://nodejs.org/) 12+ — must be installed on the same system where Claude Code runs (WSL Node for WSL users; Windows Node for native users)
- [BurntToast](https://github.com/Windos/BurntToast) PowerShell module
- Windows Terminal
- WSL2 (optional; only if running Claude Code inside WSL)

> Supports both **WSL** and **Windows native** (PowerShell/CMD) Claude Code. Pick during install with `-Target Wsl` or `-Target Windows`.

## 🚀 Installation

```powershell
git clone https://github.com/atesop/claude-windows-toast.git
cd claude-windows-toast
powershell -ExecutionPolicy Bypass -File install.ps1
```

See [中文](#中文) section for detailed manual installation instructions.

## 📄 License

[MIT License](LICENSE)
