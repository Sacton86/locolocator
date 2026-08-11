# LocoLocator

Automated Ubiquiti airOS radio provisioning tool for field technicians.
Detects, authenticates, and flashes Building Side (AP / 218) and Sign Side (Station / 219) radios — including paired-radio follow-up in a single session.

---

## Quick Start — Run Remotely

### Linux (run as root / sudo)

```bash
curl -sSL https://raw.githubusercontent.com/Sacton86/locolocator/main/locolocator.sh | sudo bash
```

To download first and then run:

```bash
curl -sSL -o locolocator.sh https://raw.githubusercontent.com/Sacton86/locolocator/main/locolocator.sh
chmod +x locolocator.sh
sudo bash locolocator.sh
```

---

### Windows (run PowerShell as Administrator)

```powershell
Invoke-Expression (Invoke-WebRequest -Uri "https://raw.githubusercontent.com/Sacton86/locolocator/main/locolocator.ps1" -UseBasicParsing).Content
```

To download first and then run:

```powershell
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/Sacton86/locolocator/main/locolocator.ps1" -OutFile "locolocator.ps1" -UseBasicParsing
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\locolocator.ps1
```

---

## Requirements

### Linux
- Must be run with `sudo` / as root
- `sshpass` — auto-installed if missing (`apt`)

### Windows
- PowerShell 5.1+ (built-in on Windows 10 and later)
- Must run PowerShell **as Administrator**
- `Posh-SSH` module — auto-installed if missing

---

## What It Does

1. **Auto-detects** your active Ethernet interface
2. **Adds** both `192.168.1.x` and `192.168.0.x` subnets to your adapter
3. **Scans** for a radio at `192.168.1.20`, `192.168.0.218`, or `192.168.0.219`
4. **Auto-selects credentials** based on the detected IP:
   - `192.168.1.20` → `ubnt / ubnt`
   - `192.168.0.218` or `192.168.0.219` → `Admin / !mpact1234`
5. **Waits 15 seconds** for the device to stabilize before connecting
6. Prompts for **role** (Building Side or Sign Side) and **SSID**
7. Flashes the configuration and reboots the radio
8. **Waits 15 seconds** for the reboot to complete
9. **Offers to provision the paired radio** immediately after (reusing the same SSID)
10. Loops to configure additional units as needed
