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

# SSH options with legacy cipher support for airOS / Dropbear SSH
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=4 -o PubkeyAuthentication=no -o HostKeyAlgorithms=+ssh-rsa -o KexAlgorithms=+diffie-hellman-group1-sha1,diffie-hellman-group14-sha1"

# 15-second countdown display
countdown() {
    local secs="$1"
    local label="$2"
    for ((i=secs; i>0; i--)); do
        echo -ne "\r${YELLOW}${label} [${i}s]${NC}"
        sleep 1
    done
    echo -e "\r${GREEN}${label} [done]          ${NC}"
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

# Scan for a radio at the three known candidate IPs
scan_for_radio() {
    local candidates=("192.168.1.20" "192.168.0.218" "192.168.0.219")
    for ip in "${candidates[@]}"; do
        if ping -c 1 -W 1 "$ip" &>/dev/null; then
            echo "$ip"
            return 0
        fi
    done
    return 0
}

# Core Provisioning Function
# $1 = preset SSID   (optional — skips SSID prompt, reuses from paired radio)
# $2 = forced role   (optional — "1" = Building Side, "2" = Sign Side; skips role prompt)
provision_device() {
    local preset_ssid="${1:-}"
    local forced_role="${2:-}"

    echo -e "\n${YELLOW}[*] Scanning for connected radio...${NC}"

    local FOUND_IP
    FOUND_IP=$(scan_for_radio)

    while [ -z "$FOUND_IP" ]; do
        echo -e "${RED}[!] No radio detected at 192.168.1.20, 192.168.0.218, or 192.168.0.219.${NC}"
        echo -e "  ${CYAN}1)${NC} Try Again"
        echo -e "  ${CYAN}2)${NC} Enter IP Manually"
        echo -e "  ${CYAN}3)${NC} Abort"
        read -p "$(echo -e ${CYAN}"Choice: "${NC})" scan_choice
        case "$scan_choice" in
            1)
                echo -e "${YELLOW}[*] Rescanning...${NC}"
                FOUND_IP=$(scan_for_radio)
                ;;
            2)
                read -p "$(echo -e ${CYAN}"Enter radio IP (e.g. 192.168.1.20): "${NC})" FOUND_IP
                if [ -z "$FOUND_IP" ]; then
                    echo -e "${RED}[!] No IP entered.${NC}"
                fi
                ;;
            *)
                echo -e "${RED}[!] Aborting.${NC}"
                return 1
                ;;
        esac
    done

    echo -e "${GREEN}[+] Radio detected at: ${FOUND_IP}${NC}"
    countdown 15 "[*] Waiting for device to boot and connect"

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

    # Role selection
    local ROLE_CHOICE
    if [ -n "$forced_role" ]; then
        ROLE_CHOICE="$forced_role"
        if [ "$ROLE_CHOICE" == "1" ]; then
            echo -e "${CYAN}[*] Configuring as: Building Side (AP / 192.168.0.218)${NC}"
        else
            echo -e "${CYAN}[*] Configuring as: Sign Side (Station / 192.168.0.219)${NC}"
        fi
    else
        echo -e "${CYAN}Select configuration for this unit (${FOUND_IP}):${NC}"
        echo -e "  ${CYAN}1)${NC} Building Side  (AP / Fallback IP: 192.168.0.218)"
        echo -e "  ${CYAN}2)${NC} Sign Side      (Station / Fallback IP: 192.168.0.219)"
        read -p "$(echo -e ${CYAN}"Choice [1 or 2]: "${NC})" ROLE_CHOICE
    fi

    # SSID selection
    local CUSTOM_SSID
    if [ -n "$preset_ssid" ]; then
        CUSTOM_SSID="$preset_ssid"
        echo -e "${CYAN}[*] Using SSID: ${CUSTOM_SSID}${NC}\n"
    else
        echo ""
        read -p "$(echo -e ${CYAN}"Enter Wireless SSID [Default: Impact]: "${NC})" CUSTOM_SSID
        CUSTOM_SSID="${CUSTOM_SSID:-Impact}"
    fi

    # Generate config file
    local TMP_CFG="/tmp/locolocator_system.cfg"
    if [ "$ROLE_CHOICE" == "1" ]; then
        echo -e "${YELLOW}[*] Generating Building Side config for SSID '${CUSTOM_SSID}'...${NC}"
        generate_building_cfg "$CUSTOM_SSID" > "$TMP_CFG"
    elif [ "$ROLE_CHOICE" == "2" ]; then
        echo -e "${YELLOW}[*] Generating Sign Side config for SSID '${CUSTOM_SSID}'...${NC}"
        generate_sign_cfg "$CUSTOM_SSID" > "$TMP_CFG"
    else
        echo -e "${RED}[!] Invalid selection. Aborting.${NC}"
        return 1
    fi

    # Transfer config and reboot
    echo -e "${YELLOW}[*] Transferring configuration via SSH...${NC}"
    sshpass -p "$VALID_PASS" ssh $SSH_OPTS "${VALID_USER}@${FOUND_IP}" "cat > /tmp/system.cfg" < "$TMP_CFG"

    echo -e "${YELLOW}[*] Writing to flash and rebooting radio...${NC}"
    sshpass -p "$VALID_PASS" ssh $SSH_OPTS "${VALID_USER}@${FOUND_IP}" "cfgmtd -w -p /etc/ && reboot" || true

    rm -f "$TMP_CFG"

    countdown 15 "[*] Waiting for radio to reboot successfully"

    echo -e "${GREEN}====================================================${NC}"
    echo -e "${GREEN}  [✔] Radio successfully configured and rebooted.  ${NC}"
    echo -e "${GREEN}      SSID: ${CUSTOM_SSID}${NC}"
    if [ "$ROLE_CHOICE" == "1" ]; then
        echo -e "${GREEN}      Role: Building Side (AP) — 192.168.0.218${NC}"
    else
        echo -e "${GREEN}      Role: Sign Side (Station) — 192.168.0.219${NC}"
    fi
    echo -e "${GREEN}====================================================${NC}"

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
