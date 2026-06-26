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

# Scenario A9-A12: Notification entry mixed with user hook -> migration preserves user hook
# (locks the #1 fix's "no accidental user-hook deletion" for the new Notification event)
$s2 = [PSCustomObject]@{
    hooks = [PSCustomObject]@{
        Notification = @(
            [PSCustomObject]@{
                matcher = 'permission_prompt'
                hooks = @(
                    [PSCustomObject]@{ type='command'; command='user-perm-notifier' },
                    [PSCustomObject]@{ type='command'; command='node'; args=@($cjs, '--permission') }
                )
            }
        )
    }
}
Remove-ProjectHooks $s2 @('Notification')
Add-HookEntry $s2 'Notification' 'permission_prompt' $cjs '--permission'
$mix = @($s2.hooks.Notification)
$mh = @($mix[0].hooks)
$cmds = New-Object System.Collections.ArrayList
foreach ($h in $mh) { [void]$cmds.Add("$($h.command)") }
$permFlags = New-Object System.Collections.ArrayList
foreach ($h in $mh) { if ($h.args) { [void]$permFlags.Add("$($h.args[1])") } }
Check 'A9 mixed: entry preserved (1)' ($mix.Count -eq 1)
Check 'A10 mixed: user hook preserved' ($cmds -contains 'user-perm-notifier')
Check 'A11 mixed: project hook refreshed (node+--permission)' (($cmds -contains 'node') -and ($permFlags -contains '--permission'))
Check 'A12 mixed: total 2 hooks (user + project)' ($mh.Count -eq 2)

Write-Host 'Part B: install.ps1 source contains Notification config'
Check 'B1 Add-HookEntry Notification permission_prompt call present' ($src -match "Add-HookEntry.*'Notification'.*'permission_prompt'.*'--permission'")
Check 'B2 Remove-ProjectHooks scope includes Notification' ($src -match "Remove-ProjectHooks.*'Notification'")

Write-Host ''
Write-Host "TOTAL: PASS=$pass FAIL=$fail"
if ($fail -gt 0) { exit 1 } else { exit 0 }
