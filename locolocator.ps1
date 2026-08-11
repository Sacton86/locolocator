#Requires -Version 5.1
<#
.SYNOPSIS
    LocoLocator — Ubiquiti airOS Auto-Provisioning Tool (Windows)
.DESCRIPTION
    Automatically detects, authenticates, and provisions Ubiquiti radios.
    Requires: PowerShell 5.1+, run as Administrator.
    Posh-SSH module is auto-installed if missing.
#>

# Bypass execution policy for this process so Posh-SSH format files can load
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

# --- Admin check ---
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[!] This script must be run as Administrator." -ForegroundColor Red
    Write-Host "    Right-click PowerShell and select 'Run as Administrator'." -ForegroundColor Yellow
    exit 1
}

# --- Banner ---
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "       LocoLocator - Radio Provisioning Tool       " -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host ""

# --- Ensure Posh-SSH is available ---
if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
    Write-Host "[*] Installing required module 'Posh-SSH'..." -ForegroundColor Yellow
    try {
        Install-Module -Name Posh-SSH -Force -Scope CurrentUser -AllowClobber -ErrorAction Stop
    } catch {
        Write-Host "[!] Failed to install Posh-SSH: $_" -ForegroundColor Red
        Write-Host "    Run manually: Install-Module -Name Posh-SSH -Force -Scope CurrentUser" -ForegroundColor Yellow
        exit 1
    }
}
Import-Module Posh-SSH -ErrorAction Stop

# --- Auto-detect active Ethernet adapter ---
$adapter = Get-NetAdapter | Where-Object {
    $_.Status -eq 'Up' -and
    ($_.PhysicalMediaType -match '802.3' -or $_.Name -match 'Ethernet|LAN') -and
    $_.Name -notmatch 'Bluetooth|Wi-Fi|Wireless|vEthernet|Loopback'
} | Select-Object -First 1

if (-not $adapter) {
    Write-Host "[!] Could not detect an active Ethernet adapter. Check your connection." -ForegroundColor Red
    exit 1
}
Write-Host "[*] Detected network adapter: $($adapter.Name)" -ForegroundColor Yellow

# --- Add IPs to adapter (skip if already present) ---
function Add-IPIfMissing {
    param([string]$AdapterName, [string]$IP, [int]$Prefix)
    $existing = Get-NetIPAddress -InterfaceAlias $AdapterName -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -eq $IP }
    if (-not $existing) {
        try { New-NetIPAddress -InterfaceAlias $AdapterName -IPAddress $IP -PrefixLength $Prefix -ErrorAction Stop | Out-Null }
        catch { }
    }
}
Add-IPIfMissing -AdapterName $adapter.Name -IP "192.168.1.50" -Prefix 24
Add-IPIfMissing -AdapterName $adapter.Name -IP "192.168.0.50" -Prefix 24

# --- 15-second countdown display ---
function Invoke-Countdown {
    param([int]$Seconds, [string]$Label)
    for ($i = $Seconds; $i -gt 0; $i--) {
        Write-Host "`r$Label [$i s remaining]  " -NoNewline -ForegroundColor Yellow
        Start-Sleep -Seconds 1
    }
    Write-Host "`r$Label [done]                    " -ForegroundColor Green
}

# --- SSH helpers using Posh-SSH ---
function New-RadioSession {
    param([string]$IP, [string]$User, [string]$Pass)
    $secPass = ConvertTo-SecureString $Pass -AsPlainText -Force
    $cred = New-Object PSCredential($User, $secPass)
    try {
        $session = New-SSHSession -ComputerName $IP -Credential $cred -AcceptKey $true -ConnectionTimeout 5 -ErrorAction Stop
        return $session
    } catch {
        return $null
    }
}

function Invoke-RadioCommand {
    param($SessionId, [string]$Command)
    return (Invoke-SSHCommand -SessionId $SessionId -Command $Command -EnsureConnection -TimeOut 30).Output
}

function Send-ConfigFile {
    param($SessionId, [string]$Content, [string]$IP, [string]$User, [string]$Pass)
    # Write content to a local temp file, then SCP it to the radio
    $tmpFile = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($tmpFile, $Content, [System.Text.Encoding]::UTF8)
        $secPass = ConvertTo-SecureString $Pass -AsPlainText -Force
        $cred = New-Object PSCredential($User, $secPass)
        Set-SCPItem -ComputerName $IP -Credential $cred -AcceptKey $true `
                    -Path $tmpFile -Destination "/tmp/system.cfg" -ErrorAction Stop
    } finally {
        Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
    }
}

# --- Scan for radio at known IPs ---
function Find-Radio {
    $candidates = @("192.168.1.20", "192.168.0.218", "192.168.0.219")
    foreach ($ip in $candidates) {
        if (Test-Connection -ComputerName $ip -Count 1 -Quiet -ErrorAction SilentlyContinue) {
            return $ip
        }
    }
    return $null
}

# --- Config generators (single-quote here-strings so $ is literal; ##SSID## replaced at runtime) ---
function Get-BuildingCfg {
    param([string]$SSID)
    $template = @'
aaa.1.br.devname=br0
wpasupplicant.status=disabled
wpasupplicant.profile.1.network.1.psk=!mpact1234
wpasupplicant.device.1.status=disabled
wireless.status=enabled
wireless.hideindoor.status=disabled
wireless.1.wds.status=enabled
wireless.1.status=enabled
wireless.1.ssid=##SSID##
wireless.1.security.type=none
wireless.1.scan_list.status=disabled
wireless.1.mac_acl.status=disabled
wireless.1.mac_acl.policy=allow
wireless.1.hide_ssid=enabled
wireless.1.devname=ath0
wireless.1.autowds=disabled
wireless.1.authmode=1
wireless.1.addmtikie=enabled
vlan.status=disabled
users.status=enabled
users.2.status=disabled
users.1.status=enabled
users.1.password=$1$jhG7EaVx$WR6RYDiaigNGMwDKeReNk0
users.1.name=Admin
update.check.status=enabled
system.timezone=GMT+12
system.cfg.version=65546
system.button.reset=disabled
sshd.status=enabled
sshd.port=22
route.status=enabled
route.1.status=disabled
route.1.netmask=0
route.1.ip=0.0.0.0
route.1.gateway=192.168.1.1
route.1.devname=br0
resolv.status=disabled
resolv.host.1.status=enabled
resolv.host.1.name=Impact-BuildingEnd
radio.status=enabled
radio.rate_module=atheros
radio.countrycode=840
radio.1.txpower=23
radio.1.subsystemid=0xe867
radio.1.status=enabled
radio.1.reg_obey=enabled
radio.1.rate.mcs=15
radio.1.rate.auto=enabled
radio.1.pollingnoack=0
radio.1.polling=enabled
radio.1.obey=enabled
radio.1.mode=master
radio.1.mcastrate=15
radio.1.ieee_mode=11nght40
radio.1.freq=0
radio.1.forbiasauto=1
radio.1.dfs.status=enabled
radio.1.devname=ath0
radio.1.cwm.mode=2
radio.1.cwm.enable=0
radio.1.countrycode=840
radio.1.chanbw=40
radio.1.cable.loss=0
radio.1.antenna.id=4
radio.1.antenna.gain=8
radio.1.acktimeout=25
radio.1.ackdistance=600
radio.1.ack.auto=enabled
ppp.status=disabled
netmode=bridge
netconf.status=enabled
netconf.3.up=enabled
netconf.3.status=enabled
netconf.3.role=mlan
netconf.3.netmask=255.255.255.0
netconf.3.mtu=1500
netconf.3.ip=0.0.0.0
netconf.3.devname=br0
netconf.3.autoip.status=enabled
netconf.2.up=enabled
netconf.2.status=enabled
netconf.2.role=bridge_port
netconf.2.promisc=enabled
netconf.2.netmask=255.255.255.0
netconf.2.mtu=1500
netconf.2.ip=0.0.0.0
netconf.2.devname=ath0
netconf.2.autoip.status=disabled
netconf.2.allmulti=enabled
netconf.1.up=enabled
netconf.1.status=enabled
netconf.1.role=bridge_port
netconf.1.promisc=enabled
netconf.1.netmask=255.255.255.0
netconf.1.mtu=1500
netconf.1.ip=0.0.0.0
netconf.1.devname=eth0
netconf.1.autoip.status=disabled
httpd.status=enabled
httpd.https.status=enabled
httpd.https.port=443
gui.language=en_US
ebtables.sys.vlan.status=disabled
ebtables.sys.status=enabled
ebtables.sys.eap.status=enabled
ebtables.sys.eap.1.status=enabled
ebtables.sys.eap.1.devname=ath0
ebtables.sys.arpnat.status=disabled
ebtables.sys.arpnat.1.status=enabled
ebtables.sys.arpnat.1.devname=ath0
ebtables.status=enabled
dhcpd.status=disabled
dhcpc.status=enabled
dhcpc.1.status=enabled
dhcpc.1.fallback_netmask=255.255.255.0
dhcpc.1.fallback=192.168.0.218
dhcpc.1.devname=br0
dhcp6c.status=disabled
bridge.status=enabled
bridge.1.stp.status=disabled
bridge.1.status=enabled
bridge.1.port.2.status=enabled
bridge.1.port.2.devname=ath0
bridge.1.port.1.status=enabled
bridge.1.port.1.devname=eth0
bridge.1.fd=1
bridge.1.devname=br0
aaa.status=enabled
aaa.1.wpa.psk=!mpact1234
aaa.1.wpa.mode=2
aaa.1.wpa.key.1.mgmt=WPA-PSK
aaa.1.wpa.1.pairwise=CCMP
aaa.1.status=enabled
aaa.1.ssid=##SSID##
aaa.1.driver=madwifi
aaa.1.devname=ath0
'@
    return $template.Replace('##SSID##', $SSID)
}

function Get-SignCfg {
    param([string]$SSID)
    $template = @'
aaa.1.status=disabled
aaa.status=disabled
bridge.1.devname=br0
bridge.1.fd=1
bridge.1.port.1.devname=eth0
bridge.1.port.1.status=enabled
bridge.1.port.2.devname=ath0
bridge.1.port.2.status=enabled
bridge.1.status=enabled
bridge.1.stp.status=disabled
bridge.status=enabled
dhcp6c.status=disabled
dhcpc.1.devname=br0
dhcpc.1.fallback=192.168.0.219
dhcpc.1.fallback_netmask=255.255.255.0
dhcpc.1.status=enabled
dhcpc.status=enabled
dhcpd.status=disabled
ebtables.status=enabled
ebtables.sys.arpnat.1.devname=ath0
ebtables.sys.arpnat.1.status=enabled
ebtables.sys.arpnat.status=disabled
ebtables.sys.eap.1.devname=ath0
ebtables.sys.eap.1.status=enabled
ebtables.sys.eap.status=enabled
ebtables.sys.status=enabled
ebtables.sys.vlan.status=disabled
gui.language=en_US
httpd.https.port=443
httpd.https.status=enabled
httpd.status=enabled
netconf.1.autoip.status=disabled
netconf.1.devname=eth0
netconf.1.ip=0.0.0.0
netconf.1.mtu=1500
netconf.1.netmask=255.255.255.0
netconf.1.promisc=enabled
netconf.1.role=bridge_port
netconf.1.status=enabled
netconf.1.up=enabled
netconf.2.allmulti=enabled
netconf.2.autoip.status=disabled
netconf.2.devname=ath0
netconf.2.ip=0.0.0.0
netconf.2.mtu=1500
netconf.2.netmask=255.255.255.0
netconf.2.promisc=enabled
netconf.2.role=bridge_port
netconf.2.status=enabled
netconf.2.up=enabled
netconf.3.autoip.status=enabled
netconf.3.devname=br0
netconf.3.ip=0.0.0.0
netconf.3.mtu=1500
netconf.3.netmask=255.255.255.0
netconf.3.role=mlan
netconf.3.status=enabled
netconf.3.up=enabled
netconf.status=enabled
netmode=bridge
ppp.status=disabled
radio.1.ack.auto=enabled
radio.1.ackdistance=600
radio.1.acktimeout=25
radio.1.antenna.gain=8
radio.1.antenna.id=4
radio.1.cable.loss=0
radio.1.chanbw=40
radio.1.countrycode=840
radio.1.cwm.enable=0
radio.1.cwm.mode=1
radio.1.devname=ath0
radio.1.dfs.status=enabled
radio.1.forbiasauto=1
radio.1.freq=0
radio.1.ieee_mode=11nght40
radio.1.mcastrate=15
radio.1.mode=managed
radio.1.obey=enabled
radio.1.polling=enabled
radio.1.pollingnoack=0
radio.1.rate.auto=enabled
radio.1.rate.mcs=15
radio.1.reg_obey=enabled
radio.1.status=enabled
radio.1.subsystemid=0xe867
radio.1.txpower=23
radio.countrycode=840
radio.rate_module=atheros
radio.status=enabled
resolv.host.1.name=Impact-SIGNEND
resolv.host.1.status=enabled
resolv.status=disabled
route.1.devname=br0
route.1.gateway=192.168.1.1
route.1.ip=0.0.0.0
route.1.netmask=0
route.1.status=disabled
route.status=enabled
sshd.port=22
sshd.status=enabled
system.button.reset=disabled
system.cfg.version=65546
system.date.status=disabled
system.timezone=GMT+12
update.check.status=enabled
users.1.name=Admin
users.1.password=$1$xd.2TZZX$vCGSJtFy.kU6ssmsFjj.91
users.1.status=enabled
users.2.status=disabled
users.status=enabled
vlan.status=disabled
wireless.1.addmtikie=enabled
wireless.1.authmode=1
wireless.1.autowds=disabled
wireless.1.devname=ath0
wireless.1.hide_ssid=disabled
wireless.1.mac_acl.policy=allow
wireless.1.mac_acl.status=disabled
wireless.1.security.type=none
wireless.1.ssid=##SSID##
wireless.1.status=enabled
wireless.1.wds.status=enabled
wireless.hideindoor.status=disabled
wireless.status=enabled
wpasupplicant.device.1.devname=ath0
wpasupplicant.device.1.driver=madwifi
wpasupplicant.device.1.profile=WPA-PSK
wpasupplicant.device.1.status=enabled
wpasupplicant.profile.1.name=WPA-PSK
wpasupplicant.profile.1.network.1.key_mgmt.1.name=WPA-PSK
wpasupplicant.profile.1.network.1.pairwise.1.name=CCMP
wpasupplicant.profile.1.network.1.proto.1.name=RSN
wpasupplicant.profile.1.network.1.psk=!mpact1234
wpasupplicant.profile.1.network.1.ssid=##SSID##
wpasupplicant.status=enabled
'@
    return $template.Replace('##SSID##', $SSID)
}

# =============================================================================
# Core Provisioning Function
# Parameters:
#   $PresetSSID  - reuse SSID from paired radio (skips SSID prompt)
#   $ForcedRole  - "1" = Building Side, "2" = Sign Side (skips role prompt)
# =============================================================================
function Invoke-Provision {
    param(
        [string]$PresetSSID = "",
        [string]$ForcedRole = ""
    )

    Write-Host ""
    Write-Host "[*] Scanning for connected radio..." -ForegroundColor Yellow

    $foundIP = Find-Radio

    while (-not $foundIP) {
        Write-Host "[!] No radio detected at 192.168.1.20, 192.168.0.218, or 192.168.0.219." -ForegroundColor Red
        Write-Host "  1) Try Again"         -ForegroundColor Cyan
        Write-Host "  2) Enter IP Manually" -ForegroundColor Cyan
        Write-Host "  3) Abort"             -ForegroundColor Cyan
        $scanChoice = Read-Host "Choice"
        switch ($scanChoice) {
            "1" {
                Write-Host "[*] Rescanning..." -ForegroundColor Yellow
                $foundIP = Find-Radio
            }
            "2" {
                $foundIP = Read-Host "Enter radio IP (e.g. 192.168.1.20)"
                if (-not $foundIP) {
                    Write-Host "[!] No IP entered." -ForegroundColor Red
                    $foundIP = $null
                }
            }
            default {
                Write-Host "[!] Aborting." -ForegroundColor Red
                return
            }
        }
    }

    Write-Host "[+] Radio detected at: $foundIP" -ForegroundColor Green
    Invoke-Countdown -Seconds 15 -Label "[*] Waiting for device to boot and connect"

    # --- Determine credentials by IP ---
    $validUser = $null
    $validPass = $null

    switch ($foundIP) {
        "192.168.1.20" {
            $validUser = "ubnt"
            $validPass = "ubnt"
            Write-Host "[*] Using ubnt credentials for $foundIP..." -ForegroundColor Yellow
        }
        { $_ -eq "192.168.0.218" -or $_ -eq "192.168.0.219" } {
            $validUser = "Admin"
            $validPass = "!mpact1234"
            Write-Host "[*] Using Admin credentials for $foundIP..." -ForegroundColor Yellow
        }
        default {
            # Manually entered IP — try known combinations
            Write-Host "[*] Testing credentials for $foundIP..." -ForegroundColor Yellow
            $credList = @(
                @{ User = "ubnt";  Pass = "ubnt"       },
                @{ User = "root";  Pass = "ubnt"       },
                @{ User = "Admin"; Pass = "!mpact1234" },
                @{ User = "root";  Pass = "!mpact1234" }
            )
            foreach ($cred in $credList) {
                $testSession = New-RadioSession -IP $foundIP -User $cred.User -Pass $cred.Pass
                if ($testSession) {
                    $validUser = $cred.User
                    $validPass = $cred.Pass
                    Remove-SSHSession -SessionId $testSession.SessionId | Out-Null
                    break
                }
            }
            if (-not $validUser) {
                Write-Host "[!] Auto-authentication failed. Enter credentials manually." -ForegroundColor Yellow
                $validUser = Read-Host "Username [ubnt]"
                if (-not $validUser) { $validUser = "ubnt" }
                $secPass = Read-Host "Password" -AsSecureString
                $validPass = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPass))
                $testSession = New-RadioSession -IP $foundIP -User $validUser -Pass $validPass
                if (-not $testSession) {
                    Write-Host "[!] Authentication failed. Aborting." -ForegroundColor Red
                    return
                }
                Remove-SSHSession -SessionId $testSession.SessionId | Out-Null
            }
        }
    }

    Write-Host "[+] Authenticated as '$validUser'" -ForegroundColor Green
    Write-Host ""

    # --- Role selection ---
    $roleChoice = $null
    if ($ForcedRole) {
        $roleChoice = $ForcedRole
        if ($roleChoice -eq "1") {
            Write-Host "[*] Configuring as: Building Side (AP / 192.168.0.218)" -ForegroundColor Cyan
        } else {
            Write-Host "[*] Configuring as: Sign Side (Station / 192.168.0.219)" -ForegroundColor Cyan
        }
    } else {
        Write-Host "Select configuration for this unit ($foundIP):" -ForegroundColor Cyan
        Write-Host "  1) Building Side  (AP / Fallback IP: 192.168.0.218)" -ForegroundColor Cyan
        Write-Host "  2) Sign Side      (Station / Fallback IP: 192.168.0.219)" -ForegroundColor Cyan
        $roleChoice = Read-Host "Choice [1 or 2]"
    }

    # --- SSID selection ---
    $customSSID = $null
    if ($PresetSSID) {
        $customSSID = $PresetSSID
        Write-Host "[*] Using SSID: $customSSID" -ForegroundColor Cyan
        Write-Host ""
    } else {
        $customSSID = Read-Host "Enter Wireless SSID [Default: Impact]"
        if (-not $customSSID) { $customSSID = "Impact" }
    }

    # --- Generate config ---
    $cfgContent = $null
    if ($roleChoice -eq "1") {
        Write-Host "[*] Generating Building Side config for SSID '$customSSID'..." -ForegroundColor Yellow
        $cfgContent = Get-BuildingCfg -SSID $customSSID
    } elseif ($roleChoice -eq "2") {
        Write-Host "[*] Generating Sign Side config for SSID '$customSSID'..." -ForegroundColor Yellow
        $cfgContent = Get-SignCfg -SSID $customSSID
    } else {
        Write-Host "[!] Invalid selection. Aborting." -ForegroundColor Red
        return
    }

    # --- Open SSH session ---
    $session = New-RadioSession -IP $foundIP -User $validUser -Pass $validPass
    if (-not $session) {
        Write-Host "[!] Could not open SSH session to $foundIP. Aborting." -ForegroundColor Red
        return
    }

    try {
        # Transfer config
        Write-Host "[*] Transferring configuration via SCP..." -ForegroundColor Yellow
        Send-ConfigFile -SessionId $session.SessionId -Content $cfgContent `
                        -IP $foundIP -User $validUser -Pass $validPass

        # Write to flash and reboot
        Write-Host "[*] Writing to flash and rebooting radio..." -ForegroundColor Yellow
        Invoke-RadioCommand -SessionId $session.SessionId -Command "cfgmtd -w -p /etc/ && reboot"
    } catch {
        Write-Host "[!] Error during provisioning: $_" -ForegroundColor Red
    } finally {
        Remove-SSHSession -SessionId $session.SessionId -ErrorAction SilentlyContinue | Out-Null
    }

    Invoke-Countdown -Seconds 15 -Label "[*] Waiting for radio to reboot successfully"

    Write-Host "====================================================" -ForegroundColor Green
    Write-Host "  [OK] Radio successfully configured and rebooted.  " -ForegroundColor Green
    Write-Host "       SSID: $customSSID"                             -ForegroundColor Green
    if ($roleChoice -eq "1") {
        Write-Host "       Role: Building Side (AP) - 192.168.0.218"  -ForegroundColor Green
    } else {
        Write-Host "       Role: Sign Side (Station) - 192.168.0.219" -ForegroundColor Green
    }
    Write-Host "====================================================" -ForegroundColor Green

    # --- Offer to provision paired radio (only on non-forced calls) ---
    if (-not $ForcedRole) {
        if ($roleChoice -eq "1") {
            Write-Host ""
            Write-Host "----------------------------------------------------" -ForegroundColor Cyan
            $pairChoice = Read-Host "Provision the paired Sign Side (219) radio now? [y/N]"
            if ($pairChoice -match '^[Yy]$') {
                Write-Host "[!] Unplug the current radio and connect the Sign Side radio." -ForegroundColor Yellow
                Read-Host "Press ENTER when the Sign Side radio is powered and connected"
                Invoke-Provision -PresetSSID $customSSID -ForcedRole "2"
            }
        } elseif ($roleChoice -eq "2") {
            Write-Host ""
            Write-Host "----------------------------------------------------" -ForegroundColor Cyan
            $pairChoice = Read-Host "Provision the paired Building Side (218) radio now? [y/N]"
            if ($pairChoice -match '^[Yy]$') {
                Write-Host "[!] Unplug the current radio and connect the Building Side radio." -ForegroundColor Yellow
                Read-Host "Press ENTER when the Building Side radio is powered and connected"
                Invoke-Provision -PresetSSID $customSSID -ForcedRole "1"
            }
        }
    }
}

# =============================================================================
# Main execution
# =============================================================================
Invoke-Provision

# Loop for additional independent units
while ($true) {
    Write-Host ""
    Write-Host "----------------------------------------------------" -ForegroundColor Cyan
    $again = Read-Host "Configure another radio? [y/N]"
    if ($again -match '^[Yy]$') {
        Write-Host "[!] Unplug the current radio and connect the next radio." -ForegroundColor Yellow
        Read-Host "Press ENTER when the next radio is powered and connected"
        Invoke-Provision
    } else {
        Write-Host ""
        Write-Host "[*] LocoLocator session complete. Goodbye!" -ForegroundColor Green
        Write-Host ""
        break
    }
}
