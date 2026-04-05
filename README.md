# Surface Charge Tray

A lightweight system tray app for Microsoft Surface devices that lets you control the battery charge mode without opening the Surface app or rebooting into UEFI.

Way quick and 1 click change vs slow Surface book app.

![Screenshot](https://img.shields.io/badge/platform-Windows-blue)

## Features

- **System tray icon** shows current charge mode at a glance (A = Adaptive, 80 = Limited, 100 = Charging to full)
- **Quick switching** between charge modes via right-click or left-click menu:
  - **Charge to 100%** with a timeout (2 hours, 1 day, 3 days, or 1 week)
  - **Limit to 80%** for everyday battery longevity
  - **Adaptive (Smart Charging)** lets the firmware decide
- **Status display** shows the active mode and remaining time for temporary 100% charging
- **30-second polling** keeps the icon and menu in sync with the actual device state
- **Optional startup registration** via a scheduled task with admin privileges

## Requirements

- **Microsoft Surface** device with the [Surface app](https://apps.microsoft.com/detail/9WZDNCRFJB8P) installed (provides the `BatteryDm.exe` firmware interface)
- **Windows 10/11**
- **PowerShell 5.1+**
- **Administrator privileges** (required for DeviceIoControl access to the battery firmware)

## Installation

### Quick start

Run the script directly — it will self-elevate and prompt for UAC:

```powershell
powershell -ExecutionPolicy Bypass -File .\SurfaceChargeTray.ps1
```

### Run at startup

To have the tray app start automatically at logon with admin privileges, run the installer (as admin):

```powershell
.\Install-Startup.ps1
```

This creates a scheduled task called `SurfaceChargeTray` that runs at logon with highest privileges.

To remove it:

```powershell
.\Install-Startup.ps1 -Uninstall
```

## Usage

Once running, a small icon appears in the system tray:

| Icon | Meaning |
|------|---------|
| **A** (blue) | Adaptive / Smart Charging |
| **80** (green) | Limited to 80% |
| **100** (red) | Charging to 100% (with timeout) |
| **?** (grey) | Error reading battery state |

Click the icon (left or right) to open the menu and switch modes.

## How it works

The app loads the `BatteryDm.exe` .NET assembly from the installed Surface app and uses it to communicate directly with the Surface battery firmware via `DeviceIoControl`. This is the same mechanism the Surface app itself uses.

## Files

| File | Description |
|------|-------------|
| `SurfaceChargeTray.ps1` | Main tray application |
| `Install-Startup.ps1` | Scheduled task installer/uninstaller |
| `test-read-chargemode.ps1` | Dev utility — reads current charge mode |
| `test-set-chargemode.ps1` | Dev utility — tests setting charge mode |

## License

MIT
