#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Install or uninstall the Surface Charge Tray as a logon startup task.
.PARAMETER Uninstall
    Remove the scheduled task instead of creating it.
#>
param([switch]$Uninstall)

$taskName = 'SurfaceChargeTray'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$scriptPath = Join-Path $scriptDir 'SurfaceChargeTray.ps1'

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Removed scheduled task '$taskName'."
    return
}

if (-not (Test-Path $scriptPath)) {
    Write-Error "SurfaceChargeTray.ps1 not found at: $scriptPath"
    exit 1
}

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument @"
-ExecutionPolicy Bypass -WindowStyle Hidden -File "$scriptPath"
"@

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest -LogonType Interactive

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Force | Out-Null

Write-Host "Installed scheduled task '$taskName'."
Write-Host "The tray app will start automatically at logon with admin privileges."
Write-Host "To remove: .\Install-Startup.ps1 -Uninstall"
