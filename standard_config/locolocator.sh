#!/usr/bin/env bash
#
# LocoLocator — Ubiquiti airOS Auto-Provisioning Tool
#

set -e

# Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}====================================================${NC}"
echo -e "${CYAN}       LocoLocator — Radio Provisioning Tool       ${NC}"
echo -e "${CYAN}====================================================${NC}\n"

# Ensure Root Privileges
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[!] This script must be run with sudo.${NC}"
   echo -e "    Example: sudo bash $0"
   exit 1
fi

# Check for required tool: sshpass
if ! command -v sshpass &> /dev/null; then
    echo -e "${YELLOW}[*] Installing required tool 'sshpass'...${NC}"
    apt-get update -qq && apt-get install -y -qq sshpass
fi

# Auto-detect active Ethernet interface
IFACE=$(ip -o link show up | awk -F': ' '{print $2}' | grep -E '^(eth|en)' | sed 's/@.*//' | grep -v '^lo$' | head -1)
if [ -z "$IFACE" ]; then
    echo -e "${RED}[!] Could not detect an active Ethernet interface. Check your connection and try again.${NC}"
    exit 1
fi
echo -e "${YELLOW}[*] Detected network interface: ${IFACE}${NC}"

# Configure both subnets on the interface
ip addr add 192.168.1.50/24 dev "$IFACE" 2>/dev/null || true
ip addr add 192.168.0.50/24 dev "$IFACE" 2>/dev/null || true
ip link set "$IFACE" up

# Also try to pick up a real DHCP lease on this interface, in the background,
# in parallel with the two static addresses above. A radio can end up on
# either a DHCP-provided subnet (if the site network offers one) or its
# static fallback — this makes sure the laptop itself is reachable on
# whichever one actually shows up, not just the two hardcoded /24s. Backgrounded
# and best-effort: an isolated bench link with no DHCP server just times out.
DHCP_CLIENT=""
DHCP_PID=""
command -v dhclient &>/dev/null && DHCP_CLIENT="dhclient"
[ -z "$DHCP_CLIENT" ] && command -v dhcpcd &>/dev/null && DHCP_CLIENT="dhcpcd"
if [ -n "$DHCP_CLIENT" ]; then
    (
        if [ "$DHCP_CLIENT" == "dhclient" ]; then
            dhclient -1 -timeout 8 "$IFACE" &>/dev/null
        else
            dhcpcd -t 8 "$IFACE" &>/dev/null
        fi
    ) &
    DHCP_PID=$!
fi

# Blocks briefly (at most the DHCP attempt's own ~8s timeout) so we can report
# an accurate result instead of guessing — called once, right before the first
# scan, so the wait overlaps with reading the banner rather than adding to it.
report_dhcp_status() {
    if [ -z "$DHCP_CLIENT" ]; then
        echo -e "${YELLOW}[*] No dhclient/dhcpcd found — this laptop will only use the static 192.168.0.x/192.168.1.x addresses.${NC}"
        return
    fi
    [ -n "$DHCP_PID" ] && wait "$DHCP_PID" 2>/dev/null
    local lease
    lease=$(ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '/dynamic/ {split($4,a,"/"); print a[1]; exit}')
    if [ -n "$lease" ]; then
        echo -e "${GREEN}[+] Also picked up a DHCP lease on ${IFACE}: ${lease}${NC}"
    else
        echo -e "${YELLOW}[*] No DHCP server answered on ${IFACE} — using the static addresses only (normal for an isolated bench link).${NC}"
    fi
}

# SSH options with legacy cipher support for airOS / Dropbear SSH
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=4 -o PubkeyAuthentication=no -o HostKeyAlgorithms=+ssh-rsa -o KexAlgorithms=+diffie-hellman-group1-sha1,diffie-hellman-group14-sha1"

# Poll a TCP port until it accepts a connection (used to confirm sshd is actually
# listening, since airOS answers ping before its services finish starting).
wait_for_port() {
    local ip="$1" port="$2" timeout="${3:-30}" label="${4:-Waiting for service}"
    local waited=0
    echo -ne "${YELLOW}${label}${NC}"
    while true; do
        if (exec 3<>"/dev/tcp/${ip}/${port}") 2>/dev/null; then
            exec 3<&- 2>/dev/null; exec 3>&- 2>/dev/null
            echo -e " ${GREEN}[ready, ${waited}s]${NC}"
            return 0
        fi
        if [ "$waited" -ge "$timeout" ]; then
            echo -e " ${YELLOW}[not ready after ${timeout}s, continuing anyway]${NC}"
            return 1
        fi
        echo -ne "."
        sleep 2
        waited=$((waited+2))
    done
}

# Poll ping until a host responds (or stops responding), with a hard timeout.
# $4 = "up" (default, wait until it responds) or "down" (wait until it stops responding)
wait_for_ping() {
    local ip="$1" timeout="${2:-90}" label="${3:-Waiting for device}" mode="${4:-up}"
    local waited=0
    echo -ne "${YELLOW}${label}${NC}"
    while true; do
        if ping -c 1 -W 1 "$ip" &>/dev/null; then
            [ "$mode" == "up" ] && { echo -e " ${GREEN}[online, ${waited}s]${NC}"; return 0; }
        else
            [ "$mode" == "down" ] && { echo -e " ${GREEN}[offline, ${waited}s]${NC}"; return 0; }
        fi
        if [ "$waited" -ge "$timeout" ]; then
            echo -e " ${RED}[timed out after ${timeout}s]${NC}"
            return 1
        fi
        echo -ne "."
        sleep 2
        waited=$((waited+2))
    done
}

# Broadcast the Ubiquiti discovery probe (UDP/10001) and print every reply as
# "ip<TAB>mac<TAB>hostname<TAB>platform". This finds a radio's real IP whether
# it ended up there via DHCP or its static fallback — every airOS/UniFi device
# answers this broadcast regardless of how it got its address, which a fixed
# candidate-IP guess list can never do. Pure stdlib Python, no extra packages.
discover_radios_py() {
    local timeout="${1:-2}"
    python3 - "$timeout" <<'PYEOF'
import socket, sys, time

timeout = float(sys.argv[1])
PORT = 10001
PROBE = b"\x01\x00\x00\x00"

def parse(data):
    mac = hostname = platform_ = fw = ""
    try:
        pos = 4
        while pos + 3 <= len(data):
            t = data[pos]
            length = int.from_bytes(data[pos + 1:pos + 3], "big")
            pos += 3
            if pos + length > len(data):
                break
            val = data[pos:pos + length]
            pos += length
            if t in (0x01, 0x02) and length >= 6 and not mac:
                mac = ":".join(f"{b:02x}" for b in val[:6])
            elif t == 0x0b and not hostname:
                hostname = val.decode(errors="replace").strip("\x00")
            elif t in (0x0c, 0x14) and not platform_:
                platform_ = val.decode(errors="replace").strip("\x00")
            elif t == 0x03 and not fw:
                fw = val.decode(errors="replace").strip("\x00")
    except Exception:
        pass
    return mac, hostname, platform_, fw

found = {}
try:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("", 0))
    sock.sendto(PROBE, ("255.255.255.255", PORT))
except OSError:
    sys.exit(0)

deadline = time.monotonic() + timeout
with sock:
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        sock.settimeout(min(0.3, remaining))
        try:
            data, (ip, _p) = sock.recvfrom(4096)
        except (socket.timeout, OSError):
            continue
        if ip not in found:
            found[ip] = parse(data)

for ip, (mac, hostname, platform_, fw) in found.items():
    print(f"{ip}\t{mac}\t{hostname}\t{platform_}\t{fw}")
PYEOF
}

# Combined scan: broadcast discovery (primary) plus a direct ping of the known
# static/fallback addresses (backup, in case broadcast is filtered by a
# managed switch or VLAN). Populates the global RADIO_IPS array and the
# RADIO_INFO associative array (ip -> human-readable description).
declare -ga RADIO_IPS=()
declare -gA RADIO_INFO=()
scan_for_radios() {
    local timeout="${1:-2}"
    RADIO_IPS=()
    RADIO_INFO=()

    local ip mac hostname platform fw
    while IFS=$'\t' read -r ip mac hostname platform fw; do
        [ -z "$ip" ] && continue
        RADIO_IPS+=("$ip")
        local desc="${platform:-Ubiquiti airOS device}"
        [ -n "$hostname" ] && desc="${desc} — ${hostname}"
        [ -n "$mac" ] && desc="${desc} (${mac})"
        RADIO_INFO["$ip"]="$desc"
    done < <(discover_radios_py "$timeout")

    local candidates=("192.168.1.20" "192.168.0.218" "192.168.0.219")
    for ip in "${candidates[@]}"; do
        if [ -n "${RADIO_INFO[$ip]+x}" ]; then
            continue
        fi
        if ping -c 1 -W 1 "$ip" &>/dev/null; then
            RADIO_IPS+=("$ip")
            RADIO_INFO["$ip"]="Known fallback address (not seen via broadcast — may be behind a filtered switch/VLAN)"
        fi
    done
}

# Keep scanning until at least one radio answers, printing elapsed time so the
# technician knows it's working rather than hung — a previously-configured
# radio can take up to ~2 minutes to time out its DHCP attempt and fall back
# to its static address.
scan_until_found() {
    local max_wait="${1:-150}"
    local waited=0
    echo -ne "${YELLOW}[*] Broadcasting discovery probe + checking known addresses${NC}"
    while true; do
        scan_for_radios 2
        if [ "${#RADIO_IPS[@]}" -gt 0 ]; then
            echo -e " ${GREEN}[${#RADIO_IPS[@]} device(s) found, ${waited}s]${NC}"
            return 0
        fi
        if [ "$waited" -ge "$max_wait" ]; then
            echo -e " ${YELLOW}[none found after ${waited}s]${NC}"
            return 1
        fi
        echo -ne "."
        waited=$((waited+2))
    done
}

# Confirm a radio has actually rebooted: waits for it to drop offline, come back
# online, and start accepting SSH connections again — instead of guessing with a
# fixed sleep. Returns 0 once the radio is verified reachable again. On success
# (or failure), sets REBOOT_IP to the address the radio is actually answering on
# — which can differ from the address we flashed it at, if it picked up a new
# DHCP lease on reboot instead of falling back to its static address.
REBOOT_IP=""
wait_for_reboot() {
    local ip="$1" user="$2" pass="$3"
    REBOOT_IP="$ip"

    wait_for_ping "$ip" 20 "[*] Confirming radio dropped offline for reboot" "down" || \
        echo -e "${YELLOW}[!] Radio never went offline — it may reboot quickly, or the reboot command may not have taken effect. Continuing to monitor...${NC}"

    if ! wait_for_ping "$ip" 90 "[*] Waiting for radio to come back online at ${ip}"; then
        echo -e "${YELLOW}[!] No response from ${ip} yet — broadcasting to see if it came back at a different DHCP address...${NC}"
        scan_for_radios 3
        local other=""
        for cand in "${RADIO_IPS[@]:-}"; do
            [ -n "$cand" ] && [ "$cand" != "$ip" ] && { other="$cand"; break; }
        done
        if [ -n "$other" ]; then
            echo -e "${GREEN}[+] Radio reappeared at ${other} (new DHCP lease) — continuing verification there.${NC}"
            ip="$other"
            REBOOT_IP="$ip"
        else
            echo -e "${RED}[!] No response from ${ip} after 90s, and nothing new answered a discovery broadcast.${NC}"
            read -p "$(echo -e ${CYAN}"Keep waiting another 2 minutes? [Y/n]: "${NC})" KEEP_WAITING
            if [[ "$KEEP_WAITING" =~ ^[Nn]$ ]]; then
                return 1
            fi
            wait_for_ping "$ip" 120 "[*] Still waiting for radio" || return 1
        fi
    fi

    if ! wait_for_port "$ip" 22 60 "[*] Waiting for SSH to come back up"; then
        echo -e "${YELLOW}[!] Radio is pingable but SSH isn't answering yet.${NC}"
        wait_for_port "$ip" 22 30 "[*] One more check for SSH" || return 1
    fi

    # Final sanity check: actually log in, don't just trust the open port.
    if ! sshpass -p "$pass" ssh $SSH_OPTS "${user}@${ip}" "echo OK" &>/dev/null; then
        echo -e "${YELLOW}[!] SSH port is open but login isn't succeeding yet — giving it a few more seconds...${NC}"
        sleep 5
        sshpass -p "$pass" ssh $SSH_OPTS "${user}@${ip}" "echo OK" &>/dev/null || return 1
    fi

    return 0
}

# --- Config Generators ---

generate_building_cfg() {
    local ssid="$1"
    cat <<EOF
aaa.1.br.devname=br0
wpasupplicant.status=disabled
wpasupplicant.profile.1.network.1.psk=!mpact1234
wpasupplicant.device.1.status=disabled
wireless.status=enabled
wireless.hideindoor.status=disabled
wireless.1.wds.status=enabled
wireless.1.status=enabled
wireless.1.ssid=${ssid}
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
users.1.password=\$1\$jhG7EaVx\$WR6RYDiaigNGMwDKeReNk0
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
aaa.1.ssid=${ssid}
aaa.1.driver=madwifi
aaa.1.devname=ath0
EOF
}

generate_sign_cfg() {
    local ssid="$1"
    cat <<EOF
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
users.1.password=\$1\$xd.2TZZX\$vCGSJtFy.kU6ssmsFjj.91
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
wireless.1.ssid=${ssid}
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
wpasupplicant.profile.1.network.1.ssid=${ssid}
wpasupplicant.status=enabled
EOF
}

# Core Provisioning Function
# $1 = preset SSID   (optional — skips SSID prompt, reuses from paired radio)
# $2 = forced role   (optional — "1" = Building Side, "2" = Sign Side; skips role prompt)
provision_device() {
    local preset_ssid="${1:-}"
    local forced_role="${2:-}"

    echo -e "\n${YELLOW}[*] Scanning for connected radio...${NC}"

    local FOUND_IP=""
    while [ -z "$FOUND_IP" ]; do
        if scan_until_found 150; then
            if [ "${#RADIO_IPS[@]}" -eq 1 ]; then
                FOUND_IP="${RADIO_IPS[0]}"
            else
                while [ -z "$FOUND_IP" ]; do
                    echo -e "${CYAN}Multiple Ubiquiti devices answered — select the one connected to THIS cable:${NC}"
                    local i=1
                    for ip in "${RADIO_IPS[@]}"; do
                        echo -e "  ${CYAN}${i})${NC} ${ip} — ${RADIO_INFO[$ip]}"
                        i=$((i+1))
                    done
                    read -p "$(echo -e ${CYAN}"Choice: "${NC})" pick
                    if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "${#RADIO_IPS[@]}" ]; then
                        FOUND_IP="${RADIO_IPS[$((pick-1))]}"
                    else
                        echo -e "${RED}[!] Invalid selection.${NC}"
                    fi
                done
            fi
            continue
        fi

        echo -e "${RED}[!] No radio answered a discovery broadcast or the known fallback addresses.${NC}"
        while [ -z "$FOUND_IP" ]; do
            echo -e "  ${CYAN}1)${NC} Keep Scanning"
            echo -e "  ${CYAN}2)${NC} Enter IP Manually"
            echo -e "  ${CYAN}3)${NC} Abort"
            read -p "$(echo -e ${CYAN}"Choice: "${NC})" scan_choice
            case "$scan_choice" in
                1) break ;;
                2)
                    read -p "$(echo -e ${CYAN}"Enter radio IP (e.g. 192.168.1.20): "${NC})" FOUND_IP
                    [ -z "$FOUND_IP" ] && echo -e "${RED}[!] No IP entered.${NC}"
                    ;;
                *)
                    echo -e "${RED}[!] Aborting.${NC}"
                    return 1
                    ;;
            esac
        done
    done

    echo -e "${GREEN}[+] Radio detected at: ${FOUND_IP}${NC}"
    [ -n "${RADIO_INFO[$FOUND_IP]:-}" ] && echo -e "${GREEN}    ${RADIO_INFO[$FOUND_IP]}${NC}"
    wait_for_port "$FOUND_IP" 22 30 "[*] Waiting for SSH to be ready"

    # Determine credentials based on detected IP
    local VALID_USER VALID_PASS
    case "$FOUND_IP" in
        "192.168.1.20")
            VALID_USER="ubnt"
            VALID_PASS="ubnt"
            echo -e "${YELLOW}[*] Using ubnt credentials for ${FOUND_IP}...${NC}"
            ;;
        "192.168.0.218"|"192.168.0.219")
            VALID_USER="Admin"
            VALID_PASS="!mpact1234"
            echo -e "${YELLOW}[*] Using Admin credentials for ${FOUND_IP}...${NC}"
            ;;
        *)
            # Manually entered IP — try all known credential combinations
            VALID_USER=""
            VALID_PASS=""
            echo -e "${YELLOW}[*] Testing credentials for ${FOUND_IP}...${NC}"
            local creds=("ubnt:ubnt" "root:ubnt" "Admin:!mpact1234" "root:!mpact1234")
            for cred in "${creds[@]}"; do
                local u="${cred%%:*}"
                local p="${cred#*:}"
                if sshpass -p "$p" ssh $SSH_OPTS "${u}@${FOUND_IP}" "echo OK" &>/dev/null; then
                    VALID_USER="$u"
                    VALID_PASS="$p"
                    break
                fi
            done
            if [ -z "$VALID_USER" ]; then
                echo -e "${YELLOW}[!] Auto-authentication failed. Enter credentials manually.${NC}"
                read -p "$(echo -e ${CYAN}"Username [ubnt]: "${NC})" VALID_USER
                VALID_USER="${VALID_USER:-ubnt}"
                read -sp "$(echo -e ${CYAN}"Password: "${NC})" VALID_PASS
                echo ""
                if ! sshpass -p "$VALID_PASS" ssh $SSH_OPTS "${VALID_USER}@${FOUND_IP}" "echo OK" &>/dev/null; then
                    echo -e "${RED}[!] Authentication failed. Aborting.${NC}"
                    return 1
                fi
            fi
            ;;
    esac

    echo -e "${GREEN}[+] Authenticated as '${VALID_USER}'${NC}\n"

    # Role and SSID selection, with a confirmation step before anything is flashed
    # so a wrong menu pick can be caught before it's written to the radio.
    local ROLE_CHOICE CUSTOM_SSID CONFIRM
    while true; do
        if [ -n "$forced_role" ]; then
            ROLE_CHOICE="$forced_role"
        elif [ -z "${ROLE_CHOICE:-}" ]; then
            echo -e "${CYAN}Select configuration for this unit (${FOUND_IP}):${NC}"
            echo -e "  ${CYAN}1)${NC} Building Side  (AP / Fallback IP: 192.168.0.218)"
            echo -e "  ${CYAN}2)${NC} Sign Side      (Station / Fallback IP: 192.168.0.219)"
            read -p "$(echo -e ${CYAN}"Choice [1 or 2]: "${NC})" ROLE_CHOICE
        fi

        if [ "$ROLE_CHOICE" != "1" ] && [ "$ROLE_CHOICE" != "2" ]; then
            echo -e "${RED}[!] Invalid selection. Aborting.${NC}"
            return 1
        fi

        if [ -n "$preset_ssid" ]; then
            CUSTOM_SSID="$preset_ssid"
        elif [ -z "${CUSTOM_SSID:-}" ]; then
            echo ""
            read -p "$(echo -e ${CYAN}"Enter Wireless SSID [Default: Impact]: "${NC})" CUSTOM_SSID
            CUSTOM_SSID="${CUSTOM_SSID:-Impact}"
        fi

        local role_label="Building Side (AP) — 192.168.0.218"
        [ "$ROLE_CHOICE" == "2" ] && role_label="Sign Side (Station) — 192.168.0.219"

        echo -e "\n${CYAN}----------------------------------------------------${NC}"
        echo -e "${CYAN}About to flash ${FOUND_IP}:${NC}"
        echo -e "${CYAN}  Role: ${role_label}${NC}"
        echo -e "${CYAN}  SSID: ${CUSTOM_SSID}${NC}"
        echo -e "${CYAN}----------------------------------------------------${NC}"
        read -p "$(echo -e ${CYAN}"Proceed with this configuration? [Y/n]: "${NC})" CONFIRM
        if [[ "$CONFIRM" =~ ^[Nn]$ ]]; then
            if [ -n "$forced_role" ] || [ -n "$preset_ssid" ]; then
                echo -e "${RED}[!] Aborting this radio.${NC}"
                return 1
            fi
            echo -e "${YELLOW}[*] Let's redo that.${NC}"
            unset ROLE_CHOICE CUSTOM_SSID
            continue
        fi
        break
    done

    # Generate config file
    local TMP_CFG="/tmp/locolocator_system.cfg"
    if [ "$ROLE_CHOICE" == "1" ]; then
        echo -e "${YELLOW}[*] Generating Building Side config for SSID '${CUSTOM_SSID}'...${NC}"
        generate_building_cfg "$CUSTOM_SSID" > "$TMP_CFG"
    else
        echo -e "${YELLOW}[*] Generating Sign Side config for SSID '${CUSTOM_SSID}'...${NC}"
        generate_sign_cfg "$CUSTOM_SSID" > "$TMP_CFG"
    fi

    # Transfer config, then verify it landed intact before touching flash/reboot
    echo -e "${YELLOW}[*] Transferring configuration via SSH...${NC}"
    sshpass -p "$VALID_PASS" ssh $SSH_OPTS "${VALID_USER}@${FOUND_IP}" "cat > /tmp/system.cfg" < "$TMP_CFG"

    local LOCAL_SIZE REMOTE_SIZE
    LOCAL_SIZE=$(wc -c < "$TMP_CFG" | tr -d ' ')
    REMOTE_SIZE=$(sshpass -p "$VALID_PASS" ssh $SSH_OPTS "${VALID_USER}@${FOUND_IP}" "wc -c < /tmp/system.cfg" 2>/dev/null | tr -d ' \r')

    if [ -z "$REMOTE_SIZE" ] || [ "$LOCAL_SIZE" != "$REMOTE_SIZE" ]; then
        echo -e "${RED}[!] Config transfer verification failed (local ${LOCAL_SIZE} bytes vs remote '${REMOTE_SIZE}' bytes).${NC}"
        echo -e "${RED}[!] Refusing to write to flash or reboot — the radio still has its previous config.${NC}"
        rm -f "$TMP_CFG"
        return 1
    fi
    echo -e "${GREEN}[+] Config verified on device (${REMOTE_SIZE} bytes).${NC}"

    echo -e "${YELLOW}[*] Writing to flash and rebooting radio...${NC}"
    sshpass -p "$VALID_PASS" ssh $SSH_OPTS "${VALID_USER}@${FOUND_IP}" "cfgmtd -w -p /etc/ && reboot" || true

    rm -f "$TMP_CFG"

    if wait_for_reboot "$FOUND_IP" "$VALID_USER" "$VALID_PASS"; then
        echo -e "${GREEN}====================================================${NC}"
        echo -e "${GREEN}  [✔] Radio rebooted and verified back online.     ${NC}"
        echo -e "${GREEN}      SSID: ${CUSTOM_SSID}${NC}"
        if [ "$ROLE_CHOICE" == "1" ]; then
            echo -e "${GREEN}      Role: Building Side (AP) — fallback 192.168.0.218${NC}"
        else
            echo -e "${GREEN}      Role: Sign Side (Station) — fallback 192.168.0.219${NC}"
        fi
        echo -e "${GREEN}      Answering now at: ${REBOOT_IP}${NC}"
        echo -e "${GREEN}====================================================${NC}"
    else
        echo -e "${RED}====================================================${NC}"
        echo -e "${RED}  [!] Config was sent, but the radio has not come   ${NC}"
        echo -e "${RED}      back online yet. Check power/cabling and      ${NC}"
        echo -e "${RED}      verify it manually before trusting this unit. ${NC}"
        echo -e "${RED}====================================================${NC}"
    fi

    # Offer to provision the paired radio (only on initial calls, not on forced-role calls)
    if [ -z "$forced_role" ]; then
        if [ "$ROLE_CHOICE" == "1" ]; then
            echo -e "\n${CYAN}----------------------------------------------------${NC}"
            read -p "$(echo -e ${CYAN}"Provision the paired Sign Side (219) radio now? [y/N]: "${NC})" PAIR_CHOICE
            if [[ "$PAIR_CHOICE" =~ ^[Yy]$ ]]; then
                echo -e "${YELLOW}[!] Unplug the current radio and connect the Sign Side radio.${NC}"
                read -p "$(echo -e ${GREEN}"Press ENTER when the Sign Side radio is powered and connected: "${NC})"
                provision_device "$CUSTOM_SSID" "2"
            fi
        elif [ "$ROLE_CHOICE" == "2" ]; then
            echo -e "\n${CYAN}----------------------------------------------------${NC}"
            read -p "$(echo -e ${CYAN}"Provision the paired Building Side (218) radio now? [y/N]: "${NC})" PAIR_CHOICE
            if [[ "$PAIR_CHOICE" =~ ^[Yy]$ ]]; then
                echo -e "${YELLOW}[!] Unplug the current radio and connect the Building Side radio.${NC}"
                read -p "$(echo -e ${GREEN}"Press ENTER when the Building Side radio is powered and connected: "${NC})"
                provision_device "$CUSTOM_SSID" "1"
            fi
        fi
    fi
}

# Main execution
report_dhcp_status
provision_device

# Loop for additional independent units
while true; do
    echo -e "\n${CYAN}----------------------------------------------------${NC}"
    read -p "$(echo -e ${CYAN}"Configure another radio? [y/N]: "${NC})" AGAIN
    case "$AGAIN" in
        [Yy]*)
            echo -e "${YELLOW}[!] Unplug the current radio and connect the next radio.${NC}"
            read -p "$(echo -e ${GREEN}"Press ENTER when the next radio is powered and connected: "${NC})"
            provision_device
            ;;
        *)
            echo -e "\n${GREEN}[*] LocoLocator session complete. Goodbye!${NC}\n"
            break
            ;;
    esac
done
