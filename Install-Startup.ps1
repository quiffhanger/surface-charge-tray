#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Install or uninstall the Surface Charge Tray as a logon startup task.
.DESCRIPTION
    Copies SurfaceChargeTray.ps1 to %LOCALAPPDATA%\SurfaceChargeTray so the
    startup task keeps working if this repo is moved or deleted. Re-run after
    editing the script to deploy the new version.
.PARAMETER Uninstall
    Remove the scheduled task and installed copy instead of creating them.
#>
param([switch]$Uninstall)

$taskName = 'SurfaceChargeTray'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$sourcePath = Join-Path $scriptDir 'SurfaceChargeTray.ps1'
$installDir = Join-Path $env:LOCALAPPDATA 'SurfaceChargeTray'
$installPath = Join-Path $installDir 'SurfaceChargeTray.ps1'

function Stop-TrayApp {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*SurfaceChargeTray.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

if ($Uninstall) {
    Stop-TrayApp
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item $installDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Removed scheduled task '$taskName' and $installDir."
    return
}

if (-not (Test-Path $sourcePath)) {
    Write-Error "SurfaceChargeTray.ps1 not found at: $sourcePath"
    exit 1
}

Stop-TrayApp
New-Item -ItemType Directory -Path $installDir -Force | Out-Null
Copy-Item $sourcePath $installPath -Force

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument @"
-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$installPath"
"@

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew

$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest -LogonType Interactive

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Force | Out-Null

Start-ScheduledTask -TaskName $taskName

Write-Host "Installed scheduled task '$taskName' running $installPath"
Write-Host "The tray app has been started and will start automatically at logon."
Write-Host "To remove: .\Install-Startup.ps1 -Uninstall"
