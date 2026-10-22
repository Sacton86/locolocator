#Requires -Version 5.1
<#
.SYNOPSIS
    LocoLocator — Ubiquiti airOS Repeater Chain Provisioning Tool (Windows)
.DESCRIPTION
    Provisions a full Building → Repeater(s) → Sign chain.
    IPs are assigned sequentially from 218 upward.
    Requires: PowerShell 5.1+, run as Administrator.
    Posh-SSH module is auto-installed if missing.
#>

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
Write-Host "   LocoLocator — Repeater Chain Provisioning       " -ForegroundColor Cyan
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
    Write-Host "[!] Could not detect an active Ethernet adapter." -ForegroundColor Red
    exit 1
}
Write-Host "[*] Detected adapter: $($adapter.Name)" -ForegroundColor Yellow

# --- Add IPs to adapter ---
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

# --- Countdown display ---
function Invoke-Countdown {
    param([int]$Seconds, [string]$Label)
    for ($i = $Seconds; $i -gt 0; $i--) {
        Write-Host "`r$Label [$i s remaining]  " -NoNewline -ForegroundColor Yellow
        Start-Sleep -Seconds 1
    }
    Write-Host "`r$Label [done]                    " -ForegroundColor Green
}

# --- Poll a TCP port until it accepts a connection (confirms sshd is actually up,
#     since airOS answers ping before its services finish starting) ---
function Wait-ForPort {
    param([string]$IP, [int]$Port, [int]$TimeoutSec = 30, [string]$Label = "Waiting for service")
    $waited = 0
    Write-Host $Label -NoNewline -ForegroundColor Yellow
    while ($true) {
        $ok = Test-NetConnection -ComputerName $IP -Port $Port -WarningAction SilentlyContinue -InformationLevel Quiet -ErrorAction SilentlyContinue
        if ($ok) {
            Write-Host " [ready, ${waited}s]" -ForegroundColor Green
            return $true
        }
        if ($waited -ge $TimeoutSec) {
            Write-Host " [not ready after ${TimeoutSec}s, continuing anyway]" -ForegroundColor Yellow
            return $false
        }
        Write-Host "." -NoNewline -ForegroundColor Yellow
        Start-Sleep -Seconds 2
        $waited += 2
    }
}

# --- Poll ping until a host responds (or stops responding), with a hard timeout ---
function Wait-ForPing {
    param([string]$IP, [int]$TimeoutSec = 90, [string]$Label = "Waiting for device", [string]$Mode = "up")
    $waited = 0
    Write-Host $Label -NoNewline -ForegroundColor Yellow
    while ($true) {
        $alive = Test-Connection -ComputerName $IP -Count 1 -Quiet -ErrorAction SilentlyContinue
        if ($Mode -eq "up" -and $alive) {
            Write-Host " [online, ${waited}s]" -ForegroundColor Green
            return $true
        }
        if ($Mode -eq "down" -and -not $alive) {
            Write-Host " [offline, ${waited}s]" -ForegroundColor Green
            return $true
        }
        if ($waited -ge $TimeoutSec) {
            Write-Host " [timed out after ${TimeoutSec}s]" -ForegroundColor Red
            return $false
        }
        Write-Host "." -NoNewline -ForegroundColor Yellow
        Start-Sleep -Seconds 2
        $waited += 2
    }
}

# --- SSH helpers ---
function New-RadioSession {
    param([string]$IP, [string]$User, [string]$Pass)
    $secPass = ConvertTo-SecureString $Pass -AsPlainText -Force
    $cred = New-Object PSCredential($User, $secPass)
    try {
        return New-SSHSession -ComputerName $IP -Credential $cred -AcceptKey $true -ConnectionTimeout 5 -ErrorAction Stop
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
    # Write content to a local temp file, then SCP it to the radio.
    # Returns the local file's byte length so the caller can verify the transfer.
    $tmpFile = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($tmpFile, $Content, [System.Text.Encoding]::UTF8)
        $localSize = (Get-Item $tmpFile).Length
        $secPass = ConvertTo-SecureString $Pass -AsPlainText -Force
        $cred = New-Object PSCredential($User, $secPass)
        Set-SCPItem -ComputerName $IP -Credential $cred -AcceptKey $true `
                    -Path $tmpFile -Destination "/tmp/system.cfg" -ErrorAction Stop
        return $localSize
    } finally {
        Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
    }
}

# --- Confirm a radio has actually rebooted: waits for it to drop offline, come
#     back online, and start accepting SSH connections again - instead of
#     guessing with a fixed sleep. ---
function Wait-ForReboot {
    param([string]$IP, [string]$User, [string]$Pass)

    if (-not (Wait-ForPing -IP $IP -TimeoutSec 20 -Label "[*] Confirming radio dropped offline for reboot" -Mode "down")) {
        Write-Host "[!] Radio never went offline - it may reboot quickly, or the reboot command may not have taken effect. Continuing to monitor..." -ForegroundColor Yellow
    }

    if (-not (Wait-ForPing -IP $IP -TimeoutSec 120 -Label "[*] Waiting for radio to come back online")) {
        Write-Host "[!] No response from $IP after 120s." -ForegroundColor Red
        $keepWaiting = Read-Host "Keep waiting another 2 minutes? [Y/n]"
        if ($keepWaiting -match '^[Nn]$') { return $false }
        if (-not (Wait-ForPing -IP $IP -TimeoutSec 120 -Label "[*] Still waiting for radio")) { return $false }
    }

    if (-not (Wait-ForPort -IP $IP -Port 22 -TimeoutSec 60 -Label "[*] Waiting for SSH to come back up")) {
        Write-Host "[!] Radio is pingable but SSH isn't answering yet." -ForegroundColor Yellow
        if (-not (Wait-ForPort -IP $IP -Port 22 -TimeoutSec 30 -Label "[*] One more check for SSH")) { return $false }
    }

    # Final sanity check: actually log in, don't just trust the open port.
    $testSession = New-RadioSession -IP $IP -User $User -Pass $Pass
    if (-not $testSession) {
        Write-Host "[!] SSH port is open but login isn't succeeding yet - giving it a few more seconds..." -ForegroundColor Yellow
        Start-Sleep -Seconds 5
        $testSession = New-RadioSession -IP $IP -User $User -Pass $Pass
        if (-not $testSession) { return $false }
    }
    Remove-SSHSession -SessionId $testSession.SessionId -ErrorAction SilentlyContinue | Out-Null
    return $true
}

# --- Scan for radio (wider range for repeater chains) ---
function Find-Radio {
    $candidates = @("192.168.1.20", "192.168.1.1")
    218..235 | ForEach-Object { $candidates += "192.168.0.$_" }
    foreach ($ip in $candidates) {
        if (Test-Connection -ComputerName $ip -Count 1 -Quiet -ErrorAction SilentlyContinue) {
            return $ip
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Config generators — ##SSID## and ##IP## are replaced at runtime
# ---------------------------------------------------------------------------

function Get-BuildingCfg {
    param([string]$SSID, [string]$IP)
    $t = @'
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
resolv.host.1.name=Impact-Building-##IP##
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
dhcpc.1.fallback=192.168.0.##IP##
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
    return $t.Replace('##SSID##', $SSID).Replace('##IP##', $IP)
}

function Get-RepeaterCfg {
    param([string]$SSID, [string]$IP)
    $t = @'
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
resolv.host.1.name=Impact-Repeater-##IP##
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
dhcpc.1.fallback=192.168.0.##IP##
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
    return $t.Replace('##SSID##', $SSID).Replace('##IP##', $IP)
}

function Get-SignCfg {
    param([string]$SSID, [string]$IP)
    $t = @'
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
dhcpc.1.fallback=192.168.0.##IP##
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
resolv.host.1.name=Impact-Sign-##IP##
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
    return $t.Replace('##SSID##', $SSID).Replace('##IP##', $IP)
}

# ---------------------------------------------------------------------------
# Detect and authenticate — returns $foundIP, $validUser, $validPass
# ---------------------------------------------------------------------------
function Invoke-DetectAndAuth {
    Write-Host "[*] Scanning for connected radio..." -ForegroundColor Yellow
    $foundIP = Find-Radio

    while (-not $foundIP) {
        Write-Host "[!] No radio detected." -ForegroundColor Red
        Write-Host "  1) Try Again"         -ForegroundColor Cyan
        Write-Host "  2) Enter IP Manually" -ForegroundColor Cyan
        Write-Host "  3) Skip"              -ForegroundColor Cyan
        $scanChoice = Read-Host "Choice"
        switch ($scanChoice) {
            "1" { $foundIP = Find-Radio }
            "2" {
                $foundIP = Read-Host "Enter radio IP (e.g. 192.168.1.20)"
                if (-not $foundIP) { $foundIP = $null }
            }
            default { return $null }
        }
    }

    Write-Host "[+] Radio detected at: $foundIP" -ForegroundColor Green
    Invoke-Countdown -Seconds 15 -Label "[*] Waiting for device to stabilise"

    $validUser = $null
    $validPass = $null

    $credList = @(
        @{ User = "ubnt";  Pass = "ubnt"       },
        @{ User = "root";  Pass = "ubnt"       },
        @{ User = "Admin"; Pass = "!mpact1234" },
        @{ User = "root";  Pass = "!mpact1234" }
    )

    Write-Host "[*] Testing credentials..." -ForegroundColor Yellow
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
            Write-Host "[!] Authentication failed." -ForegroundColor Red
            return $null
        }
        Remove-SSHSession -SessionId $testSession.SessionId | Out-Null
    }

    Write-Host "[+] Authenticated as '$validUser'" -ForegroundColor Green
    Write-Host ""
    return @{ IP = $foundIP; User = $validUser; Pass = $validPass }
}

# ---------------------------------------------------------------------------
# Transfer config and reboot
# ---------------------------------------------------------------------------
function Invoke-FlashAndReboot {
    param([string]$CfgContent, [hashtable]$Auth)

    $session = New-RadioSession -IP $Auth.IP -User $Auth.User -Pass $Auth.Pass
    if (-not $session) {
        Write-Host "[!] Could not open SSH session. Aborting this radio." -ForegroundColor Red
        return $false
    }

    $rebootTriggered = $false
    try {
        # Transfer config, then verify it landed intact before touching flash/reboot
        Write-Host "[*] Transferring configuration via SCP..." -ForegroundColor Yellow
        $localSize = Send-ConfigFile -SessionId $session.SessionId -Content $CfgContent `
                        -IP $Auth.IP -User $Auth.User -Pass $Auth.Pass

        $remoteSize = ((Invoke-RadioCommand -SessionId $session.SessionId -Command "wc -c < /tmp/system.cfg") -join "").Trim()

        if (-not $remoteSize -or [int]$remoteSize -ne [int]$localSize) {
            Write-Host "[!] Config transfer verification failed (local $localSize bytes vs remote '$remoteSize' bytes)." -ForegroundColor Red
            Write-Host "[!] Refusing to write to flash or reboot - the radio still has its previous config." -ForegroundColor Red
            return $false
        }
        Write-Host "[+] Config verified on device ($remoteSize bytes)." -ForegroundColor Green

        Write-Host "[*] Writing to flash and rebooting..." -ForegroundColor Yellow
        Invoke-RadioCommand -SessionId $session.SessionId -Command "cfgmtd -w -p /etc/ && reboot"
        $rebootTriggered = $true
    } catch {
        Write-Host "[!] Error during provisioning: $_" -ForegroundColor Red
    } finally {
        Remove-SSHSession -SessionId $session.SessionId -ErrorAction SilentlyContinue | Out-Null
    }

    if (-not $rebootTriggered) { return $false }

    if (Wait-ForReboot -IP $Auth.IP -User $Auth.User -Pass $Auth.Pass) {
        Write-Host "====================================================" -ForegroundColor Green
        Write-Host "  [OK] Radio configured and verified back online.   " -ForegroundColor Green
        Write-Host "====================================================" -ForegroundColor Green
        return $true
    } else {
        Write-Host "====================================================" -ForegroundColor Red
        Write-Host "  [!] Config was sent, but the radio has not come   " -ForegroundColor Red
        Write-Host "      back online yet. Check power/cabling and      " -ForegroundColor Red
        Write-Host "      verify it manually before trusting this unit. " -ForegroundColor Red
        Write-Host "====================================================" -ForegroundColor Red
        return $false
    }
}

# ===========================================================================
# MAIN
# ===========================================================================

$IpCounter   = 218
$ChainSSID   = ""
$RepeaterIPs = @()
$SignIP       = $null

# --- STEP 1: Building Side (always first, always 218) ---
Write-Host ""
Write-Host "--- STEP 1: BUILDING SIDE (192.168.0.$IpCounter) ---" -ForegroundColor Cyan

$auth = Invoke-DetectAndAuth
if (-not $auth) { Write-Host "[!] Aborting." -ForegroundColor Red; exit 1 }

$ChainSSID = Read-Host "Enter Wireless SSID for this chain [Default: Impact]"
if (-not $ChainSSID) { $ChainSSID = "Impact" }

Write-Host "[*] Generating Building Side config for SSID '$ChainSSID'..." -ForegroundColor Yellow
$cfg = Get-BuildingCfg -SSID $ChainSSID -IP "$IpCounter"
if (-not (Invoke-FlashAndReboot -CfgContent $cfg -Auth $auth)) {
    Write-Host "[!] Building Side provisioning failed. Aborting chain." -ForegroundColor Red
    exit 1
}
$IpCounter++

# --- STEP 2+: Repeaters and Sign Side ---
$Step = 2
while ($true) {
    Write-Host ""
    Write-Host "----------------------------------------------------" -ForegroundColor Cyan
    Write-Host "--- STEP ${Step}: Next radio → 192.168.0.$IpCounter ---" -ForegroundColor Cyan
    Write-Host "  1) Repeater   (AP — serves the next radio in chain)" -ForegroundColor Cyan
    Write-Host "  2) Sign Side  (Station — end of chain)"              -ForegroundColor Cyan
    Write-Host "  3) Exit"                                              -ForegroundColor Cyan
    $choice = Read-Host "Choice [1, 2, or 3]"

    switch ($choice) {
        "1" {
            Write-Host "[!] Unplug current radio. Connect the REPEATER radio." -ForegroundColor Yellow
            Read-Host "Press ENTER when powered on and connected"

            $auth = Invoke-DetectAndAuth
            if (-not $auth) { Write-Host "[!] Skipping this radio." -ForegroundColor Red; continue }

            Write-Host "[*] Generating Repeater config (192.168.0.$IpCounter)..." -ForegroundColor Yellow
            $cfg = Get-RepeaterCfg -SSID $ChainSSID -IP "$IpCounter"
            if (-not (Invoke-FlashAndReboot -CfgContent $cfg -Auth $auth)) {
                Write-Host "[!] Repeater provisioning failed. Aborting chain." -ForegroundColor Red
                exit 1
            }
            $RepeaterIPs += $IpCounter
            $IpCounter++
            $Step++
        }
        "2" {
            Write-Host "[!] Unplug current radio. Connect the SIGN SIDE radio." -ForegroundColor Yellow
            Read-Host "Press ENTER when powered on and connected"

            $auth = Invoke-DetectAndAuth
            if (-not $auth) { Write-Host "[!] Skipping this radio." -ForegroundColor Red; continue }

            Write-Host "[*] Generating Sign Side config (192.168.0.$IpCounter)..." -ForegroundColor Yellow
            $cfg = Get-SignCfg -SSID $ChainSSID -IP "$IpCounter"
            if (-not (Invoke-FlashAndReboot -CfgContent $cfg -Auth $auth)) {
                Write-Host "[!] Sign Side provisioning failed. Aborting chain." -ForegroundColor Red
                exit 1
            }
            $SignIP = $IpCounter
            $IpCounter++

            Write-Host ""
            Write-Host "====================================================" -ForegroundColor Green
            Write-Host "  Chain provisioning complete!"                        -ForegroundColor Green
            Write-Host "====================================================" -ForegroundColor Green
            Write-Host "  SSID          : $ChainSSID"                         -ForegroundColor Cyan
            Write-Host "  Building Side : 192.168.0.218"                      -ForegroundColor Cyan
            foreach ($rip in $RepeaterIPs) {
                Write-Host "  Repeater      : 192.168.0.$rip"                 -ForegroundColor Cyan
            }
            Write-Host "  Sign Side     : 192.168.0.$SignIP"                  -ForegroundColor Cyan
            Write-Host "====================================================" -ForegroundColor Green
            exit 0
        }
        "3" {
            Write-Host ""
            Write-Host "[*] Session ended." -ForegroundColor Green
            exit 0
        }
        default {
            Write-Host "[!] Invalid choice. Enter 1, 2, or 3." -ForegroundColor Red
        }
    }
}
