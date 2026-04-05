$logFile = "$env:USERPROFILE\chargemode-test.log"
"$(Get-Date) - Starting test" | Out-File $logFile
$svc = "C:\Program Files\WindowsApps\Microsoft.SurfaceHub_76.2010.134.0_x64__8wekyb3d8bbwe\Services"

# Load dependencies
[System.Reflection.Assembly]::LoadFrom("$svc\Microsoft.Extensions.Logging.Abstractions.dll") | Out-Null
[System.Reflection.Assembly]::LoadFrom("$svc\Microsoft.Extensions.Logging.dll") | Out-Null
[System.Reflection.Assembly]::LoadFrom("$svc\Microsoft.Extensions.DependencyInjection.Abstractions.dll") | Out-Null
$asm = [System.Reflection.Assembly]::LoadFrom("$svc\BatteryDm.exe")

$bdType = $asm.GetType('Microsoft.Surface.SDMA.Battery.Device.BatteryDevice')
$nullLogger = [Microsoft.Extensions.Logging.Abstractions.NullLogger]::Instance

# Try both GUIDs
$guids = @{
    'BatteryClient' = [guid]'31076642-1572-4fbb-a5dd-4b879b515476'
    'SID'           = [guid]'54f596c1-3b0d-40f2-97a4-fcbcfd253d3b'
}

foreach ($name in $guids.Keys) {
    Write-Host "=== Trying $name GUID: $($guids[$name]) ==="
    try {
        $device = [System.Activator]::CreateInstance($bdType, $guids[$name])
        Write-Host "Device opened."

        $result = $device.GetUserChargeMode($nullLogger)
        "SUCCESS with $name" | Out-File $logFile -Append
        "  Mode:             $($result.Mode)" | Out-File $logFile -Append
        "  LimitPercent:     $($result.LimitPercent)" | Out-File $logFile -Append
        "  TimeoutInSeconds: $($result.TimeoutInSeconds)" | Out-File $logFile -Append
        
        $data = $result.Data
        "  Raw ModesSupported: $($data.ModesSupported)" | Out-File $logFile -Append
        "  Raw CurrentMode:    $($data.CurrentMode)" | Out-File $logFile -Append
        "  Raw PreviousMode:   $($data.PreviousMode)" | Out-File $logFile -Append
        "  Raw ModeSettings:   $($data.ModeSettings -join ',')" | Out-File $logFile -Append

        $device.Dispose()
        break
    } catch {
        "Error ($name): $($_.Exception.InnerException.Message)" | Out-File $logFile -Append
        "NativeErrorCode: $($_.Exception.InnerException.NativeErrorCode)" | Out-File $logFile -Append
    }
}

"Done" | Out-File $logFile -Append
