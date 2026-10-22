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

# --- Also make sure this adapter can pick up a real DHCP lease, in addition
#     to the two static addresses above. A radio can end up on either a
#     DHCP-provided subnet (if the site network offers one) or its static
#     fallback - this makes sure the laptop itself is reachable on whichever
#     one actually shows up, not just the two hardcoded /24s. Best-effort: an
#     isolated bench link with no DHCP server just leaves this unanswered. ---
try { Set-NetIPInterface -InterfaceAlias $adapter.Name -Dhcp Enabled -ErrorAction Stop } catch { }
Start-Sleep -Seconds 2
$dhcpLease = Get-NetIPAddress -InterfaceAlias $adapter.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue |
             Where-Object { $_.PrefixOrigin -eq 'Dhcp' } | Select-Object -First 1
if ($dhcpLease) {
    Write-Host "[+] Also has a DHCP lease on $($adapter.Name): $($dhcpLease.IPAddress)" -ForegroundColor Green
} else {
    Write-Host "[*] No DHCP server answered on $($adapter.Name) yet - using the static addresses only (normal for an isolated bench link)." -ForegroundColor Yellow
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
#     guessing with a fixed sleep. Returns @{ Success; IP } - IP is normally
#     the same as the input, but if the radio comes back with a *different*
#     DHCP lease than it had before (which the config we just wrote allows,
#     since dhcpc tries DHCP before falling back to the static address), we
#     re-discover it by broadcast and report the new address instead of just
#     timing out against the old one. ---
function Wait-ForReboot {
    param([string]$IP, [string]$User, [string]$Pass)

    if (-not (Wait-ForPing -IP $IP -TimeoutSec 20 -Label "[*] Confirming radio dropped offline for reboot" -Mode "down")) {
        Write-Host "[!] Radio never went offline - it may reboot quickly, or the reboot command may not have taken effect. Continuing to monitor..." -ForegroundColor Yellow
    }

    if (-not (Wait-ForPing -IP $IP -TimeoutSec 90 -Label "[*] Waiting for radio to come back online at $IP")) {
        Write-Host "[!] No response from $IP yet - broadcasting to see if it came back at a different DHCP address..." -ForegroundColor Yellow
        $found = Get-UbntDiscoveryReplies -TimeoutSec 3.0
        $other = @($found.Keys | Where-Object { $_ -ne $IP }) | Select-Object -First 1
        if ($other) {
            Write-Host "[+] Radio reappeared at $other (new DHCP lease) - continuing verification there." -ForegroundColor Green
            $IP = $other
        } else {
            Write-Host "[!] No response from $IP after 90s, and nothing new answered a discovery broadcast." -ForegroundColor Red
            $keepWaiting = Read-Host "Keep waiting another 2 minutes? [Y/n]"
            if ($keepWaiting -match '^[Nn]$') { return @{ Success = $false; IP = $IP } }
            if (-not (Wait-ForPing -IP $IP -TimeoutSec 120 -Label "[*] Still waiting for radio")) { return @{ Success = $false; IP = $IP } }
        }
    }

    if (-not (Wait-ForPort -IP $IP -Port 22 -TimeoutSec 60 -Label "[*] Waiting for SSH to come back up")) {
        Write-Host "[!] Radio is pingable but SSH isn't answering yet." -ForegroundColor Yellow
        if (-not (Wait-ForPort -IP $IP -Port 22 -TimeoutSec 30 -Label "[*] One more check for SSH")) { return @{ Success = $false; IP = $IP } }
    }

    # Final sanity check: actually log in, don't just trust the open port.
    $testSession = New-RadioSession -IP $IP -User $User -Pass $Pass
    if (-not $testSession) {
        Write-Host "[!] SSH port is open but login isn't succeeding yet - giving it a few more seconds..." -ForegroundColor Yellow
        Start-Sleep -Seconds 5
        $testSession = New-RadioSession -IP $IP -User $User -Pass $Pass
        if (-not $testSession) { return @{ Success = $false; IP = $IP } }
    }
    Remove-SSHSession -SessionId $testSession.SessionId -ErrorAction SilentlyContinue | Out-Null
    return @{ Success = $true; IP = $IP }
}

# --- Best-effort decode of a Ubiquiti discovery-protocol reply (TLV body
#     after a 4-byte header). Never throws - a field is simply omitted if the
#     packet doesn't look like what we expect, since the IP address (which is
#     all that actually matters for connecting) comes from the UDP sender
#     address, not from this payload. ---
function ConvertFrom-UbntReply {
    param([byte[]]$Data)
    $info = @{}
    try {
        $pos = 4
        while ($pos + 3 -le $Data.Length) {
            $type = $Data[$pos]
            $len = ([int]$Data[$pos + 1] -shl 8) -bor [int]$Data[$pos + 2]
            $pos += 3
            if ($pos + $len -gt $Data.Length) { break }
            $value = if ($len -gt 0) { $Data[$pos..($pos + $len - 1)] } else { @() }
            $pos += $len
            if (($type -eq 1 -or $type -eq 2) -and $len -ge 6 -and -not $info.ContainsKey('mac')) {
                $info['mac'] = ($value[0..5] | ForEach-Object { $_.ToString("x2") }) -join ":"
            } elseif ($type -eq 3 -and -not $info.ContainsKey('firmware')) {
                $info['firmware'] = [System.Text.Encoding]::ASCII.GetString($value).Trim([char]0)
            } elseif ($type -eq 0x0b -and -not $info.ContainsKey('hostname')) {
                $info['hostname'] = [System.Text.Encoding]::ASCII.GetString($value).Trim([char]0)
            } elseif (($type -eq 0x0c -or $type -eq 0x14) -and -not $info.ContainsKey('platform')) {
                $info['platform'] = [System.Text.Encoding]::ASCII.GetString($value).Trim([char]0)
            }
        }
    } catch { }
    return $info
}

# --- Broadcast the Ubiquiti discovery probe (UDP/10001) and collect every
#     reply. This finds a radio's real IP whether it ended up there via DHCP
#     or its static fallback - every airOS/UniFi device answers this
#     broadcast regardless of how it got its address, which a fixed
#     candidate-IP guess list can never do. Returns @{ ip = info-hashtable }. ---
function Get-UbntDiscoveryReplies {
    param([double]$TimeoutSec = 2.0)
    $found = @{}
    $udp = New-Object System.Net.Sockets.UdpClient
    try {
        $udp.EnableBroadcast = $true
        $udp.Client.ReceiveTimeout = 300
        $udp.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)))
        $probe = [byte[]](1, 0, 0, 0)
        $endpoint = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Broadcast, 10001)
        $udp.Send($probe, $probe.Length, $endpoint) | Out-Null
    } catch {
        $udp.Close()
        return $found
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
            $data = $udp.Receive([ref]$remote)
            $ip = $remote.Address.ToString()
            if (-not $found.ContainsKey($ip)) {
                $found[$ip] = ConvertFrom-UbntReply -Data $data
            }
        } catch {
            continue
        }
    }
    $udp.Close()
    return $found
}

# --- Combined scan: broadcast discovery (primary) plus a direct ping of the
#     known static/fallback addresses (backup, in case broadcast is filtered
#     by a managed switch or VLAN). Returns @{ ip = info-hashtable }. ---
function Get-RadioCandidates {
    $found = Get-UbntDiscoveryReplies -TimeoutSec 2.0
    $fallback = @("192.168.1.20", "192.168.0.218", "192.168.0.219")
    foreach ($ip in $fallback) {
        if (-not $found.ContainsKey($ip)) {
            if (Test-Connection -ComputerName $ip -Count 1 -Quiet -ErrorAction SilentlyContinue) {
                $found[$ip] = @{}
            }
        }
    }
    return $found
}

function Format-RadioLabel {
    param($Info)
    $label = if ($Info.platform) { $Info.platform } else { "Ubiquiti airOS device" }
    $bits = @()
    if ($Info.hostname) { $bits += $Info.hostname }
    if ($Info.mac) { $bits += $Info.mac }
    if ($bits.Count -gt 0) { $label = "$label ($($bits -join ' / '))" }
    return $label
}

# --- Keep scanning until at least one radio answers, printing elapsed time so
#     the technician knows it's working rather than hung - a previously-
#     configured radio can take up to ~2 minutes to time out its DHCP attempt
#     and fall back to its static address. ---
function Wait-ForRadioScan {
    param([int]$MaxWaitSec = 150)
    $waited = 0
    Write-Host "[*] Broadcasting discovery probe + checking known addresses" -NoNewline -ForegroundColor Yellow
    while ($true) {
        $found = Get-RadioCandidates
        if ($found.Count -gt 0) {
            Write-Host " [$($found.Count) device(s) found, ${waited}s]" -ForegroundColor Green
            return $found
        }
        if ($waited -ge $MaxWaitSec) {
            Write-Host " [none found after ${waited}s]" -ForegroundColor Yellow
            return $found
        }
        Write-Host "." -NoNewline -ForegroundColor Yellow
        $waited += 2
    }
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

    $foundIP = $null
    $foundInfo = @{}
    while (-not $foundIP) {
        $candidates = Wait-ForRadioScan -MaxWaitSec 150

        if ($candidates.Count -eq 1) {
            $foundIP = @($candidates.Keys)[0]
            $foundInfo = $candidates[$foundIP]
            continue
        }
        if ($candidates.Count -gt 1) {
            while (-not $foundIP) {
                Write-Host "Multiple Ubiquiti devices answered - select the one connected to THIS cable:" -ForegroundColor Cyan
                $ips = @($candidates.Keys)
                for ($i = 0; $i -lt $ips.Count; $i++) {
                    Write-Host "  $($i+1)) $($ips[$i]) - $(Format-RadioLabel -Info $candidates[$ips[$i]])" -ForegroundColor Cyan
                }
                $pick = Read-Host "Choice"
                $idx = 0
                if ([int]::TryParse($pick, [ref]$idx) -and $idx -ge 1 -and $idx -le $ips.Count) {
                    $foundIP = $ips[$idx - 1]
                    $foundInfo = $candidates[$foundIP]
                } else {
                    Write-Host "[!] Invalid selection." -ForegroundColor Red
                }
            }
            continue
        }

        Write-Host "[!] No radio answered a discovery broadcast or the known fallback addresses." -ForegroundColor Red
        # Labeled loop: PowerShell's `break` inside a switch only exits the
        # switch itself (unlike bash's `case`), so "Keep Scanning" needs an
        # explicit labeled break to drop out of this menu and re-scan.
        :menuLoop while (-not $foundIP) {
            Write-Host "  1) Keep Scanning"      -ForegroundColor Cyan
            Write-Host "  2) Enter IP Manually" -ForegroundColor Cyan
            Write-Host "  3) Abort"             -ForegroundColor Cyan
            $scanChoice = Read-Host "Choice"
            switch ($scanChoice) {
                "1" { break menuLoop }
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
    }

    Write-Host "[+] Radio detected at: $foundIP" -ForegroundColor Green
    if ($foundInfo.Count -gt 0) {
        Write-Host "    $(Format-RadioLabel -Info $foundInfo)" -ForegroundColor Green
    }
    Wait-ForPort -IP $foundIP -Port 22 -TimeoutSec 30 -Label "[*] Waiting for SSH to be ready" | Out-Null

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

    # --- Role and SSID selection, with a confirmation step before anything is
    #     flashed so a wrong menu pick can be caught before it's written. ---
    $roleChoice = $null
    $customSSID = $null
    while ($true) {
        if ($ForcedRole) {
            $roleChoice = $ForcedRole
        } elseif (-not $roleChoice) {
            Write-Host "Select configuration for this unit ($foundIP):" -ForegroundColor Cyan
            Write-Host "  1) Building Side  (AP / Fallback IP: 192.168.0.218)" -ForegroundColor Cyan
            Write-Host "  2) Sign Side      (Station / Fallback IP: 192.168.0.219)" -ForegroundColor Cyan
            $roleChoice = Read-Host "Choice [1 or 2]"
        }

        if ($roleChoice -ne "1" -and $roleChoice -ne "2") {
            Write-Host "[!] Invalid selection. Aborting." -ForegroundColor Red
            return
        }

        if ($PresetSSID) {
            $customSSID = $PresetSSID
        } elseif (-not $customSSID) {
            $customSSID = Read-Host "Enter Wireless SSID [Default: Impact]"
            if (-not $customSSID) { $customSSID = "Impact" }
        }

        $roleLabel = if ($roleChoice -eq "1") { "Building Side (AP) - 192.168.0.218" } else { "Sign Side (Station) - 192.168.0.219" }
        Write-Host ""
        Write-Host "----------------------------------------------------" -ForegroundColor Cyan
        Write-Host "About to flash $foundIP`:" -ForegroundColor Cyan
        Write-Host "  Role: $roleLabel" -ForegroundColor Cyan
        Write-Host "  SSID: $customSSID" -ForegroundColor Cyan
        Write-Host "----------------------------------------------------" -ForegroundColor Cyan
        $confirm = Read-Host "Proceed with this configuration? [Y/n]"
        if ($confirm -match '^[Nn]$') {
            if ($ForcedRole -or $PresetSSID) {
                Write-Host "[!] Aborting this radio." -ForegroundColor Red
                return
            }
            Write-Host "[*] Let's redo that." -ForegroundColor Yellow
            $roleChoice = $null
            $customSSID = $null
            continue
        }
        break
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

    $rebootTriggered = $false
    try {
        # Transfer config, then verify it landed intact before touching flash/reboot
        Write-Host "[*] Transferring configuration via SCP..." -ForegroundColor Yellow
        $localSize = Send-ConfigFile -SessionId $session.SessionId -Content $cfgContent `
                        -IP $foundIP -User $validUser -Pass $validPass

        $remoteSize = ((Invoke-RadioCommand -SessionId $session.SessionId -Command "wc -c < /tmp/system.cfg") -join "").Trim()

        if (-not $remoteSize -or [int]$remoteSize -ne [int]$localSize) {
            Write-Host "[!] Config transfer verification failed (local $localSize bytes vs remote '$remoteSize' bytes)." -ForegroundColor Red
            Write-Host "[!] Refusing to write to flash or reboot - the radio still has its previous config." -ForegroundColor Red
            return
        }
        Write-Host "[+] Config verified on device ($remoteSize bytes)." -ForegroundColor Green

        # Write to flash and reboot
        Write-Host "[*] Writing to flash and rebooting radio..." -ForegroundColor Yellow
        Invoke-RadioCommand -SessionId $session.SessionId -Command "cfgmtd -w -p /etc/ && reboot"
        $rebootTriggered = $true
    } catch {
        Write-Host "[!] Error during provisioning: $_" -ForegroundColor Red
    } finally {
        Remove-SSHSession -SessionId $session.SessionId -ErrorAction SilentlyContinue | Out-Null
    }

    if (-not $rebootTriggered) { return }

    $rebootResult = Wait-ForReboot -IP $foundIP -User $validUser -Pass $validPass
    if ($rebootResult.Success) {
        Write-Host "====================================================" -ForegroundColor Green
        Write-Host "  [OK] Radio rebooted and verified back online.     " -ForegroundColor Green
        Write-Host "       SSID: $customSSID"                             -ForegroundColor Green
        if ($roleChoice -eq "1") {
            Write-Host "       Role: Building Side (AP) - fallback 192.168.0.218" -ForegroundColor Green
        } else {
            Write-Host "       Role: Sign Side (Station) - fallback 192.168.0.219" -ForegroundColor Green
        }
        Write-Host "       Answering now at: $($rebootResult.IP)"         -ForegroundColor Green
        Write-Host "====================================================" -ForegroundColor Green
    } else {
        Write-Host "====================================================" -ForegroundColor Red
        Write-Host "  [!] Config was sent, but the radio has not come   " -ForegroundColor Red
        Write-Host "      back online yet. Check power/cabling and      " -ForegroundColor Red
        Write-Host "      verify it manually before trusting this unit. " -ForegroundColor Red
        Write-Host "====================================================" -ForegroundColor Red
    }

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
