#Requires -Version 5.1
<#
.SYNOPSIS
    LocoLocator Web — local browser UI for Ubiquiti airOS radio provisioning (Windows).
.DESCRIPTION
    Same engine as locolocator.ps1 (scan -> authenticate -> configure -> flash ->
    verify reboot), served as a single local web page instead of a console wizard.
    Binds to 127.0.0.1 only — never reachable from the network. No extra runtime
    to install: PowerShell 5.1+ is built into Windows 10+, and Posh-SSH is
    auto-installed the same way locolocator.ps1 already does.
    Requires: PowerShell 5.1+, run as Administrator.
.NOTES
    Run with: Right-click -> Run with PowerShell (as Administrator), or:
        powershell -ExecutionPolicy Bypass -File locolocator_web.ps1
#>

Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

# --- Admin check ---
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[!] This script must be run as Administrator." -ForegroundColor Red
    Write-Host "    Right-click PowerShell and select 'Run as Administrator'." -ForegroundColor Yellow
    exit 1
}

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "   LocoLocator Web — Radio Provisioning Tool        " -ForegroundColor Cyan
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

# --- Auto-detect active Ethernet adapter and add both subnets ---
function Add-IPIfMissing {
    param([string]$AdapterName, [string]$IP, [int]$Prefix)
    $existing = Get-NetIPAddress -InterfaceAlias $AdapterName -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -eq $IP }
    if (-not $existing) {
        try { New-NetIPAddress -InterfaceAlias $AdapterName -IPAddress $IP -PrefixLength $Prefix -ErrorAction Stop | Out-Null }
        catch { }
    }
}

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
$dhcpLeaseAddr = Get-NetIPAddress -InterfaceAlias $adapter.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                 Where-Object { $_.PrefixOrigin -eq 'Dhcp' } | Select-Object -First 1
$script:DhcpLeaseInfo = if ($dhcpLeaseAddr) {
    Write-Host "[+] Also has a DHCP lease on $($adapter.Name): $($dhcpLeaseAddr.IPAddress)" -ForegroundColor Green
    @{ status = "ok"; ip = $dhcpLeaseAddr.IPAddress }
} else {
    Write-Host "[*] No DHCP server answered on $($adapter.Name) yet - using the static addresses only (normal for an isolated bench link)." -ForegroundColor Yellow
    @{ status = "none"; ip = $null }
}

# ---------------------------------------------------------------------------
# Engine — everything below this point is also loaded into background
# runspaces (one per SSE stream, one per provisioning job), so these
# functions must not depend on script-scope state; state is always passed
# explicitly via $GlobalState.
# ---------------------------------------------------------------------------

function Wait-ForConditionSimple {
    param([scriptblock]$Check, [int]$TimeoutSec, [int]$IntervalSec = 2)
    $waited = 0
    while ($true) {
        if (& $Check) { return $true }
        if ($waited -ge $TimeoutSec) { return $false }
        Start-Sleep -Seconds $IntervalSec
        $waited += $IntervalSec
    }
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

# --- SSH helpers (Posh-SSH) ---
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

# ---------------------------------------------------------------------------
# Provisioning job — runs on a background runspace so it doesn't block the
# HTTP listener. Progress is pushed through the job's queue and streamed to
# the browser over Server-Sent Events by Send-JobStream.
# ---------------------------------------------------------------------------

function New-ProvisionJob {
    return [hashtable]::Synchronized(@{
        Id     = [guid]::NewGuid().ToString('N')
        Queue  = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
        Result = $null
        Done   = $false
        PS     = $null
        RS     = $null
    })
}

function Add-JobLog {
    param($Job, [string]$Level, [string]$Text)
    $Job.Queue.Enqueue(@{ level = $Level; text = $Text })
}

function Complete-ProvisionJob {
    param($Job, [string]$Result)
    $Job.Result = $Result
    $Job.Done = $true
}

function Wait-ForRebootJob {
    param($Job, [string]$IP, [string]$User, [string]$Pass)

    Add-JobLog $Job "info" "Confirming radio dropped offline for reboot..."
    if (-not (Wait-ForConditionSimple -Check { -not (Test-Connection -ComputerName $IP -Count 1 -Quiet -ErrorAction SilentlyContinue) } -TimeoutSec 20)) {
        Add-JobLog $Job "warn" "Radio never went offline - it may reboot quickly, or the reboot command may not have taken effect. Continuing to monitor..."
    }

    Add-JobLog $Job "info" "Waiting for radio to come back online at $IP (up to 90s)..."
    if (-not (Wait-ForConditionSimple -Check { Test-Connection -ComputerName $IP -Count 1 -Quiet -ErrorAction SilentlyContinue } -TimeoutSec 90)) {
        Add-JobLog $Job "warn" "No response from $IP yet - broadcasting to see if it came back at a different DHCP address..."
        $found = Get-UbntDiscoveryReplies -TimeoutSec 3.0
        $other = @($found.Keys | Where-Object { $_ -ne $IP }) | Select-Object -First 1
        if ($other) {
            Add-JobLog $Job "success" "Radio reappeared at $other (new DHCP lease) - continuing verification there."
            $IP = $other
        } elseif (-not (Wait-ForConditionSimple -Check { Test-Connection -ComputerName $IP -Count 1 -Quiet -ErrorAction SilentlyContinue } -TimeoutSec 60)) {
            Add-JobLog $Job "error" "No response from $IP after waiting, and nothing new answered a discovery broadcast."
            return @{ Success = $false; IP = $IP }
        }
    }

    Add-JobLog $Job "info" "Waiting for SSH to come back up..."
    if (-not (Wait-ForConditionSimple -Check { Test-NetConnection -ComputerName $IP -Port 22 -WarningAction SilentlyContinue -InformationLevel Quiet -ErrorAction SilentlyContinue } -TimeoutSec 60)) {
        Add-JobLog $Job "warn" "Radio is pingable but SSH isn't answering yet - one more check..."
        if (-not (Wait-ForConditionSimple -Check { Test-NetConnection -ComputerName $IP -Port 22 -WarningAction SilentlyContinue -InformationLevel Quiet -ErrorAction SilentlyContinue } -TimeoutSec 30)) {
            Add-JobLog $Job "error" "SSH never came back up."
            return @{ Success = $false; IP = $IP }
        }
    }

    $testSession = New-RadioSession -IP $IP -User $User -Pass $Pass
    if (-not $testSession) {
        Add-JobLog $Job "warn" "SSH port is open but login isn't succeeding yet - giving it a few more seconds..."
        Start-Sleep -Seconds 5
        $testSession = New-RadioSession -IP $IP -User $User -Pass $Pass
        if (-not $testSession) {
            Add-JobLog $Job "error" "Could not log back in after reboot."
            return @{ Success = $false; IP = $IP }
        }
    }
    Remove-SSHSession -SessionId $testSession.SessionId -ErrorAction SilentlyContinue | Out-Null
    return @{ Success = $true; IP = $IP }
}

function Invoke-ProvisionCore {
    param($Job, [string]$IP, [string]$User, [string]$Pass, [string]$Role, [string]$Ssid)
    try {
        $roleLabel = if ($Role -eq "1") { "Building Side (AP) - 192.168.0.218" } else { "Sign Side (Station) - 192.168.0.219" }
        Add-JobLog $Job "info" "Generating $roleLabel config for SSID '$Ssid'..."
        $cfgContent = if ($Role -eq "1") { Get-BuildingCfg -SSID $Ssid } else { Get-SignCfg -SSID $Ssid }

        $session = New-RadioSession -IP $IP -User $User -Pass $Pass
        if (-not $session) {
            Add-JobLog $Job "error" "Could not open SSH session to $IP."
            Complete-ProvisionJob $Job "failed"
            return
        }

        $rebootTriggered = $false
        try {
            Add-JobLog $Job "info" "Transferring configuration via SCP..."
            $localSize = Send-ConfigFile -SessionId $session.SessionId -Content $cfgContent -IP $IP -User $User -Pass $Pass
            $remoteSize = ((Invoke-RadioCommand -SessionId $session.SessionId -Command "wc -c < /tmp/system.cfg") -join "").Trim()

            if (-not $remoteSize -or [int]$remoteSize -ne [int]$localSize) {
                Add-JobLog $Job "error" "Config transfer verification failed (local $localSize bytes vs remote '$remoteSize' bytes)."
                Add-JobLog $Job "error" "Refusing to write to flash or reboot - the radio still has its previous config."
                Complete-ProvisionJob $Job "failed"
                return
            }
            Add-JobLog $Job "success" "Config verified on device ($remoteSize bytes)."

            Add-JobLog $Job "info" "Writing to flash and rebooting radio..."
            Invoke-RadioCommand -SessionId $session.SessionId -Command "cfgmtd -w -p /etc/ && reboot" | Out-Null
            $rebootTriggered = $true
        } catch {
            Add-JobLog $Job "error" "Error during provisioning: $_"
        } finally {
            Remove-SSHSession -SessionId $session.SessionId -ErrorAction SilentlyContinue | Out-Null
        }

        if (-not $rebootTriggered) {
            Complete-ProvisionJob $Job "failed"
            return
        }

        $rebootResult = Wait-ForRebootJob -Job $Job -IP $IP -User $User -Pass $Pass
        if ($rebootResult.Success) {
            Add-JobLog $Job "success" "Radio rebooted and verified back online at $($rebootResult.IP). Role: $roleLabel, SSID: $Ssid"
            Complete-ProvisionJob $Job "success"
        } else {
            Add-JobLog $Job "error" "Config was sent, but the radio has not come back online. Check power/cabling and verify it manually before trusting this unit."
            Complete-ProvisionJob $Job "failed"
        }
    } catch {
        Add-JobLog $Job "error" "Unexpected error: $_"
        Complete-ProvisionJob $Job "failed"
    }
}

# ---------------------------------------------------------------------------
# Background runspace plumbing — same process, so state objects (hashtables,
# ConcurrentQueue/ConcurrentDictionary) are shared by reference, no
# serialization boundary like PSRemoting.
# ---------------------------------------------------------------------------

$script:EngineFunctionNames = @(
    'Wait-ForConditionSimple', 'ConvertFrom-UbntReply', 'Get-UbntDiscoveryReplies', 'Get-RadioCandidates', 'Format-RadioLabel',
    'New-RadioSession', 'Invoke-RadioCommand', 'Send-ConfigFile',
    'Get-BuildingCfg', 'Get-SignCfg', 'New-ProvisionJob', 'Add-JobLog', 'Complete-ProvisionJob', 'Wait-ForRebootJob',
    'Invoke-ProvisionCore', 'New-EngineRunspace', 'Start-ProvisionRunspace', 'Get-RequestBody', 'Send-JsonResponse',
    'Send-HtmlResponse', 'Send-NotFound', 'Send-JobStream', 'Invoke-HttpRequest'
)

function New-EngineRunspace {
    param([string[]]$FunctionNames)
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.ImportPSModule(@('Posh-SSH')) | Out-Null
    foreach ($name in $FunctionNames) {
        $cmd = Get-Command $name -CommandType Function
        $entry = [System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new($name, $cmd.ScriptBlock)
        $iss.Commands.Add($entry)
    }
    $rs = [runspacefactory]::CreateRunspace($iss)
    $rs.Open()
    return $rs
}

function Start-ProvisionRunspace {
    param($Job, [string]$IP, [string]$User, [string]$Pass, [string]$Role, [string]$Ssid, $GlobalState)
    # $script:EngineFunctionNames is not used here: this can run inside a
    # request-handling child runspace (every request is dispatched, including
    # /api/provision), and that runspace never executed this script's
    # top-level assignments — its script scope is empty. GlobalState carries
    # the list explicitly instead, since it's shared by reference everywhere.
    $rs = New-EngineRunspace -FunctionNames $GlobalState.EngineFunctionNames
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddCommand('Invoke-ProvisionCore').
        AddParameter('Job', $Job).
        AddParameter('IP', $IP).
        AddParameter('User', $User).
        AddParameter('Pass', $Pass).
        AddParameter('Role', $Role).
        AddParameter('Ssid', $Ssid)
    $Job.PS = $ps
    $Job.RS = $rs
    [void]$ps.BeginInvoke()
}

# ---------------------------------------------------------------------------
# HTTP plumbing
# ---------------------------------------------------------------------------

function Get-RequestBody {
    param($Context)
    $reader = New-Object IO.StreamReader($Context.Request.InputStream, [Text.Encoding]::UTF8)
    $raw = $reader.ReadToEnd()
    $reader.Close()
    if ([string]::IsNullOrWhiteSpace($raw)) { return [PSCustomObject]@{} }
    try { return $raw | ConvertFrom-Json } catch { return [PSCustomObject]@{} }
}

function Send-JsonResponse {
    param($Context, $Object, [int]$StatusCode = 200)
    $json = $Object | ConvertTo-Json -Depth 6 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = "application/json"
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

function Send-HtmlResponse {
    param($Context, [string]$Html)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Html)
    $Context.Response.StatusCode = 200
    $Context.Response.ContentType = "text/html; charset=utf-8"
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

function Send-NotFound {
    param($Context)
    $Context.Response.StatusCode = 404
    $Context.Response.OutputStream.Close()
}

function Send-JobStream {
    param($Context, $GlobalState, [string]$JobId)
    $job = $null
    if (-not $JobId -or -not $GlobalState.Jobs.TryGetValue($JobId, [ref]$job)) {
        Send-NotFound -Context $Context
        return
    }

    $Context.Response.StatusCode = 200
    $Context.Response.ContentType = "text/event-stream"
    $Context.Response.Headers.Add("Cache-Control", "no-cache")
    $Context.Response.SendChunked = $true
    $stream = $Context.Response.OutputStream

    try {
        while ($true) {
            $item = $null
            if ($job.Queue.TryDequeue([ref]$item)) {
                $line = "data: $($item | ConvertTo-Json -Compress)`n`n"
                $bytes = [Text.Encoding]::UTF8.GetBytes($line)
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush()
            } elseif ($job.Done) {
                $line = "event: done`ndata: $($job.Result)`n`n"
                $bytes = [Text.Encoding]::UTF8.GetBytes($line)
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush()
                break
            } else {
                $bytes = [Text.Encoding]::UTF8.GetBytes(": keepalive`n`n")
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush()
                Start-Sleep -Milliseconds 500
            }
        }
    } catch {
        # Client disconnected (browser closed / navigated away) — nothing to do.
    } finally {
        try { $Context.Response.OutputStream.Close() } catch { }
    }
}

function Invoke-HttpRequest {
    param($Context, $GlobalState)
    $path = $Context.Request.Url.AbsolutePath
    $method = $Context.Request.HttpMethod

    try {
        if ($method -eq "GET" -and $path -eq "/") {
            Send-HtmlResponse -Context $Context -Html $GlobalState.IndexHtml
        }
        elseif ($method -eq "GET" -and $path -eq "/api/preflight") {
            Send-JsonResponse -Context $Context -Object @{ iface = $GlobalState.Iface; dhcp = $GlobalState.DhcpLease }
        }
        elseif ($method -eq "GET" -and $path -eq "/api/stream") {
            $jobId = $Context.Request.QueryString["job_id"]
            Send-JobStream -Context $Context -GlobalState $GlobalState -JobId $jobId
        }
        elseif ($method -eq "POST" -and $path -eq "/api/scan") {
            $found = Get-RadioCandidates
            $radios = @($found.Keys | ForEach-Object {
                $info = $found[$_]
                @{ ip = $_; mac = $info.mac; hostname = $info.hostname; platform = $info.platform; firmware = $info.firmware }
            })
            if ($radios.Count -eq 1) { $GlobalState.AppState.IP = $radios[0].ip }
            Send-JsonResponse -Context $Context -Object @{ radios = $radios }
        }
        elseif ($method -eq "POST" -and $path -eq "/api/set_ip") {
            $data = Get-RequestBody -Context $Context
            $ip = [string]$data.ip
            $parsedIp = $null
            if (-not [System.Net.IPAddress]::TryParse($ip, [ref]$parsedIp)) {
                Send-JsonResponse -Context $Context -Object @{ ok = $false; error = "That doesn't look like a valid IP address." } -StatusCode 400
            } else {
                $GlobalState.AppState.IP = $ip
                Send-JsonResponse -Context $Context -Object @{ ok = $true }
            }
        }
        elseif ($method -eq "POST" -and $path -eq "/api/connect") {
            $ip = $GlobalState.AppState.IP
            if (-not $ip) {
                Send-JsonResponse -Context $Context -Object @{ ok = $false; error = "No IP set" } -StatusCode 400
            } else {
                Wait-ForConditionSimple -Check { Test-NetConnection -ComputerName $ip -Port 22 -WarningAction SilentlyContinue -InformationLevel Quiet -ErrorAction SilentlyContinue } -TimeoutSec 30 | Out-Null

                $creds = switch ($ip) {
                    "192.168.1.20" { , @{ User = "ubnt"; Pass = "ubnt" } }
                    { $_ -eq "192.168.0.218" -or $_ -eq "192.168.0.219" } { , @{ User = "Admin"; Pass = "!mpact1234" } }
                    default { $GlobalState.KnownCreds }
                }

                $authed = $false
                foreach ($cred in $creds) {
                    $s = New-RadioSession -IP $ip -User $cred.User -Pass $cred.Pass
                    if ($s) {
                        Remove-SSHSession -SessionId $s.SessionId -ErrorAction SilentlyContinue | Out-Null
                        $GlobalState.AppState.User = $cred.User
                        $GlobalState.AppState.Pass = $cred.Pass
                        Send-JsonResponse -Context $Context -Object @{ ok = $true; user = $cred.User }
                        $authed = $true
                        break
                    }
                }
                if (-not $authed) {
                    Send-JsonResponse -Context $Context -Object @{ ok = $false }
                }
            }
        }
        elseif ($method -eq "POST" -and $path -eq "/api/manual_auth") {
            $data = Get-RequestBody -Context $Context
            $ip = $GlobalState.AppState.IP
            $user = [string]$data.user
            if (-not $user) { $user = "ubnt" }
            $pass = [string]$data.pass
            $authed = $false
            if ($ip) {
                $s = New-RadioSession -IP $ip -User $user -Pass $pass
                if ($s) {
                    Remove-SSHSession -SessionId $s.SessionId -ErrorAction SilentlyContinue | Out-Null
                    $GlobalState.AppState.User = $user
                    $GlobalState.AppState.Pass = $pass
                    $authed = $true
                }
            }
            Send-JsonResponse -Context $Context -Object @{ ok = $authed }
        }
        elseif ($method -eq "POST" -and $path -eq "/api/provision") {
            $data = Get-RequestBody -Context $Context
            $ip = $GlobalState.AppState.IP
            $user = $GlobalState.AppState.User
            $pass = $GlobalState.AppState.Pass
            $role = [string]$data.role
            $ssid = [string]$data.ssid
            if (-not $ssid) { $ssid = "Impact" }

            if (-not ($ip -and $user -and $pass) -or ($role -ne "1" -and $role -ne "2")) {
                Send-JsonResponse -Context $Context -Object @{ error = "Missing IP/credentials/role" } -StatusCode 400
            } else {
                $job = New-ProvisionJob
                $GlobalState.Jobs[$job.Id] = $job
                Start-ProvisionRunspace -Job $job -IP $ip -User $user -Pass $pass -Role $role -Ssid $ssid -GlobalState $GlobalState
                Send-JsonResponse -Context $Context -Object @{ job_id = $job.Id }
            }
        }
        elseif ($method -eq "POST" -and $path -eq "/api/reset") {
            $GlobalState.AppState.IP = $null
            $GlobalState.AppState.User = $null
            $GlobalState.AppState.Pass = $null
            Send-JsonResponse -Context $Context -Object @{ ok = $true }
        }
        else {
            Send-NotFound -Context $Context
        }
    } catch {
        try { Send-JsonResponse -Context $Context -Object @{ error = "$_" } -StatusCode 500 } catch { }
    }
}

function Get-FreePort {
    $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $l.Start()
    $port = ([System.Net.IPEndPoint]$l.LocalEndpoint).Port
    $l.Stop()
    return $port
}

# Best-effort cleanup for the runspaces spun up per request — swept on every
# new request, piggybacking on real traffic instead of a dedicated timer.
function Clear-CompletedRunspaces {
    param($GlobalState)
    $remaining = [System.Collections.Concurrent.ConcurrentBag[object]]::new()
    foreach ($item in $GlobalState.PendingRunspaces.ToArray()) {
        if ($item.PS.InvocationStateInfo.State -eq 'Running') {
            $remaining.Add($item)
        } else {
            try { $item.PS.Dispose() } catch { }
            try { $item.RS.Close(); $item.RS.Dispose() } catch { }
        }
    }
    $GlobalState.PendingRunspaces = $remaining
}

# ---------------------------------------------------------------------------
# Front end — identical wizard to the CLI flow (scan -> auth -> configure ->
# confirm -> flash -> live log -> result), auto-scans for a radio on load and
# keeps retrying quietly until one answers.
# ---------------------------------------------------------------------------

$IndexHtml = @'
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>LocoLocator</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0; font-family: -apple-system, Segoe UI, Roboto, sans-serif;
    background: #0f1115; color: #e6e6e6; display: flex; justify-content: center;
    padding: 32px 16px;
  }
  .app { width: 100%; max-width: 640px; }
  h1 { font-size: 1.4rem; margin: 0 0 4px; color: #5ee1ff; }
  .subtitle { color: #8a94a3; margin-bottom: 24px; font-size: 0.9rem; }
  .card {
    background: #171a21; border: 1px solid #262b36; border-radius: 10px;
    padding: 20px; margin-bottom: 16px;
  }
  .card h2 { font-size: 1rem; margin: 0 0 12px; color: #b9c2cf; }
  button {
    background: #2563eb; color: white; border: none; border-radius: 6px;
    padding: 10px 16px; font-size: 0.9rem; cursor: pointer; margin-right: 8px;
  }
  button.secondary { background: #2a2f3a; }
  button.danger { background: #7f1d1d; }
  button:disabled { opacity: 0.5; cursor: not-allowed; }
  input, select {
    background: #0f1115; border: 1px solid #333a47; color: #e6e6e6;
    border-radius: 6px; padding: 8px 10px; font-size: 0.9rem; width: 100%;
    margin: 4px 0 12px;
  }
  label { font-size: 0.85rem; color: #b9c2cf; }
  .status { font-size: 0.85rem; margin-top: 8px; min-height: 1.2em; }
  .status.info { color: #f4c542; }
  .status.error { color: #ff6b6b; }
  .status.success { color: #4ade80; }
  .role-options { display: flex; gap: 12px; margin-bottom: 12px; }
  .role-options label {
    flex: 1; border: 1px solid #333a47; border-radius: 8px; padding: 10px;
    display: block; cursor: pointer; font-size: 0.85rem;
  }
  .role-options input { width: auto; margin: 0 6px 0 0; }
  .role-options .selected { border-color: #2563eb; background: #16223f; }
  #log {
    background: #05070a; border-radius: 8px; padding: 12px; height: 260px;
    overflow-y: auto; font-family: ui-monospace, Menlo, Consolas, monospace;
    font-size: 0.82rem; line-height: 1.5;
  }
  #log .info { color: #f4c542; }
  #log .success { color: #4ade80; }
  #log .error { color: #ff6b6b; }
  #log .warn { color: #ffa94d; }
  .hidden { display: none !important; }
  .summary-row { display: flex; justify-content: space-between; font-size: 0.9rem; margin: 4px 0; }
  .summary-row span:first-child { color: #8a94a3; }
  .found-banner {
    border: 1px solid #1d6b3f; background: #0d2318; border-radius: 8px;
    padding: 12px 14px; margin-top: 10px;
  }
  .found-banner .headline { color: #4ade80; font-weight: 700; font-size: 1rem; }
  .found-banner .detail { color: #9fb3a6; font-size: 0.8rem; margin-top: 4px; }
  .radio-list { margin-top: 10px; display: flex; flex-direction: column; gap: 8px; }
  .radio-pick {
    border: 1px solid #333a47; background: #12151c; border-radius: 8px;
    padding: 10px 12px; cursor: pointer; display: flex; justify-content: space-between;
    align-items: center;
  }
  .radio-pick:hover { border-color: #2563eb; background: #16223f; }
  .radio-pick .ip { font-weight: 700; font-family: ui-monospace, Menlo, Consolas, monospace; }
  .radio-pick .meta { color: #8a94a3; font-size: 0.78rem; }
  .confirm-banner {
    border: 1px solid #3a2f0d; background: #221c0a; border-radius: 8px;
    padding: 14px; margin-bottom: 4px;
  }
  .confirm-banner .big-row { font-size: 1.05rem; font-weight: 700; color: #f4c542; margin: 2px 0; }
  .confirm-banner .big-row span.label { color: #b9a35a; font-weight: 400; font-size: 0.75rem; display: block; }
</style>
</head>
<body>
<div class="app">
  <h1>LocoLocator</h1>
  <div class="subtitle" id="preflight">Starting up…</div>

  <div class="card" id="step-detect">
    <h2>1. Find the radio</h2>
    <button id="btn-scan">Scan for radio</button>
    <div style="margin-top:12px;">
      <label>Or enter its IP manually</label>
      <input id="manual-ip" placeholder="192.168.1.20">
      <button class="secondary" id="btn-manual-ip">Use this IP</button>
    </div>
    <div class="status" id="detect-status"></div>
    <div id="radio-list" class="radio-list hidden"></div>
    <div id="found-banner" class="found-banner hidden">
      <div class="headline" id="found-headline"></div>
      <div class="detail" id="found-detail"></div>
    </div>
  </div>

  <div class="card hidden" id="step-auth">
    <h2>2. Authenticate</h2>
    <div class="status info" id="auth-status">Testing standard credentials…</div>
    <div id="manual-auth" class="hidden" style="margin-top:12px;">
      <label>Username</label>
      <input id="auth-user" value="ubnt">
      <label>Password</label>
      <input id="auth-pass" type="password">
      <button id="btn-try-login">Try login</button>
    </div>
  </div>

  <div class="card hidden" id="step-configure">
    <h2>3. Configure</h2>
    <div class="role-options">
      <label id="role-1-label"><input type="radio" name="role" value="1" checked> Building Side (AP)<br><small>Fallback: 192.168.0.218</small></label>
      <label id="role-2-label"><input type="radio" name="role" value="2"> Sign Side (Station)<br><small>Fallback: 192.168.0.219</small></label>
    </div>
    <label>Wireless SSID</label>
    <input id="ssid" value="Impact">
    <button id="btn-review">Review</button>
  </div>

  <div class="card hidden" id="step-confirm">
    <h2>Confirm before flashing</h2>
    <div class="confirm-banner">
      <div class="big-row"><span class="label">About to configure</span><span id="c-ip"></span></div>
      <div class="big-row"><span class="label">As</span><span id="c-role"></span></div>
      <div class="big-row"><span class="label">SSID</span><span id="c-ssid"></span></div>
    </div>
    <div style="margin-top:16px;">
      <button id="btn-flash">Flash now</button>
      <button class="secondary" id="btn-back">Back</button>
    </div>
  </div>

  <div class="card hidden" id="step-progress">
    <h2>Progress</h2>
    <div id="log"></div>
  </div>

  <div class="card hidden" id="step-result">
    <h2 id="result-title"></h2>
    <div id="result-detail" class="status"></div>
    <div style="margin-top:16px;">
      <button class="secondary hidden" id="btn-pair">Configure paired radio</button>
      <button class="secondary" id="btn-again">Configure another radio</button>
    </div>
  </div>
</div>

<script>
let state = { ip: null, role: null, ssid: null, forcedRole: null, presetSsid: null };

async function api(path, body) {
  const res = await fetch(path, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body || {}),
  });
  return res.json();
}

function show(id) {
  document.getElementById(id).classList.remove("hidden");
}
function hide(id) {
  document.getElementById(id).classList.add("hidden");
}
function setStatus(id, level, text) {
  const el = document.getElementById(id);
  el.className = "status " + level;
  el.textContent = text;
}

function renderPreflight(d) {
  if (!d.iface) {
    document.getElementById("preflight").textContent = "Preflight status unavailable";
    return;
  }
  let text = `Interface ${d.iface}: static 192.168.0.x / 192.168.1.x`;
  if (d.dhcp) {
    if (d.dhcp.status === "ok") text += ` + DHCP lease ${d.dhcp.ip}`;
    else if (d.dhcp.status === "pending") text += " + requesting a DHCP lease…";
    else if (d.dhcp.status === "none") text += " (no DHCP server answered — static only)";
  }
  document.getElementById("preflight").textContent = text;
  return d.dhcp && d.dhcp.status === "pending";
}

async function pollPreflight() {
  for (let i = 0; i < 6; i++) {
    const d = await fetch("/api/preflight").then(r => r.json());
    const stillPending = renderPreflight(d);
    if (!stillPending) return;
    await new Promise(r => setTimeout(r, 2000));
  }
}
pollPreflight();

let autoScanTimer = null;
let scanStartedAt = null;

function stopAutoScan() {
  if (autoScanTimer) {
    clearInterval(autoScanTimer);
    autoScanTimer = null;
  }
}

function deviceLabel(r) {
  return r.platform || "Ubiquiti airOS device";
}

function deviceMeta(r) {
  const bits = [];
  if (r.hostname) bits.push(r.hostname);
  if (r.mac) bits.push(r.mac);
  if (r.firmware) bits.push(r.firmware);
  return bits.join(" · ");
}

function showFound(r) {
  document.getElementById("found-banner").classList.remove("hidden");
  document.getElementById("found-headline").textContent = `Found: ${deviceLabel(r)} at ${r.ip}`;
  document.getElementById("found-detail").textContent = deviceMeta(r) || "Discovered via Ubiquiti broadcast discovery (UDP/10001)";
}

function renderRadioList(radios) {
  const list = document.getElementById("radio-list");
  list.innerHTML = "";
  if (radios.length < 2) {
    list.classList.add("hidden");
    return;
  }
  list.classList.remove("hidden");
  radios.forEach(r => {
    const row = document.createElement("div");
    row.className = "radio-pick";
    row.innerHTML = `<div><div class="ip">${r.ip}</div><div class="meta">${deviceLabel(r)}${deviceMeta(r) ? " — " + deviceMeta(r) : ""}</div></div><button>Use this one</button>`;
    row.onclick = () => selectRadio(r);
    list.appendChild(row);
  });
}

async function selectRadio(r) {
  stopAutoScan();
  document.getElementById("radio-list").classList.add("hidden");
  showFound(r);
  setStatus("detect-status", "success", `Using radio at ${r.ip}`);
  const d = await api("/api/set_ip", { ip: r.ip });
  if (d.ok) afterIp(r.ip);
}

async function doScan() {
  const d = await api("/api/scan");
  const radios = d.radios || [];
  if (radios.length === 1) {
    stopAutoScan();
    showFound(radios[0]);
    setStatus("detect-status", "success", `Found radio at ${radios[0].ip}`);
    afterIp(radios[0].ip);
    return true;
  }
  if (radios.length > 1) {
    stopAutoScan();
    setStatus("detect-status", "info", `${radios.length} Ubiquiti devices answered — pick the one connected to this cable:`);
    renderRadioList(radios);
    return false;
  }
  renderRadioList([]);
  return false;
}

async function startAutoScan(waitingMsg) {
  waitingMsg = waitingMsg || "Connect a radio — it'll be picked up automatically.";
  scanStartedAt = Date.now();
  setStatus("detect-status", "info", "Broadcasting discovery probe + checking known addresses…");
  if (await doScan()) return;
  autoScanTimer = setInterval(async () => {
    if (await doScan()) return;
    const elapsed = Math.round((Date.now() - scanStartedAt) / 1000);
    setStatus("detect-status", "info",
      `${waitingMsg} Still scanning (${elapsed}s — a previously-configured radio can take up to ~2 min to fall off DHCP and answer). Or enter its IP manually below.`);
  }, 3000);
}

document.getElementById("btn-scan").onclick = async () => {
  stopAutoScan();
  setStatus("detect-status", "info", "Broadcasting discovery probe + checking known addresses…");
  if (!(await doScan())) {
    setStatus("detect-status", "error", "No radio answered yet — enter its IP manually below, or wait and it'll keep retrying automatically.");
    autoScanTimer = setInterval(doScan, 3000);
  }
};

document.getElementById("btn-manual-ip").onclick = async () => {
  const ip = document.getElementById("manual-ip").value.trim();
  if (!ip) return;
  stopAutoScan();
  setStatus("detect-status", "info", `Using ${ip}…`);
  const d = await api("/api/set_ip", { ip });
  if (d.ok) afterIp(ip);
  else setStatus("detect-status", "error", d.error || "Invalid IP");
};

startAutoScan();

async function afterIp(ip) {
  state.ip = ip;
  hide("step-detect");
  show("step-auth");
  setStatus("auth-status", "info", "Waiting for SSH and testing standard credentials…");
  const d = await api("/api/connect", { ip });
  if (d.ok) {
    setStatus("auth-status", "success", `Authenticated as '${d.user}'`);
    setTimeout(() => afterAuth(), 600);
  } else {
    setStatus("auth-status", "error", "Automatic login failed — enter credentials manually.");
    document.getElementById("manual-auth").classList.remove("hidden");
  }
}

document.getElementById("btn-try-login").onclick = async () => {
  const user = document.getElementById("auth-user").value.trim();
  const pass = document.getElementById("auth-pass").value;
  setStatus("auth-status", "info", "Trying login…");
  const d = await api("/api/manual_auth", { user, pass });
  if (d.ok) {
    setStatus("auth-status", "success", `Authenticated as '${user}'`);
    setTimeout(() => afterAuth(), 400);
  } else {
    setStatus("auth-status", "error", "Authentication failed.");
  }
};

function afterAuth() {
  hide("step-auth");
  show("step-configure");
  if (state.forcedRole) {
    document.querySelector(`input[name=role][value="${state.forcedRole}"]`).checked = true;
    document.querySelectorAll('input[name=role]').forEach(r => r.disabled = true);
  }
  if (state.presetSsid) {
    document.getElementById("ssid").value = state.presetSsid;
    document.getElementById("ssid").disabled = true;
  }
}

document.getElementById("btn-review").onclick = () => {
  state.role = document.querySelector('input[name=role]:checked').value;
  state.ssid = document.getElementById("ssid").value.trim() || "Impact";
  document.getElementById("c-ip").textContent = state.ip;
  document.getElementById("c-role").textContent = state.role === "1"
    ? "Building Side (AP) — 192.168.0.218" : "Sign Side (Station) — 192.168.0.219";
  document.getElementById("c-ssid").textContent = state.ssid;
  hide("step-configure");
  show("step-confirm");
};

document.getElementById("btn-back").onclick = () => {
  hide("step-confirm");
  show("step-configure");
};

document.getElementById("btn-flash").onclick = async () => {
  hide("step-confirm");
  show("step-progress");
  document.getElementById("log").innerHTML = "";
  const d = await api("/api/provision", { role: state.role, ssid: state.ssid });
  const es = new EventSource("/api/stream?job_id=" + d.job_id);
  es.onmessage = (ev) => {
    const line = JSON.parse(ev.data);
    const div = document.createElement("div");
    div.className = line.level;
    div.textContent = line.text;
    document.getElementById("log").appendChild(div);
    document.getElementById("log").scrollTop = document.getElementById("log").scrollHeight;
  };
  es.addEventListener("done", (ev) => {
    es.close();
    showResult(ev.data === "success");
  });
};

function showResult(success) {
  hide("step-progress");
  show("step-result");
  document.getElementById("result-title").textContent = success
    ? "Radio configured successfully" : "Something went wrong";
  document.getElementById("result-title").style.color = success ? "#4ade80" : "#ff6b6b";
  document.getElementById("result-detail").textContent = success
    ? `SSID: ${state.ssid}` : "Check the log above, verify the radio manually, then try again.";

  const pairBtn = document.getElementById("btn-pair");
  if (success && !state.forcedRole) {
    pairBtn.classList.remove("hidden");
    pairBtn.textContent = state.role === "1"
      ? "Configure paired Sign Side (219) radio now"
      : "Configure paired Building Side (218) radio now";
    pairBtn.onclick = () => resetWizard(state.role === "1" ? "2" : "1", state.ssid);
  } else {
    pairBtn.classList.add("hidden");
  }
}

document.getElementById("btn-again").onclick = () => resetWizard(null, null);

async function resetWizard(forcedRole, presetSsid) {
  await api("/api/reset");
  state = { ip: null, role: null, ssid: null, forcedRole, presetSsid };
  document.getElementById("manual-auth").classList.add("hidden");
  document.querySelectorAll('input[name=role]').forEach(r => r.disabled = false);
  document.getElementById("ssid").disabled = false;
  document.getElementById("ssid").value = presetSsid || "Impact";
  document.getElementById("found-banner").classList.add("hidden");
  document.getElementById("radio-list").classList.add("hidden");
  hide("step-result");
  show("step-detect");
  startAutoScan(forcedRole
    ? "Unplug the current radio and connect the paired radio — it'll be picked up automatically."
    : "Connect the next radio — it'll be picked up automatically.");
}
</script>
</body>
</html>
'@

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------

$GlobalState = [hashtable]::Synchronized(@{
    Iface               = $adapter.Name
    DhcpLease           = $script:DhcpLeaseInfo
    IndexHtml           = $IndexHtml
    AppState            = [hashtable]::Synchronized(@{ IP = $null; User = $null; Pass = $null })
    Jobs                = [System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new()
    KnownCreds          = @(
        @{ User = "ubnt";  Pass = "ubnt"       },
        @{ User = "root";  Pass = "ubnt"       },
        @{ User = "Admin"; Pass = "!mpact1234" },
        @{ User = "root";  Pass = "!mpact1234" }
    )
    PendingRunspaces    = [System.Collections.Concurrent.ConcurrentBag[object]]::new()
    EngineFunctionNames = $script:EngineFunctionNames
})

$port = Get-FreePort
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$port/")
$listener.Start()

$url = "http://127.0.0.1:$port/"
Write-Host ""
Write-Host "[*] Web UI running at $url" -ForegroundColor Yellow
Write-Host "[*] Press Ctrl+C here to stop." -ForegroundColor Yellow
Write-Host ""

Start-Sleep -Milliseconds 300
try { Start-Process $url } catch {
    Write-Host "[*] Could not auto-open a browser — open this URL manually: $url" -ForegroundColor Yellow
}

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()

        # Every request runs on its own runspace, not just /api/stream. The
        # accept loop must never block: /api/scan alone can take several
        # seconds (up to three sequential ping timeouts), and the page's
        # auto-scan retry fires every 3s — handling requests inline on the
        # main thread lets that backlog up and starve every other endpoint
        # (confirmed by hitting exactly this deadlock in testing).
        Clear-CompletedRunspaces -GlobalState $GlobalState
        $rs = New-EngineRunspace -FunctionNames $script:EngineFunctionNames
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddCommand('Invoke-HttpRequest').AddParameter('Context', $context).AddParameter('GlobalState', $GlobalState)
        [void]$ps.BeginInvoke()
        $GlobalState.PendingRunspaces.Add(@{ PS = $ps; RS = $rs })
    }
} finally {
    $listener.Stop()
    $listener.Close()
}
