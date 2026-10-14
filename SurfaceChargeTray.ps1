#Requires -Version 5.1
<#
.SYNOPSIS
    System tray app to control Surface battery charge limit.
.DESCRIPTION
    Talks directly to the Surface firmware via the BatteryDm.exe assembly
    from the Surface app. Requires admin elevation for DeviceIoControl access.
#>

# --- Self-elevate if not admin ---
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $scriptPath = $MyInvocation.MyCommand.Definition
    Start-Process powershell -Verb RunAs -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden',
        '-File', "`"$scriptPath`""
    )
    exit
}

# --- Single instance (a second copy would add a duplicate tray icon) ---
$script:Mutex = New-Object System.Threading.Mutex($false, 'Local\SurfaceChargeTray')
try {
    $owned = $script:Mutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    $owned = $true   # previous instance died without releasing; we own it now
}
if (-not $owned) { exit }

# --- Error logging (rotated at 1 MB) ---
$script:LogFile = Join-Path $env:USERPROFILE 'SurfaceChargeTray.log'
if ((Test-Path $script:LogFile) -and (Get-Item $script:LogFile).Length -gt 1MB) {
    Move-Item $script:LogFile "$script:LogFile.old" -Force -ErrorAction SilentlyContinue
}
function Write-Log {
    param([string]$Msg)
    try {
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Msg" | Out-File $script:LogFile -Append
    } catch {}
}
Write-Log "Starting SurfaceChargeTray (PID $PID, $($MyInvocation.MyCommand.Definition))"

# --- Hide the console window ---
Add-Type -Name Win32 -Namespace Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr hIcon);
'@
$consoleHwnd = [Native.Win32]::GetConsoleWindow()
if ($consoleHwnd -ne [IntPtr]::Zero) {
    [Native.Win32]::ShowWindow($consoleHwnd, 0) | Out-Null  # SW_HIDE
}

# --- Load WinForms ---
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Log exceptions from event handlers instead of showing the WinForms crash dialog
[System.Windows.Forms.Application]::SetUnhandledExceptionMode('CatchException')
[System.Windows.Forms.Application]::add_ThreadException({
    param($sender, $e)
    Write-Log "Unhandled UI exception: $($e.Exception)"
})

# --- Load Surface Battery DM assemblies ---
# At logon the AppX package can take a while to register, so retry for ~2 minutes
$hub = $null
for ($i = 0; $i -lt 24 -and -not $hub; $i++) {
    $hub = (Get-AppxPackage -Name 'Microsoft.SurfaceHub' -ErrorAction SilentlyContinue).InstallLocation
    if (-not $hub) { Start-Sleep -Seconds 5 }
}
if (-not $hub) {
    Write-Log 'Surface app not found; exiting'
    [System.Windows.Forms.MessageBox]::Show(
        "Surface app not found. Please install it from the Microsoft Store.",
        "Surface Charge Tray", "OK", "Error")
    exit 1
}
$svc = "$hub\Services"

try {
    [System.Reflection.Assembly]::LoadFrom("$svc\Microsoft.Extensions.Logging.Abstractions.dll") | Out-Null
    [System.Reflection.Assembly]::LoadFrom("$svc\Microsoft.Extensions.Logging.dll") | Out-Null
    [System.Reflection.Assembly]::LoadFrom("$svc\Microsoft.Extensions.DependencyInjection.Abstractions.dll") | Out-Null
    $script:Asm = [System.Reflection.Assembly]::LoadFrom("$svc\BatteryDm.exe")
} catch {
    Write-Log "Failed to load Surface battery assemblies from ${svc}: $_"
    [System.Windows.Forms.MessageBox]::Show(
        "Failed to load Surface battery assemblies: $_",
        "Surface Charge Tray", "OK", "Error")
    exit 1
}

# --- Type references ---
$script:BdType    = $script:Asm.GetType('Microsoft.Surface.SDMA.Battery.Device.BatteryDevice')
$script:SetType   = $script:Asm.GetType('Microsoft.Surface.SDMA.Battery.Data.BatterySetUserChargeMode')
$script:InnerType = $script:Asm.GetType('Microsoft.Surface.SDMA.Battery.Data.BatterySetUserChargeMode+Battery_Set_UserChargeMode')
$script:Logger    = [Microsoft.Extensions.Logging.Abstractions.NullLogger]::Instance
$script:DevGuid   = [guid]'54f596c1-3b0d-40f2-97a4-fcbcfd253d3b'

# --- Battery device helpers ---
function Get-ChargeMode {
    $device = $null
    try {
        $device = [System.Activator]::CreateInstance($script:BdType, $script:DevGuid)
        $result = $device.GetUserChargeMode($script:Logger)
        return @{
            Mode           = [int]$result.Mode
            LimitPercent   = [int]$result.LimitPercent
            TimeoutSeconds = [int]$result.TimeoutInSeconds
            RawCurrent     = [int]$result.Data.CurrentMode
            RawPrevious    = [int]$result.Data.PreviousMode
        }
    } catch {
        return $null
    } finally {
        if ($device) { $device.Dispose() }
    }
}

function Set-ChargeMode {
    param(
        [byte]$Mode,
        [byte[]]$ModeSettings = @(0,0,0,0)
    )
    $device = $null
    try {
        $device = [System.Activator]::CreateInstance($script:BdType, $script:DevGuid)
        $inner = [Activator]::CreateInstance($script:InnerType)
        $script:InnerType.GetField('Mode').SetValue($inner, $Mode)
        $script:InnerType.GetField('ModeSettings').SetValue($inner, $ModeSettings)

        $setObj = [System.Runtime.Serialization.FormatterServices]::GetUninitializedObject($script:SetType)
        $script:SetType.GetProperty('Data').SetValue($setObj, $inner)

        return $device.SetUserChargeMode($setObj, $script:Logger)
    } catch {
        return $false
    } finally {
        if ($device) { $device.Dispose() }
    }
}

function Set-ChargeLimitTo80 {
    Set-ChargeMode -Mode 1 -ModeSettings @(80, 0, 0, 0)
}

function Set-ChargeUnlimited {
    param([int]$TimeoutSeconds)
    $bytes = [BitConverter]::GetBytes([uint32]$TimeoutSeconds)
    Set-ChargeMode -Mode 2 -ModeSettings $bytes
}

function Set-ChargeAdaptive {
    Set-ChargeMode -Mode 0 -ModeSettings @(0, 0, 0, 0)
}

# --- Icon generation ---
function New-TrayIcon {
    param([string]$Text, [System.Drawing.Color]$Color)
    $bmp = New-Object System.Drawing.Bitmap(16, 16)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'ClearTypeGridFit'
    $g.Clear([System.Drawing.Color]::Transparent)

    $fontSize = if ($Text.Length -le 2) { 9 } else { 7 }
    $font = New-Object System.Drawing.Font('Segoe UI', $fontSize, [System.Drawing.FontStyle]::Bold)
    $brush = New-Object System.Drawing.SolidBrush($Color)
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = 'Center'
    $sf.LineAlignment = 'Center'
    $rect = New-Object System.Drawing.RectangleF(0, 0, 16, 16)
    $g.DrawString($Text, $font, $brush, $rect, $sf)

    $g.Dispose()
    $font.Dispose()
    $brush.Dispose()
    $sf.Dispose()
    $hIcon = $bmp.GetHicon()
    $tempIcon = [System.Drawing.Icon]::FromHandle($hIcon)
    $icon = $tempIcon.Clone()   # independent copy that owns its own handle
    $tempIcon.Dispose()
    [Native.Win32]::DestroyIcon($hIcon) | Out-Null
    $bmp.Dispose()
    return $icon
}

# --- Mode display names ---
$script:ModeNames = @{
    0 = 'Adaptive'
    1 = 'Limited to 80%'
    2 = 'Charging to 100%'
}

function Get-ModeDisplayText {
    param($state)
    if (-not $state) { return 'Unknown' }
    $name = $script:ModeNames[$state.Mode]
    if ($state.Mode -eq 2 -and $state.TimeoutSeconds -gt 0) {
        $remaining = [TimeSpan]::FromSeconds($state.TimeoutSeconds)
        if ($remaining.TotalHours -ge 24) {
            $name += " ($([math]::Round($remaining.TotalDays, 1))d left)"
        } else {
            $name += " ($([math]::Round($remaining.TotalHours, 1))h left)"
        }
    }
    return $name
}

# --- Build context menu ---
function Build-ContextMenu {
    param($state)
    $menu = New-Object System.Windows.Forms.ContextMenuStrip

    # Status header
    $statusItem = $menu.Items.Add("Surface Charge: $(Get-ModeDisplayText $state)")
    $statusItem.Enabled = $false
    $statusItem.Font = New-Object System.Drawing.Font($statusItem.Font, [System.Drawing.FontStyle]::Bold)
    [void]$menu.Items.Add('-')

    # Charge to 100% options
    $durations = [ordered]@{
        '100% for 2 hours' = 7200
        '100% for 1 day'   = 86400
        '100% for 3 days'  = 259200
        '100% for 1 week'  = 604800
    }
    # Find which duration bucket the remaining timeout falls into
    $checkedTimeout = 0
    if ($state -and $state.Mode -eq 2 -and $state.TimeoutSeconds -gt 0) {
        foreach ($t in $durations.Values) {
            if ($state.TimeoutSeconds -le $t) { $checkedTimeout = $t; break }
        }
        if ($checkedTimeout -eq 0) { $checkedTimeout = 604800 }
    }
    foreach ($label in $durations.Keys) {
        $timeout = $durations[$label]
        $item = $menu.Items.Add($label)
        if ($timeout -eq $checkedTimeout) {
            $item.Checked = $true
        }
        $item.Tag = $timeout
        $item.Add_Click({
            param($sender, $e)
            $t = $sender.Tag
            $ok = Set-ChargeUnlimited -TimeoutSeconds $t
            if ($ok) {
                Update-TrayState
            } else {
                [System.Windows.Forms.MessageBox]::Show(
                    "Failed to set charge mode.", "Surface Charge Tray", "OK", "Warning")
            }
        })
    }
    [void]$menu.Items.Add('-')

    # Limit to 80%
    $limit80 = $menu.Items.Add('Limit to 80%')
    if ($state -and $state.Mode -eq 1) { $limit80.Checked = $true }
    $limit80.Add_Click({
        $ok = Set-ChargeLimitTo80
        if ($ok) { Update-TrayState }
    })

    # Adaptive
    $adaptive = $menu.Items.Add('Adaptive (Smart Charging)')
    if ($state -and $state.Mode -eq 0) { $adaptive.Checked = $true }
    $adaptive.Add_Click({
        $ok = Set-ChargeAdaptive
        if ($ok) { Update-TrayState }
    })

    [void]$menu.Items.Add('-')

    # Exit
    $exitItem = $menu.Items.Add('Exit')
    $exitItem.Add_Click({
        $script:Exiting = $true
        Write-Log 'Exit requested'
        $script:NotifyIcon.Visible = $false
        $script:NotifyIcon.Dispose()
        $script:Timer.Stop()
        $script:Timer.Dispose()
        [System.Windows.Forms.Application]::Exit()
    })

    # Catch up on any refresh that was skipped while the menu was open
    $menu.Add_Closed({ Update-TrayState })

    return $menu
}

# --- Update tray icon and menu ---
$script:LastMode = -1
$script:LastText = $null
$script:StaleMenu = $null

function Update-TrayState {
    if ($script:Exiting) { return }
    try {
        $state = Get-ChargeMode
        $mode = if ($state) { $state.Mode } else { $null }
        $text = if ($state) { "Surface Charge: $(Get-ModeDisplayText $state)" } else { 'Surface Charge: Error reading state' }

        # Only redraw the icon when the mode changes (keeps GDI churn near zero)
        if ($mode -ne $script:LastMode) {
            Write-Log "State: Mode=$mode Limit=$($state.LimitPercent) Timeout=$($state.TimeoutSeconds)"
            $oldIcon = $script:NotifyIcon.Icon
            switch ($mode) {
                0       { $script:NotifyIcon.Icon = New-TrayIcon 'A' ([System.Drawing.Color]::DodgerBlue) }
                1       { $script:NotifyIcon.Icon = New-TrayIcon '80' ([System.Drawing.Color]::ForestGreen) }
                2       { $script:NotifyIcon.Icon = New-TrayIcon '100' ([System.Drawing.Color]::OrangeRed) }
                default { $script:NotifyIcon.Icon = New-TrayIcon '?' ([System.Drawing.Color]::Gray) }
            }
            if ($oldIcon) { $oldIcon.Dispose() }
            $script:LastMode = $mode
        }

        # Rebuild the menu only when its content changes, and never while it is open
        $current = $script:NotifyIcon.ContextMenuStrip
        if ($text -ne $script:LastText -and -not ($current -and $current.Visible)) {
            $script:NotifyIcon.Text = $text
            # The old menu may be the one whose Click handler is running right now,
            # so dispose it on the next refresh rather than immediately
            if ($script:StaleMenu) { $script:StaleMenu.Dispose() }
            $script:StaleMenu = $current
            $script:NotifyIcon.ContextMenuStrip = Build-ContextMenu $state
            $script:LastText = $text
        }
    } catch {
        Write-Log "Update-TrayState ERROR: $_"
    }
}

# --- Create NotifyIcon ---
$script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$script:NotifyIcon.Icon = New-TrayIcon '...' ([System.Drawing.Color]::Gray)
$script:NotifyIcon.Text = 'Surface Charge Tray - Loading...'
$script:NotifyIcon.Visible = $true

# Show context menu on left click too
$script:NotifyIcon.Add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        if ($sender.ContextMenuStrip) {
            $sender.ContextMenuStrip.Show([System.Windows.Forms.Cursor]::Position)
        }
    }
})

# --- Polling timer ---
$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = 30000  # 30 seconds
$script:Timer.Add_Tick({ Update-TrayState })
$script:Timer.Start()

# --- Initial state load ---
Update-TrayState

# --- Run message loop ---
[System.Windows.Forms.Application]::Run()
