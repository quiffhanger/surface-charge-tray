$logFile = "$env:USERPROFILE\chargemode-set-test.log"
"$(Get-Date) - Starting Set test v2" | Out-File $logFile

$hub = (Get-AppxPackage -Name 'Microsoft.SurfaceHub').InstallLocation
$svc = "$hub\Services"

[System.Reflection.Assembly]::LoadFrom("$svc\Microsoft.Extensions.Logging.Abstractions.dll") | Out-Null
[System.Reflection.Assembly]::LoadFrom("$svc\Microsoft.Extensions.Logging.dll") | Out-Null
[System.Reflection.Assembly]::LoadFrom("$svc\Microsoft.Extensions.DependencyInjection.Abstractions.dll") | Out-Null
$asm = [System.Reflection.Assembly]::LoadFrom("$svc\BatteryDm.exe")

$bdType = $asm.GetType('Microsoft.Surface.SDMA.Battery.Device.BatteryDevice')
$setType = $asm.GetType('Microsoft.Surface.SDMA.Battery.Data.BatterySetUserChargeMode')
$innerType = $asm.GetType('Microsoft.Surface.SDMA.Battery.Data.BatterySetUserChargeMode+Battery_Set_UserChargeMode')
$nullLogger = [Microsoft.Extensions.Logging.Abstractions.NullLogger]::Instance
$guid = [guid]'54f596c1-3b0d-40f2-97a4-fcbcfd253d3b'

try {
    $device = [System.Activator]::CreateInstance($bdType, $guid)

    # 1. Read current mode
    $before = $device.GetUserChargeMode($nullLogger)
    "BEFORE: Mode=$($before.Mode) LimitPct=$($before.LimitPercent) Timeout=$($before.TimeoutInSeconds)" | Out-File $logFile -Append

    # 2. Build the Set struct directly (bypass dictionary constructor)
    $inner = [Activator]::CreateInstance($innerType)
    $innerType.GetField('Mode').SetValue($inner, [byte]1)       # UserLimit
    $innerType.GetField('ModeSettings').SetValue($inner, [byte[]](80,0,0,0))  # 80% limit

    $setObj = [System.Runtime.Serialization.FormatterServices]::GetUninitializedObject($setType)
    $setType.GetProperty('Data').SetValue($setObj, $inner)
    "Built Set object: Mode=$($setObj.Data.Mode) ModeSettings=$($setObj.Data.ModeSettings -join ',')" | Out-File $logFile -Append

    # 3. Call SetUserChargeMode (setting to same value - safe test)
    "Calling SetUserChargeMode..." | Out-File $logFile -Append
    $result = $device.SetUserChargeMode($setObj, $nullLogger)
    "SetUserChargeMode returned: $result" | Out-File $logFile -Append

    # 4. Read again to confirm
    $after = $device.GetUserChargeMode($nullLogger)
    "AFTER: Mode=$($after.Mode) LimitPct=$($after.LimitPercent) Timeout=$($after.TimeoutInSeconds)" | Out-File $logFile -Append

    $device.Dispose()
} catch {
    "ERROR: $($_.Exception.Message)" | Out-File $logFile -Append
    "INNER: $($_.Exception.InnerException)" | Out-File $logFile -Append
    if ($_.Exception.InnerException.InnerException) {
        "INNER2: $($_.Exception.InnerException.InnerException)" | Out-File $logFile -Append
    }
}

"Done" | Out-File $logFile -Append
