#!/usr/bin/env bash
# =============================================================================
# TAK Stack Setup v1.1 - Raspberry Pi 5 / Orange Pi 5+ on Ubuntu Server 24.04 LTS
# Services: TAK Server 5.4, ownCloud (Docker), MediaMTX, Mumble
#
# Put these in ONE folder with this script, copy the folder to the Pi, then run it:
#   takserver_5.4-RELEASE19_all.deb   deb_policy.pol   takserver-public-gpg.key
#   (optional) installTAK + LICENSE   - saved copy; if missing, it's downloaded from GitHub
#
# Usage:
#   sudo bash setup.sh               Normal install. Shows the TAK setup answers below and asks
#                                    "Enter to use these, or c to change them" before starting.
#   sudo bash setup.sh --defaults    Use the answers without asking (hands-off / scripted installs).
#   sudo bash setup.sh --manual-tak  Show installTAK's own menus and answer them yourself.
#   sudo bash setup.sh --clean       Wipes TAK/Mumble/ownCloud/MediaMTX first (asks you to type WIPE).
#
# Any TAK answer can also be set on the command line, e.g.:
#   sudo TAK_STATE=Virginia TAK_DESCRIPTION="Alpha TAK" bash setup.sh --defaults
# =============================================================================

# ---- Settings ---------------------------------------------------------------
TAK_DEB="takserver_5.4-RELEASE19_all.deb"
TAK_FILES=("$TAK_DEB" "deb_policy.pol" "takserver-public-gpg.key")
INSTALLTAK_REPO="https://github.com/myTeckNet/installTAK.git"
MTX_VERSION="v1.12.3"
OWNCLOUD_IMAGE="owncloud:latest"

# ---- TAK setup answers (defaults; change here, at the prompt, or on the command line)
TAK_COUNTRY="${TAK_COUNTRY:-XX}"                      # 2-letter code; XX = not specified
TAK_STATE="${TAK_STATE:-None}"                      # never blank (installTAK geolocates) and no "/" - use None
TAK_CITY="${TAK_CITY:-None}"                          # never blank and no "/" - use None
TAK_ORG="${TAK_ORG:-TAK}"
TAK_ORG_UNIT="${TAK_ORG_UNIT:-TAK}"
TAK_CERT_PASSWORD="${TAK_CERT_PASSWORD:-}"            # blank = TAK default (atakatak). Letters/numbers only.
TAK_ROOT_CA="${TAK_ROOT_CA:-TAK Server Root CA}"      # installTAK turns this into TAK-SERVER-ROOT-CA
TAK_INT_CA="${TAK_INT_CA:-TAK Server CA}"             # installTAK turns this into TAK-SERVER-CA
TAK_AUTO_ENROLL="${TAK_AUTO_ENROLL:-yes}"
TAK_FEDERATION="${TAK_FEDERATION:-yes}"
TAK_WEB_OPTIONS="${TAK_WEB_OPTIONS-enableAdminUI enableWebtak}"  # WebAdmin UI + WebTAK; NonAdminUI off
TAK_CONNECTIONS="${TAK_CONNECTIONS:-SSL QUIC}"        # only asked on older TAK versions; 5.4 does both
TAK_DESCRIPTION="${TAK_DESCRIPTION:-TAK Server}"      # name clients see for this server
TAK_FIREWALL="${TAK_FIREWALL:-yes}"                   # yes = turn on the UFW firewall at the very end of setup,
                                                      # with SSH, TAK, ownCloud, Mumble and MediaMTX allowed. no = leave it off
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
USE_DEFAULTS=no
for arg in "$@"; do
  case "$arg" in
    --clean) CLEAN=yes ;;
    --manual-tak) MANUAL_TAK=yes ;;
    --defaults) USE_DEFAULTS=yes ;;
    *) echo "[!] Unknown option: $arg  (use --clean, --defaults and/or --manual-tak)"; exit 1 ;;
  esac
done

mkdir -p "$LOG_DIR"
chown "$ACTUAL_USER": "$LOG_DIR"
log()  { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_DIR/setup.log"; }
step() { echo; log "=== $* ==="; }
# True if UFW is active. Reads the whole status first, so an early-exiting grep can't trip pipefail.
ufw_on() { [[ "$(ufw status 2>/dev/null || true)" == *"Status: active"* ]]; }
apt_q() {
  DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confold \
    -o Acquire::Retries=5 -o DPkg::Lock::Timeout=900 "$@"
}
# Retries an apt step up to 3 times, refreshing package lists between tries,
# so a short Wi-Fi or DNS dropout doesn't end the whole install
# Waits until no other package tool is running (Ubuntu's first-boot setup and its daily
# auto-updates run apt in the background). Gives up after 30 minutes.
apt_busy() {
  pgrep -x apt-get >/dev/null 2>&1 || pgrep -x apt >/dev/null 2>&1 || pgrep -x dpkg >/dev/null 2>&1 ||
    pgrep -f "^/usr/bin/python3 /usr/bin/unattended-upgrade" >/dev/null 2>&1 || pgrep -f "^/usr/bin/unattended-upgrade" >/dev/null 2>&1 || pgrep -f "apt.systemd.daily" >/dev/null 2>&1
}
wait_for_apt() {
  if command -v cloud-init >/dev/null 2>&1 && ! cloud-init status 2>/dev/null | grep -qE "done|disabled|error"; then
    log "  Ubuntu's first-boot setup is still running - waiting for it to finish..."
    timeout 1800 cloud-init status --wait >/dev/null 2>&1 || true
  fi
  local waited=0
  while apt_busy; do
    if [ $((waited % 60)) -eq 0 ]; then
      log "  Ubuntu is updating in the background - waiting for it to finish (${waited}s so far)..."
    fi
    sleep 10; waited=$((waited + 10))
    if [ "$waited" -ge 1800 ]; then
      log "[!] Background updates still running after 30 minutes - trying anyway."
      break
    fi
  done
  return 0
}
apt_retry() {  # logfile apt-args...
  local logf="$1"; shift
  local i
  for i in 1 2 3; do
    wait_for_apt
    if apt_q "$@" >>"$logf" 2>&1; then return 0; fi
    log "  apt attempt $i failed (see $logf). Waiting 20s and retrying..."
    sleep 20
    apt_q update >>"$logf" 2>&1 || true
  done
  log "[!] apt kept failing. Last lines of $logf:"
  tail -n 6 "$logf" | sed 's/^/      /' | tee -a "$LOG_DIR/setup.log"
  return 1
}
tak_installed() { dpkg -s takserver >/dev/null 2>&1 || [ -d /opt/tak ]; }

# Waits (up to ~5 min) for a host to resolve, so a short internet dropout doesn't end the install
wait_for_internet() {  # host
  local i
  for i in $(seq 1 30); do
    getent hosts "$1" >/dev/null 2>&1 && return 0
    [ "$i" = 1 ] && log "  Can't reach $1 (internet dropped?) - waiting up to 5 minutes for it to come back..."
    sleep 10
  done
  return 1
}
# Downloads a file, riding out dropouts: waits for internet, then retries up to 5 times
fetch() {  # url outfile
  local host i
  host="$(echo "$1" | sed -E 's#^[a-z]+://([^/]+).*#\1#')"
  for i in 1 2 3 4 5; do
    wait_for_internet "$host" || true
    if curl -fsSL --retry 3 --retry-all-errors --connect-timeout 15 -o "$2" "$1" 2>>"$LOG_DIR/downloads.log"; then
      return 0
    fi
    log "  Download attempt $i failed - retrying in 15s..."
    sleep 15
  done
  return 1
}

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

# ---- TAK setup answers: confirm or change them now, before the long install ----
show_tak_answers() {
  echo
  echo "  TAK Server setup answers:"
  echo "    Location:          $TAK_COUNTRY / $TAK_STATE / $TAK_CITY"
  echo "    Organization:      $TAK_ORG / $TAK_ORG_UNIT"
  echo "    Cert password:     $([ -n "$TAK_CERT_PASSWORD" ] && echo 'custom (hidden)' || echo 'default (atakatak)')"
  echo "    Root CA:           $TAK_ROOT_CA"
  echo "    Intermediate CA:   $TAK_INT_CA"
  echo "    Auto-enrollment:   $TAK_AUTO_ENROLL"
  echo "    Federation v2:     $TAK_FEDERATION"
  echo "    Web options:       ${TAK_WEB_OPTIONS:-none}"
  echo "    Server name:       $TAK_DESCRIPTION"
  echo "    FQDN:              no"
  echo "    Firewall (UFW):    $TAK_FIREWALL"
}
ask() {  # variable prompt
  local cur="${!1}" v
  read -r -p "  $2 [$cur]: " v || true
  if [ -n "$v" ]; then printf -v "$1" '%s' "$v"; fi
  return 0
}
ask_word() {  # variable prompt - no blanks (installTAK would geolocate) and no / & " ' (break installTAK)
  while true; do
    ask "$1" "$2"
    local v="${!1}"
    if [ -z "$v" ]; then echo "  Can't be blank (installTAK would fill in the Pi's real location). Try None."; printf -v "$1" '%s' "None"; continue; fi
    if [[ "$v" == *[/\&\"\']* ]]; then echo "  Avoid / & and quotes - they break installTAK. Try None instead of N/A."; continue; fi
    return 0
  done
}
ask_yn() {  # variable prompt
  local cur="${!1}" v
  while true; do
    read -r -p "  $2 (yes/no) [$cur]: " v || true
    v="$(echo "${v:-$cur}" | tr 'A-Z' 'a-z')"
    case "$v" in y|yes) printf -v "$1" yes; return ;; n|no) printf -v "$1" no; return ;; esac
    echo "  Please answer yes or no."
  done
}
change_tak_answers() {
  echo
  echo "  Press Enter to keep the value in [brackets]."
  while true; do
    ask TAK_COUNTRY "Country (2 letters; XX = not specified)"
    TAK_COUNTRY="$(echo "$TAK_COUNTRY" | tr 'a-z' 'A-Z')"
    if [[ "$TAK_COUNTRY" =~ ^[A-Z]{2}$ ]]; then break; fi
    echo "  Use a 2-letter code like US."
  done
  ask_word TAK_STATE "State (or None)"
  ask_word TAK_CITY "City (or None)"
  ask_word TAK_ORG "Organization"
  ask_word TAK_ORG_UNIT "Organizational unit"
  while true; do
    local p1 p2
    read -r -s -p "  Cert password (letters/numbers; Enter = keep $([ -n "$TAK_CERT_PASSWORD" ] && echo 'current' || echo 'atakatak')): " p1 || true; echo
    if [ -z "$p1" ]; then break; fi
    if ! [[ "$p1" =~ ^[A-Za-z0-9]{6,}$ ]]; then echo "  Use at least 6 letters/numbers, no symbols."; continue; fi
    read -r -s -p "  Type it again: " p2 || true; echo
    if [ "$p1" = "$p2" ]; then TAK_CERT_PASSWORD="$p1"; break; fi
    echo "  They didn't match - try again."
  done
  while true; do
    ask TAK_ROOT_CA "Root CA name"
    ask TAK_INT_CA "Intermediate CA name"
    a="$(echo "${TAK_ROOT_CA// /-}" | tr 'a-z' 'A-Z')"; b="$(echo "${TAK_INT_CA// /-}" | tr 'a-z' 'A-Z')"
    if [ "$a" != "$b" ]; then break; fi
    echo "  The two CA names must be different."
  done
  ask_yn TAK_AUTO_ENROLL "Certificate auto-enrollment"
  ask_yn TAK_FEDERATION "Federation v2"
  local wa=no ww=no wn=no opts=""
  if [[ " $TAK_WEB_OPTIONS " == *" enableAdminUI "* ]]; then wa=yes; fi
  if [[ " $TAK_WEB_OPTIONS " == *" enableWebtak "* ]]; then ww=yes; fi
  if [[ " $TAK_WEB_OPTIONS " == *" enableNonAdminUI "* ]]; then wn=yes; fi
  ask_yn wa "Web: WebAdmin UI"
  ask_yn ww "Web: WebTAK"
  ask_yn wn "Web: NonAdmin UI"
  if [ "$wa" = yes ]; then opts="enableAdminUI"; fi
  if [ "$ww" = yes ]; then opts="${opts:+$opts }enableWebtak"; fi
  if [ "$wn" = yes ]; then opts="${opts:+$opts }enableNonAdminUI"; fi
  TAK_WEB_OPTIONS="$opts"
  ask TAK_DESCRIPTION "Server name clients see"
  ask_yn TAK_FIREWALL "Turn on the UFW firewall at the end (SSH, TAK, ownCloud, Mumble, MediaMTX stay open)"
}
if [ "$MANUAL_TAK" = no ] && { ! tak_installed || [ "$CLEAN" = yes ]; }; then
  if [ "$USE_DEFAULTS" = no ] && [ -t 0 ]; then
    while true; do
      show_tak_answers
      echo
      read -r -p "  Press Enter to use these, or type c to change them: " c || true
      case "$c" in
        c|C) change_tak_answers ;;
        *) break ;;
      esac
    done
  else
    show_tak_answers
  fi
fi

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
# ---- PostgreSQL repository key ----
# installTAK adds the PostgreSQL apt repo and downloads its signing key, but doesn't check the
# download. If the internet blips at that moment, the repo is added WITHOUT its key, TAK can't
# install, and every later "apt update" fails with "NO_PUBKEY 7FCC7D46ACCC4CF8".
PGDG_KEY="/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc"
PGDG_LIST="/etc/apt/sources.list.d/pgdg.list"
pgdg_key_ok() {
  [ -s "$PGDG_KEY" ] && gpg --show-keys --with-colons "$PGDG_KEY" 2>/dev/null | grep -q "ACCC4CF8"
}
get_pgdg_key() {
  local tmp; tmp="$(mktemp)"
  if fetch "https://www.postgresql.org/media/keys/ACCC4CF8.asc" "$tmp"; then
    install -d /usr/share/postgresql-common/pgdg
    install -m 644 "$tmp" "$PGDG_KEY"
  fi
  rm -f "$tmp"
  pgdg_key_ok
}
# Repair a PostgreSQL repo that was left behind without its key by an earlier run
if [ -f "$PGDG_LIST" ] && ! pgdg_key_ok; then
  log "Found the PostgreSQL repo without its signing key (from an earlier interrupted run) - fixing..."
  if get_pgdg_key; then
    log "  PostgreSQL key downloaded. Fixed."
  else
    mv "$PGDG_LIST" "$PGDG_LIST.disabled"
    log "  Couldn't download the key - disabled the PostgreSQL repo for now (TAK's install re-adds it)."
  fi
fi

log "Refreshing the package list (waits first if Ubuntu is updating in the background)..."
log "  Output is hidden. To watch:  tail -f ~/tak-setup-logs/apt_*.log"
apt_retry "$LOG_DIR/apt_update.log"  update
log "Package list refreshed. Installing system updates (usually 2-10 minutes)..."
# SSH can end up turned on two ways (ssh.socket AND ssh.service) - Raspberry Pi Imager's
# first boot can do this. They fight over port 22 and every SSH package update then fails.
# Fix it without stopping whatever is serving SSH right now, so no session drops.
fix_ssh_double_enable() {
  systemctl cat ssh.socket >/dev/null 2>&1 || return 0
  local sock svc
  sock="$(systemctl is-enabled ssh.socket 2>/dev/null || true)"
  svc="$(systemctl is-enabled ssh.service 2>/dev/null || true)"
  [ "$sock" = enabled ] && [ "$svc" = enabled ] || return 0
  log "SSH is enabled twice (ssh.socket + ssh.service) - switching to ssh.service only."
  log "  Your current SSH session stays connected; new logins pause for a second."
  mkdir -p /run/sshd && chmod 755 /run/sshd
  systemctl disable --now ssh.socket >/dev/null 2>&1 || true
  systemctl enable ssh.service >/dev/null 2>&1 || true
  # A listener systemd lost track of keeps port 22 and blocks the restart. Only the
  # listener is stopped - logged-in sessions are separate processes and stay up.
  pkill -f "sshd: /usr/sbin/sshd -D \[listener\]" 2>/dev/null || true
  sleep 1
  systemctl reset-failed ssh.service >/dev/null 2>&1 || true
  mkdir -p /run/sshd && chmod 755 /run/sshd
  if systemctl restart ssh.service && systemctl is-active --quiet ssh.service; then
    log "  SSH is running as ssh.service. Fixed."
  else
    log "[!] ssh.service didn't start - putting ssh.socket back so you can still log in."
    systemctl enable --now ssh.socket >/dev/null 2>&1 || true
  fi
  DEBIAN_FRONTEND=noninteractive dpkg --force-confold --force-confdef --configure -a </dev/null >>"$LOG_DIR/apt_upgrade.log" 2>&1 || true
}
fix_ssh_double_enable

# Finish any half-done package setup from before, then upgrade.
# An upgrade problem is a warning, not a stop - TAK only needs the installs below.
DEBIAN_FRONTEND=noninteractive dpkg --force-confold --force-confdef --configure -a </dev/null >>"$LOG_DIR/apt_upgrade.log" 2>&1 || true
if ! apt_retry "$LOG_DIR/apt_upgrade.log" upgrade; then
  log "[!] System upgrade had problems (see $LOG_DIR/apt_upgrade.log). Continuing with the install."
fi

log "System updates done. Installing Docker, Mumble, ffmpeg and other tools..."
echo "mumble-server mumble-server/autostart boolean true" | debconf-set-selections
apt_retry "$LOG_DIR/apt_install.log" install git curl v4l-utils ffmpeg docker.io containerd \
  mumble-server openssh-server net-tools dialog dos2unix ufw

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
# (Firewall rules, including SSH, are applied at the end - see section 7)

# ---- 3. TAK Server ----------------------------------------------------------
step "TAK Server"
if tak_installed && [ ! -f /opt/tak/certs/files/webadmin.p12 ]; then
  log "[!] TAK Server looks HALF-installed (package is there, but no admin certificate)."
  log "    This happens if the connection dropped while the TAK step was running."
  log "    Fix: sudo bash setup.sh --clean   (wipes the partial TAK install and redoes it)"
  exit 1
elif tak_installed; then
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

  # Put the PostgreSQL key in place first, with retries. If installTAK's own download of it
  # fails later, curl leaves this good copy alone, so TAK can still install.
  if ! pgdg_key_ok; then
    log "Downloading the PostgreSQL signing key TAK needs..."
    if ! get_pgdg_key; then
      log "[!] Couldn't download the PostgreSQL key (internet down?). TAK can't install without it."
      log "    Nothing was changed. Run setup.sh again once the Pi has internet."
      exit 1
    fi
  fi
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
    # installTAK runs "ufw enable" mid-install, which silently waits for a y/n answer.
    # Always skip it here: setup.sh turns the firewall on ONCE, at the very end, after every
    # service's ports are on the allow list - so nothing gets cut off part-way through.
    cat > "$SHIM_DIR/ufw" <<'SHIM'
#!/usr/bin/env bash
if [ "${1:-}" = enable ]; then
  echo "$(date '+%H:%M:%S') Firewall: installTAK's enable skipped (setup.sh turns it on at the end)" >> "${TAKA_LOG:-/dev/null}"
  exit 0
fi
exec /usr/sbin/ufw "$@"
SHIM
    chmod +x "$SHIM_DIR/ufw"
    export TAKA_LOG="$LOG_DIR/tak_answers.log" TAKA_COUNTRY="$TAK_COUNTRY" TAKA_STATE="$TAK_STATE" \
      TAKA_CITY="$TAK_CITY" TAKA_ORG="$TAK_ORG" TAKA_OU="$TAK_ORG_UNIT" TAKA_PASS="$TAK_CERT_PASSWORD" \
      TAKA_ROOT="$TAK_ROOT_CA" TAKA_INT="$TAK_INT_CA" TAKA_ENROLL="$TAK_AUTO_ENROLL" TAKA_FED="$TAK_FEDERATION" \
      TAKA_WEB="$TAK_WEB_OPTIONS" TAKA_CONN="$TAK_CONNECTIONS" TAKA_DESC="$TAK_DESCRIPTION" TAKA_FIREWALL="$TAK_FIREWALL"
    : > "$TAKA_LOG"
    RUN_PATH="$SHIM_DIR:$PATH"
    log "Answering the TAK setup menus automatically:"
    log "  Location: $TAK_COUNTRY / $TAK_STATE / $TAK_CITY   Org: $TAK_ORG / $TAK_ORG_UNIT"
    log "  Cert password: $([ -n "$TAK_CERT_PASSWORD" ] && echo custom || echo 'default (atakatak)')"
    log "  Root CA: $TAK_ROOT_CA   Intermediate CA: $TAK_INT_CA"
    log "  Auto-enrollment: $TAK_AUTO_ENROLL   Federation v2: $TAK_FEDERATION   FQDN: no"
    log "  WebTAK options: $TAK_WEB_OPTIONS   Description: $TAK_DESCRIPTION   Firewall: $TAK_FIREWALL"
    log "  (To answer the menus yourself instead: sudo bash setup.sh --manual-tak)"
  fi
  log "NOTE: the 'enable takserver' step can sit for 5+ minutes. That's normal."
  sleep 3
  cd "$WORK_DIR"
  PATH="$RUN_PATH" script -q -e -c "./installTAK $TAK_DEB" /dev/null | tee "$LOG_DIR/tak_install.log"
  cd "$USER_HOME"

  if ! tak_installed; then
    log "[!] TAK Server did not install. Last lines of $LOG_DIR/tak_install.log:"
    tail -n 8 "$LOG_DIR/tak_install.log" | sed 's/\x1b\[[0-9;]*m//g; s/^/      /' | tee -a "$LOG_DIR/setup.log"
    log "    If it mentions 'Could not resolve' or 'not installable', the internet dropped - just rerun setup.sh."
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
  log "Downloading the ownCloud image (a few hundred MB - can take 5-15 minutes)..."
  pulled=no
  for i in 1 2 3 4 5; do
    wait_for_internet registry-1.docker.io || true
    if docker pull "$OWNCLOUD_IMAGE" >>"$LOG_DIR/owncloud_docker.log" 2>&1; then pulled=yes; break; fi
    log "  ownCloud download attempt $i failed - retrying in 15s..."
    sleep 15
  done
  if [ "$pulled" = yes ]; then
    # Named volume keeps your files and settings if the container is ever recreated
    docker run -d --name owncloud --restart unless-stopped \
      -p 80:80 -v owncloud_data:/var/www/html "$OWNCLOUD_IMAGE" >>"$LOG_DIR/owncloud_docker.log" 2>&1
    log "ownCloud started on port 80."
  else
    log "[!] Couldn't download ownCloud - skipping it for now. Rerun setup.sh later to add it."
  fi
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
  got=no
  if [ -n "$(find_src "$MTX_TAR")" ]; then
    cp "$(find_src "$MTX_TAR")" "$TMP/$MTX_TAR" && got=yes
    log "Using saved $MTX_TAR from the script folder."
  elif fetch "https://github.com/bluenviron/mediamtx/releases/download/${MTX_VERSION}/${MTX_TAR}" "$TMP/$MTX_TAR"; then
    got=yes
  fi
  if [ "$got" = yes ] && tar xzf "$TMP/$MTX_TAR" -C "$TMP"; then
    install -m 755 -o "$ACTUAL_USER" -g "$ACTUAL_USER" "$TMP/mediamtx" "$MTX_BIN"
    # Only use the stock config on first install - never overwrite your edits
    if [ ! -f "$MTX_YML" ]; then
      install -m 644 -o "$ACTUAL_USER" -g "$ACTUAL_USER" "$TMP/mediamtx.yml" "$MTX_YML"
    fi
    log "MediaMTX binary installed."
  else
    log "[!] Couldn't download MediaMTX - skipping it for now. Rerun setup.sh later, or put"
    log "    $MTX_TAR in the script folder for an offline install."
  fi
  rm -rf "$TMP"
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
if [ -x "$MTX_BIN" ]; then
  systemctl enable "mediamtx@$ACTUAL_USER" >/dev/null 2>&1
  systemctl restart "mediamtx@$ACTUAL_USER"
  log "MediaMTX running as mediamtx@$ACTUAL_USER"
fi


# ---- 6. Mumble --------------------------------------------------------------
step "Mumble"
systemctl restart mumble-server
log "Mumble running (default port 64738)."

# ---- 7. Firewall ------------------------------------------------------------
# One allow list for everything this Pi serves. Applied whenever UFW is used, then UFW is
# turned on last (if TAK_FIREWALL=yes) so no service is ever cut off mid-setup.
FW_RULES=(
  "8089/tcp|TAK clients (SSL)"
  "8090/udp|TAK clients (QUIC)"
  "8443/tcp|TAK admin page + API"
  "8444/tcp|TAK federation API"
  "8446/tcp|TAK enrollment + WebTAK"
  "9001/tcp|TAK federation v2"
  "80/tcp|ownCloud"
  "64738/tcp|Mumble"
  "64738/udp|Mumble voice"
  "8554/tcp|MediaMTX RTSP"
  "8000/udp|MediaMTX RTP"
  "8001/udp|MediaMTX RTCP"
  "1935/tcp|MediaMTX RTMP"
  "8888/tcp|MediaMTX HLS"
  "8889/tcp|MediaMTX WebRTC"
  "8189/udp|MediaMTX WebRTC media"
  "8890/udp|MediaMTX SRT"
)
apply_firewall_rules() {
  local r sshport ifc spec
  # 1. SSH first, on the port sshd actually listens on, so the session can't be locked out
  mkdir -p /run/sshd && chmod 755 /run/sshd
  sshport="$( { sshd -T 2>/dev/null || true; } | awk '/^port /{print $2}' | head -n1 || true)"
  [[ "$sshport" =~ ^[0-9]+$ ]] || sshport=22
  ufw allow "$sshport/tcp" comment "SSH" >/dev/null
  [ "$sshport" = 22 ] || ufw allow 22/tcp comment "SSH (default port)" >/dev/null
  # 2. Services (port/protocol rules; UFW shows each once for IPv4 and once more as "(v6)")
  for r in "${FW_RULES[@]}"; do
    ufw allow "${r%%|*}" comment "${r#*|}" >/dev/null
  done
  # 3. VPN links set up before the firewall (radio-setup.sh adds these itself when UFW is already on)
  for ifc in /sys/class/net/tailscale0 /sys/class/net/zt*; do
    [ -e "$ifc" ] && ufw allow in on "$(basename "$ifc")" comment "VPN" >/dev/null
  done
  # 4. Remove installTAK's unlabeled duplicates. These have NO protocol (e.g. "8089"), so they are
  #    separate UFW rules from the labeled "8089/tcp" ones above and deleting them can't touch those.
  for spec in OpenSSH 8089 8443 8446 9001; do
    ufw --force delete allow "$spec" >/dev/null 2>&1 || true
  done
  # 5. Safety net: if SSH somehow isn't allowed now, put it back before anything else happens
  if ! { ufw status 2>/dev/null || true; } | grep -cE "^(${sshport}|22)/tcp[[:space:]]+ALLOW" >/dev/null; then
    ufw allow "$sshport/tcp" comment "SSH" >/dev/null
  fi
  return 0
}
if command -v ufw >/dev/null; then
  if [ "$TAK_FIREWALL" = yes ]; then
    step "Firewall"
    apply_firewall_rules
    ufw logging low >/dev/null        # blocked attempts are logged - see the summary for how to check
    if [ "$(ufw show added 2>/dev/null | grep -c 'ufw allow')" -lt 10 ]; then
      log "[!] Firewall rules didn't all go in - leaving the firewall OFF so nothing gets blocked."
      log "    Check: sudo ufw show added"
    else
      ufw --force enable >/dev/null
    fi
    if ufw_on; then
      log "Firewall is ON: $( { ufw status 2>/dev/null || true; } | grep -v '(v6)' | grep -c ALLOW || true) allow rules (SSH, TAK, ownCloud, Mumble, MediaMTX)."
    else
      log "[!] The firewall didn't turn on - check: sudo ufw status verbose"
    fi
  elif ufw_on; then
    step "Firewall"
    apply_firewall_rules
    log "Firewall was already on - made sure SSH, TAK, ownCloud, Mumble and MediaMTX are allowed."
  else
    log "Firewall left off (TAK_FIREWALL=no)."
  fi
fi

# ---- 8. Health check + summary ----------------------------------------------
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
  if ufw_on; then
    echo "  Firewall     ON    see blocked attempts:  sudo journalctl -k | grep 'UFW BLOCK' | tail"
  else
    echo "  Firewall     off"
  fi
  echo
  echo "  Certs are in $CERT_OUT:"
  find "$CERT_OUT" -maxdepth 1 -type f -printf '      %f\n'
  echo
  echo "  Copy them to Windows (run in PowerShell on your PC):"
  echo "      scp $ACTUAL_USER@$IP:~/tak-certs/* \$HOME\\Desktop\\"
  echo
  echo "  Logs: $LOG_DIR"
  echo "================================================"
} | tee -a "$LOG_DIR/setup.log"
chown -R "$ACTUAL_USER": "$LOG_DIR"
exit 0
