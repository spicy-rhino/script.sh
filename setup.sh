#!/usr/bin/env bash
# =============================================================================
# TAK Stack Setup v6 - Raspberry Pi 5 / Orange Pi 5+ on Ubuntu Server 24.04 LTS
# Services: TAK Server 5.4, ownCloud (Docker), MediaMTX, Mumble, Radio USB netplan
#
# Put these in ONE folder with this script, copy the folder to the Pi, then run it:
#   takserver_5.4-RELEASE19_all.deb   deb_policy.pol   takserver-public-gpg.key
#   (optional) installTAK + LICENSE   - saved copy; if missing, it's downloaded from GitHub
#   (optional) 99-radio-usb-static.yaml - your filled-in version; otherwise a blank template is installed
#
# Usage:
#   sudo bash setup.sh               Normal install. TAK menus are answered automatically
#                                    with the answers under "TAK setup answers" below.
#   sudo bash setup.sh --manual-tak  Show the TAK menus and answer them yourself.
#   sudo bash setup.sh --clean       Wipes TAK/Mumble/ownCloud/MediaMTX first (asks you to type WIPE).
# =============================================================================

# ---- Settings ---------------------------------------------------------------
TAK_DEB="takserver_5.4-RELEASE19_all.deb"
TAK_FILES=("$TAK_DEB" "deb_policy.pol" "takserver-public-gpg.key")
INSTALLTAK_REPO="https://github.com/myTeckNet/installTAK.git"
MTX_VERSION="v1.12.3"
OWNCLOUD_IMAGE="owncloud:latest"
NETPLAN_FILE="99-radio-usb-static.yaml"

# ---- TAK setup answers (used unless you run with --manual-tak) --------------
TAK_COUNTRY="US"                      # 2-letter country code
TAK_STATE="Kansas"
TAK_CITY="Lebanon"                    # geographic center of the lower 48 - a neutral default
TAK_ORG="TAK"
TAK_ORG_UNIT="TAK"
TAK_CERT_PASSWORD=""                  # blank = TAK default (atakatak). Letters/numbers only if you set one.
TAK_ROOT_CA="TAK Server Root CA"      # installTAK turns this into TAK-SERVER-ROOT-CA
TAK_INT_CA="TAK Server CA"            # installTAK turns this into TAK-SERVER-CA
TAK_AUTO_ENROLL="yes"
TAK_FEDERATION="yes"
TAK_WEB_OPTIONS="enableAdminUI enableWebtak"   # WebAdmin UI + WebTAK; NonAdminUI off
TAK_CONNECTIONS="SSL QUIC"            # only asked on older TAK versions; 5.4 does both
TAK_DESCRIPTION="TAK Server"          # name clients see for this server
# FQDN connections: always No (clients connect by IP)
# -----------------------------------------------------------------------------

set -Eeuo pipefail
LOG_DIR="/tmp"
trap 'echo "[!] ERROR on line $LINENO: \"$BASH_COMMAND\" failed. Logs: $LOG_DIR" >&2' ERR

if [ "$(id -u)" -ne 0 ]; then
  echo "[!] Run this with sudo:  sudo bash setup.sh"
  exit 1
fi

ACTUAL_USER="${SUDO_USER:-root}"
USER_HOME="$(getent passwd "$ACTUAL_USER" | cut -d: -f6)"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$USER_HOME/tak-setup-logs"
CERT_OUT="$USER_HOME/tak-certs"
WORK_DIR="$USER_HOME/installTAK-run"
CLEAN=no
MANUAL_TAK=no
for arg in "$@"; do
  case "$arg" in
    --clean) CLEAN=yes ;;
    --manual-tak) MANUAL_TAK=yes ;;
    *) echo "[!] Unknown option: $arg  (use --clean and/or --manual-tak)"; exit 1 ;;
  esac
done

mkdir -p "$LOG_DIR"
chown "$ACTUAL_USER": "$LOG_DIR"
log()  { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_DIR/setup.log"; }
step() { echo; log "=== $* ==="; }
apt_q() {
  DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confold \
    -o Acquire::Retries=5 -o DPkg::Lock::Timeout=900 "$@"
}
# Retries an apt step up to 3 times, refreshing package lists between tries,
# so a short Wi-Fi or DNS dropout doesn't end the whole install
apt_retry() {  # logfile apt-args...
  local logf="$1"; shift
  local i
  for i in 1 2 3; do
    if apt_q "$@" >>"$logf" 2>&1; then return 0; fi
    log "  apt attempt $i failed (see $logf). Waiting 20s and retrying..."
    sleep 20
    apt_q update >>"$logf" 2>&1 || true
  done
  log "[!] apt kept failing - usually the Pi lost internet. Check: ping -c 4 ports.ubuntu.com"
  return 1
}
tak_installed() { dpkg -s takserver >/dev/null 2>&1 || [ -d /opt/tak ]; }

# Finds a file in the script folder, ignoring upper/lower case in the name
find_src() { find "$SRC_DIR" -maxdepth 1 -type f -iname "$1" | head -n1; }

# ---- 0. Preflight checks ----------------------------------------------------
step "Preflight checks"
log "User: $ACTUAL_USER   Home: $USER_HOME   Script folder: $SRC_DIR"

ARCH="$(uname -m)"
if [ "$ARCH" != "aarch64" ]; then
  log "[!] Expected aarch64 (ARM64) but this is $ARCH. Continuing anyway."
fi
grep -q 'VERSION_ID="24.04"' /etc/os-release || log "[!] This isn't Ubuntu 24.04. Continuing anyway."

FREE_GB="$(df -BG --output=avail / | tail -1 | tr -dc '0-9')"
if [ "$FREE_GB" -lt 10 ]; then
  log "[!] Only ${FREE_GB}GB free on /. Need at least 10GB."
  exit 1
fi

if ! getent hosts archive.ubuntu.com >/dev/null || ! getent hosts github.com >/dev/null; then
  log "[!] DNS lookups are failing. Check the Pi's internet:  ping 1.1.1.1  then  ping google.com"
  exit 1
fi

# TAK files are only required if TAK isn't installed yet (or we're wiping it)
if ! tak_installed || [ "$CLEAN" = yes ]; then
  MISSING=()
  for f in "${TAK_FILES[@]}"; do
    [ -n "$(find_src "$f")" ] || MISSING+=("$f")
  done
  if [ "${#MISSING[@]}" -gt 0 ]; then
    log "[!] Missing TAK files in $SRC_DIR:"
    printf '      %s\n' "${MISSING[@]}"
    log "    Copy them into this folder and run the script again."
    exit 1
  fi
fi
log "Preflight OK (${FREE_GB}GB free)"

# ---- 1. Optional wipe (only with --clean) -----------------------------------
if [ "$CLEAN" = yes ]; then
  step "CLEAN MODE"
  echo "This DELETES the TAK Server (CA, certs, database), Mumble, ownCloud files, and MediaMTX."
  echo "Every client cert you've issued will stop working."
  read -r -p "Type WIPE to continue, anything else to cancel: " ans
  [ "$ans" = "WIPE" ] || { log "Cancelled."; exit 1; }

  systemctl disable --now takserver mumble-server "mediamtx@$ACTUAL_USER" 2>/dev/null || true
  docker rm -f owncloud 2>/dev/null || true
  docker volume rm owncloud_data 2>/dev/null || true
  apt_q purge takserver mumble-server || true
  apt_q autoremove || true
  rm -rf /opt/tak /etc/tak /var/tak /var/lib/mumble-server "$WORK_DIR" "$CERT_OUT"
  rm -f "$USER_HOME/mediamtx" "$USER_HOME/mediamtx.yml"
  log "Wipe complete."
fi

# ---- 2. System update + dependencies ----------------------------------------
step "Updating system and installing dependencies (this takes a while)"
log "Refreshing the package list (waits first if Ubuntu is updating in the background)..."
log "  Output is hidden. To watch:  tail -f ~/tak-setup-logs/apt_*.log"
apt_retry "$LOG_DIR/apt_update.log"  update
log "Package list refreshed. Installing system updates (usually 2-10 minutes)..."
# Finish any half-done package setup from before, then upgrade.
# An upgrade problem is a warning, not a stop - TAK only needs the installs below.
dpkg --configure -a >>"$LOG_DIR/apt_upgrade.log" 2>&1 || true
if ! apt_retry "$LOG_DIR/apt_upgrade.log" upgrade; then
  log "[!] System upgrade had problems (see $LOG_DIR/apt_upgrade.log). Continuing with the install."
fi

log "System updates done. Installing Docker, Mumble, ffmpeg and other tools..."
echo "mumble-server mumble-server/autostart boolean true" | debconf-set-selections
apt_retry "$LOG_DIR/apt_install.log" install git curl v4l-utils ffmpeg docker.io containerd \
  mumble-server openssh-server net-tools dialog dos2unix

systemctl enable --now docker mumble-server
# SSH: Ubuntu 24.04 runs it from ssh.socket. Never turn on ssh.service alongside it -
# the two fight over port 22 and break SSH package updates. Only start SSH if nothing serves it.
if systemctl list-unit-files ssh.socket >/dev/null 2>&1 && systemctl cat ssh.socket >/dev/null 2>&1; then
  if ! systemctl is-active --quiet ssh.socket && ! systemctl is-active --quiet ssh.service; then
    systemctl enable --now ssh.socket
  fi
elif ! systemctl is-active --quiet ssh.service; then
  systemctl enable --now ssh.service
fi
log "Dependencies installed. SSH, Docker, and Mumble are running."

# Keep SSH open if a firewall is (or later gets) turned on
if command -v ufw >/dev/null; then ufw allow OpenSSH >/dev/null || true; fi

# ---- 3. TAK Server ----------------------------------------------------------
step "TAK Server"
if tak_installed; then
  log "TAK Server is already installed - skipping. (Use --clean to reinstall from scratch.)"
else
  rm -rf "$WORK_DIR"
  if [ -d "$SRC_DIR/installTAK" ] && [ -f "$SRC_DIR/installTAK/installTAK" ]; then
    log "Using saved installTAK folder from $SRC_DIR"
    cp -r "$SRC_DIR/installTAK" "$WORK_DIR"
  elif [ -f "$SRC_DIR/installTAK" ]; then
    log "Using saved installTAK script from $SRC_DIR"
    mkdir -p "$WORK_DIR" && cp "$SRC_DIR/installTAK" "$WORK_DIR/"
  else
    log "No saved installTAK found - downloading from GitHub"
    ok=no
    for i in 1 2 3; do
      if git clone --depth 1 "$INSTALLTAK_REPO" "$WORK_DIR" >>"$LOG_DIR/tak_clone.log" 2>&1; then ok=yes; break; fi
      log "  Download attempt $i failed, retrying in 5s..."; rm -rf "$WORK_DIR"; sleep 5
    done
    [ "$ok" = yes ] || { log "[!] Couldn't download installTAK. Put a saved copy in $SRC_DIR and rerun."; exit 1; }
  fi

  for f in "${TAK_FILES[@]}"; do
    cp "$(find_src "$f")" "$WORK_DIR/$f"
  done
  dos2unix -q "$WORK_DIR/installTAK" 2>/dev/null || true
  chmod +x "$WORK_DIR/installTAK"

  RUN_PATH="$PATH"
  if [ "$MANUAL_TAK" = yes ]; then
    log "Launching the TAK setup menus. Answer them as usual."
  else
    # installTAK asks everything through 'dialog'. A stand-in placed first on PATH
    # answers each known menu; anything it doesn't recognize shows the real menu.
    SHIM_DIR="$WORK_DIR/.autoanswer"
    mkdir -p "$SHIM_DIR"
    cat > "$SHIM_DIR/dialog" <<'SHIM'
#!/usr/bin/env bash
title=""; widget=""; text=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    --title) title="${args[$((i + 1))]}" ;;
    --msgbox|--yesno|--inputbox|--form|--checklist|--infobox) widget="${args[$i]}"; text="${args[$((i + 1))]}" ;;
  esac
done
note() { echo "$(date '+%H:%M:%S') $*" >> "${TAKA_LOG:-/dev/null}"; }
yes_no() { if [ "$1" = yes ]; then exit 0; else exit 1; fi; }
case "$widget|$title" in
  "--msgbox|"*|"--infobox|"*)
    note "OK: $title"; exit 0 ;;
  "--form|TAK PKI Configuration")
    printf '%s
' "$TAKA_COUNTRY" "$TAKA_STATE" "$TAKA_CITY" "$TAKA_ORG" "$TAKA_OU" >&2
    note "Location: $TAKA_COUNTRY / $TAKA_STATE / $TAKA_CITY / $TAKA_ORG / $TAKA_OU"; exit 0 ;;
  "--yesno|TAK PKI Configuration")
    if [ -n "$TAKA_PASS" ]; then note "Cert password: custom"; exit 0; fi
    note "Cert password: default (atakatak)"; exit 1 ;;
  "--inputbox|TAK PKI Configuration")
    case "$text" in
      *"new certificate password"*) printf '%s' "$TAKA_PASS" >&2; exit 0 ;;
      *"Intermediate CA:"*) printf '%s' "$TAKA_INT" >&2; note "Intermediate CA: $TAKA_INT"; exit 0 ;;
      *"Root CA:"*) printf '%s' "$TAKA_ROOT" >&2; note "Root CA: $TAKA_ROOT"; exit 0 ;;
    esac ;;
  "--yesno|Certificate Auto-Enrollment Configuration")
    note "Auto-enrollment: $TAKA_ENROLL"; yes_no "$TAKA_ENROLL" ;;
  "--yesno|Federation Configuration")
    note "Federation v2: $TAKA_FED"; yes_no "$TAKA_FED" ;;
  "--checklist|TAK Server WebTAK Options")
    printf '%s' "$TAKA_WEB" >&2; note "WebTAK options: $TAKA_WEB"; exit 0 ;;
  "--checklist|TAK Server Connection Type")
    printf '%s' "$TAKA_CONN" >&2; note "Connection types: $TAKA_CONN"; exit 0 ;;
  "--yesno|Configuration Summary")
    note "Summary: Confirm"; exit 0 ;;
  "--inputbox|TAK Server Description")
    printf '%s' "$TAKA_DESC" >&2; note "Server description: $TAKA_DESC"; exit 0 ;;
  "--yesno|Configure FQDN")
    note "FQDN: No"; exit 1 ;;
esac
note "Not auto-answered - showing the menu: $title"
exec /usr/bin/dialog "$@"
SHIM
    chmod +x "$SHIM_DIR/dialog"
    export TAKA_LOG="$LOG_DIR/tak_answers.log" TAKA_COUNTRY="$TAK_COUNTRY" TAKA_STATE="$TAK_STATE" \
      TAKA_CITY="$TAK_CITY" TAKA_ORG="$TAK_ORG" TAKA_OU="$TAK_ORG_UNIT" TAKA_PASS="$TAK_CERT_PASSWORD" \
      TAKA_ROOT="$TAK_ROOT_CA" TAKA_INT="$TAK_INT_CA" TAKA_ENROLL="$TAK_AUTO_ENROLL" TAKA_FED="$TAK_FEDERATION" \
      TAKA_WEB="$TAK_WEB_OPTIONS" TAKA_CONN="$TAK_CONNECTIONS" TAKA_DESC="$TAK_DESCRIPTION"
    : > "$TAKA_LOG"
    RUN_PATH="$SHIM_DIR:$PATH"
    log "Answering the TAK setup menus automatically:"
    log "  Location: $TAK_COUNTRY / $TAK_STATE / $TAK_CITY   Org: $TAK_ORG / $TAK_ORG_UNIT"
    log "  Cert password: $([ -n "$TAK_CERT_PASSWORD" ] && echo custom || echo 'default (atakatak)')"
    log "  Root CA: $TAK_ROOT_CA   Intermediate CA: $TAK_INT_CA"
    log "  Auto-enrollment: $TAK_AUTO_ENROLL   Federation v2: $TAK_FEDERATION   FQDN: no"
    log "  WebTAK options: $TAK_WEB_OPTIONS   Description: $TAK_DESCRIPTION"
    log "  (To answer the menus yourself instead: sudo bash setup.sh --manual-tak)"
  fi
  log "NOTE: the 'enable takserver' step can sit for 5+ minutes. That's normal."
  sleep 3
  cd "$WORK_DIR"
  PATH="$RUN_PATH" script -q -e -c "./installTAK $TAK_DEB" /dev/null | tee "$LOG_DIR/tak_install.log"
  cd "$USER_HOME"

  if ! tak_installed; then
    log "[!] TAK Server did not install. Check $LOG_DIR/tak_install.log"
    exit 1
  fi
  log "TAK Server installed."
fi

# Collect client/admin certs into one folder so a single scp grabs them all
mkdir -p "$CERT_OUT"
for f in webadmin.p12 enrollmentDP.zip enrollmentDP-QUIC.zip caCert.p12 FedCA.pem; do
  for d in /root /opt/tak/certs/files "$USER_HOME"; do
    if [ -f "$d/$f" ]; then
      cp "$d/$f" "$CERT_OUT/$f"
      log "  Collected $f from $d"
      break
    fi
  done
done
chown -R "$ACTUAL_USER": "$CERT_OUT"
chmod 700 "$CERT_OUT"
chmod 600 "$CERT_OUT"/* 2>/dev/null || true

# ---- 4. ownCloud (Docker) ---------------------------------------------------
step "ownCloud"
if docker ps -a --format '{{.Names}}' | grep -qx owncloud; then
  docker start owncloud >/dev/null || true
  log "ownCloud container already exists - left as is."
else
  # Named volume keeps your files and settings if the container is ever recreated
  docker run -d --name owncloud --restart unless-stopped \
    -p 80:80 -v owncloud_data:/var/www/html "$OWNCLOUD_IMAGE" \
    2>&1 | tee "$LOG_DIR/owncloud_docker.log" >/dev/null
  log "ownCloud started on port 80."
fi

# ---- 5. MediaMTX ------------------------------------------------------------
step "MediaMTX $MTX_VERSION"
MTX_BIN="$USER_HOME/mediamtx"
MTX_YML="$USER_HOME/mediamtx.yml"
if [ -x "$MTX_BIN" ] && "$MTX_BIN" --version 2>/dev/null | grep -q "$MTX_VERSION"; then
  log "MediaMTX $MTX_VERSION already installed - skipping download."
else
  case "$ARCH" in
    aarch64|arm64) MTX_TAR="mediamtx_${MTX_VERSION}_linux_arm64.tar.gz" ;;
    x86_64|amd64)  MTX_TAR="mediamtx_${MTX_VERSION}_linux_amd64.tar.gz" ;;
    *) log "[!] Unsupported architecture for MediaMTX: $ARCH"; exit 1 ;;
  esac
  TMP="$(mktemp -d)"
  curl -fsSL --retry 3 --connect-timeout 15 -o "$TMP/$MTX_TAR" \
    "https://github.com/bluenviron/mediamtx/releases/download/${MTX_VERSION}/${MTX_TAR}"
  tar xzf "$TMP/$MTX_TAR" -C "$TMP"
  install -m 755 -o "$ACTUAL_USER" -g "$ACTUAL_USER" "$TMP/mediamtx" "$MTX_BIN"
  # Only use the stock config on first install - never overwrite your edits
  if [ ! -f "$MTX_YML" ]; then
    install -m 644 -o "$ACTUAL_USER" -g "$ACTUAL_USER" "$TMP/mediamtx.yml" "$MTX_YML"
  fi
  rm -rf "$TMP"
  log "MediaMTX binary installed."
fi

cat > /etc/systemd/system/mediamtx@.service <<'UNIT'
[Unit]
Description=MediaMTX (%i)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=%i
Group=%i
WorkingDirectory=/home/%i
ExecStart=/home/%i/mediamtx /home/%i/mediamtx.yml
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
systemctl disable --now mediamtx 2>/dev/null || true
systemctl daemon-reload
systemctl enable "mediamtx@$ACTUAL_USER" >/dev/null 2>&1
systemctl restart "mediamtx@$ACTUAL_USER"
log "MediaMTX running as mediamtx@$ACTUAL_USER"


# ---- 6. Mumble --------------------------------------------------------------
step "Mumble"
systemctl restart mumble-server
log "Mumble running (default port 64738)."

# ---- 7. Firewall: only open ports if UFW is already turned on ---------------
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  step "Firewall is on - opening Mumble and MediaMTX ports"
  ufw allow OpenSSH >/dev/null
  ufw allow 80/tcp >/dev/null
  ufw allow 64738 >/dev/null
  for p in 8554/tcp 8000/udp 8001/udp 1935/tcp 8888/tcp 8889/tcp 8189/udp 8890/udp; do
    ufw allow "$p" >/dev/null
  done
  log "Firewall rules added (SSH kept open)."
fi

# ---- 8. Radio USB netplan ---------------------------------------------------
step "Radio USB netplan"
NETPLAN_DEST="/etc/netplan/$NETPLAN_FILE"
if [ -f "$SRC_DIR/$NETPLAN_FILE" ]; then
  install -m 600 -o root -g root "$SRC_DIR/$NETPLAN_FILE" "$NETPLAN_DEST"
  log "Installed $NETPLAN_FILE from script folder."
elif [ ! -f "$NETPLAN_DEST" ]; then
  # Blank template - everything is commented out, so it changes nothing until you fill it in
  install -m 600 -o root -g root /dev/null "$NETPLAN_DEST"
  cat > "$NETPLAN_DEST" <<'NETPLAN'
network:
  version: 2
  # To use: uncomment "ethernets:" AND at least one adapter block below.
  #ethernets:
    #tw-usb:
      #match:
        #macaddress: YOUR-TW-USB-ADAPTER'S-LINK/ETHER-ADDRESS-HERE
      #set-name: tw-usb
      #dhcp4: false
      #addresses:
        #- 10.100.100.100/8
      #optional: true

    #silvus-usb:
      #match:
        #macaddress: YOUR-SILVUS-USB-ADAPTER'S-LINK/ETHER-ADDRESS-HERE
      #set-name: silvus-usb
      #dhcp4: false
      #addresses:
        #- 172.20.100.100/12
      #optional: true

#find the link/ether address by running "ip link show" before and after plugging in the adapters. Label the physical adapters so they don't get swapped.
NETPLAN
  log "Installed blank radio template at $NETPLAN_DEST (edit it to add your adapters)."
else
  log "$NETPLAN_FILE already present - left as is."
fi

# Make sure netplan accepts the file, so a reboot can't break networking
if ! netplan generate >>"$LOG_DIR/netplan.log" 2>&1; then
  mv "$NETPLAN_DEST" "$NETPLAN_DEST.disabled"
  log "[!] netplan rejected $NETPLAN_FILE - renamed it to $NETPLAN_FILE.disabled so reboots stay safe. See $LOG_DIR/netplan.log"
else
  log "Netplan check passed. Changes take effect after a reboot."
fi

# ---- 9. Health check + summary ----------------------------------------------
step "Health check"
IP="$(hostname -I | awk '{print $1}')"
status() { systemctl is-active --quiet "$1" && echo "OK" || echo "NOT RUNNING"; }
OC="$(docker inspect -f '{{.State.Running}}' owncloud 2>/dev/null || echo false)"
[ "$OC" = true ] && OC="OK" || OC="NOT RUNNING"

{
  echo
  echo "================ SETUP COMPLETE ================"
  echo "  TAK Server   $(status takserver)   https://$IP:8443   (can take 2-5 min to come up)"
  echo "  ownCloud     $OC   http://$IP"
  echo "  MediaMTX     $(status "mediamtx@$ACTUAL_USER")   rtsp://$IP:8554/<name>"
  echo "  Mumble       $(status mumble-server)   $IP port 64738"
  echo "  Docker       $(status docker)"
  echo
  echo "  Certs are in $CERT_OUT:"
  find "$CERT_OUT" -maxdepth 1 -type f -printf '      %f\n'
  echo
  echo "  Copy them to Windows (run in PowerShell on your PC):"
  echo "      scp $ACTUAL_USER@$IP:~/tak-certs/* \$HOME\\Desktop\\"
  echo
  echo "  Logs: $LOG_DIR"
  echo "  Reboot once to apply the radio netplan:  sudo reboot"
  echo "================================================"
} | tee -a "$LOG_DIR/setup.log"
chown -R "$ACTUAL_USER": "$LOG_DIR"
exit 0
