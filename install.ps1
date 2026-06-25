# ============================================================================
# install.ps1 - claude-windows-toast 安装脚本
# ============================================================================
# 用法:
#   powershell -ExecutionPolicy Bypass -File install.ps1
#   powershell -ExecutionPolicy Bypass -File install.ps1 -SkipDependencyInstall
#
# 功能:
#   1. 检查前置依赖 (BurntToast 模块)
#   2. 部署 activate-wt.ps1 和 activate-wt.vbs 到 %APPDATA%\claude-code\
#   3. 注册 claudewt:// 自定义协议到 HKCU 注册表
#   4. 部署 claude-windows-toast.cjs 到 ~/.claude/hooks/
#   5. 追加（非覆盖）hooks 配置到 ~/.claude/settings.json

param(
    [switch]$SkipDependencyInstall,
    [string]$WslDistro = ""
)

$ErrorActionPreference = 'Stop'

# ---- 颜色输出 ----

function Write-Info($msg)  { Write-Host "[INFO]  $msg" -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host "[OK]    $msg" -ForegroundColor Green }
function Write-Warn($msg)  { Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Write-Err($msg)   { Write-Host "[ERROR] $msg" -ForegroundColor Red }

# ---- 步骤 1: 检查前置依赖 ----

Write-Info "检查前置依赖..."

# 检查 Node.js
$nodeExe = Get-Command node -ErrorAction SilentlyContinue
if (-not $nodeExe) {
    Write-Err "未找到 Node.js，请先安装: https://nodejs.org/"
    exit 1
}
Write-Ok "Node.js: $($nodeExe.Version)"

# 检查 BurntToast
$burntToast = Get-Module BurntToast -ListAvailable -ErrorAction SilentlyContinue
if (-not $burntToast) {
    if ($SkipDependencyInstall) {
        Write-Warn "未找到 BurntToast 模块。请手动安装:"
        Write-Host "  Install-Module -Name BurntToast -Force -Scope CurrentUser" -ForegroundColor White
        Write-Host "安装后重新运行本脚本，或去掉 -SkipDependencyInstall 参数" -ForegroundColor White
        exit 1
    }
    Write-Warn "未找到 BurntToast 模块"
    $answer = Read-Host "是否自动安装 BurntToast? (Y/n)"
    if ($answer -eq 'n' -or $answer -eq 'N') {
        Write-Err "用户取消安装"
        exit 1
    }
    try {
        Install-Module -Name BurntToast -Force -Scope CurrentUser -ErrorAction Stop
        Write-Ok "BurntToast 模块已安装"
    } catch {
        Write-Err "BurntToast 安装失败: $_"
        Write-Host "请手动安装: Install-Module -Name BurntToast -Force -Scope CurrentUser" -ForegroundColor White
        exit 1
    }
} else {
    Write-Ok "BurntToast: v$($burntToast.Version)"
}

# ---- 步骤 1.5: 预检 settings.json（在任何写操作前完成，解析失败立即中止） ----

Write-Info "预检 Claude Code 配置..."

# 确定 hooks 目录与 settings 路径（优先 WSL）
$hooksDir = ""
$settingsFile = ""
$settings = $null

# 获取 WSL $HOME 在 Windows 侧的 UNC 路径（\\wsl.localhost\<distro>\home\...）
# 注意：不能直接用 "/home/user"，Windows PowerShell 会把它当成 C:\home\user，
# 导致 hook 部署到错误位置、Claude Code 找不到。必须用 wslpath 转成 UNC。
function Get-WslHomeWinPath {
    param([string]$Distro)
    try {
        if ($Distro) {
            $unc = wsl.exe -d $Distro -e sh -lc 'wslpath -w "$HOME"' 2>$null
        } else {
            $unc = wsl.exe -e sh -lc 'wslpath -w "$HOME"' 2>$null
        }
        if ($LASTEXITCODE -eq 0 -and $unc) { return $unc.Trim() }
    } catch {}
    return $null
}

$wslHome = Get-WslHomeWinPath $WslDistro
if ($wslHome) {
    $hooksDir = Join-Path $wslHome '.claude\hooks'
    $settingsFile = Join-Path $wslHome '.claude\settings.json'
    Write-Info "检测到 WSL 环境: $wslHome"
} else {
    # 纯 Windows 环境（或未安装 WSL）
    $homeDir = $env:USERPROFILE
    if (-not $homeDir) { $homeDir = $env:HOME }
    $hooksDir = Join-Path $homeDir '.claude\hooks'
    $settingsFile = Join-Path $homeDir '.claude\settings.json'
    Write-Info "使用 Windows 路径: $homeDir"
}

# 解析 settings.json：在任何写操作前完成。损坏则直接中止，不留半安装状态。
if (Test-Path $settingsFile) {
    try {
        $settings = Get-Content $settingsFile -Raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Err "settings.json 解析失败，已中止（尚未部署任何文件或注册协议）: $_"
        Write-Err "  文件: $settingsFile"
        Write-Err "  请修复该文件后重新运行安装"
        exit 1
    }
} else {
    $settings = [PSCustomObject]@{}
}

# ---- 步骤 2: 部署激活脚本 ----

Write-Info "部署激活脚本..."

$deployDir = Join-Path $env:APPDATA 'claude-code'
$ps1Path = Join-Path $deployDir 'activate-wt.ps1'
$vbsPath = Join-Path $deployDir 'activate-wt.vbs'

# 创建目录
New-Item -Path $deployDir -ItemType Directory -Force | Out-Null

# 复制 activate-wt.ps1
$srcDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$srcPs1 = Join-Path $srcDir 'src\activate-wt.ps1'

if (Test-Path $srcPs1) {
    Copy-Item -Path $srcPs1 -Destination $ps1Path -Force
    Write-Ok "activate-wt.ps1 已部署"
} else {
    Write-Warn "src\activate-wt.ps1 不存在，将在首次运行时由 hook 自动生成"
}

# 生成 VBS 包装器
$vbsContent = @"
Set objShell = CreateObject("WScript.Shell")
objShell.Run "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File ""$ps1Path""", 0, False
"@
Set-Content -Path $vbsPath -Value $vbsContent -Encoding ASCII
Write-Ok "activate-wt.vbs 已生成"

Write-Ok "激活脚本已部署到: $deployDir"

# ---- 步骤 3: 注册自定义协议 ----

Write-Info "注册 claudewt:// 协议..."

$protoKey = 'HKCU:\Software\Classes\claudewt'
$cmdKey = "$protoKey\shell\open\command"

# 创建协议注册表项
if (-not (Test-Path $protoKey)) {
    New-Item -Path $protoKey -Force | Out-Null
}
Set-ItemProperty -Path $protoKey -Name '(Default)' -Value 'URL:Claude Code Terminal'
Set-ItemProperty -Path $protoKey -Name 'URL Protocol' -Value ''

# 设置协议命令（使用 wscript.exe 避免弹出窗口）
if (-not (Test-Path $cmdKey)) {
    New-Item -Path $cmdKey -Force | Out-Null
}
$protoCmd = "wscript.exe `"$vbsPath`""
Set-ItemProperty -Path $cmdKey -Name '(Default)' -Value $protoCmd

Write-Ok "claudewt:// 协议已注册"

# ---- 步骤 4: 部署 Hook 脚本 ----

Write-Info "部署 Hook 脚本..."

# hooks 目录与 settingsFile 已在步骤 1.5 确定（WSL 路径检测亦在那里完成）
# 创建 hooks 目录
New-Item -Path $hooksDir -ItemType Directory -Force | Out-Null

# 复制 Hook 脚本
$srcCjs = Join-Path $srcDir 'src\claude-windows-toast.cjs'
$dstCjs = Join-Path $hooksDir 'claude-windows-toast.cjs'

if (Test-Path $srcCjs) {
    Copy-Item -Path $srcCjs -Destination $dstCjs -Force
    Write-Ok "Hook 脚本已部署到: $dstCjs"
} else {
    Write-Err "未找到 src\claude-windows-toast.cjs"
    exit 1
}

# ---- 步骤 5: 更新 settings.json（追加模式，不覆盖现有 hooks） ----

Write-Info "配置 Claude Code hooks..."

# 定义 hook command 模板
$askCmd = 'node "$HOME/.claude/hooks/claude-windows-toast.cjs" --ask'
$markAskCmd = 'node "$HOME/.claude/hooks/claude-windows-toast.cjs" --mark-ask'
$stopCmd = 'node "$HOME/.claude/hooks/claude-windows-toast.cjs" --stop'

# settings 已在步骤 1.5 解析完成（$settings）。写前备份，避免重排格式丢失用户配置。
if (Test-Path $settingsFile) {
    $backupFile = "$settingsFile.bak"
    try {
        Copy-Item -Path $settingsFile -Destination $backupFile -Force
        Write-Info "已备份 settings.json -> $backupFile"
    } catch {
        Write-Warn "备份 settings.json 失败（继续）: $_"
    }
}

# 确保 hooks 节点存在
if (-not $settings.hooks) {
    $settings | Add-Member -NotePropertyName 'hooks' -NotePropertyValue ([PSCustomObject]@{}) -Force
}

# 辅助函数：追加 hook 到指定事件（不覆盖现有）
function Add-HookEntry {
    param(
        [PSObject]$Settings,
        [string]$EventName,
        [string]$Matcher,
        [string]$Command
    )

    # 检查是否已存在相同 command（幂等）
    $existing = $Settings.hooks.$EventName
    if ($existing) {
        foreach ($entry in $existing) {
            foreach ($hook in $entry.hooks) {
                if ($hook.command -eq $Command) {
                    Write-Info "  Hook 已存在，跳过: $EventName/$Matcher"
                    return
                }
            }
        }
    }

    # 构建新 entry
    $newEntry = [PSCustomObject]@{
        matcher = $Matcher
        hooks = @([PSCustomObject]@{
            type = "command"
            command = $Command
        })
    }

    # 追加到现有数组
    if ($Settings.hooks.$EventName) {
        $current = @($Settings.hooks.$EventName)
        $Settings.hooks.$EventName = @($current + $newEntry)
    } else {
        $Settings.hooks | Add-Member -NotePropertyName $EventName -NotePropertyValue @($newEntry) -Force
    }

    Write-Ok "  已添加 hook: $EventName/$Matcher"
}

# 追加 hooks
# ⚠️ --ask 必须配在 PreToolUse 而非 PermissionRequest：
# PermissionRequest 只在"权限对话框即将显示"时触发，bypassPermissions 等模式下永不触发，
# 会导致 🔴"需要输入"通知丢失。PreToolUse 对 AskUserQuestion 必触发（与 --mark-ask 同事件）。
Add-HookEntry $settings 'PreToolUse' 'AskUserQuestion' $askCmd
Add-HookEntry $settings 'PreToolUse' 'AskUserQuestion' $markAskCmd
Add-HookEntry $settings 'Stop' '' $stopCmd

# 保存
$settings | ConvertTo-Json -Depth 10 | Set-Content $settingsFile -Encoding UTF8
Write-Ok "settings.json 已更新（保留现有配置）"

# ---- 完成 ----

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  安装完成！" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Info "部署文件:"
Write-Host "  激活脚本: $ps1Path"
Write-Host "  VBS 包装: $vbsPath"
Write-Host "  Hook 脚本: $dstCjs"
Write-Host ""
Write-Info "注册表:"
Write-Host "  claudewt:// -> wscript.exe `"$vbsPath`""
Write-Host ""
Write-Info "现在重启 Claude Code 即可生效"
