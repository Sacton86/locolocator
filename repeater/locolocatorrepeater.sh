#!/usr/bin/env bash
#
# LocoLocator — Ubiquiti airOS Repeater Chain Provisioning Script
#

set -e

IFACE="eno1"
LOCAL_IP1="192.168.1.50/24"
LOCAL_IP2="192.168.0.50/24"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

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

# Confirm a radio has actually rebooted: waits for it to drop offline, come back
# online, and start accepting SSH connections again — instead of guessing with a
# fixed sleep. Returns 0 once the radio is verified reachable again.
wait_for_reboot() {
    local ip="$1" user="$2" pass="$3"

    wait_for_ping "$ip" 20 "[*] Confirming radio dropped offline for reboot" "down" || \
        echo -e "${YELLOW}[!] Radio never went offline — it may reboot quickly, or the reboot command may not have taken effect. Continuing to monitor...${NC}"

    if ! wait_for_ping "$ip" 120 "[*] Waiting for radio to come back online"; then
        echo -e "${RED}[!] No response from ${ip} after 120s.${NC}"
        read -p "$(echo -e ${CYAN}"Keep waiting another 2 minutes? [Y/n]: "${NC})" KEEP_WAITING
        if [[ "$KEEP_WAITING" =~ ^[Nn]$ ]]; then
            return 1
        fi
        wait_for_ping "$ip" 120 "[*] Still waiting for radio" || return 1
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

IP_COUNTER=218
CHAIN_SSID=""
REPEATER_IPS=()
SIGN_IP=""

echo -e "${CYAN}====================================================${NC}"
echo -e "${CYAN}   LocoLocator — Repeater Chain Provisioning       ${NC}"
echo -e "${CYAN}====================================================${NC}\n"

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[!] This script must be run with sudo.${NC}"
    exit 1
fi

if ! command -v sshpass &> /dev/null; then
    echo -e "${YELLOW}[*] Installing required tool 'sshpass'...${NC}"
    apt-get update -qq && apt-get install -y -qq sshpass
fi

echo -e "${YELLOW}[*] Configuring Ethernet interface ($IFACE)...${NC}"
ip addr add $LOCAL_IP1 dev $IFACE 2>/dev/null || true
ip addr add $LOCAL_IP2 dev $IFACE 2>/dev/null || true
ip link set $IFACE up

# ---------------------------------------------------------------------------
# Config generators — each takes SSID and IP suffix as arguments
# ---------------------------------------------------------------------------

generate_building_cfg() {
    local ssid="$1" ip="$2"
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
resolv.host.1.name=Impact-Building-${ip}
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
dhcpc.1.fallback=192.168.0.${ip}
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

generate_repeater_cfg() {
    local ssid="$1" ip="$2"
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
resolv.host.1.name=Impact-Repeater-${ip}
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
dhcpc.1.fallback=192.168.0.${ip}
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
    local ssid="$1" ip="$2"
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
dhcpc.1.fallback=192.168.0.${ip}
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
resolv.host.1.name=Impact-Sign-${ip}
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

# ---------------------------------------------------------------------------
# Detect radio and authenticate — sets FOUND_IP, VALID_USER, VALID_PASS
# ---------------------------------------------------------------------------
detect_and_auth() {
    echo -e "${YELLOW}[*] Scanning for connected radio...${NC}"

    local CANDIDATES=("192.168.1.20" "192.168.1.1")
    for i in $(seq 218 235); do
        CANDIDATES+=("192.168.0.${i}")
    done

    FOUND_IP=""
    for ip in "${CANDIDATES[@]}"; do
        if ping -c 1 -W 1 "$ip" &>/dev/null; then
            FOUND_IP="$ip"
            break
        fi
    done

    if [ -z "$FOUND_IP" ]; then
        echo -e "${RED}[!] Radio not detected automatically.${NC}"
        read -p "$(echo -e ${YELLOW}"Enter radio IP manually (e.g. 192.168.1.20): "${NC})" FOUND_IP
        if [ -z "$FOUND_IP" ]; then
            echo -e "${RED}[!] No IP entered. Skipping.${NC}"
            return 1
        fi
    fi

    echo -e "${GREEN}[+] Radio detected at IP: ${FOUND_IP}${NC}\n"

    local CREDS=("ubnt:ubnt" "root:ubnt" "Admin:!mpact1234" "root:!mpact1234")
    VALID_USER=""
    VALID_PASS=""

    echo -e "${YELLOW}[*] Testing credentials...${NC}"
    for cred in "${CREDS[@]}"; do
        local user="${cred%%:*}"
        local pass="${cred#*:}"
        if sshpass -p "$pass" ssh $SSH_OPTS "${user}@${FOUND_IP}" "echo OK" &>/dev/null; then
            VALID_USER="$user"
            VALID_PASS="$pass"
            echo -e "${GREEN}[+] Authenticated as '${VALID_USER}'${NC}\n"
            break
        fi
    done

    if [ -z "$VALID_USER" ]; then
        echo -e "${YELLOW}[!] Automatic login failed.${NC}"
        read -p "$(echo -e ${CYAN}"Username [Default: ubnt]: "${NC})" VALID_USER
        VALID_USER=${VALID_USER:-ubnt}
        read -sp "$(echo -e ${CYAN}"Password: "${NC})" VALID_PASS
        echo ""
        if ! sshpass -p "$VALID_PASS" ssh $SSH_OPTS "${VALID_USER}@${FOUND_IP}" "echo OK" &>/dev/null; then
            echo -e "${RED}[!] Authentication failed.${NC}"
            return 1
        fi
        echo -e "${GREEN}[+] Manual authentication successful!${NC}\n"
    fi
}

# ---------------------------------------------------------------------------
# Transfer config and reboot
# ---------------------------------------------------------------------------
flash_and_reboot() {
    local cfg_file="$1"

    # Transfer config, then verify it landed intact before touching flash/reboot
    echo -e "${YELLOW}[*] Transferring configuration...${NC}"
    sshpass -p "$VALID_PASS" ssh $SSH_OPTS "${VALID_USER}@${FOUND_IP}" "cat > /tmp/system.cfg" < "$cfg_file"

    local LOCAL_SIZE REMOTE_SIZE
    LOCAL_SIZE=$(wc -c < "$cfg_file" | tr -d ' ')
    REMOTE_SIZE=$(sshpass -p "$VALID_PASS" ssh $SSH_OPTS "${VALID_USER}@${FOUND_IP}" "wc -c < /tmp/system.cfg" 2>/dev/null | tr -d ' \r')

    if [ -z "$REMOTE_SIZE" ] || [ "$LOCAL_SIZE" != "$REMOTE_SIZE" ]; then
        echo -e "${RED}[!] Config transfer verification failed (local ${LOCAL_SIZE} bytes vs remote '${REMOTE_SIZE}' bytes).${NC}"
        echo -e "${RED}[!] Refusing to write to flash or reboot — the radio still has its previous config.${NC}"
        rm -f "$cfg_file"
        return 1
    fi
    echo -e "${GREEN}[+] Config verified on device (${REMOTE_SIZE} bytes).${NC}"

    echo -e "${YELLOW}[*] Writing to flash and rebooting...${NC}"
    sshpass -p "$VALID_PASS" ssh $SSH_OPTS "${VALID_USER}@${FOUND_IP}" "cfgmtd -w -p /etc/ && reboot" || true
    rm -f "$cfg_file"

    if wait_for_reboot "$FOUND_IP" "$VALID_USER" "$VALID_PASS"; then
        echo -e "${GREEN}====================================================${NC}"
        echo -e "${GREEN}[✔] SUCCESS! Radio configured and verified back online.${NC}"
        echo -e "${GREEN}====================================================${NC}"
    else
        echo -e "${RED}====================================================${NC}"
        echo -e "${RED}[!] Config was sent, but the radio has not come back${NC}"
        echo -e "${RED}    online yet. Check power/cabling and verify it     ${NC}"
        echo -e "${RED}    manually before trusting this unit.               ${NC}"
        echo -e "${RED}====================================================${NC}"
        return 1
    fi
}

# ===========================================================================
# STEP 1 — Building Side (always first, always 218)
# ===========================================================================
echo -e "${CYAN}\n--- STEP 1: BUILDING SIDE (192.168.0.${IP_COUNTER}) ---${NC}"
detect_and_auth || exit 1

read -p "$(echo -e ${CYAN}"Enter Wireless SSID for this chain [Default: Impact]: "${NC})" CHAIN_SSID
CHAIN_SSID=${CHAIN_SSID:-Impact}

TMP="/tmp/system_building.cfg"
generate_building_cfg "$CHAIN_SSID" "$IP_COUNTER" > "$TMP"
flash_and_reboot "$TMP"
((IP_COUNTER++))

# ===========================================================================
# STEP 2+ — Repeaters and Sign Side
# ===========================================================================
STEP=2
while true; do
    echo -e "\n${CYAN}----------------------------------------------------${NC}"
    echo -e "${CYAN}--- STEP ${STEP}: Next radio → 192.168.0.${IP_COUNTER} ---${NC}"
    echo -e "  1) Repeater   (AP — connects to this site, serves the next)"
    echo -e "  2) Sign Side  (Station — end of chain)"
    echo -e "  3) Exit"
    read -p "$(echo -e ${CYAN}"Choice [1, 2, or 3]: "${NC})" CHOICE

    case "$CHOICE" in
        1)
            echo -e "${YELLOW}\n[!] Unplug current radio. Connect the REPEATER radio.${NC}"
            read -p "$(echo -e ${GREEN}"Press ENTER when powered on and connected..."${NC})"
            detect_and_auth || continue
            TMP="/tmp/system_repeater.cfg"
            generate_repeater_cfg "$CHAIN_SSID" "$IP_COUNTER" > "$TMP"
            flash_and_reboot "$TMP"
            REPEATER_IPS+=($IP_COUNTER)
            ((IP_COUNTER++))
            ((STEP++))
            ;;
        2)
            echo -e "${YELLOW}\n[!] Unplug current radio. Connect the SIGN SIDE radio.${NC}"
            read -p "$(echo -e ${GREEN}"Press ENTER when powered on and connected..."${NC})"
            detect_and_auth || continue
            TMP="/tmp/system_sign.cfg"
            generate_sign_cfg "$CHAIN_SSID" "$IP_COUNTER" > "$TMP"
            flash_and_reboot "$TMP"
            SIGN_IP=$IP_COUNTER

            echo -e "\n${GREEN}====================================================${NC}"
            echo -e "${GREEN}  Chain provisioning complete!${NC}"
            echo -e "${GREEN}====================================================${NC}"
            echo -e "${CYAN}  SSID          : ${CHAIN_SSID}${NC}"
            echo -e "${CYAN}  Building Side : 192.168.0.218${NC}"
            for rip in "${REPEATER_IPS[@]}"; do
                echo -e "${CYAN}  Repeater      : 192.168.0.${rip}${NC}"
            done
            echo -e "${CYAN}  Sign Side     : 192.168.0.${SIGN_IP}${NC}"
            echo -e "${GREEN}====================================================${NC}"
            exit 0
            ;;
        3)
            echo -e "\n${GREEN}[*] Session ended.${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}[!] Invalid choice. Enter 1, 2, or 3.${NC}"
            ;;
    esac
done
