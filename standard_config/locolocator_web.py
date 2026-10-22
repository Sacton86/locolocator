#!/usr/bin/env python3
"""
LocoLocator Web — local browser UI for Ubiquiti airOS radio provisioning.

Same engine as locolocator.sh (scan -> authenticate -> configure -> flash ->
verify reboot), served as a single local web page instead of a terminal
wizard. Binds to 127.0.0.1 only — never reachable from the network.

Run with: sudo python3 locolocator_web.py
"""

import ipaddress
import json
import os
import pwd
import queue
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
import uuid
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HOST = "127.0.0.1"

SSH_OPTS = [
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "ConnectTimeout=4",
    "-o", "PubkeyAuthentication=no",
    "-o", "HostKeyAlgorithms=+ssh-rsa",
    "-o", "KexAlgorithms=+diffie-hellman-group1-sha1,diffie-hellman-group14-sha1",
]

CANDIDATES = ["192.168.1.20", "192.168.0.218", "192.168.0.219"]
KNOWN_CREDS = [("ubnt", "ubnt"), ("root", "ubnt"), ("Admin", "!mpact1234"), ("root", "!mpact1234")]

UBNT_DISCOVER_PORT = 10001
UBNT_DISCOVER_PROBE = b"\x01\x00\x00\x00"

# Single global session — this tool is a one-technician-at-a-time local wizard.
STATE_LOCK = threading.Lock()
STATE = {"ip": None, "user": None, "pass": None}

# Set by preflight(); reported to the UI so the technician can see whether the
# laptop actually got a DHCP lease on top of its static addresses.
DHCP_LEASE = {"status": "pending", "ip": None}

JOBS = {}
JOBS_LOCK = threading.Lock()


# --------------------------------------------------------------------------
# Config generators (ported from the heredocs in locolocator.sh)
# --------------------------------------------------------------------------

def generate_building_cfg(ssid: str) -> str:
    return f"""aaa.1.br.devname=br0
wpasupplicant.status=disabled
wpasupplicant.profile.1.network.1.psk=!mpact1234
wpasupplicant.device.1.status=disabled
wireless.status=enabled
wireless.hideindoor.status=disabled
wireless.1.wds.status=enabled
wireless.1.status=enabled
wireless.1.ssid={ssid}
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
aaa.1.ssid={ssid}
aaa.1.driver=madwifi
aaa.1.devname=ath0
"""


def generate_sign_cfg(ssid: str) -> str:
    return f"""aaa.1.status=disabled
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
wireless.1.ssid={ssid}
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
wpasupplicant.profile.1.network.1.ssid={ssid}
wpasupplicant.status=enabled
"""


# --------------------------------------------------------------------------
# Network helpers
# --------------------------------------------------------------------------

def valid_ip(ip: str) -> bool:
    try:
        ipaddress.ip_address(ip)
        return True
    except ValueError:
        return False


def ping_once(ip: str, timeout: float = 1.0) -> bool:
    return subprocess.run(
        ["ping", "-c", "1", "-W", str(int(timeout)), ip],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ).returncode == 0


def port_open(ip: str, port: int, timeout: float = 1.0) -> bool:
    try:
        with socket.create_connection((ip, port), timeout=timeout):
            return True
    except OSError:
        return False


def parse_ubnt_reply(data: bytes) -> dict:
    """Best-effort decode of a Ubiquiti discovery-protocol reply (TLV body
    after a 4-byte header). Never raises — a field is simply omitted if the
    packet doesn't look like what we expect, since the IP address (which is
    all that actually matters for connecting) comes from the UDP sender
    address, not from this payload."""
    info = {}
    try:
        pos = 4
        while pos + 3 <= len(data):
            tlv_type = data[pos]
            tlv_len = int.from_bytes(data[pos + 1:pos + 3], "big")
            pos += 3
            if pos + tlv_len > len(data):
                break
            value = data[pos:pos + tlv_len]
            pos += tlv_len
            if tlv_type in (0x01, 0x02) and tlv_len >= 6 and "mac" not in info:
                info["mac"] = ":".join(f"{b:02x}" for b in value[:6])
            elif tlv_type == 0x03 and "firmware" not in info:
                info["firmware"] = value.decode(errors="replace").strip("\x00")
            elif tlv_type == 0x0b and "hostname" not in info:
                info["hostname"] = value.decode(errors="replace").strip("\x00")
            elif tlv_type in (0x0c, 0x14) and "platform" not in info:
                info["platform"] = value.decode(errors="replace").strip("\x00")
    except Exception:
        pass
    return info


def discover_radios(timeout: float = 1.5) -> dict[str, dict]:
    """Broadcast the Ubiquiti discovery probe on UDP/10001 and collect every
    reply. This finds a radio's real IP whether it ended up there via DHCP or
    its static fallback — every airOS/UniFi device answers this broadcast
    regardless of how it got its address, which a fixed candidate-IP guess
    list can never do."""
    found: dict[str, dict] = {}
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(("", 0))
        sock.sendto(UBNT_DISCOVER_PROBE, ("255.255.255.255", UBNT_DISCOVER_PORT))
    except OSError:
        return found

    deadline = time.monotonic() + timeout
    with sock:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            sock.settimeout(min(0.3, remaining))
            try:
                data, (ip, _port) = sock.recvfrom(4096)
            except (socket.timeout, OSError):
                continue
            if ip not in found:
                found[ip] = parse_ubnt_reply(data)
    return found


def scan_for_radios() -> dict[str, dict]:
    """Combined scan: broadcast discovery (primary — works no matter what IP
    the radio ended up with) plus a direct ping of the known static/fallback
    addresses (backup — catches the case where broadcast is filtered by a
    managed switch or VLAN)."""
    found = discover_radios()

    results = {}
    lock = threading.Lock()

    def check(ip):
        if ping_once(ip, timeout=1.0):
            with lock:
                results[ip] = {}

    threads = [threading.Thread(target=check, args=(ip,)) for ip in CANDIDATES if ip not in found]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    found.update(results)
    return found


def ssh_run(ip, user, password, remote_cmd, input_data=None, timeout=15):
    cmd = ["sshpass", "-p", password, "ssh", *SSH_OPTS, f"{user}@{ip}", remote_cmd]
    try:
        result = subprocess.run(cmd, input=input_data, capture_output=True, timeout=timeout)
        return result.returncode == 0, result.stdout, result.stderr
    except subprocess.TimeoutExpired:
        return False, b"", b"timeout"
    except FileNotFoundError:
        return False, b"", b"sshpass/ssh not installed"


def try_login(ip, user, password) -> bool:
    ok, _, _ = ssh_run(ip, user, password, "echo OK", timeout=8)
    return ok


def wait_for(check_fn, timeout: int, interval: float = 2.0) -> bool:
    waited = 0.0
    while True:
        if check_fn():
            return True
        if waited >= timeout:
            return False
        time.sleep(interval)
        waited += interval


# --------------------------------------------------------------------------
# Job (background provisioning run) with a log queue for SSE streaming
# --------------------------------------------------------------------------

class Job:
    def __init__(self):
        self.id = uuid.uuid4().hex
        self.queue = queue.Queue()
        self.result = None  # "success" | "failed"

    def log(self, level: str, text: str):
        self.queue.put({"level": level, "text": text})

    def finish(self, result: str):
        self.result = result
        self.queue.put(None)  # sentinel


def wait_for_reboot(job: Job, ip: str, user: str, password: str) -> tuple[bool, str]:
    """Confirm the radio actually rebooted and is reachable again. Returns
    (ok, ip_to_use) — ip_to_use is normally the same ip, but if the radio
    comes back with a *different* DHCP lease than it had before (which the
    config we just wrote allows, since dhcpc tries DHCP before falling back
    to the static address), we re-discover it by broadcast and report the
    new address instead of just timing out against the old one."""
    job.log("info", "Confirming radio dropped offline for reboot...")
    if not wait_for(lambda: not ping_once(ip), timeout=20):
        job.log("warn", "Radio never went offline — it may reboot quickly, or the reboot command may not have taken effect. Continuing to monitor...")

    job.log("info", f"Waiting for radio to come back online at {ip} (up to 90s)...")
    if not wait_for(lambda: ping_once(ip), timeout=90):
        job.log("warn", f"No response from {ip} yet — broadcasting to see if it came back at a different DHCP address...")
        found = discover_radios(timeout=3.0)
        other = next((cand for cand in found if cand != ip), None)
        if other:
            job.log("success", f"Radio reappeared at {other} (new DHCP lease) — continuing verification there.")
            ip = other
        elif not wait_for(lambda: ping_once(ip), timeout=60):
            job.log("error", f"No response from {ip} after waiting, and nothing new answered a discovery broadcast.")
            return False, ip

    job.log("info", "Waiting for SSH to come back up...")
    if not wait_for(lambda: port_open(ip, 22), timeout=60):
        job.log("warn", "Radio is pingable but SSH isn't answering yet — one more check...")
        if not wait_for(lambda: port_open(ip, 22), timeout=30):
            job.log("error", "SSH never came back up.")
            return False, ip

    if not try_login(ip, user, password):
        job.log("warn", "SSH port is open but login isn't succeeding yet — giving it a few more seconds...")
        time.sleep(5)
        if not try_login(ip, user, password):
            job.log("error", "Could not log back in after reboot.")
            return False, ip

    return True, ip


def run_provision(job: Job, ip: str, user: str, password: str, role: str, ssid: str):
    try:
        role_label = "Building Side (AP) — 192.168.0.218" if role == "1" else "Sign Side (Station) — 192.168.0.219"
        job.log("info", f"Generating {role_label} config for SSID '{ssid}'...")
        cfg_text = generate_building_cfg(ssid) if role == "1" else generate_sign_cfg(ssid)
        cfg_bytes = cfg_text.encode()

        job.log("info", "Transferring configuration via SSH...")
        ok, _, err = ssh_run(ip, user, password, "cat > /tmp/system.cfg", input_data=cfg_bytes, timeout=20)
        if not ok:
            job.log("error", f"Config transfer failed: {err.decode(errors='replace').strip()}")
            job.finish("failed")
            return

        ok, out, _ = ssh_run(ip, user, password, "wc -c < /tmp/system.cfg", timeout=10)
        remote_size = out.decode(errors="replace").strip()
        local_size = str(len(cfg_bytes))
        if not ok or remote_size != local_size:
            job.log("error", f"Config transfer verification failed (local {local_size} bytes vs remote '{remote_size}' bytes).")
            job.log("error", "Refusing to write to flash or reboot — the radio still has its previous config.")
            job.finish("failed")
            return
        job.log("success", f"Config verified on device ({remote_size} bytes).")

        job.log("info", "Writing to flash and rebooting radio...")
        ssh_run(ip, user, password, "cfgmtd -w -p /etc/ && reboot", timeout=15)

        ok, final_ip = wait_for_reboot(job, ip, user, password)
        if ok:
            job.log("success", f"Radio rebooted and verified back online at {final_ip}. Role: {role_label}, SSID: {ssid}")
            job.finish("success")
        else:
            job.log("error", "Config was sent, but the radio has not come back online. Check power/cabling and verify it manually before trusting this unit.")
            job.finish("failed")
    except Exception as exc:  # keep the SSE stream from hanging on unexpected errors
        job.log("error", f"Unexpected error: {exc}")
        job.finish("failed")


# --------------------------------------------------------------------------
# Preflight (mirrors the top of locolocator.sh) — run once at startup
# --------------------------------------------------------------------------

def preflight() -> str:
    if os.geteuid() != 0:
        print("[!] This must be run with sudo (needed to configure network interfaces).")
        print(f"    Example: sudo python3 {sys.argv[0]}")
        sys.exit(1)

    if not shutil.which("sshpass"):
        print("[*] Installing required tool 'sshpass'...")
        subprocess.run(["apt-get", "update", "-qq"])
        subprocess.run(["apt-get", "install", "-y", "-qq", "sshpass"])

    result = subprocess.run(["ip", "-o", "link", "show", "up"], capture_output=True, text=True)
    iface = None
    for line in result.stdout.splitlines():
        m = re.match(r"\d+:\s+([^:@]+)", line)
        if m:
            name = m.group(1)
            if name != "lo" and re.match(r"^(eth|en)", name):
                iface = name
                break

    if not iface:
        print("[!] Could not detect an active Ethernet interface. Check your connection and try again.")
        sys.exit(1)

    print(f"[*] Detected network interface: {iface}")
    subprocess.run(["ip", "addr", "add", "192.168.1.50/24", "dev", iface], stderr=subprocess.DEVNULL)
    subprocess.run(["ip", "addr", "add", "192.168.0.50/24", "dev", iface], stderr=subprocess.DEVNULL)
    subprocess.run(["ip", "link", "set", iface, "up"])

    # Also try to pick up a real DHCP lease on this interface, in parallel
    # with the two static addresses above. A radio can show up on either a
    # DHCP-provided subnet (if the site network offers one) or its static
    # fallback — this makes sure the laptop itself is reachable on whichever
    # one actually shows up, instead of only ever being reachable on the two
    # hardcoded /24s. Backgrounded and best-effort: an isolated bench link
    # with no DHCP server simply times out and changes nothing.
    threading.Thread(target=_attempt_dhcp_lease, args=(iface,), daemon=True).start()

    return iface


def _attempt_dhcp_lease(iface: str):
    client = shutil.which("dhclient") or shutil.which("dhcpcd")
    if not client:
        DHCP_LEASE["status"] = "unavailable"
        return
    try:
        if "dhclient" in client:
            cmd = [client, "-1", "-timeout", "8", iface]
        else:
            cmd = [client, "-t", "8", iface]
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=12)
    except Exception:
        DHCP_LEASE["status"] = "unavailable"
        return

    result = subprocess.run(["ip", "-4", "-o", "addr", "show", "dev", iface],
                             capture_output=True, text=True)
    for line in result.stdout.splitlines():
        m = re.search(r"inet (\d+\.\d+\.\d+\.\d+)/\d+.*\bdynamic\b", line)
        if m:
            DHCP_LEASE["status"] = "ok"
            DHCP_LEASE["ip"] = m.group(1)
            return
    DHCP_LEASE["status"] = "none"


# --------------------------------------------------------------------------
# HTML / JS front end (single page, no external assets)
# --------------------------------------------------------------------------

INDEX_HTML = """<!doctype html>
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
"""


# --------------------------------------------------------------------------
# HTTP server
# --------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass  # keep the terminal quiet; the web log panel is the real output

    def _json(self, obj, status=200):
        body = json.dumps(obj).encode()
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            # Client disconnected (tab closed/reloaded, request superseded by a
            # newer auto-scan poll) before a slow endpoint finished — nothing
            # to send it back to, so just drop the response.
            pass

    def _read_json(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            return json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return {}

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/":
            body = INDEX_HTML.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif parsed.path == "/api/preflight":
            self._json({"iface": DETECTED_IFACE, "dhcp": DHCP_LEASE})
        elif parsed.path == "/api/stream":
            job_id = parse_qs(parsed.query).get("job_id", [None])[0]
            self._stream_job(job_id)
        else:
            self.send_error(404)

    def _stream_job(self, job_id):
        with JOBS_LOCK:
            job = JOBS.get(job_id)
        if not job:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        while True:
            try:
                item = job.queue.get(timeout=15)
            except queue.Empty:
                try:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    return
                continue
            try:
                if item is None:
                    self.wfile.write(f"event: done\ndata: {job.result}\n\n".encode())
                    self.wfile.flush()
                    return
                self.wfile.write(f"data: {json.dumps(item)}\n\n".encode())
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                return

    def do_POST(self):
        parsed = urlparse(self.path)
        data = self._read_json()

        if parsed.path == "/api/scan":
            found = scan_for_radios()
            radios = [
                {
                    "ip": ip,
                    "mac": info.get("mac"),
                    "hostname": info.get("hostname"),
                    "platform": info.get("platform"),
                    "firmware": info.get("firmware"),
                }
                for ip, info in found.items()
            ]
            if len(radios) == 1:
                with STATE_LOCK:
                    STATE["ip"] = radios[0]["ip"]
            self._json({"radios": radios})

        elif parsed.path == "/api/set_ip":
            ip = str(data.get("ip", "")).strip()
            if not valid_ip(ip):
                self._json({"ok": False, "error": "That doesn't look like a valid IP address."}, 400)
                return
            with STATE_LOCK:
                STATE["ip"] = ip
            self._json({"ok": True})

        elif parsed.path == "/api/connect":
            ip = STATE.get("ip")
            if not ip:
                self._json({"ok": False, "error": "No IP set"}, 400)
                return
            wait_for(lambda: port_open(ip, 22), timeout=30)
            if ip == "192.168.1.20":
                creds = [("ubnt", "ubnt")]
            elif ip in ("192.168.0.218", "192.168.0.219"):
                creds = [("Admin", "!mpact1234")]
            else:
                creds = KNOWN_CREDS
            for user, password in creds:
                if try_login(ip, user, password):
                    with STATE_LOCK:
                        STATE["user"] = user
                        STATE["pass"] = password
                    self._json({"ok": True, "user": user})
                    return
            self._json({"ok": False})

        elif parsed.path == "/api/manual_auth":
            ip = STATE.get("ip")
            user = str(data.get("user", "")).strip() or "ubnt"
            password = str(data.get("pass", ""))
            if ip and try_login(ip, user, password):
                with STATE_LOCK:
                    STATE["user"] = user
                    STATE["pass"] = password
                self._json({"ok": True})
            else:
                self._json({"ok": False})

        elif parsed.path == "/api/provision":
            with STATE_LOCK:
                ip, user, password = STATE.get("ip"), STATE.get("user"), STATE.get("pass")
            role = str(data.get("role", ""))
            ssid = str(data.get("ssid", "")).strip() or "Impact"
            if not (ip and user and password) or role not in ("1", "2"):
                self._json({"error": "Missing IP/credentials/role"}, 400)
                return
            job = Job()
            with JOBS_LOCK:
                JOBS[job.id] = job
            threading.Thread(target=run_provision, args=(job, ip, user, password, role, ssid), daemon=True).start()
            self._json({"job_id": job.id})

        elif parsed.path == "/api/reset":
            with STATE_LOCK:
                STATE["ip"] = None
                STATE["user"] = None
                STATE["pass"] = None
            self._json({"ok": True})

        else:
            self.send_error(404)


DETECTED_IFACE = None


def open_browser(url: str):
    # We normally run as root (via sudo, to configure network interfaces), but
    # Chromium-based browsers (Chrome, Brave, Edge...) refuse to launch as root.
    # Drop back to the invoking user — identified via the SUDO_UID/SUDO_GID/
    # SUDO_USER that sudo sets — before spawning the browser.
    if os.geteuid() != 0:
        webbrowser.open(url)
        return

    sudo_user = os.environ.get("SUDO_USER")
    sudo_uid = os.environ.get("SUDO_UID")
    sudo_gid = os.environ.get("SUDO_GID")
    if not (sudo_user and sudo_uid and sudo_gid):
        print(f"[*] Running as root with no invoking user detected — open this URL manually: {url}")
        return

    env = os.environ.copy()
    env["USER"] = sudo_user
    env["LOGNAME"] = sudo_user
    try:
        env["HOME"] = pwd.getpwuid(int(sudo_uid)).pw_dir
    except (KeyError, ValueError):
        pass

    def drop_privileges():
        os.setgroups([])
        os.setgid(int(sudo_gid))
        os.setuid(int(sudo_uid))

    try:
        subprocess.Popen(
            ["xdg-open", url],
            preexec_fn=drop_privileges,
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        print(f"[*] Could not auto-open a browser — open this URL manually: {url}")


def main():
    global DETECTED_IFACE
    print("====================================================")
    print("   LocoLocator Web — Radio Provisioning Tool        ")
    print("====================================================\n")
    DETECTED_IFACE = preflight()

    server = ThreadingHTTPServer((HOST, 0), Handler)
    port = server.server_address[1]
    url = f"http://{HOST}:{port}/"
    print(f"\n[*] Web UI running at {url}")
    print("[*] Press Ctrl+C here to stop.\n")

    threading.Timer(0.5, lambda: open_browser(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[*] Shutting down.")
        server.shutdown()


if __name__ == "__main__":
    main()
