# LocoLocator

Automated Ubiquiti airOS radio provisioning tool for field technicians.
Detects, authenticates, and flashes Building Side (AP / 218) and Sign Side (Station / 219) radios — including paired-radio follow-up in a single session.

---

## Quick Start — Run Remotely

### Linux (run as root / sudo)

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Sacton86/locolocator/main/standard_config/locolocator.sh)"
```

This downloads the script into memory first, then runs it as a `bash -c` argument — **not** as `curl | sudo bash`. That distinction matters: this script asks interactive questions (role, SSID, confirmations) with `read -p`, and a plain `curl ... | sudo bash` pipe makes `read` consume the *script's own remaining source code* as if it were your typed answer (bash reads both the script and your input from the same stdin stream), silently corrupting execution the first time any prompt is hit. `bash -c "$(...)"` downloads the whole script into a string first, so stdin stays free for your actual answers.

To download first and then run:

```bash
curl -sSL -o locolocator.sh https://raw.githubusercontent.com/Sacton86/locolocator/main/standard_config/locolocator.sh
chmod +x locolocator.sh
sudo bash locolocator.sh
```

---

### Windows (run PowerShell as Administrator)

```powershell
Invoke-Expression (Invoke-WebRequest -Uri "https://raw.githubusercontent.com/Sacton86/locolocator/main/standard_config/locolocator.ps1" -UseBasicParsing).Content
```

To download first and then run:

```powershell
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/Sacton86/locolocator/main/standard_config/locolocator.ps1" -OutFile "locolocator.ps1" -UseBasicParsing
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\locolocator.ps1
```

---

### Web UI (Linux, run as root / sudo)

Prefer a browser wizard over a terminal? `locolocator_web.py` runs the same engine behind a local web page — no install beyond Python 3 (already on any Debian-based technician laptop). It's entirely browser-driven (no console prompts), so unlike the CLI script above, it's safe to pipe straight off GitHub with no clone needed:

```bash
curl -fsSL https://raw.githubusercontent.com/Sacton86/locolocator/main/standard_config/locolocator_web.py | sudo python3 -
```

Or, if you already have the repo checked out locally:

```bash
sudo python3 standard_config/locolocator_web.py
```

### Web UI (Windows, run PowerShell as Administrator)

`locolocator_web.ps1` is the same wizard, native to Windows — no install beyond what the CLI script already needs (PowerShell 5.1+ is built into Windows 10+, Posh-SSH auto-installs the same way). It's also browser-driven with no console prompts:

```powershell
Invoke-Expression (Invoke-WebRequest -Uri "https://raw.githubusercontent.com/Sacton86/locolocator/main/standard_config/locolocator_web.ps1" -UseBasicParsing).Content
```

Or, if you already have the repo checked out locally:

```powershell
.\standard_config\locolocator_web.ps1
```

Both start a server on `127.0.0.1` only (never reachable from the network) and open your default browser to it automatically. Walk through Scan → Authenticate → Configure → Confirm → Flash, with a live progress log instead of terminal text. The radio scan starts automatically on page load and keeps retrying in the background until one answers — no need to click anything until a radio is actually connected. If more than one Ubiquiti device answers (e.g. you're on a live network with other gear on it), you'll be shown a picker with each device's IP, platform, hostname, and MAC so you can confirm which one is actually on the cable in front of you before anything gets touched.

---

## Requirements

### Linux
- Must be run with `sudo` / as root
- `sshpass` — auto-installed if missing (`apt`)
- Web UI additionally requires Python 3 (stdlib only, no pip packages)
- Radio discovery is a plain UDP broadcast (stdlib `socket`, no extra packages). `dhclient` or `dhcpcd` is used for the laptop's own DHCP lease if either is already present — neither is required, and nothing breaks without them

### Windows
- PowerShell 5.1+ (built-in on Windows 10 and later)
- Must run PowerShell **as Administrator**
- `Posh-SSH` module — auto-installed if missing
- Same requirements for the web UI (`locolocator_web.ps1`) — no extra install
- Radio discovery uses .NET's built-in `UdpClient` — no extra module needed

---

## What It Does

1. **Auto-detects** your active Ethernet interface
2. **Adds** both `192.168.1.x` and `192.168.0.x` static subnets to your adapter, **and** requests a real DHCP lease on it in parallel — so your laptop is reachable whether the site network is static or DHCP (best-effort: an isolated bench link with no DHCP server just leaves the static addresses in place)
3. **Finds the radio by broadcasting Ubiquiti's own discovery protocol** (UDP/10001) instead of guessing addresses — this is what lets it locate a radio no matter whether it ended up on a DHCP-assigned IP or its static fallback. A direct ping of the three known fallback addresses (`192.168.1.20`, `192.168.0.218`, `192.168.0.219`) runs alongside it as a backup, in case broadcast is filtered by a managed switch or VLAN. If more than one Ubiquiti device answers, you're shown a picker (IP, platform, hostname, MAC) to confirm which one is actually on the cable — nothing is touched until you choose
4. **Auto-selects credentials** based on the detected IP:
   - `192.168.1.20` → `ubnt / ubnt`
   - `192.168.0.218` or `192.168.0.219` → `Admin / !mpact1234`
   - any other address (DHCP-assigned) → tries all known credential combinations automatically
5. **Polls the SSH port** until the device actually answers, instead of guessing with a fixed wait
6. Prompts for **role** (Building Side or Sign Side) and **SSID**, then shows a **confirmation summary before flashing anything**
7. Transfers the configuration and **verifies it landed intact** (byte-for-byte) before writing to flash
8. Writes to flash and reboots the radio
9. **Confirms the reboot actually happened** — waits for the radio to drop offline, come back online, and accept an SSH login again, instead of guessing with a fixed wait. If it comes back on a *different* DHCP-assigned address than it had before, a fresh discovery broadcast finds it there too, instead of timing out against the old address
10. **Offers to provision the paired radio** immediately after (reusing the same SSID)
11. Loops to configure additional units as needed

A previously-configured radio tries DHCP before falling back to its static address, which can take up to ~2 minutes — the scan keeps retrying automatically and tells you how long it's been waiting, instead of giving up after a few seconds.
