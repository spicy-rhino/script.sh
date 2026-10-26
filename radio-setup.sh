#!/usr/bin/env bash
# =============================================================================
# radio-setup.sh - radio networks for the TAK Pi, all in one place
#
#   TW / Silvus:  binds a USB-Ethernet adapter to a radio network by its MAC
#                 (TW = 10.100.100.100/8, Silvus = 172.20.100.100/12), checks the
#                 netplan config before applying it, never touches Wi-Fi.
#   Meshtastic:   installs/updates the Meshtastic <-> TAK Server bridge
#                 (app chat + positions, ATAK over Meshtastic (TAK V2), two-way chat).
#
# Usage:
#   sudo bash radio-setup.sh                 menu
#   sudo bash radio-setup.sh --tw            set up the TW adapter
#   sudo bash radio-setup.sh --silvus        set up the Silvus adapter
#   sudo bash radio-setup.sh --mesh          install or update the Meshtastic bridge
#   sudo bash radio-setup.sh --mesh-remove   remove the Meshtastic bridge
#   sudo bash radio-setup.sh --tailscale     connect / check / disconnect Tailscale
#   sudo bash radio-setup.sh --zerotier      join / check / leave a ZeroTier network
#   sudo bash radio-setup.sh --status        show adapters, bridge and VPN status
#
# Meshtastic bridge joins TAK group __ANON__ (users' default group). Different group:
#   sudo TAK_GROUP=YourGroup bash radio-setup.sh --mesh
# =============================================================================

if [ "$(id -u)" -ne 0 ]; then
  echo "[!] Run this with sudo:  sudo bash radio-setup.sh"
  exit 1
fi

# ============================ Radio adapters (TW / Silvus) ============================
radio_main() (
FILE="/etc/netplan/99-radio-usb-static.yaml"
TW_IP="10.100.100.100/8"
SILVUS_IP="172.20.100.100/12"


# Wired adapters only - skips loopback, Wi-Fi, Docker and virtual interfaces
list_ifaces() {
  local d n
  for d in /sys/class/net/*; do
    n="$(basename "$d")"
    case "$n" in lo|wl*|docker*|veth*|br-*|virbr*) continue ;; esac
    [ -e "$d/device" ] || continue
    echo "$n"
  done | sort
}

# Reads the MAC already saved for an adapter name (ignores commented lines)
get_mac() {
  [ -f "$FILE" ] || return 0
  awk -v n="$1" '
    /^[[:space:]]*#/ {next}
    $1 == n":" {f=1; next}
    f && $1 == "macaddress:" {print $2; exit}
    f && /^    [^ ]/ {f=0}
  ' "$FILE"
}

block() {  # name mac ip
  cat <<EOF
    $1:
      match:
        macaddress: $2
      set-name: $1
      dhcp4: false
      addresses:
        - $3
      optional: true
EOF
}

write_file() {  # tw_mac silvus_mac
  {
    echo "network:"
    echo "  version: 2"
    if [ -n "$1" ] || [ -n "$2" ]; then
      echo "  ethernets:"
      [ -n "$1" ] && block tw-usb "$1" "$TW_IP"
      [ -n "$2" ] && block silvus-usb "$2" "$SILVUS_IP"
    fi
    echo "# Managed by radio-setup.sh. TW = $TW_IP   Silvus = $SILVUS_IP"
  } > "$FILE"
  chmod 600 "$FILE"
  chown root:root "$FILE"
}

show_current() {
  echo
  echo "Current radio adapters:"
  echo "  TW      (tw-usb)      MAC: ${TW_MAC:-not set}"
  echo "  Silvus  (silvus-usb)  MAC: ${SILVUS_MAC:-not set}"
  echo
}

TW_MAC="$(get_mac tw-usb)"
SILVUS_MAC="$(get_mac silvus-usb)"

show_current
choice="${1:-}"

case "$choice" in
  1) NAME=tw-usb;     LABEL=TW ;;
  2) NAME=silvus-usb; LABEL=Silvus ;;
  3)
    read -r -p "Remove which? (1 = TW, 2 = Silvus): " r
    case "$r" in 1) TW_MAC="" ;; 2) SILVUS_MAC="" ;; *) echo "Cancelled."; exit 0 ;; esac
    NAME=""; LABEL=""
    ;;
  *) echo "Nothing changed."; exit 0 ;;
esac

if [ -n "$NAME" ]; then
  echo
  echo ">> UNPLUG the USB-Ethernet adapter you want to use for $LABEL."
  echo "   (Leave any other radio adapter plugged in.)"
  read -r -p "   Press Enter once it's unplugged... "
  BEFORE="$(list_ifaces)"

  echo
  echo ">> Now PLUG IN the $LABEL adapter."
  read -r -p "   Press Enter once it's plugged in... "

  NEW=""
  for _ in $(seq 1 15); do
    NEW="$(comm -13 <(echo "$BEFORE") <(list_ifaces) | head -n1)"
    [ -n "$NEW" ] && break
    sleep 1
  done
  if [ -z "$NEW" ]; then
    echo "[!] No new adapter showed up. Try a different USB port and run this again."
    exit 1
  fi

  MAC="$(tr 'A-F' 'a-f' < "/sys/class/net/$NEW/address")"
  if ! [[ "$MAC" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]; then
    echo "[!] Couldn't read a valid MAC from $NEW (got: $MAC)."
    exit 1
  fi
  echo
  echo "   Found adapter $NEW with MAC $MAC"

  if [ "$NAME" = tw-usb ] && [ "$MAC" = "$SILVUS_MAC" ]; then
    echo "[!] That adapter is already assigned to Silvus. Use a different adapter, or remove Silvus first."
    exit 1
  fi
  if [ "$NAME" = silvus-usb ] && [ "$MAC" = "$TW_MAC" ]; then
    echo "[!] That adapter is already assigned to TW. Use a different adapter, or remove TW first."
    exit 1
  fi

  [ "$NAME" = tw-usb ] && TW_MAC="$MAC"
  [ "$NAME" = silvus-usb ] && SILVUS_MAC="$MAC"
fi

# Back up, write, and test before applying anything
BACKUP=""
if [ -f "$FILE" ]; then
  BACKUP="$FILE.bak.$(date +%Y%m%d-%H%M%S)"
  cp -p "$FILE" "$BACKUP"
  chmod 600 "$BACKUP"
fi
write_file "$TW_MAC" "$SILVUS_MAC"

if ! ERR="$(netplan generate 2>&1)"; then
  echo "[!] netplan rejected the new config:"
  echo "$ERR"
  if [ -n "$BACKUP" ]; then mv "$BACKUP" "$FILE"; else rm -f "$FILE"; fi
  echo "    Restored the previous file. Nothing was applied."
  exit 1
fi

echo
echo ">> Config checks out. Applying (you can ignore any '** WARNING' lines)..."
netplan apply 2>&1 | grep -v '^\*\* (generate' || true
sleep 3

show_current
for n in tw-usb silvus-usb; do
  ip -br addr show "$n" 2>/dev/null || true
done
echo
[ -n "$BACKUP" ] && echo "Previous file saved as $BACKUP"
if [ -n "$NAME" ]; then
  echo "Plug the $LABEL radio into that adapter and check for link lights."
  if [ "$NAME" = tw-usb ]; then
    echo "TW ATAK users point their server connection at ${TW_IP%/*}"
  else
    echo "Silvus ATAK users point their server connection at ${SILVUS_IP%/*}"
  fi
fi
)

# ============================ Meshtastic bridge ============================
mesh_main() (
APP_DIR="/opt/tak-meshbridge"
CONF="/etc/tak-meshbridge.conf"
SVC="tak-meshbridge"
SVC_USER="meshbridge"
CERT_NAME="meshtastic-bridge"
TAK_CERTS="/opt/tak/certs"
TAK_GROUP="${TAK_GROUP:-__ANON__}"   # TAK group the bridge joins; must match your users' group


log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ---- Uninstall ---------------------------------------------------------------
if [ "${1:-}" = "--remove" ]; then
  systemctl disable --now "$SVC" 2>/dev/null || true
  rm -f "/etc/systemd/system/$SVC.service" "$CONF"
  rm -rf "$APP_DIR"
  systemctl daemon-reload
  log "Bridge removed. (Its TAK certificate '$CERT_NAME' is still in $TAK_CERTS/files.)"
  exit 0
fi

# ---- 1. Preflight ------------------------------------------------------------
log "=== Preflight ==="
if [ ! -x "$TAK_CERTS/makeCert.sh" ]; then
  log "[!] TAK Server isn't installed (no $TAK_CERTS/makeCert.sh). Run setup.sh first."
  exit 1
fi

# Find the Meshtastic node by its stable USB path
mapfile -t PORTS < <(ls /dev/serial/by-id/* 2>/dev/null || true)
if [ "${#PORTS[@]}" -eq 0 ]; then
  log "[!] No USB serial device found. Plug in the Meshtastic node (use a data cable, not charge-only) and rerun."
  exit 1
elif [ "${#PORTS[@]}" -eq 1 ]; then
  SERIAL_PORT="${PORTS[0]}"
else
  echo "Several USB serial devices found:"
  for i in "${!PORTS[@]}"; do echo "  $((i+1))) ${PORTS[$i]}"; done
  read -r -p "Which one is the Meshtastic node? " n
  SERIAL_PORT="${PORTS[$((n-1))]:-}"
  [ -n "$SERIAL_PORT" ] || { log "[!] Invalid choice."; exit 1; }
fi
log "Meshtastic node: $SERIAL_PORT"

# Programs that grab USB serial ports and block the node
for p in brltty ModemManager; do
  if systemctl is-active --quiet "$p" 2>/dev/null; then
    log "[!] $p is running and may grab the node's USB port. If the bridge can't connect: sudo systemctl disable --now $p"
  fi
done

# ---- 2. Python environment ----------------------------------------------------
log "=== Python environment ==="
if pgrep -x unattended-upgr >/dev/null 2>&1 || pgrep -x apt-get >/dev/null 2>&1 || pgrep -x dpkg >/dev/null 2>&1; then
  log "Ubuntu is installing updates in the background - waiting for it to finish (can take up to 15 min)..."
fi
DEBIAN_FRONTEND=noninteractive apt-get -y -o DPkg::Lock::Timeout=900 install python3-venv openssl >/dev/null
log "Downloading Python packages for the bridge (first time can take a few minutes)..."
id "$SVC_USER" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$SVC_USER"
usermod -aG dialout "$SVC_USER"
mkdir -p "$APP_DIR"
if [ ! -x "$APP_DIR/venv/bin/python" ]; then
  python3 -m venv "$APP_DIR/venv"
fi
"$APP_DIR/venv/bin/pip" install --quiet --upgrade pip
"$APP_DIR/venv/bin/pip" install --quiet --upgrade meshtastic
# Official converter for ATAK's over-the-air format (TAK V2). Optional: the bridge still runs without it.
# Not on PyPI yet, so it's installed from Meshtastic's TAKPacket-SDK repo.
SDK_DIR="$APP_DIR/TAKPacket-SDK"
sdk_ok() { "$APP_DIR/venv/bin/python" -c "from meshtastic_tak import TakCompressor, CotXmlParser, CotXmlBuilder, CotMeshSanitizer" >/dev/null 2>&1; }
if ! sdk_ok; then
  "$APP_DIR/venv/bin/pip" install --quiet --upgrade meshtastic-tak >/dev/null 2>&1 || true
fi
if ! sdk_ok; then
  rm -rf "$SDK_DIR"
  if git clone --quiet --depth 1 https://github.com/meshtastic/TAKPacket-SDK.git "$SDK_DIR" >/dev/null 2>&1; then
    "$APP_DIR/venv/bin/pip" install --quiet -e "$SDK_DIR/python" >/tmp/meshbridge-sdk.log 2>&1 || true
  fi
fi
if sdk_ok; then
  log "meshtastic-tak converter installed (ATAK over Meshtastic is available)."
else
  log "[!] Couldn't install the meshtastic-tak converter (see /tmp/meshbridge-sdk.log)."
  log "    ATAK-over-Meshtastic will be off. Meshtastic app chat/positions still work."
fi
log "meshtastic Python library $("$APP_DIR/venv/bin/pip" show meshtastic | awk '/^Version/{print $2}') installed."

# ---- 3. Bridge certificate ------------------------------------------------------
log "=== Bridge certificate ==="
CERT_PEM="$TAK_CERTS/files/$CERT_NAME.pem"
CERT_KEY="$TAK_CERTS/files/$CERT_NAME.key"
if [ ! -f "$CERT_PEM" ] || [ ! -f "$CERT_KEY" ]; then
  log "Creating TAK client certificate '$CERT_NAME'..."
  ( cd "$TAK_CERTS" && ./makeCert.sh client "$CERT_NAME" ) >/dev/null
  chown -R tak:tak "$TAK_CERTS/files" 2>/dev/null || true
else
  log "Certificate '$CERT_NAME' already exists - reusing it."
fi

# The key is password-protected; store an unlocked copy readable only by the bridge.
# The password is used once here and never saved.
install -d -m 750 -o root -g "$SVC_USER" "$APP_DIR/certs"
install -m 644 -o root -g "$SVC_USER" "$CERT_PEM" "$APP_DIR/certs/client.pem"
if [ ! -s "$APP_DIR/certs/client.key" ]; then
  unlocked=no
  for attempt in 1 2 3; do
    echo
    echo ">> Enter the TAK certificate password (the one you set in the TAK menus)."
    echo "   Nothing shows while you type - that's normal. Press Enter when done."
    read -r -s -p "   Password: " TAKPASS; echo
    export TAKPASS
    if openssl pkey -in "$CERT_KEY" -passin env:TAKPASS -out "$APP_DIR/certs/client.key" 2>/dev/null; then
      unlocked=yes; break
    fi
    # makeCert.sh may still use TAK's default password
    TAKPASS="atakatak"
    if openssl pkey -in "$CERT_KEY" -passin env:TAKPASS -out "$APP_DIR/certs/client.key" 2>/dev/null; then
      unlocked=yes; break
    fi
    log "  That password didn't unlock the key. Try again ($attempt/3)."
  done
  unset TAKPASS
  [ "$unlocked" = yes ] || { rm -f "$APP_DIR/certs/client.key"; log "[!] Couldn't unlock the certificate."; exit 1; }
fi
chown root:"$SVC_USER" "$APP_DIR/certs/client.key"
chmod 640 "$APP_DIR/certs/client.key"
log "Certificate ready."

# Put the bridge in the same TAK group as your users, or the server won't pass traffic between them
log "Adding the bridge to TAK group '$TAK_GROUP'..."
if java -jar /opt/tak/utils/UserManager.jar certmod -g "$TAK_GROUP" "$CERT_PEM" >/tmp/meshbridge-certmod.log 2>&1; then
  log "Bridge is in group '$TAK_GROUP'."
else
  log "[!] Couldn't set the bridge's TAK group (see /tmp/meshbridge-certmod.log)."
  log "    Fix by hand: admin page > Manage Users, or rerun with: sudo TAK_GROUP=YourGroup bash radio-setup.sh --mesh"
fi

# ---- 4. Config + bridge program --------------------------------------------------
log "=== Bridge program ==="
if [ ! -f "$CONF" ]; then
  cat > "$CONF" <<EOF
# tak-meshbridge settings. Restart after editing: sudo systemctl restart $SVC
SERIAL_PORT=$SERIAL_PORT
TAK_HOST=127.0.0.1
TAK_PORT=8089
EOF
  log "Wrote settings to $CONF"
else
  sed -i "s|^SERIAL_PORT=.*|SERIAL_PORT=$SERIAL_PORT|" "$CONF"
  log "Keeping your existing settings in $CONF"
fi
# Add any settings that are new in this version (existing values are never changed)
add_setting() {  # key value comment
  grep -q "^$1=" "$CONF" || printf '\n# %s\n%s=%s\n' "$3" "$1" "$2" >> "$CONF"
}
add_setting STALE_MINUTES 15 "Minutes a Meshtastic marker stays on the map after its last position report"
add_setting MAX_AGE_MINUTES 60 "Ignore positions older than this many minutes (stops stale nodes appearing as fresh)"
add_setting TWO_WAY yes "yes = also send TAK chat out over the mesh; no = Meshtastic -> TAK only"
add_setting TAK_CHATROOM "All Chat Rooms" "Which TAK chat room is relayed to the mesh"
add_setting MESH_CHANNEL 0 "Meshtastic channel index used for TAK chat (0 = primary channel)"
add_setting MESH_PREFIX "[TAK]" "Text added in front of TAK messages on the mesh"
add_setting MESH_MIN_GAP_SECONDS 5 "Minimum seconds between messages sent to the mesh (protects LoRa airtime)"
add_setting MESH_TAK_FORMAT both "How TAK chat goes to the mesh: text (Meshtastic app users), atak (ATAK users), or both"
add_setting TAK_PLI_TO_MESH no "yes = also send TAK users' positions to ATAK users on the mesh (uses airtime)"
add_setting TAK_PLI_INTERVAL_SECONDS 300 "Minimum seconds between position updates per TAK user sent to the mesh"
add_setting TAK_MARKERS_TO_MESH yes "yes = send markers, drawings and routes from TAK users to ATAK users on the mesh"
add_setting MARKER_MAX_AGE_MINUTES 10 "Don't send markers older than this (stops old markers flooding the mesh on reconnect)"
add_setting MARKER_MIN_RESEND_SECONDS 60 "Minimum seconds before the same marker is sent to the mesh again"
add_setting RADIO_COT_TYPE a-f-G "How radios are drawn on the TAK map: a-f-G = blue rectangle (friendly ground); a-f-G-U-C + team color was the old cyan dot"
add_setting RADIO_PLI non-atak "Radio positions on the TAK map: all, non-atak (hide radios that carry an ATAK user), or none"

set_setting() {  # key value
  if grep -q "^$1=" "$CONF"; then sed -i "s|^$1=.*|$1=$2|" "$CONF"; else printf '%s=%s\n' "$1" "$2" >> "$CONF"; fi
}

# Ask how Meshtastic radios' own positions should show (Enter keeps the current choice)
if [ -t 0 ]; then
  cur="$(grep '^RADIO_PLI=' "$CONF" | cut -d= -f2)"
  case "$cur" in all) d=1 ;; none) d=3 ;; *) d=2 ;; esac
  echo
  echo "Which positions should show on the TAK map?"
  echo "  (Radio PLI = the Meshtastic radio's own GPS, shown as a blue rectangle."
  echo "   ATAK client PLI = the phone running ATAK through that radio, shown as a team dot.)"
  echo
  echo "  1) Radio PLI + ATAK client PLI"
  echo "       Every radio and every ATAK user. Someone with ATAK on their radio shows twice."
  echo "  2) Radio PLI (no client) + ATAK client PLI"
  echo "       Radios WITHOUT an ATAK phone, plus every ATAK user. Nobody shows twice."
  echo "  3) ATAK client PLI only"
  echo "       Only ATAK users. No radio markers at all."
  read -r -p "Choose 1-3 [current: $d]: " rp
  case "${rp:-$d}" in 1) set_setting RADIO_PLI all ;; 3) set_setting RADIO_PLI none ;; *) set_setting RADIO_PLI non-atak ;; esac
  log "Radio positions on the TAK map: $(grep '^RADIO_PLI=' "$CONF" | cut -d= -f2)"
fi
chmod 644 "$CONF"

cat > "$APP_DIR/meshbridge.py" <<'PY'
#!/usr/bin/env python3
"""Meshtastic <-> TAK Server bridge (v4).

Mesh -> TAK : node positions become TAK markers; Meshtastic app text becomes TAK chat;
              ATAK traffic sent over Meshtastic (TAK V2, port 78) is passed to TAK Server.
TAK -> Mesh : chat in one TAK chat room goes out as Meshtastic text and/or ATAK (TAK V2);
              markers/drawings/routes go out as ATAK; optionally, TAK users'
              positions go out as ATAK at a slow rate.
Connects to TAK Server over TLS with its own client certificate.
"""
import os
import queue
import socket
import ssl
import threading
import time
import uuid
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone
from xml.sax.saxutils import escape, quoteattr

from pubsub import pub
import meshtastic.serial_interface

# Official Meshtastic converter for ATAK's over-the-air format (TAK V2, firmware 2.8+)
try:
    from meshtastic_tak import CotXmlParser, CotXmlBuilder, TakCompressor, CotMeshSanitizer
    TAKSDK_ERR = ""
except Exception as _e:  # bridge still runs; only the ATAK-over-mesh features are off
    CotXmlParser = CotXmlBuilder = TakCompressor = CotMeshSanitizer = None
    TAKSDK_ERR = str(_e)

SERIAL_PORT = os.environ["SERIAL_PORT"]
TAK_HOST = os.environ.get("TAK_HOST", "127.0.0.1")
TAK_PORT = int(os.environ.get("TAK_PORT", "8089"))
STALE_MIN = int(os.environ.get("STALE_MINUTES", "15"))
MAX_AGE_MIN = int(os.environ.get("MAX_AGE_MINUTES", "60"))
TWO_WAY = os.environ.get("TWO_WAY", "yes").strip().lower() in ("yes", "true", "1", "on")
TAK_CHATROOM = os.environ.get("TAK_CHATROOM", "All Chat Rooms").strip().strip('"')
MESH_CHANNEL = int(os.environ.get("MESH_CHANNEL", "0"))
MESH_PREFIX = os.environ.get("MESH_PREFIX", "[TAK]").strip().strip('"')
MESH_MIN_GAP = float(os.environ.get("MESH_MIN_GAP_SECONDS", "5"))
MESH_MAX_BYTES = 200  # Meshtastic text payload limit, with some margin
# What TAK chat is sent to the mesh as: text (Meshtastic app users), atak (ATAK users), or both
MESH_TAK_FORMAT = os.environ.get("MESH_TAK_FORMAT", "both").strip().lower()
TAK_PLI_TO_MESH = os.environ.get("TAK_PLI_TO_MESH", "no").strip().lower() in ("yes", "true", "1", "on")
TAK_PLI_INTERVAL = int(os.environ.get("TAK_PLI_INTERVAL_SECONDS", "300"))
# Markers, drawings, routes, alerts from TAK users -> ATAK users on the mesh
TAK_MARKERS_TO_MESH = os.environ.get("TAK_MARKERS_TO_MESH", "yes").strip().lower() in ("yes", "true", "1", "on")
MARKER_MAX_AGE_MIN = int(os.environ.get("MARKER_MAX_AGE_MINUTES", "10"))
MARKER_MIN_RESEND = int(os.environ.get("MARKER_MIN_RESEND_SECONDS", "60"))
# Meshtastic radios' own GPS positions on the TAK map:
#   all       every radio shows up
#   non-atak  hide radios that carry an ATAK user (their ATAK callsign already shows)
#   none      no radio positions; only ATAK users
RADIO_PLI = os.environ.get("RADIO_PLI", "non-atak").strip().lower()
if RADIO_PLI not in ("all", "non-atak", "none"):
    RADIO_PLI = "non-atak"
# How Meshtastic radios are drawn on the TAK map. a-f-G = plain friendly ground (blue rectangle).
RADIO_COT_TYPE = os.environ.get("RADIO_COT_TYPE", "a-f-G").strip() or "a-f-G"
PORT_ATAK_V1 = 72   # ATAK_PLUGIN (older firmware)
PORT_ATAK_V2 = 78   # ATAK_PLUGIN_V2 (firmware 2.8+)
MAX_MESH_DATA = 233  # largest data payload Meshtastic accepts
CERT = os.environ.get("CLIENT_CERT", "/opt/tak-meshbridge/certs/client.pem")
KEY = os.environ.get("CLIENT_KEY", "/opt/tak-meshbridge/certs/client.key")
UID_PREFIX = "MESHTASTIC-"

to_tak = queue.Queue(maxsize=500)
to_mesh = queue.Queue(maxsize=20)
seen_chat = {}  # TAK chat event uid -> time, to avoid sending duplicates
from_mesh = {}  # uids of events/senders that came from the mesh -> time (loop protection)
last_pli_sent = {}  # TAK uid -> time its position was last sent to the mesh
last_marker_sent = {}  # marker uid -> time it was last sent to the mesh
atak_nodes = set()  # Meshtastic node numbers that carry an ATAK user
_warned_v1 = False
iface = None
my_num = None


def log(msg):
    print(msg, flush=True)


# ---------------------------------------------------------------- Mesh -> TAK
def ts(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%S.%fZ")[:-4] + "Z"


def node_uid(node_id):
    return UID_PREFIX + str(node_id).lstrip("!")


def node_name(node_id):
    try:
        user = iface.nodes.get(node_id, {}).get("user", {})
        return user.get("longName") or user.get("shortName") or str(node_id)
    except Exception:
        return str(node_id)


def pli_cot(node_id, lat, lon, alt):
    now = datetime.now(timezone.utc)
    name = node_name(node_id)
    hae = alt if alt is not None else 9999999.0
    return (
        f'<event version="2.0" uid={quoteattr(node_uid(node_id))} type={quoteattr(RADIO_COT_TYPE)} how="m-g" '
        f'time="{ts(now)}" start="{ts(now)}" stale="{ts(now + timedelta(minutes=STALE_MIN))}">'
        f'<point lat="{lat:.6f}" lon="{lon:.6f}" hae="{hae}" ce="9999999.0" le="9999999.0"/>'
        f'<detail><contact callsign={quoteattr(name)}/>'
        f'<remarks>{escape("Meshtastic radio " + str(node_id))}</remarks></detail></event>'
    )


def chat_cot(node_id, text):
    now = datetime.now(timezone.utc)
    sender = node_uid(node_id)
    name = node_name(node_id)
    room = TAK_CHATROOM
    lat = lon = 0.0
    pos = iface.nodes.get(node_id, {}).get("position", {}) if iface else {}
    if "latitude" in pos and "longitude" in pos:
        lat, lon = pos["latitude"], pos["longitude"]
    msg_uid = f"GeoChat.{sender}.{room}.{uuid.uuid4()}"
    return (
        f'<event version="2.0" uid={quoteattr(msg_uid)} type="b-t-f" how="h-g-i-g-o" '
        f'time="{ts(now)}" start="{ts(now)}" stale="{ts(now + timedelta(days=1))}">'
        f'<point lat="{lat:.6f}" lon="{lon:.6f}" hae="9999999.0" ce="9999999.0" le="9999999.0"/>'
        f'<detail><__chat parent="RootContactGroup" groupOwner="false" chatroom={quoteattr(room)} '
        f'id={quoteattr(room)} senderCallsign={quoteattr(name)}>'
        f'<chatgrp uid0={quoteattr(sender)} uid1={quoteattr(room)} id={quoteattr(room)}/></__chat>'
        f'<link uid={quoteattr(sender)} type="a-f-G-U-C" relation="p-p"/>'
        f'<remarks source={quoteattr("BAO.F.ATAK." + sender)} to={quoteattr(room)} time="{ts(now)}">'
        f'{escape(text)}</remarks></detail></event>'
    )


def enqueue(q, item):
    try:
        q.put_nowait(item)
    except queue.Full:
        try:
            q.get_nowait()  # drop the oldest
        except queue.Empty:
            pass
        q.put_nowait(item)


def show_radio_position(node_num):
    if RADIO_PLI == "none":
        return False
    if RADIO_PLI == "non-atak" and node_num in atak_nodes:
        return False
    return True


def delete_cot(target_uid):
    """CoT event that removes a marker from TAK maps right away."""
    now = datetime.now(timezone.utc)
    return (
        f'<event version="2.0" uid={quoteattr("delete-" + target_uid)} type="t-x-d-d" how="h-g-i-g-o" '
        f'time="{ts(now)}" start="{ts(now)}" stale="{ts(now + timedelta(minutes=5))}">'
        f'<point lat="0" lon="0" hae="9999999.0" ce="9999999.0" le="9999999.0"/>'
        f'<detail><link uid={quoteattr(target_uid)} relation="none" type="none"/><__forcedelete/></detail></event>'
    )


def position_is_fresh(packet, pos):
    """Skips positions whose own GPS time is older than MAX_AGE_MINUTES."""
    t = pos.get("time") or pos.get("timestamp")
    if not t:
        return True  # no timestamp to judge by
    return (time.time() - float(t)) <= MAX_AGE_MIN * 60


def on_position(packet, interface):
    try:
        if packet.get("from") == my_num:
            return
        pos = packet.get("decoded", {}).get("position", {})
        if "latitude" not in pos or "longitude" not in pos:
            return
        node_id = packet.get("fromId") or f"!{packet.get('from', 0):08x}"
        if not show_radio_position(packet.get("from")):
            return
        if not position_is_fresh(packet, pos):
            log(f"stale     {node_name(node_id)}  (position older than {MAX_AGE_MIN} min, skipped)")
            return
        enqueue(to_tak, pli_cot(node_id, pos["latitude"], pos["longitude"], pos.get("altitude")).encode())
        log(f"position  {node_name(node_id)}  {pos['latitude']:.5f},{pos['longitude']:.5f}")
    except Exception as e:
        log(f"skipped a position packet: {e}")


def on_text(packet, interface):
    try:
        text = packet.get("decoded", {}).get("text", "")
        if not text:
            return
        node_id = packet.get("fromId") or f"!{packet.get('from', 0):08x}"
        enqueue(to_tak, chat_cot(node_id, text).encode())
        log(f"mesh->TAK {node_name(node_id)}: {text[:60]}")
    except Exception as e:
        log(f"skipped a text packet: {e}")


def remember_from_mesh(uid):
    if uid:
        from_mesh[uid] = time.time()


def came_from_mesh(uid):
    now = time.time()
    for k, t in list(from_mesh.items()):
        if now - t > 3600:
            del from_mesh[k]
    return bool(uid) and (uid.startswith(UID_PREFIX) or uid in from_mesh)


def strip_xml_decl(xml):
    xml = xml.strip()
    if xml.startswith("<?xml"):
        xml = xml[xml.find("?>") + 2:].strip()
    return xml


def raw_port_and_payload(packet):
    """Returns (port number, payload bytes), working even if this library version doesn't know the port's name."""
    raw = packet.get("raw")
    try:
        if raw is not None and raw.HasField("decoded"):
            return int(raw.decoded.portnum), bytes(raw.decoded.payload)
    except Exception:
        pass
    d = packet.get("decoded", {}) or {}
    port = d.get("portnum")
    names = {"ATAK_PLUGIN": PORT_ATAK_V1, "ATAK_PLUGIN_V2": PORT_ATAK_V2}
    port = names.get(port, port)
    try:
        port = int(port)
    except (TypeError, ValueError):
        port = -1
    return port, d.get("payload", b"") or b""


def on_any_packet(packet, interface):
    """Handles ATAK traffic sent over Meshtastic."""
    global _warned_v1
    try:
        if packet.get("from") == my_num:
            return
        port, payload = raw_port_and_payload(packet)
        if port == PORT_ATAK_V1:
            if not _warned_v1:
                log("Heard older ATAK-over-Meshtastic traffic (port 72). Only the newer TAK V2 format (firmware 2.8+) is supported.")
                _warned_v1 = True
            return
        if port != PORT_ATAK_V2 or not payload:
            return
        node_num = packet.get("from")
        if node_num not in atak_nodes:
            atak_nodes.add(node_num)
            if RADIO_PLI == "non-atak":
                # this radio carries an ATAK user - drop its separate radio marker
                node_id = packet.get("fromId") or f"!{node_num:08x}"
                enqueue(to_tak, delete_cot(node_uid(node_id)).encode())
                log(f"radio     {node_name(node_id)} carries an ATAK user - showing the ATAK callsign only")
        if TakCompressor is None:
            log(f"ATAK packet heard, but the meshtastic-tak library isn't loaded ({TAKSDK_ERR}). Run radio-setup.sh option 6.")
            return
        pkt = TakCompressor().decompress(payload)
        xml = strip_xml_decl(CotXmlBuilder().build(pkt))
        ev = ET.fromstring(xml)
        uid, etype = ev.get("uid", ""), ev.get("type", "")
        remember_from_mesh(uid)
        det = ev.find("detail")
        callsign = ""
        if det is not None:
            c = det.find("contact")
            chat = det.find("__chat")
            grp = chat.find("chatgrp") if chat is not None else None
            if c is not None:
                callsign = c.get("callsign", "")
            if chat is not None:
                callsign = chat.get("senderCallsign", callsign)
            if grp is not None:
                remember_from_mesh(grp.get("uid0", ""))
            link = det.find("link")
            if link is not None and etype.startswith("b-t-f"):
                remember_from_mesh(link.get("uid", ""))
        enqueue(to_tak, xml.encode("utf-8"))
        if etype.startswith("b-t-f"):
            what = "chat"
        elif etype.startswith("a-") and det is not None and (det.find("takv") is not None or det.find("__group") is not None):
            what = "position"
        else:
            what = f"marker ({etype})"
        log(f"ATAK mesh->TAK {what}  {callsign or uid}")
    except Exception as e:
        log(f"skipped an ATAK packet from the mesh: {e}")


def on_lost(interface):
    log("Lost connection to the Meshtastic node - exiting so systemd restarts the bridge.")
    os._exit(1)


def resend_known_nodes():
    """Every 5 minutes, put every recently heard node back on the map."""
    while True:
        try:
            cutoff = time.time() - MAX_AGE_MIN * 60
            for node_id, n in list((iface.nodes or {}).items()):
                if n.get("num") == my_num or not show_radio_position(n.get("num")):
                    continue
                pos = n.get("position", {})
                if "latitude" in pos and "longitude" in pos and n.get("lastHeard", 0) >= cutoff:
                    enqueue(to_tak, pli_cot(node_id, pos["latitude"], pos["longitude"], pos.get("altitude")).encode())
        except Exception as e:
            log(f"node refresh failed: {e}")
        time.sleep(300)


# ---------------------------------------------------------------- TAK -> Mesh
def trim_utf8(text, limit):
    data = text.encode("utf-8")
    if len(data) <= limit:
        return text
    return data[: limit - 3].decode("utf-8", "ignore") + "..."


def encode_for_mesh(xml_bytes):
    """CoT XML from TAK Server -> compressed TAK V2 payload for the mesh (None if it can't fit)."""
    if TakCompressor is None:
        return None
    xml = xml_bytes.decode("utf-8", "replace")
    try:
        xml = CotMeshSanitizer.normalize_cot_xml(xml)
        xml = CotMeshSanitizer.strip_non_essential_for_mesh(xml)
    except Exception:
        pass
    data = TakCompressor().compress(CotXmlParser().parse(xml))
    if len(data) > MAX_MESH_DATA:
        log(f"  too large for one Meshtastic packet ({len(data)} bytes), not sent")
        return None
    return bytes(data)


MARKER_TYPES = ("a-", "b-m-p", "u-d-", "u-r-", "b-m-r", "b-r-f-h-c", "b-a-o")


def event_age_minutes(ev):
    t = ev.get("time", "")
    try:
        dt = datetime.strptime(t[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
        return (datetime.now(timezone.utc) - dt).total_seconds() / 60
    except ValueError:
        return 0


def handle_tak_event(raw):
    """Decides whether an event from TAK Server goes out to the mesh."""
    if not TWO_WAY:
        return
    is_chat = b'type="b-t-f"' in raw
    try:
        ev = ET.fromstring(raw)
    except ET.ParseError:
        return
    uid = ev.get("uid", "")
    etype = ev.get("type", "")
    if came_from_mesh(uid):
        return  # came from the mesh in the first place - don't echo it back
    detail = ev.find("detail")
    if detail is None:
        return
    # A user's own position report carries <takv> or <__group>; anything else in these families is a marker
    is_user_pli = etype.startswith("a-") and (detail.find("takv") is not None or detail.find("__group") is not None)
    is_pli = (not is_chat) and is_user_pli and TAK_PLI_TO_MESH and detail.find("contact") is not None
    is_marker = (not is_chat) and (not is_user_pli) and TAK_MARKERS_TO_MESH and etype.startswith(MARKER_TYPES)
    if not (is_chat or is_pli or is_marker):
        return

    if is_marker:
        if uid.startswith(UID_PREFIX):
            return  # our own Meshtastic radio markers
        if event_age_minutes(ev) > MARKER_MAX_AGE_MIN:
            return  # old marker replayed by the server (e.g. on reconnect)
        now = time.time()
        if now - last_marker_sent.get(uid, 0) < MARKER_MIN_RESEND:
            return
        c = detail.find("contact")
        name = (c.get("callsign") if c is not None else "") or uid
        try:
            data = encode_for_mesh(raw)
        except Exception as e:
            log(f"couldn't convert marker {name} ({etype}) for the mesh: {e}")
            return
        if data:
            last_marker_sent[uid] = now
            enqueue(to_mesh, ("atak", data, f"marker {name} ({etype})"))
        return

    if is_pli:
        now = time.time()
        if now - last_pli_sent.get(uid, 0) < TAK_PLI_INTERVAL:
            return
        c = detail.find("contact")
        callsign = c.get("callsign", uid) if c is not None else uid
        try:
            data = encode_for_mesh(raw)
        except Exception as e:
            log(f"couldn't convert {callsign}'s position for the mesh: {e}")
            return
        if data:
            last_pli_sent[uid] = now
            enqueue(to_mesh, ("atak", data, f"position {callsign}"))
        return

    chat = detail.find("__chat")
    remarks = detail.find("remarks")
    if chat is None or remarks is None or not (remarks.text or "").strip():
        return
    room = chat.get("chatroom") or chat.get("id") or ""
    if room != TAK_CHATROOM:
        return  # private chats and other rooms stay in TAK
    grp = chat.find("chatgrp")
    sender_uid = (grp.get("uid0") if grp is not None else "") or ""
    link = detail.find("link")
    if link is not None and not sender_uid:
        sender_uid = link.get("uid", "")
    if came_from_mesh(sender_uid) or uid.startswith(f"GeoChat.{UID_PREFIX}"):
        return
    now = time.time()
    for k, t in list(seen_chat.items()):
        if now - t > 3600:
            del seen_chat[k]
    if uid in seen_chat:
        return
    seen_chat[uid] = now
    callsign = chat.get("senderCallsign") or "TAK"
    if MESH_TAK_FORMAT in ("atak", "both"):
        try:
            data = encode_for_mesh(raw)
            if data:
                enqueue(to_mesh, ("atak", data, f"chat {callsign}: {remarks.text.strip()[:50]}"))
        except Exception as e:
            log(f"couldn't convert chat for ATAK-over-mesh: {e}")
    if MESH_TAK_FORMAT in ("text", "both"):
        msg = trim_utf8(f"{MESH_PREFIX} {callsign}: {remarks.text.strip()}".strip(), MESH_MAX_BYTES)
        enqueue(to_mesh, ("text", msg, msg))


def split_events(buf):
    """Pulls complete <event>...</event> blocks out of the TAK stream buffer."""
    events = []
    while True:
        end = buf.find(b"</event>")
        if end == -1:
            break
        chunk, buf = buf[: end + 8], buf[end + 8 :]
        start = chunk.find(b"<event")
        if start != -1:
            events.append(chunk[start:])
    if len(buf) > 1_000_000:  # never let a broken stream eat memory
        buf = b""
    return events, buf


def mesh_sender():
    """Sends queued TAK chat to the mesh, spaced out to protect LoRa airtime."""
    last = 0.0
    while True:
        kind, body, label = to_mesh.get()
        wait = MESH_MIN_GAP - (time.time() - last)
        if wait > 0:
            time.sleep(wait)
        try:
            if kind == "atak":
                iface.sendData(body, portNum=PORT_ATAK_V2, channelIndex=MESH_CHANNEL)
                log(f"TAK->mesh (ATAK) {label[:70]}")
            else:
                iface.sendText(body, channelIndex=MESH_CHANNEL)
                log(f"TAK->mesh (text) {label[:70]}")
        except Exception as e:
            log(f"couldn't send to mesh: {e}")
        last = time.time()


# ---------------------------------------------------------------- TAK link
def tak_link():
    """Keeps a TLS connection to TAK Server open, sends queued events, reads chat."""
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.load_cert_chain(CERT, KEY)
    # Loopback connection to the server on this same machine, so the server's
    # certificate isn't verified; the bridge's own client cert still authenticates it.
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    backoff = 2
    while True:
        try:
            with socket.create_connection((TAK_HOST, TAK_PORT), timeout=15) as raw:
                with ctx.wrap_socket(raw) as s:
                    log(f"Connected to TAK Server {TAK_HOST}:{TAK_PORT}"
                        + (f" (two-way: '{TAK_CHATROOM}' <-> mesh channel {MESH_CHANNEL})" if TWO_WAY else " (one-way)"))
                    backoff = 2
                    s.settimeout(0.5)
                    buf = b""
                    pending = None
                    while True:
                        try:
                            data = s.recv(65536)
                            if not data:
                                raise ConnectionError("TAK Server closed the connection")
                            events, buf = split_events(buf + data)
                            for ev in events:
                                handle_tak_event(ev)
                        except (socket.timeout, ssl.SSLWantReadError):
                            pass
                        if pending is None:
                            try:
                                pending = to_tak.get(timeout=0.5)
                            except queue.Empty:
                                continue
                        s.sendall(pending)
                        pending = None
        except Exception as e:
            log(f"TAK connection problem: {e}. Retrying in {backoff}s.")
            time.sleep(backoff)
            backoff = min(backoff * 2, 60)


def find_serial_port():
    """Uses the saved port; if that node was unplugged or swapped, uses the only USB serial device present."""
    if os.path.exists(SERIAL_PORT):
        return SERIAL_PORT
    by_id = "/dev/serial/by-id"
    found = sorted(os.listdir(by_id)) if os.path.isdir(by_id) else []
    if len(found) == 1:
        port = os.path.join(by_id, found[0])
        log(f"Saved node {SERIAL_PORT} not found - using the one plugged in: {port}")
        return port
    if not found:
        log("No Meshtastic node plugged in (no USB serial devices). Waiting 30s...")
    else:
        log(f"Saved node not found and {len(found)} USB serial devices present - run radio-setup.sh option 6 to pick one. Waiting 30s...")
    time.sleep(30)
    raise SystemExit(1)


def main():
    global iface, my_num
    threading.Thread(target=tak_link, daemon=True).start()
    pub.subscribe(on_position, "meshtastic.receive.position")
    pub.subscribe(on_text, "meshtastic.receive.text")
    pub.subscribe(on_lost, "meshtastic.connection.lost")
    pub.subscribe(on_any_packet, "meshtastic.receive")
    if TakCompressor is None:
        log(f"ATAK-over-Meshtastic is OFF: meshtastic-tak library not loaded ({TAKSDK_ERR})")
    else:
        log(f"ATAK-over-Meshtastic is ON (TAK V2). TAK chat to mesh as: {MESH_TAK_FORMAT}. "
            f"Markers to mesh: {'on' if TAK_MARKERS_TO_MESH else 'off'}. "
            f"TAK positions to mesh: {'every %ss' % TAK_PLI_INTERVAL if TAK_PLI_TO_MESH else 'off'}")
    log(f"Radio positions on the TAK map: {RADIO_PLI} (drawn as {RADIO_COT_TYPE})")
    port = find_serial_port()
    log(f"Opening Meshtastic node on {port}")
    iface = meshtastic.serial_interface.SerialInterface(devPath=port)
    try:
        my_num = iface.myInfo.my_node_num
    except Exception:
        my_num = None
    log(f"Meshtastic connected. {len(iface.nodes or {})} nodes known.")
    threading.Thread(target=resend_known_nodes, daemon=True).start()
    if TWO_WAY:
        threading.Thread(target=mesh_sender, daemon=True).start()
    while True:
        time.sleep(60)


if __name__ == "__main__":
    main()
PY
chmod 755 "$APP_DIR/meshbridge.py"

cat > "/etc/systemd/system/$SVC.service" <<EOF
[Unit]
Description=Meshtastic to TAK Server bridge
After=network-online.target takserver.service
Wants=network-online.target

[Service]
Type=simple
User=$SVC_USER
Group=$SVC_USER
SupplementaryGroups=dialout
EnvironmentFile=$CONF
ExecStart=$APP_DIR/venv/bin/python -u $APP_DIR/meshbridge.py
Restart=always
RestartSec=10
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SVC" >/dev/null 2>&1
systemctl restart "$SVC"
sleep 8

# ---- 5. Status -------------------------------------------------------------------
echo
echo "================ MESHTASTIC BRIDGE ================"
if systemctl is-active --quiet "$SVC"; then
  echo "  Bridge service: OK"
else
  echo "  Bridge service: NOT RUNNING"
fi
echo "  Node: $SERIAL_PORT"
echo "  TAK group: $TAK_GROUP"
echo "  Two-way chat: $(grep '^TWO_WAY=' "$CONF" | cut -d= -f2)   Markers to mesh: $(grep '^TAK_MARKERS_TO_MESH=' "$CONF" | cut -d= -f2)"
echo "  Radio positions on map: $(grep '^RADIO_PLI=' "$CONF" | cut -d= -f2)   (settings: $CONF)"
echo "  Recent log:"
journalctl -u "$SVC" -n 8 --no-pager -o cat | sed 's/^/    /'
echo
echo "  Watch it live:   sudo journalctl -u $SVC -f"
echo "  Settings file:   $CONF"
echo "  Uninstall:       sudo bash radio-setup.sh  (option 7)"
echo "==================================================="
)

# ============================ VPN (Tailscale / ZeroTier) ============================
vpn_user_home() {
  local u="${SUDO_USER:-root}"
  getent passwd "$u" | cut -d: -f6
}

vpn_have_internet() {
  if ! getent hosts github.com >/dev/null 2>&1; then
    echo "[!] No internet/DNS on the Pi. Tailscale and ZeroTier need internet to install and connect."
    return 1
  fi
}

# Let traffic arriving over the VPN reach the Pi (only if the firewall is on)
vpn_allow_firewall() {  # interface
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow in on "$1" >/dev/null && echo "  Firewall: allowed traffic arriving on $1."
  fi
}

# Copies the TAK enrollment packages with the server address changed to the VPN address
vpn_make_packages() {  # label ip
  local label="$1" ip="$2" home certdir src made=0
  home="$(vpn_user_home)"; certdir="$home/tak-certs"
  mkdir -p "$certdir"
  for base in enrollmentDP enrollmentDP-QUIC; do
    src=""
    for d in "$certdir" "$home" /root; do
      [ -f "$d/$base.zip" ] && { src="$d/$base.zip"; break; }
    done
    [ -n "$src" ] || continue
    local tmp; tmp="$(mktemp -d)"
    unzip -q "$src" -d "$tmp"
    if [ -f "$tmp/config.pref" ]; then
      sed -i -E "s#(<entry key=\"connectString0\"[^>]*>)[^:<]*:#\1${ip}:#" "$tmp/config.pref"
      sed -i -E "s#(<entry key=\"description0\"[^>]*>)([^<]*)(</entry>)#\1\2 (${label})\3#" "$tmp/config.pref"
      [ -f "$tmp/MANIFEST.xml" ] && sed -i -E \
        -e "s#(name=\"uid\" value=\")[^\"]*#\1$(cat /proc/sys/kernel/random/uuid)#" \
        -e "s#(name=\"name\" value=\")[^\"]*#\1${base}-${label}.zip#" "$tmp/MANIFEST.xml"
      rm -f "$certdir/${base}-${label}.zip"
      (cd "$tmp" && zip -q -j "$certdir/${base}-${label}.zip" ./*)
      made=$((made + 1))
    fi
    rm -rf "$tmp"
  done
  chown -R "${SUDO_USER:-root}": "$certdir" 2>/dev/null || true
  chmod 600 "$certdir"/*.zip 2>/dev/null || true
  if [ "$made" -gt 0 ]; then
    echo "  Enrollment packages for remote users (server address $ip):"
    ls -1 "$certdir"/enrollmentDP*-"$label".zip | sed 's#^#    #'
  else
    echo "  [!] No enrollment packages found to copy (is TAK Server installed?)."
  fi
}

vpn_summary() {  # label ip
  local ip="$2"
  echo
  echo "  ---- Reaching this TAK Server over $1 ($ip) ----"
  echo "  Admin:       ssh ${SUDO_USER:-root}@$ip     https://$ip:8443"
  echo "  TAK users:   load the *-$1.zip enrollment package below in ATAK/WinTAK"
  echo "  ownCloud:    http://$ip      Mumble: $ip port 64738"
  echo "  Federation:  other TAK Servers connect to $ip port 9001"
  echo "               (swap FedCA.pem from ~/tak-certs with the other server's admin first)"
  vpn_make_packages "$1" "$ip"
  echo "  Copy them to your PC:  scp ${SUDO_USER:-root}@<pi-ip>:~/tak-certs/*-$1.zip \$HOME\\Desktop\\"
}

# ZeroTier networks as "nwid status device ipv4" lines (JSON is used so blank names can't shift columns)
zt_networks() {
  zerotier-cli -j listnetworks 2>/dev/null | python3 -c '
import json, sys
try:
    nets = json.load(sys.stdin)
except Exception:
    nets = []
for n in nets:
    ip = next((a.split("/")[0] for a in n.get("assignedAddresses", []) if "." in a), "-")
    print(n.get("nwid", "-"), n.get("status", "-"), n.get("portDeviceName", "-") or "-", ip)
'
}

tailscale_main() (
  set -u
  ts_ip() { tailscale ip -4 2>/dev/null | head -n1; }
  ts_finish() {
    local ip; ip="$(ts_ip)"
    if [ -z "$ip" ]; then echo "  Tailscale isn't connected yet."; return 1; fi
    echo "  Tailscale connected. This Pi's Tailscale IP: $ip"
    vpn_allow_firewall tailscale0
    vpn_summary tailscale "$ip"
  }
  if ! command -v tailscale >/dev/null; then
    vpn_have_internet || exit 1
    echo "Installing Tailscale (official installer from tailscale.com)..."
    curl -fsSL https://tailscale.com/install.sh | sh || { echo "[!] Tailscale install failed."; exit 1; }
  fi
  echo
  echo "Tailscale:"
  echo "  1) Connect / reconnect"
  echo "  2) Status (and rebuild remote enrollment packages)"
  echo "  3) Disconnect"
  read -r -p "Choose 1-3: " t
  case "$t" in
    1)
      vpn_have_internet || exit 1
      echo
      echo "Paste a Tailscale auth key (Tailscale admin console > Settings > Keys),"
      echo "or just press Enter to log in with a link instead. Nothing shows while you paste."
      read -r -s -p "Auth key: " key; echo
      if [ -n "$key" ]; then
        tailscale up --hostname="$(hostname)" --auth-key="$key" || { echo "[!] tailscale up failed."; exit 1; }
      else
        echo "Open the link below on any device, log in, and approve this Pi:"
        tailscale up --hostname="$(hostname)" || { echo "[!] tailscale up failed."; exit 1; }
      fi
      unset key
      ts_finish
      ;;
    2) tailscale status 2>/dev/null | head -15; ts_finish || true ;;
    3) tailscale down && echo "Tailscale disconnected. (Reconnect any time with option 1.)" ;;
    *) echo "Nothing changed." ;;
  esac
)

zerotier_main() (
  set -u
  zt_finish() {
    local found=0 nwid status dev ip
    while read -r nwid status dev ip; do
      [ -n "${nwid:-}" ] || continue
      found=1
      if [ "$status" = "OK" ] && [ "$ip" != "-" ]; then
        echo "  Network $nwid: connected. Interface $dev, this Pi's ZeroTier IP: $ip"
        vpn_allow_firewall "$dev"
        vpn_summary zerotier "$ip"
      else
        echo "  Network $nwid: $status (not authorized yet, or no IP assigned)."
        echo "  In ZeroTier Central (my.zerotier.com) > your network > Members, tick 'Auth' for"
        echo "  device $(zerotier-cli info | awk '{print $3}'), then run this option's Status."
      fi
    done < <(zt_networks)
    [ "$found" = 1 ] || { echo "  Not joined to any ZeroTier network."; return 1; }
  }
  if ! command -v zerotier-cli >/dev/null; then
    vpn_have_internet || exit 1
    echo "Installing ZeroTier (official installer from zerotier.com)..."
    curl -fsSL https://install.zerotier.com | bash || { echo "[!] ZeroTier install failed."; exit 1; }
    systemctl enable --now zerotier-one >/dev/null 2>&1 || true
  fi
  echo
  echo "ZeroTier (this Pi's device ID: $(zerotier-cli info 2>/dev/null | awk '{print $3}')):"
  echo "  1) Join a network"
  echo "  2) Status (and rebuild remote enrollment packages)"
  echo "  3) Leave a network"
  read -r -p "Choose 1-3: " z
  case "$z" in
    1)
      read -r -p "ZeroTier Network ID (16 characters): " nw
      nw="$(echo "$nw" | tr -d '[:space:]' | tr 'A-F' 'a-f')"
      [[ "$nw" =~ ^[0-9a-f]{16}$ ]] || { echo "[!] That isn't a 16-character network ID."; exit 1; }
      zerotier-cli join "$nw" >/dev/null || { echo "[!] Join failed."; exit 1; }
      echo
      echo ">> Now approve this Pi: ZeroTier Central (my.zerotier.com) > network $nw > Members,"
      echo "   tick 'Auth' for device $(zerotier-cli info | awk '{print $3}')."
      echo "   Waiting up to 3 minutes for approval (Ctrl+C to stop waiting - you can finish later with Status)..."
      for _ in $(seq 1 36); do
        zt_networks | awk -v n="$nw" '$1==n && $2=="OK" && $4!="-" {ok=1} END{exit !ok}' && break
        sleep 5; printf '.'
      done
      echo
      zt_finish || true
      ;;
    2) zt_finish || true ;;
    3)
      zt_networks | awk '{print "  " $1 "  " $2 "  " $4}'
      read -r -p "Network ID to leave: " nw
      [ -n "$nw" ] && zerotier-cli leave "$nw" && echo "Left $nw."
      ;;
    *) echo "Nothing changed." ;;
  esac
)

# ============================ Status ============================
show_status() {
  echo
  echo "================ RADIO STATUS ================"
  for n in tw-usb silvus-usb; do
    if ip link show "$n" >/dev/null 2>&1; then
      ip -br addr show "$n" | sed 's/^/  /'
    else
      echo "  $n  (not set up or adapter not plugged in)"
    fi
  done
  echo
  if [ -f /etc/systemd/system/tak-meshbridge.service ]; then
    if systemctl is-active --quiet tak-meshbridge; then
      echo "  Meshtastic bridge: OK"
    else
      echo "  Meshtastic bridge: NOT RUNNING"
    fi
    case "$(grep '^RADIO_PLI=' /etc/tak-meshbridge.conf 2>/dev/null | cut -d= -f2)" in
      all)  echo "  Map shows: Radio PLI + ATAK client PLI" ;;
      none) echo "  Map shows: ATAK client PLI only" ;;
      *)    echo "  Map shows: Radio PLI (no client) + ATAK client PLI" ;;
    esac
    journalctl -u tak-meshbridge -n 6 --no-pager -o cat 2>/dev/null | sed 's/^/    /'
  else
    echo "  Meshtastic bridge: not installed"
  fi
  echo
  if command -v tailscale >/dev/null; then
    tsip="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
    echo "  Tailscale: ${tsip:-installed, not connected}"
  else
    echo "  Tailscale: not installed"
  fi
  if command -v zerotier-cli >/dev/null; then
    zt="$(zt_networks)"
    if [ -n "$zt" ]; then echo "$zt" | awk '{print "  ZeroTier: network " $1 "  " $2 "  IP " $4}'
    else echo "  ZeroTier: installed, no network joined"; fi
  else
    echo "  ZeroTier: not installed"
  fi
  echo "=============================================="
}

# ============================ Menu ============================
run_choice() {
  case "$1" in
    1|--tailscale)   tailscale_main ;;
    2|--zerotier)    zerotier_main ;;
    3|--tw)          radio_main 1 ;;
    4|--silvus)      radio_main 2 ;;
    5|--remove)      radio_main 3 ;;
    6|--mesh)        mesh_main ;;
    7|--mesh-remove) mesh_main --remove ;;
    8|--status)      show_status ;;
  esac
}
valid_choice() {
  case "$1" in
    1|2|3|4|5|6|7|8|--tw|--silvus|--remove|--mesh|--mesh-remove|--tailscale|--zerotier|--status) return 0 ;;
  esac
  return 1
}

if [ -n "${1:-}" ]; then
  valid_choice "$1" || { echo "Unknown option: $1  (try --tw, --silvus, --mesh, --mesh-remove, --tailscale, --zerotier, --status)"; exit 1; }
  run_choice "$1"
  exit $?
fi

while true; do
  echo
  echo "=========== RADIO SETUP ==========="
  echo "  1) Tailscale - connect / status / disconnect"
  echo "  2) ZeroTier - join / status / leave"
  echo "  3) TW radio adapter"
  echo "  4) Silvus radio adapter"
  echo "  5) Remove a radio adapter"
  echo "  6) Meshtastic bridge - install or update"
  echo "  7) Meshtastic bridge - remove"
  echo "  8) Status of everything"
  echo "  9) Quit"
  read -r -p "Choose 1-9: " c
  if [ "$c" = 9 ] || [ -z "$c" ]; then exit 0; fi
  if valid_choice "$c"; then run_choice "$c" || true; else echo "Pick a number from 1 to 9."; fi
done
