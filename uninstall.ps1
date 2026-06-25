# ============================================================================
# uninstall.ps1 - claude-windows-toast 卸载脚本
# ============================================================================
# 用法: powershell -ExecutionPolicy Bypass -File uninstall.ps1
#
# 功能:
#   1. 移除 claudewt:// 自定义协议注册
#   2. 删除 %APPDATA%\claude-code\ 下的部署文件
#   3. 移除 Hook 脚本
#   4. 精确移除 settings.json 中的相关 hooks（保留用户其他 hooks）

param(
    # 目标环境：留空（默认）= WSL 与 Windows 两边都清（最彻底）；
    # Wsl = 只清 WSL 侧；Windows = 只清 Windows 原生侧。与 install 的 -Target 对称。
    [ValidateSet("Wsl","Windows","")][string]$Target = "",
    [string]$WslDistro = ""
)

$ErrorActionPreference = 'Stop'

function Write-Info($msg)  { Write-Host "[INFO]  $msg" -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host "[OK]    $msg" -ForegroundColor Green }
function Write-Warn($msg)  { Write-Host "[WARN]  $msg" -ForegroundColor Yellow }

$scriptMarker = 'claude-windows-toast'

# ---- 步骤 1: 移除协议注册 ----

Write-Info "移除 claudewt:// 协议注册..."

$protoKey = 'HKCU:\Software\Classes\claudewt'
if (Test-Path $protoKey) {
    Remove-Item -Path $protoKey -Recurse -Force
    Write-Ok "协议注册已移除"
} else {
    Write-Warn "协议注册不存在，跳过"
}

# ---- 步骤 2: 删除部署文件 ----

Write-Info "删除部署文件..."

# 只删本项目部署的文件，不递归删除整个 claude-code 目录
# （该目录名较泛，可能被其他 Claude Code 相关工具共用，整体删除有误伤风险）
$deployDir = Join-Path $env:APPDATA 'claude-code'
$deployFiles = @('activate-wt.ps1', 'activate-wt.vbs', 'activate-wt-debug.log', 'register-protocol.ps1')
$deletedAny = $false
foreach ($f in $deployFiles) {
    $fp = Join-Path $deployDir $f
    if (Test-Path $fp) {
        Remove-Item -Path $fp -Force
        Write-Ok "已删除: $fp"
        $deletedAny = $true
    }
}
# 目录仅当为空时才删除（避免误伤其他工具的文件）
if (Test-Path $deployDir) {
    $remaining = @(Get-ChildItem -Path $deployDir -Force -ErrorAction SilentlyContinue)
    if ($remaining.Count -eq 0) {
        Remove-Item -Path $deployDir -Force
        Write-Ok "空目录已删除: $deployDir"
    } else {
        Write-Warn "保留目录（含其他文件，未删除）: $deployDir"
    }
}
if (-not $deletedAny) { Write-Warn "无本项目部署文件，跳过" }

# ---- 步骤 3: 移除 Hook 脚本 ----

Write-Info "移除 Hook 脚本..."

# 按 -Target 决定清理范围：留空则 WSL+Windows 都清（彻底），Wsl 只清 WSL，Windows 只清 Windows。
# $wslHome/$winHome 为 $null 表示跳过该侧。
$wslHome = $null
$winHome = $null

if ($Target -ne 'Windows') {
    # WSL 路径（必须用 wslpath 转 UNC，否则 Windows PowerShell 把 /home/.. 当 C:\home\..）
    try {
        if ($WslDistro) {
            $unc = wsl.exe -d $WslDistro -e sh -lc 'wslpath -w "$HOME"' 2>$null
        } else {
            $unc = wsl.exe -e sh -lc 'wslpath -w "$HOME"' 2>$null
        }
        if ($LASTEXITCODE -eq 0 -and $unc) { $wslHome = $unc.Trim() }
    } catch {}
}

if ($Target -ne 'Wsl') {
    $winHome = $env:USERPROFILE
}

$hookPaths = @()
if ($wslHome) { $hookPaths += Join-Path $wslHome '.claude\hooks\claude-windows-toast.cjs' }
if ($winHome) { $hookPaths += Join-Path $winHome '.claude\hooks\claude-windows-toast.cjs' }

foreach ($hookFile in $hookPaths) {
    if (Test-Path $hookFile) {
        Remove-Item -Path $hookFile -Force
        Write-Ok "Hook 脚本已删除: $hookFile"
    }
}

# ---- 步骤 4: 精确清理 settings.json（逐层过滤 hooks 数组） ----

Write-Info "清理 settings.json 中的 hooks..."

$settingsPaths = @()

# WSL settings
if ($wslHome) {
    $settingsPaths += Join-Path $wslHome '.claude\settings.json'
}
# Windows settings
if ($winHome) {
    $settingsPaths += Join-Path $winHome '.claude\settings.json'
}

foreach ($settingsFile in $settingsPaths) {
    if (-not (Test-Path $settingsFile)) { continue }

    try {
        $settings = Get-Content $settingsFile -Raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Warn "settings.json 解析失败，跳过（未修改）: $settingsFile"
        continue
    }
    if (-not $settings.hooks) { continue }

    $modified = $false

    # 遍历 hooks 下的每个事件（PermissionRequest, PreToolUse, Stop 等）
    $hookEvents = @($settings.hooks.PSObject.Properties | Where-Object {
        $_.Value -is [array]
    })

    foreach ($evt in $hookEvents) {
        $eventName = $evt.Name
        $entries = @($evt.Value)

        $newEntries = @()
        $eventChanged = $false
        foreach ($entry in $entries) {
            $hooks = @($entry.hooks)

            # 过滤掉本项目的 hook：旧 shell form 的 command 含 marker；
            # 新 exec form 的 command 是 'node' 但 marker 在 args[0]，两者都要识别。
            # 显式 foreach，与 install.ps1 的 Remove-ProjectHooks 保持一致。
            $remainingHooks = @()
            foreach ($h in $hooks) {
                $isOurs = "$($h.command)" -match $scriptMarker
                if (-not $isOurs -and $h.args) {
                    foreach ($a in $h.args) { if ("$a" -match $scriptMarker) { $isOurs = $true; break } }
                }
                if (-not $isOurs) { $remainingHooks += $h }
            }

            if ($remainingHooks.Count -eq 0) {
                # 本项目 hook 占满整个 entry：丢弃 entry
                $eventChanged = $true
            } elseif ($remainingHooks.Count -lt $hooks.Count) {
                # 过滤掉部分：用过滤后的 hooks 重建 entry（直接构造，避免 Copy 浅拷贝引用陷阱）
                $newEntries += [PSCustomObject]@{ matcher = $entry.matcher; hooks = $remainingHooks }
                $eventChanged = $true
            } else {
                # 未触及本项目：原样保留 entry
                $newEntries += $entry
            }
        }

        # 写回事件：entry 全丢则移除事件节点；有变化则覆盖（用 $eventChanged 判断，
        # 而非 entry 数量比较——后者会漏掉"entry 数量不变但内部 hooks 变化"的情况）
        if ($newEntries.Count -eq 0) {
            $settings.hooks.PSObject.Properties.Remove($eventName)
            $modified = $true
        } elseif ($eventChanged) {
            $settings.hooks.$eventName = $newEntries
            $modified = $true
        }
    }

    if ($modified) {
        # 如果 hooks 下没有属性了，移除 hooks 节点
        $remaining = @($settings.hooks.PSObject.Properties)
        if ($remaining.Count -eq 0) {
            $settings.PSObject.Properties.Remove('hooks')
        }

        try { Copy-Item -Path $settingsFile -Destination "$settingsFile.bak" -Force } catch {}
        $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsFile -Encoding UTF8
        Write-Ok "settings.json 已清理（备份见 .bak）: $settingsFile"
    } else {
        Write-Warn "settings.json 无需修改: $settingsFile"
    }
}

# ---- 完成 ----

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  卸载完成！" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
