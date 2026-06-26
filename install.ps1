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
    # 目标环境：Wsl = Claude Code 跑在 WSL；Windows = Claude Code 跑在 Windows 原生（PowerShell/CMD）
    # 留空则交互询问。自动化场景用 -Target Wsl 或 -Target Windows。
    [ValidateSet("Wsl","Windows","")][string]$Target = "",
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

# ---- 步骤 1.5: 确定目标环境 + 预检配置（在任何写操作前完成） ----

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

# 获取 WSL $HOME 的 Linux 路径（/home/user），用于 settings.json 里的 hook command。
# Claude Code 在 WSL 经 sh 执行 hook，command 里的脚本路径必须是 Linux 路径。
function Get-WslHomeLinuxPath {
    param([string]$Distro)
    try {
        if ($Distro) {
            $p = wsl.exe -d $Distro -e sh -lc 'echo $HOME' 2>$null
        } else {
            $p = wsl.exe -e sh -lc 'echo $HOME' 2>$null
        }
        if ($LASTEXITCODE -eq 0 -and $p) { return $p.Trim() }
    } catch {}
    return $null
}

# 1.5a 确定目标环境（未传 -Target 时交互询问；不再凭"机器有无 WSL"猜测，避免误判）
if (-not $Target) {
    Write-Host "Claude Code 跑在哪个环境？" -ForegroundColor Cyan
    Write-Host "  1) WSL —— 在 WSL/Linux 里运行（配置在 WSL 的 ~/.claude/）" -ForegroundColor White
    Write-Host "  2) Windows 原生 —— 在 PowerShell/CMD 里运行（配置在 %USERPROFILE%\.claude\）" -ForegroundColor White
    $choice = Read-Host "请输入 1 或 2（默认 1）"
    if ($choice -eq '2') { $Target = 'Windows' } else { $Target = 'Wsl' }
}
Write-Info "目标环境: $Target"

# 1.5b 按 Target 确定 hooksDir / settingsFile / hookScriptPath（hook command 引用的 cjs 绝对路径）
Write-Info "预检 Claude Code 配置..."
$hooksDir = ""
$settingsFile = ""
$hookScriptPath = ""
$settings = $null

if ($Target -eq 'Windows') {
    # Windows 原生：Claude Code 配置在 %USERPROFILE%\.claude\
    $homeDir = $env:USERPROFILE
    if (-not $homeDir) { $homeDir = $env:HOME }
    if (-not $homeDir) { Write-Err "无法确定用户目录（%USERPROFILE%）"; exit 1 }
    $hooksDir = Join-Path $homeDir '.claude\hooks'
    $settingsFile = Join-Path $homeDir '.claude\settings.json'
    $hookScriptPath = Join-Path $hooksDir 'claude-windows-toast.cjs'
    Write-Info "Windows 原生: $homeDir"
} else {
    # WSL：配置在 WSL 的 ~/.claude/（Windows 侧经 UNC 写入）
    $wslHome = Get-WslHomeWinPath $WslDistro
    if (-not $wslHome) {
        Write-Err "未检测到 WSL 环境。若 Claude Code 跑在 Windows 原生，请用 -Target Windows 重新运行。"
        exit 1
    }
    $hooksDir = Join-Path $wslHome '.claude\hooks'
    $settingsFile = Join-Path $wslHome '.claude\settings.json'
    $wslLinuxHome = Get-WslHomeLinuxPath $WslDistro
    if (-not $wslLinuxHome) { Write-Err '无法获取 WSL 的 $HOME 路径'; exit 1 }
    $hookScriptPath = "$wslLinuxHome/.claude/hooks/claude-windows-toast.cjs"
    Write-Info "WSL 环境: $wslHome"
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

# ---- 步骤 5: 更新 settings.json（exec form，迁移清理旧条目） ----

Write-Info "配置 Claude Code hooks..."

# settings 与 hookScriptPath 均在步骤 1.5 确定。写前备份，避免重排格式丢失用户配置。
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

# 迁移清理：按 hook 粒度移除本项目旧条目（含旧的 $HOME shell-form 与新 exec form），再统一写 exec form。
# 关键：只剔除本项目 hook，保留同一 entry 内用户的其他 hook；仅当过滤后 hooks 为空才丢弃整个 entry。
# 与 uninstall.ps1 的逐 hook 过滤逻辑保持一致——避免误删与本项目共存于同一 matcher entry 的用户 hook。
function Remove-ProjectHooks {
    param([PSObject]$Settings, [string[]]$EventNames)
    foreach ($evt in $EventNames) {
        if (-not $Settings.hooks.$evt) { continue }
        $newEntries = @()
        foreach ($entry in $Settings.hooks.$evt) {
            $hooks = @($entry.hooks)

            # 逐 hook 判定是否本项目：旧 shell form 的 command 含 marker；
            # 新 exec form 的 command 是 'node' 但 marker 在 args 里，两者都要识别。
            $remainingHooks = @()
            foreach ($h in $hooks) {
                $isOurs = "$($h.command)" -match 'claude-windows-toast'
                if (-not $isOurs -and $h.args) {
                    foreach ($a in $h.args) { if ("$a" -match 'claude-windows-toast') { $isOurs = $true; break } }
                }
                if (-not $isOurs) { $remainingHooks += $h }
            }

            if ($remainingHooks.Count -eq 0) {
                # 本项目 hook 占满整个 entry：丢弃 entry（不加入 newEntries）
            } elseif ($remainingHooks.Count -lt $hooks.Count) {
                # 过滤掉部分：用过滤后的 hooks 重建 entry（直接构造，避免 Copy 浅拷贝引用陷阱）
                $newEntries += [PSCustomObject]@{ matcher = $entry.matcher; hooks = $remainingHooks }
            } else {
                # 未触及本项目：原样保留 entry
                $newEntries += $entry
            }
        }

        # 写回事件：entry 全丢则移除事件节点；否则覆盖
        if ($newEntries.Count -eq 0) {
            $Settings.hooks.PSObject.Properties.Remove($evt)
        } else {
            $Settings.hooks.$evt = $newEntries
        }
    }
}

# 辅助函数：以 exec form 追加 hook（command="node" + args=[脚本路径, 标志]）
# exec form 不经 shell 展开，跨 WSL(sh)/Windows(Git Bash/PowerShell) 最稳；
# 绝对路径由 install 按 Target 写死（$hookScriptPath），不依赖运行时 $HOME 展开。
# 同 matcher 的多个 hook 合并到同一个 entry 的 hooks 数组（符合 Claude Code 规范写法）。
function Add-HookEntry {
    param(
        [PSObject]$Settings,
        [string]$EventName,
        [string]$Matcher,
        [string]$ScriptPath,
        [string]$Flag
    )

    # 找到已有的同 matcher entry：有则往其 hooks 数组追加，无则新建 entry
    $targetEntry = $null
    if ($Settings.hooks.$EventName) {
        foreach ($entry in $Settings.hooks.$EventName) {
            if ("$($entry.matcher)" -eq $Matcher) { $targetEntry = $entry; break }
        }
    }

    if ($targetEntry) {
        # 幂等：该 entry 下已有相同 脚本+标志 的 hook 则跳过
        foreach ($hook in $targetEntry.hooks) {
            if ($hook.command -eq 'node' -and $hook.args) {
                $a = $hook.args
                if ($a.Count -ge 2 -and "$($a[0])" -eq $ScriptPath -and "$($a[1])" -eq $Flag) {
                    Write-Info "  Hook 已存在，跳过: $EventName/$Matcher ($Flag)"
                    return
                }
            }
        }
        $targetEntry.hooks = @($targetEntry.hooks) + [PSCustomObject]@{
            type = "command"
            command = "node"
            args = @($ScriptPath, $Flag)
        }
    } else {
        $newEntry = [PSCustomObject]@{
            matcher = $Matcher
            hooks = @([PSCustomObject]@{
                type = "command"
                command = "node"
                args = @($ScriptPath, $Flag)
            })
        }
        if ($Settings.hooks.$EventName) {
            $current = @($Settings.hooks.$EventName)
            $Settings.hooks.$EventName = @($current + $newEntry)
        } else {
            $Settings.hooks | Add-Member -NotePropertyName $EventName -NotePropertyValue @($newEntry) -Force
        }
    }

    Write-Ok "  已添加 hook: $EventName/$Matcher ($Flag)"
}

# 清旧 + 写新
Remove-ProjectHooks $settings @('PreToolUse','Stop')

# ⚠️ --ask 必须配在 PreToolUse 而非 PermissionRequest：
# PermissionRequest 只在"权限对话框即将显示"时触发，bypassPermissions 等模式下永不触发，
# 会导致 🔴"需要输入"通知丢失。PreToolUse 对 AskUserQuestion 必触发（与 --mark-ask 同事件）。
Add-HookEntry $settings 'PreToolUse' 'AskUserQuestion' $hookScriptPath '--mark-ask'
Add-HookEntry $settings 'PreToolUse' 'AskUserQuestion' $hookScriptPath '--ask'
Add-HookEntry $settings 'Stop' '' $hookScriptPath '--stop'

# 保存
$settings | ConvertTo-Json -Depth 10 | Set-Content $settingsFile -Encoding UTF8
Write-Ok "settings.json 已更新（exec form，脚本路径: $hookScriptPath）"

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
Write-Host "  Hook 命令路径: $hookScriptPath"
Write-Host ""
Write-Info "注册表:"
Write-Host "  claudewt:// -> wscript.exe `"$vbsPath`""
Write-Host ""
Write-Info "现在重启 Claude Code 即可生效"
