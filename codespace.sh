#!/data/data/com.termux/files/usr/bin/bash
set -uo pipefail

unset LD_PRELOAD

# ------------------------------------------------------------------ #
# Paths & constants
# ------------------------------------------------------------------ #
BASE_DIR="$HOME/.termux-codespace"
CODESPACES_DIR="$BASE_DIR/codespaces"
META_DIR="$BASE_DIR/meta"
STATE_FILE="$BASE_DIR/.setup_done"

PROOT_DISTRO_DIR="$PREFIX/var/lib/proot-distro"
BASE_ROOTFS_V5="$PROOT_DISTRO_DIR/containers/ubuntu/rootfs"
BASE_ROOTFS_V4="$PROOT_DISTRO_DIR/installed-rootfs/ubuntu"

PROOT_BIN="$PREFIX/bin/proot"

detect_base_rootfs() {
  if [[ -d "$BASE_ROOTFS_V5" ]]; then
    echo "$BASE_ROOTFS_V5"
  elif [[ -d "$BASE_ROOTFS_V4" ]]; then
    echo "$BASE_ROOTFS_V4"
  else
    echo ""
  fi
}

BASE_ROOTFS="$(detect_base_rootfs)"

PORT_RANGE_START=2000
PORT_RANGE_END=3000

# Range used for the per-codespace network-logging/filtering proxy
PROXY_PORT_RANGE_START=8000
PROXY_PORT_RANGE_END=9000

NETPROXY_SCRIPT="$BASE_DIR/proxy_server.py"

# ------------------------------------------------------------------ #
# Storage quotas
#
# Two enforcement modes, chosen per codespace:
#
#   soft - always available, no root needed. A watchdog stops the
#          codespace once its rootfs grows past the limit. It's
#          event-driven when `inotify-tools` is installed (reacts to
#          actual writes, typically within ~1-2s) and falls back to
#          fast interval polling otherwise. Either way it's a
#          best-effort check after the fact, not a kernel-level block
#          - a single very large write can still land before the
#          watchdog reacts and stops the process.
#
#   hard - a real filesystem-level cap: the codespace's rootfs lives
#          on a fixed-size ext4 image, loop-mounted at its directory.
#          Once that filesystem is full, writes get ENOSPC directly -
#          nothing can exceed it. This needs root (loop-mount requires
#          CAP_SYS_ADMIN) plus `mount`/`mkfs.ext4`. FUSE-based
#          alternatives don't help here either: Android's SELinux
#          policy blocks arbitrary FUSE mounts from third-party apps
#          (including Termux) without root, so there's no rootless way
#          to get a kernel-enforced cap. Support is detected once (a
#          real test mount, not just an ID check) and cached; if
#          unavailable, quota management offers only "soft" and says
#          why, rather than pretending it's a hard cap.
#
# 0 (or unset) quota means "no limit" for a given codespace either way.
# ------------------------------------------------------------------ #
DEFAULT_QUOTA_MB=0            # 0 = unlimited, used for newly created codespaces
QUOTA_CHECK_INTERVAL=30       # fallback poll interval (s) when inotify-tools isn't installed
QUOTA_CHECK_INTERVAL_FAST=5   # fallback poll interval (s) - unused when inotify is available
QUOTA_DEBOUNCE_SECONDS=1      # min gap (s) between size checks when reacting to inotify events

QUOTA_IMAGES_DIR="$BASE_DIR/quota_images"
HARD_QUOTA_CAPABILITY_FILE="$BASE_DIR/.hard_quota_supported"
mkdir -p "$QUOTA_IMAGES_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

mkdir -p "$CODESPACES_DIR" "$META_DIR"
mkdir -p "$PREFIX/tmp"

PROOT_BIND_EXCLUDES=(
  ".l2s"           
  "data"           
  "dev"            
  "proc"           
  "sys"            
  "storage"        
  "sdcard"         
  "system"         
  "system_ext"     
  "apex"           
  "vendor"         
  "product"        
  "odm"            
  "linkerconfig"   
)

# ------------------------------------------------------------------ #
# UI helpers
# ------------------------------------------------------------------ #
banner() {
  echo -e "${CYAN}${BOLD}"
  cat << 'EOF'
 _____                   
|_   _|__ _ __ _ __ ___  _   ___  __
  | |/ _ \ '__| '_ ` _ \| | | \ \/ /
  | |  __/ |  | | | | | | |_| |>  < 
  |_|\___|_|  |_| |_| |_|\__,_/_/\_\
 ____          _      ____                       
/ ___|___   __| | ___/ ___| _ __   __ _  ___ ___
| |   / _ \ / _` |/ _ \___ \| '_ \ / _` |/ __/ _ \
| |__| (_) | (_| |  __/___) | |_) | (_| | (_|  __/
 \____\___/ \__,_|\___|____/| .__/ \__,_|\___\___|
                             |_|
EOF
  echo -e "${RESET}"
  echo -e "${YELLOW}    Multiple isolated Ubuntu codespaces for Termux, powered by proot${RESET}"
  echo -e "${BOLD}    Made By Aryan Giri | giriaryan694-a11y${RESET}"
  echo
}

press_any_key() {
  echo
  read -n1 -rsp "Press any key to continue..."
  echo
}

# ------------------------------------------------------------------ #
# Arrow-key menu
# ------------------------------------------------------------------ #
read_key() {
  local key rest
  IFS= read -rsn1 key
  if [[ $key == $'\x1b' ]]; then
    IFS= read -rsn2 -t 0.05 rest
    key+="$rest"
  fi
  printf '%s' "$key"
}

ARROW_MENU_RESULT=""

arrow_menu() {
  local title="$1"; shift
  local options=("$@")
  local count=${#options[@]}
  local sel=0
  local key

  while true; do
    clear
    banner
    echo -e "${BOLD}${title}${RESET}"
    echo

    for i in "${!options[@]}"; do
      if [[ $i -eq $sel ]]; then
        echo -e "  ${CYAN}> ${options[$i]}${RESET}"
      else
        echo "    ${options[$i]}"
      fi
    done

    echo
    echo -e "${YELLOW}UP/DOWN move   Enter select   c cli   n netlog   b domains   R restrict${RESET}"
    echo -e "${YELLOW}p proxy on/off   s storage quota   d delete   t terminate   e export   i import   q back${RESET}"

    key=$(read_key)
    case "$key" in
      $'\x1b[A') sel=$(( (sel - 1 + count) % count )) ;;
      $'\x1b[B') sel=$(( (sel + 1) % count )) ;;
      "")        ARROW_MENU_RESULT="select:$sel"; return 0 ;;
      c|C)       ARROW_MENU_RESULT="cli:$sel"; return 0 ;;
      n|N)       ARROW_MENU_RESULT="netlog:$sel"; return 0 ;;
      b|B)       ARROW_MENU_RESULT="domains:$sel"; return 0 ;;
      r|R)       ARROW_MENU_RESULT="restrict:$sel"; return 0 ;;
      p|P)       ARROW_MENU_RESULT="toggleproxy:$sel"; return 0 ;;
      s|S)       ARROW_MENU_RESULT="quota:$sel"; return 0 ;;
      d|D)       ARROW_MENU_RESULT="delete:$sel"; return 0 ;;
      t|T)       ARROW_MENU_RESULT="terminate:$sel"; return 0 ;;
      e|E)       ARROW_MENU_RESULT="export:$sel"; return 0 ;;
      i|I)       ARROW_MENU_RESULT="import:$sel"; return 0 ;;
      q|Q)       ARROW_MENU_RESULT="back:-1"; return 0 ;;
    esac
  done
}

# ------------------------------------------------------------------ #
# Ports
# ------------------------------------------------------------------ #
is_port_free() {
  local port="$1"
  if grep -qs "^${port}$" "$META_DIR"/*.port 2>/dev/null; then
    return 1
  fi
  if command -v ss >/dev/null 2>&1; then
    if ss -tlnH 2>/dev/null | grep -q ":${port} "; then
      return 1
    fi
  elif command -v netstat >/dev/null 2>&1; then
    if netstat -tln 2>/dev/null | grep -q ":${port} "; then
      return 1
    fi
  else
    if (echo > "/dev/tcp/127.0.0.1/${port}") >/dev/null 2>&1; then
      return 1
    fi
  fi
  return 0
}

find_free_port() {
  local preferred="${1:-}"
  if [[ -n "$preferred" ]]; then
    if is_port_free "$preferred"; then
      echo "$preferred"
      return 0
    fi
    echo -e "${YELLOW}Port $preferred is busy, picking the next free one...${RESET}" >&2
  fi

  local port
  for (( port=PORT_RANGE_START; port<=PORT_RANGE_END; port++ )); do
    if is_port_free "$port"; then
      echo "$port"
      return 0
    fi
  done
  return 1
}

# Same idea as is_port_free/find_free_port but for the per-codespace
# network-logging proxy, tracked in *.proxyport files.
is_proxy_port_free() {
  local port="$1"
  if grep -qs "^${port}$" "$META_DIR"/*.proxyport 2>/dev/null; then
    return 1
  fi
  if command -v ss >/dev/null 2>&1; then
    if ss -tlnH 2>/dev/null | grep -q ":${port} "; then
      return 1
    fi
  elif command -v netstat >/dev/null 2>&1; then
    if netstat -tln 2>/dev/null | grep -q ":${port} "; then
      return 1
    fi
  else
    if (echo > "/dev/tcp/127.0.0.1/${port}") >/dev/null 2>&1; then
      return 1
    fi
  fi
  return 0
}

find_free_proxy_port() {
  local port
  for (( port=PROXY_PORT_RANGE_START; port<=PROXY_PORT_RANGE_END; port++ )); do
    if is_proxy_port_free "$port"; then
      echo "$port"
      return 0
    fi
  done
  return 1
}

harden_proot_ubuntu() {
  proot-distro login ubuntu -- bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive

    if [[ ! -s /etc/machine-id ]]; then
      echo "$(cat /proc/sys/kernel/random/uuid | tr -d "-")" > /etc/machine-id
    fi

    printf "#!/bin/sh\nexit 101\n" > /usr/sbin/policy-rc.d
    chmod +x /usr/sbin/policy-rc.d

    divert_binary() {
      local binpath="$1"
      local divert="${binpath}.real"
      if [[ -f "$binpath" && ! -L "$binpath" ]]; then
        dpkg-divert --add --rename --divert "$divert" "$binpath" 2>/dev/null || true
      else
        dpkg-divert --add --divert "$divert" "$binpath" 2>/dev/null || true
      fi
    }

    divert_binary /usr/bin/systemd-machine-id-setup
    divert_binary /bin/systemctl
    divert_binary /usr/bin/systemctl
    divert_binary /usr/bin/systemd-sysusers
    divert_binary /usr/bin/systemd-tmpfiles
    divert_binary /usr/lib/systemd/systemd-sysusers
    divert_binary /usr/lib/systemd/systemd-tmpfiles
    divert_binary /usr/bin/systemd-firstboot
    divert_binary /usr/lib/systemd/systemd-network-generator

    for binpath in \
      /usr/bin/systemd-machine-id-setup \
      /bin/systemctl \
      /usr/bin/systemctl \
      /usr/bin/systemd-sysusers \
      /usr/bin/systemd-tmpfiles \
      /usr/lib/systemd/systemd-sysusers \
      /usr/lib/systemd/systemd-tmpfiles \
      /usr/bin/systemd-firstboot \
      /usr/lib/systemd/systemd-network-generator; do
      mkdir -p "$(dirname "$binpath")"
      cat > "$binpath" << "FAKEBIN"
#!/bin/sh
exit 0
FAKEBIN
      chmod +x "$binpath"
    done

    cat > /usr/bin/systemd-machine-id-setup << "MIDEOF"
#!/bin/sh
if [ ! -s /etc/machine-id ]; then
  echo "$(cat /proc/sys/kernel/random/uuid | tr -d "-")" > /etc/machine-id
fi
exit 0
MIDEOF
    chmod +x /usr/bin/systemd-machine-id-setup

    for pkg in systemd systemd-sysv systemd-timesyncd systemd-resolved \
               systemd-cryptsetup libsystemd-shared libpam-systemd \
               libnss-systemd dbus dbus-user-session; do
      script="/var/lib/dpkg/info/${pkg}.postinst"
      if [[ -f "$script" ]]; then
        printf "#!/bin/sh\nexit 0\n" > "$script"
      fi
    done

    dpkg --configure --force-all -a 2>/dev/null || true
    apt --fix-broken install -y 2>/dev/null || true

    apt-mark hold systemd systemd-sysv systemd-timesyncd \
      systemd-resolved systemd-cryptsetup libsystemd-shared \
      libpam-systemd libnss-systemd 2>/dev/null || true

    if command -v sudo >/dev/null 2>&1; then
      chmod u+s "$(command -v sudo)" 2>/dev/null || true
    fi

    mkdir -p /usr/local/bin
    cat > /usr/local/bin/sudo << "SUDOEOF"
#!/bin/bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|-g|-C|-p) shift 2 ;;
    --)          shift; break ;;
    -*)          shift ;;
    *)           break ;;
  esac
done
exec "$@"
SUDOEOF
    chmod +x /usr/local/bin/sudo

    mkdir -p /etc/systemd/system
    for unit in systemd-resolved systemd-timesyncd systemd-networkd \
                getty@tty1 remote-fs systemd-pstore; do
      ln -sf /dev/null "/etc/systemd/system/${unit}.service" 2>/dev/null || true
    done

    # ---------------------------------------------------------- #
    # Force apt sources onto https instead of http. Ubuntu apt
    # (1.5+/noble) has https support built in, no apt-transport-
    # https package needed. Covers both classic sources.list and
    # the deb822 *.sources files used on 24.04+.
    # ---------------------------------------------------------- #
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
      [[ -f "$f" ]] || continue
      sed -i -E "s#http://(archive\.ubuntu\.com|security\.ubuntu\.com|ports\.ubuntu\.com|old-releases\.ubuntu\.com|[a-z]{2}\.archive\.ubuntu\.com)#https://\1#g" "$f" 2>/dev/null || true
    done
  '
}

post_apt_fix() {
  proot-distro login ubuntu -- bash -c '
    export DEBIAN_FRONTEND=noninteractive

    for pkg in systemd systemd-sysv systemd-timesyncd systemd-resolved \
               systemd-cryptsetup libsystemd-shared libpam-systemd \
               libnss-systemd dbus dbus-user-session; do
      script="/var/lib/dpkg/info/${pkg}.postinst"
      if [[ -f "$script" ]]; then
        printf "#!/bin/sh\nexit 0\n" > "$script"
      fi
    done

    dpkg --configure --force-all -a 2>/dev/null || true

    if command -v sudo >/dev/null 2>&1; then
      chmod u+s "$(command -v sudo)" 2>/dev/null || true
    fi

    apt-mark hold systemd systemd-sysv systemd-timesyncd \
      systemd-resolved systemd-cryptsetup libsystemd-shared \
      libpam-systemd libnss-systemd 2>/dev/null || true
  '
}

# ------------------------------------------------------------------ #
# One-time base Ubuntu setup
# ------------------------------------------------------------------ #
run_initial_setup() {
  clear
  banner
  echo -e "${YELLOW}[*] Base Ubuntu image not found - running setup.${RESET}"
  echo "This is the image every codespace gets cloned from, so it only needs to"
  echo "happen once (unless you delete it). It can take a few minutes."
  echo

  if ! command -v proot-distro >/dev/null 2>&1; then
    echo -e "${RED}proot-distro is not installed.${RESET}"
    echo "Install it first with:  pkg install proot-distro -y"
    exit 1
  fi

  if [[ ! -x "$PROOT_BIN" ]]; then
    echo -e "${RED}proot binary not found at $PROOT_BIN${RESET}"
    echo "Install it first with:  pkg install proot -y"
    exit 1
  fi

  echo -e "${CYAN}[*] Installing Ubuntu via proot-distro...${RESET}"
  proot-distro install ubuntu

  BASE_ROOTFS="$(detect_base_rootfs)"

  if [[ -z "$BASE_ROOTFS" || ! -d "$BASE_ROOTFS" ]]; then
    echo -e "${RED}Ubuntu install appears to have failed.${RESET}"
    echo -e "${YELLOW}Checked paths:${RESET}"
    echo "  v5: $BASE_ROOTFS_V5"
    echo "  v4: $BASE_ROOTFS_V4"
    echo
    echo -e "${YELLOW}Troubleshooting:${RESET}"
    echo "  1. Run:  proot-distro list"
    echo "  2. Run:  ls -la $PROOT_DISTRO_DIR/containers/"
    echo "  3. Try:  proot-distro login ubuntu   (triggers legacy migration)"
    exit 1
  fi

  echo -e "${GREEN}[*] Ubuntu rootfs found at: $BASE_ROOTFS${RESET}"
  echo

  echo -e "${CYAN}[*] Hardening proot environment (dpkg-divert, sudo, machine-id)...${RESET}"
  harden_proot_ubuntu

  echo -e "${CYAN}[*] Updating packages and installing base tooling...${RESET}"
  proot-distro login ubuntu -- bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt update
    apt install -y \
      dialog sudo curl wget git \
      python3 python3-pip python3-venv \
      ca-certificates bash lsb-release \
      unzip zip tar xz-utils \
      jq tree htop nano vim less \
      openssh-client rsync net-tools dnsutils \
      build-essential pkg-config
    apt upgrade -y
    chsh -s /bin/bash root 2>/dev/null || true
  '
  post_apt_fix

  echo -e "${CYAN}[*] Installing common dev & GUI/Electron libraries...${RESET}"
  proot-distro login ubuntu -- bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive

    apt-get install -y --no-install-recommends \
      libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
      libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 \
      libxrandr2 libgbm1 libasound2t64 libpango-1.0-0 \
      libcairo2 libnss3 libxshmfence1 libnspr4 \
      libx11-xcb1 libxcb-dri3-0 libxss1 libxtst6 \
      2>/dev/null || true

    apt-get install -y --no-install-recommends \
      libgtk-3-0 libgdk-pixbuf-2.0-0 libnotify4 \
      libsecret-1-0 libxslt1.1 \
      2>/dev/null || true

    apt-get install -y --no-install-recommends \
      xvfb xauth x11-utils x11-xserver-utils \
      dbus-x11 xdg-utils \
      2>/dev/null || true

    apt-get install -y --no-install-recommends \
      libgl1 libglu1-mesa libvulkan1 mesa-utils \
      2>/dev/null || true

    apt-get install -y --no-install-recommends \
      fonts-liberation fonts-dejavu-core \
      fonts-noto-color-emoji fontconfig \
      2>/dev/null || true

    apt-get install -y --no-install-recommends \
      libpulse0 \
      2>/dev/null || true
  '
  post_apt_fix

  echo -e "${CYAN}[*] Installing code-server...${RESET}"
  proot-distro login ubuntu -- bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    curl -fsSL https://code-server.dev/install.sh | sh
    mkdir -p /root/.config/code-server
  '
  post_apt_fix

  echo -e "${CYAN}[*] Installing PHP on the Termux host (for the recovery file manager)...${RESET}"
  if ! command -v php >/dev/null 2>&1; then
    apt update -y && apt install -y php
    post_apt_fix
  fi
  if command -v php >/dev/null 2>&1; then
    echo -e "${GREEN}    PHP $(php -v 2>/dev/null | head -n1) - OK${RESET}"
  else
    echo -e "${YELLOW}    PHP install failed - recovery file manager will be disabled until you install it:${RESET}"
    echo -e "${YELLOW}    apt install php -y${RESET}"
  fi

  echo -e "${CYAN}[*] Pre-creating recovery file manager script...${RESET}"
  ensure_filemanager_script

  echo -e "${CYAN}[*] Configuring code-server terminal profile...${RESET}"
  proot-distro login ubuntu -- bash -c '
    mkdir -p /root/.local/share/code-server/User
    cat > /root/.local/share/code-server/User/settings.json <<SETTINGS
{
  "terminal.integrated.defaultProfile.linux": "bash",
  "terminal.integrated.profiles.linux": {
    "bash": { "path": "/bin/bash", "args": ["-l"] },
    "sh":   { "path": "/bin/sh" }
  },
  "terminal.integrated.env.linux": { "SHELL": "/bin/bash" }
}
SETTINGS
  '

  echo -e "${CYAN}[*] Reading the generated password (if any)...${RESET}"
  local pass=""
  pass=$(proot-distro login ubuntu -- bash -c \
    'cat /root/.config/code-server/config.yaml 2>/dev/null' \
    | grep '^password:' | awk '{print $2}' 2>/dev/null) || true

  echo
  echo -e "${GREEN}${BOLD}Base setup complete.${RESET}"
  echo
  echo -e "${BOLD}Installed in base image:${RESET}"
  echo -e "  ${GREEN}✓${RESET} Core tools      (git, curl, wget, python3, build-essential)"
  echo -e "  ${GREEN}✓${RESET} Electron/GUI    (libnss3, libgbm1, libatk, libgtk-3, ...)"
  echo -e "  ${GREEN}✓${RESET} X11/Display     (xvfb, xauth, dbus-x11, xdg-utils)"
  echo -e "  ${GREEN}✓${RESET} Graphics        (libgl1, libvulkan1, mesa)"
  echo -e "  ${GREEN}✓${RESET} Fonts           (liberation, dejavu, noto-emoji)"
  echo -e "  ${GREEN}✓${RESET} code-server     (VS Code in browser)"
  echo -e "  ${GREEN}✓${RESET} proot hardening  (dpkg-divert, sudo shim, machine-id)"
  echo
  if [[ -n "$pass" ]]; then
    echo -e "Default code-server password: ${BOLD}${pass}${RESET}"
    echo -e "${RED}Store this somewhere safe - it will not be shown again.${RESET}"
  else
    echo -e "${YELLOW}No pre-existing password found (normal for fresh install).${RESET}"
    echo -e "${YELLOW}Each codespace will get its own unique password on creation.${RESET}"
  fi

  echo
  echo -e "${YELLOW}Note: the base 'ubuntu' image will not be modified again.${RESET}"
  echo "Every codespace you create from now on is an independent clone of this image."
  press_any_key

  touch "$STATE_FILE"
}

# ------------------------------------------------------------------ #
# Codespace management
# ------------------------------------------------------------------ #
list_codespaces() {
  local d
  for d in "$CODESPACES_DIR"/*/; do
    [[ -d "$d" ]] && basename "$d"
  done 2>/dev/null | sort
}

is_running() {
  local name="$1"
  local pidfile="$META_DIR/$name.pid"
  if [[ -f "$pidfile" ]]; then
    local pid
    pid=$(cat "$pidfile" 2>/dev/null)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

random_password() {
  head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16
}

device_ip() {
  ip addr show 2>/dev/null \
    | grep -oE 'inet [0-9.]+' \
    | grep -v '127.0.0.1' \
    | head -n1 \
    | awk '{print $2}'
}

# ================================================================== #
# Network logging / filtering proxy
#
# Each codespace gets its own explicit forward proxy that runs on the
# Termux host (NOT inside proot, and NOT as root - it's a plain
# python3 process owned by your normal Termux user). The launcher sets
# http_proxy/https_proxy inside the container so its traffic routes
# through it.
#
# Because this is an explicit proxy rather than a transparent
# iptables redirect, it stays fully rootless - but it can only see
# and filter what obeys http_proxy/https_proxy (i.e. plain HTTP and
# HTTPS via CONNECT). It logs and can allow/deny at the domain level
# only; it does not decrypt TLS, so paths/bodies of HTTPS requests
# are never inspected. Tools that ignore proxy env vars, or that talk
# raw TCP/UDP/DNS-over-something-else, will bypass it.
#
# Both HTTP and HTTPS are handled the same way regardless of whether
# the codespace's apt sources use http:// or https:// mirrors:
#   - Plain HTTP requests are terminated and re-issued by the proxy
#     (do_GET/do_POST/etc below), so they're logged with full
#     method/host/port detail.
#   - HTTPS requests arrive as a CONNECT tunnel and are relayed
#     byte-for-byte without decryption, so only host:port is logged.
# ================================================================== #
ensure_proxy_script() {
  cat > "$NETPROXY_SCRIPT" << 'PYEOF'
#!/usr/bin/env python3
"""
Termux CodeSpace network proxy
Made By Aryan Giri | giriaryan694-a11y

A small forward proxy used to log outbound network activity from a
codespace and optionally enforce a domain allow/deny policy. Domain
matching only: HTTPS is tunnelled (CONNECT) without decryption, so
only the requested host:port is ever visible or filterable.
"""
import argparse
import datetime
import select
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def log_line(logfile, verdict, method, host, port):
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = "[{}] {:5} {:8} {}:{}\n".format(ts, verdict, method, host, port)
    try:
        with open(logfile, "a") as f:
            f.write(line)
    except OSError:
        pass


def read_domain_list(path):
    domains = []
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    domains.append(line.lower())
    except OSError:
        pass
    return domains


def read_mode(path):
    try:
        with open(path) as f:
            mode = f.read().strip().lower()
            if mode in ("open", "restricted"):
                return mode
    except OSError:
        pass
    return "open"


def host_matches(host, pattern):
    host = host.lower()
    pattern = pattern.lower()
    if pattern.startswith("."):
        return host == pattern[1:] or host.endswith(pattern)
    return host == pattern or host.endswith("." + pattern)


def is_allowed(host, args):
    mode = read_mode(args.mode_file)
    blocklist = read_domain_list(args.blocklist)

    if any(host_matches(host, p) for p in blocklist):
        return False, mode

    if mode == "restricted":
        allowlist = read_domain_list(args.allowlist)
        return any(host_matches(host, p) for p in allowlist), mode

    return True, mode


class ProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    args = None  # set in main()

    def log_message(self, fmt, *a):
        pass  # keep our own log format instead of stderr access logs

    def _target_from_path(self):
        from urllib.parse import urlparse
        parsed = urlparse(self.path)
        host = parsed.hostname or self.headers.get("Host", "").split(":")[0]
        port = parsed.port or 80
        return host, port

    def do_CONNECT(self):
        try:
            host, port_s = self.path.rsplit(":", 1)
            port = int(port_s)
        except ValueError:
            self.send_error(400, "Bad CONNECT target")
            return

        allowed, _ = is_allowed(host, self.args)
        log_line(self.args.log, "ALLOW" if allowed else "DENY", "CONNECT", host, port)

        if not allowed:
            self.send_response(403, "Forbidden by codespace network policy")
            self.end_headers()
            return

        try:
            upstream = socket.create_connection((host, port), timeout=15)
        except OSError as e:
            self.send_error(502, "Could not connect upstream: {}".format(e))
            return

        self.send_response(200, "Connection Established")
        self.end_headers()
        self._relay(self.connection, upstream)

    def _handle_plain(self, method):
        host, port = self._target_from_path()
        allowed, _ = is_allowed(host, self.args)
        log_line(self.args.log, "ALLOW" if allowed else "DENY", method, host, port)

        if not allowed:
            self.send_response(403, "Forbidden by codespace network policy")
            self.end_headers()
            try:
                self.wfile.write(b"Blocked by codespace network policy\n")
            except OSError:
                pass
            return

        try:
            import urllib.request
            length = int(self.headers.get("Content-Length", 0) or 0)
            body = self.rfile.read(length) if length else None
            req = urllib.request.Request(self.path, data=body, method=method)
            for k, v in self.headers.items():
                if k.lower() in ("proxy-connection", "connection"):
                    continue
                req.add_header(k, v)
            with urllib.request.urlopen(req, timeout=20) as resp:
                self.send_response(resp.status)
                for k, v in resp.getheaders():
                    if k.lower() in ("transfer-encoding", "connection"):
                        continue
                    self.send_header(k, v)
                self.end_headers()
                self.wfile.write(resp.read())
        except Exception as e:
            try:
                self.send_error(502, "Upstream error: {}".format(e))
            except Exception:
                pass

    def do_GET(self): self._handle_plain("GET")
    def do_POST(self): self._handle_plain("POST")
    def do_PUT(self): self._handle_plain("PUT")
    def do_DELETE(self): self._handle_plain("DELETE")
    def do_HEAD(self): self._handle_plain("HEAD")
    def do_OPTIONS(self): self._handle_plain("OPTIONS")
    def do_PATCH(self): self._handle_plain("PATCH")

    @staticmethod
    def _relay(a, b):
        sockets = [a, b]
        try:
            while True:
                r, _, x = select.select(sockets, [], sockets, 60)
                if x or not r:
                    break
                closed = False
                for s in r:
                    other = b if s is a else a
                    data = s.recv(65536)
                    if not data:
                        closed = True
                        break
                    other.sendall(data)
                if closed:
                    break
        except OSError:
            pass
        finally:
            for s in (a, b):
                try:
                    s.close()
                except OSError:
                    pass


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--log", required=True)
    p.add_argument("--mode-file", required=True)
    p.add_argument("--blocklist", required=True)
    p.add_argument("--allowlist", required=True)
    args = p.parse_args()

    ProxyHandler.args = args
    server = ThreadingHTTPServer(("127.0.0.1", args.port), ProxyHandler)
    server.serve_forever()


if __name__ == "__main__":
    main()
PYEOF
}

ensure_network_files() {
  local name="$1"
  [[ -f "$META_DIR/$name.netmode" ]]   || echo "open" > "$META_DIR/$name.netmode"
  [[ -f "$META_DIR/$name.blocklist" ]] || : > "$META_DIR/$name.blocklist"
  [[ -f "$META_DIR/$name.allowlist" ]] || : > "$META_DIR/$name.allowlist"
  [[ -f "$META_DIR/$name.netlog" ]]    || : > "$META_DIR/$name.netlog"
  [[ -f "$META_DIR/$name.proxyenabled" ]] || echo "on" > "$META_DIR/$name.proxyenabled"
}

ensure_quota_files() {
  local name="$1"
  [[ -f "$META_DIR/$name.quota" ]] || echo "$DEFAULT_QUOTA_MB" > "$META_DIR/$name.quota"
  [[ -f "$META_DIR/$name.quota.mode" ]] || echo "soft" > "$META_DIR/$name.quota.mode"
  [[ -f "$META_DIR/$name.quota.log" ]] || : > "$META_DIR/$name.quota.log"
}

get_quota_mb() {
  local name="$1"
  ensure_quota_files "$name"
  local v
  v=$(cat "$META_DIR/$name.quota" 2>/dev/null)
  [[ "$v" =~ ^[0-9]+$ ]] || v=0
  echo "$v"
}

set_quota_mb() {
  local name="$1" mb="$2"
  ensure_quota_files "$name"
  echo "$mb" > "$META_DIR/$name.quota"
}

get_quota_mode() {
  local name="$1"
  ensure_quota_files "$name"
  local m
  m=$(cat "$META_DIR/$name.quota.mode" 2>/dev/null)
  [[ "$m" == "hard" ]] && echo "hard" || echo "soft"
}

is_hard_quota() {
  [[ "$(get_quota_mode "$1")" == "hard" ]]
}

quota_image_path() {
  echo "$QUOTA_IMAGES_DIR/$1.img"
}

is_quota_image_mounted() {
  local name="$1"
  local rootfs="$CODESPACES_DIR/$name"
  [[ -d "$rootfs" ]] || return 1
  if command -v mountpoint >/dev/null 2>&1; then
    mountpoint -q "$rootfs" 2>/dev/null
  else
    grep -qs " $(printf '%s' "$rootfs") " /proc/mounts 2>/dev/null
  fi
}

# Current on-disk size of a codespace's rootfs, in MB (rounded).
# For hard-quota codespaces that aren't currently mounted, this falls
# back to the actual (sparse-aware) size of the backing image file.
# Bind-mount target dirs (dev, proc, sys, ...) are excluded since
# they're empty/irrelevant and just slow `du` down on a big rootfs.
get_codespace_size_mb() {
  local name="$1"
  local rootfs="$CODESPACES_DIR/$name"
  if is_hard_quota "$name" && ! is_quota_image_mounted "$name"; then
    local img
    img=$(quota_image_path "$name")
    [[ -f "$img" ]] || { echo 0; return; }
    du -sm "$img" 2>/dev/null | awk '{print $1}' | head -n1
    return
  fi
  [[ -d "$rootfs" ]] || { echo 0; return; }
  local du_excludes=() p
  for p in "${PROOT_BIND_EXCLUDES[@]}"; do
    du_excludes+=(--exclude="$p")
  done
  local out
  out=$(du -sm "${du_excludes[@]}" "$rootfs" 2>/dev/null)
  if [[ -z "$out" ]]; then
    # BusyBox/toybox du doesn't support --exclude - retry without it.
    out=$(du -sm "$rootfs" 2>/dev/null)
  fi
  echo "$out" | awk '{print $1}' | head -n1
}

# Human-friendly "used / quota" string with no ANSI color, e.g.
# "812 MB / 2048 MB (hard)" or "812 MB / unlimited".
format_quota_usage() {
  local name="$1"
  local used quota mode
  used=$(get_codespace_size_mb "$name")
  quota=$(get_quota_mb "$name")
  mode=$(get_quota_mode "$name")
  if [[ "$quota" -eq 0 ]]; then
    echo "${used:-0} MB / unlimited"
  elif [[ "$mode" == "hard" ]]; then
    echo "${used:-0} MB / ${quota} MB (hard)"
  elif command -v inotifywait >/dev/null 2>&1; then
    echo "${used:-0} MB / ${quota} MB (soft, event-driven)"
  else
    echo "${used:-0} MB / ${quota} MB (soft, polled)"
  fi
}

is_quota_watchdog_running() {
  local name="$1"
  local pidfile="$META_DIR/$name.quota.pid"
  if [[ -f "$pidfile" ]]; then
    local pid
    pid=$(cat "$pidfile" 2>/dev/null)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

# Runs as a detached watchdog for as long as the codespace is up.
# Killed by stop_codespace / stop_quota_watchdog. Only used in "soft"
# mode - hard-mode codespaces are capped by the filesystem itself.
#
# When `inotify-tools` is installed, this reacts to actual writes
# (checked at most once every QUOTA_DEBOUNCE_SECONDS while there's
# activity, and not at all while idle - cheaper on battery than
# fixed-interval polling and much faster to react than the old 30s
# poll). A large Ubuntu rootfs can exceed the kernel's inotify watch
# limit though, so this verifies the watch actually started and falls
# back to fast interval polling if not. Without inotify-tools at all,
# it just polls every QUOTA_CHECK_INTERVAL_FAST seconds.
start_quota_watchdog() {
  local name="$1"
  ensure_quota_files "$name"

  is_hard_quota "$name" && return 0   # filesystem enforces it directly

  local quota
  quota=$(get_quota_mb "$name")
  if [[ "$quota" -eq 0 ]]; then
    # Unlimited - nothing to watch.
    return 0
  fi

  if is_quota_watchdog_running "$name"; then
    return 0
  fi

  local rootfs="$CODESPACES_DIR/$name"
  local events_file="$META_DIR/$name.quota.events"
  : > "$events_file"

  _quota_check_once() {
    # Returns 1 (and stops the codespace) if over quota; 0 otherwise.
    is_running "$name" || return 2
    is_hard_quota "$name" && return 2   # switched to hard while running
    local q used ts
    q=$(get_quota_mb "$name")
    [[ "$q" -eq 0 ]] && return 2        # quota lifted while running
    used=$(get_codespace_size_mb "$name")
    if [[ -n "$used" && "$used" -gt "$q" ]]; then
      ts=$(date "+%Y-%m-%d %H:%M:%S")
      echo "[$ts] QUOTA EXCEEDED: ${used}MB > ${q}MB - stopping codespace '$name'" >> "$META_DIR/$name.quota.log"
      touch "$META_DIR/$name.quota.exceeded"
      stop_codespace "$name"
      return 1
    fi
    return 0
  }

  (
    local iw_pid=""
    if command -v inotifywait >/dev/null 2>&1; then
      # Heuristic exclude - skip the noisiest proot bind-mount targets
      # so we don't burn watches on empty/000-permission directories.
      inotifywait -m -r -q \
        -e close_write,create,moved_to,delete,modify \
        --exclude '/(proc|sys|dev|tmp|run)(/|$)' \
        "$rootfs" >> "$events_file" 2>>"$META_DIR/$name.quota.log" &
      iw_pid=$!
      sleep 1
      kill -0 "$iw_pid" 2>/dev/null || iw_pid=""   # failed to start (e.g. watch limit)
    fi

    local last_check=0
    if [[ -n "$iw_pid" ]]; then
      # Event-driven: only check when something actually changed.
      while kill -0 "$iw_pid" 2>/dev/null; do
        _quota_check_once; local rc=$?
        [[ "$rc" -ne 0 ]] && break
        if [[ -s "$events_file" ]]; then
          : > "$events_file"
          last_check=$(date +%s)
        fi
        sleep "$QUOTA_DEBOUNCE_SECONDS"
      done
      kill "$iw_pid" 2>/dev/null
    else
      # No usable inotify - fall back to fast fixed-interval polling.
      while true; do
        sleep "$QUOTA_CHECK_INTERVAL_FAST"
        _quota_check_once; local rc=$?
        [[ "$rc" -ne 0 ]] && break
      done
    fi
    rm -f "$events_file"
  ) &
  echo $! > "$META_DIR/$name.quota.pid"
}

stop_quota_watchdog() {
  local name="$1"
  local pidfile="$META_DIR/$name.quota.pid"
  if is_quota_watchdog_running "$name"; then
    local pid
    pid=$(cat "$pidfile")
    kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null
    sleep 1
    kill -9 -- -"$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null
  fi
  rm -f "$pidfile" "$META_DIR/$name.quota.events"
  # Belt-and-suspenders: in case job-control quirks left an
  # inotifywait watching this specific rootfs, clean it up too.
  if command -v pkill >/dev/null 2>&1; then
    pkill -f "inotifywait.*${CODESPACES_DIR}/${name}\$" 2>/dev/null || true
  fi
}

hard_quota_supported() {
  if [[ -f "$HARD_QUOTA_CAPABILITY_FILE" ]]; then
    [[ "$(cat "$HARD_QUOTA_CAPABILITY_FILE" 2>/dev/null)" == "yes" ]]
    return
  fi

  local result="no"
  if command -v mount >/dev/null 2>&1 && command -v umount >/dev/null 2>&1 \
     && command -v mkfs.ext4 >/dev/null 2>&1 && [[ "$(id -u)" -eq 0 ]]; then
    local test_img test_mnt
    test_img=$(mktemp -u "${QUOTA_IMAGES_DIR}/.cap_test.XXXXXX.img")
    test_mnt=$(mktemp -d "${QUOTA_IMAGES_DIR}/.cap_test.XXXXXX.mnt")
    if truncate -s 8M "$test_img" 2>/dev/null \
       && mkfs.ext4 -q -F "$test_img" >/dev/null 2>&1 \
       && mount -o loop "$test_img" "$test_mnt" >/dev/null 2>&1; then
      umount "$test_mnt" >/dev/null 2>&1
      result="yes"
    fi
    rm -f "$test_img"
    rmdir "$test_mnt" 2>/dev/null
  fi

  echo "$result" > "$HARD_QUOTA_CAPABILITY_FILE"
  [[ "$result" == "yes" ]]
}

# Mount a hard-quota codespace's image at its rootfs directory if not
# already mounted. Returns non-zero (with a message) on failure.
mount_hard_quota() {
  local name="$1"
  local rootfs="$CODESPACES_DIR/$name"
  local img
  img=$(quota_image_path "$name")

  is_quota_image_mounted "$name" && return 0

  if [[ ! -f "$img" ]]; then
    echo -e "${RED}Hard-quota image for '$name' is missing at $img.${RESET}"
    return 1
  fi

  mkdir -p "$rootfs"
  if ! mount -o loop "$img" "$rootfs" >/dev/null 2>&1; then
    echo -e "${RED}Failed to mount hard-quota image for '$name'.${RESET}"
    echo -e "${YELLOW}(needs root + loop-mount support - re-run the capability check by deleting${RESET}"
    echo -e "${YELLOW} $HARD_QUOTA_CAPABILITY_FILE if your setup changed)${RESET}"
    return 1
  fi
  return 0
}

unmount_hard_quota() {
  local name="$1"
  local rootfs="$CODESPACES_DIR/$name"
  is_quota_image_mounted "$name" || return 0
  # Give any just-killed proot/code-server processes a moment to
  # release their file handles before we try to unmount.
  sync 2>/dev/null
  umount "$rootfs" >/dev/null 2>&1 || { sleep 1; umount "$rootfs" >/dev/null 2>&1; }
}

# Converts an existing plain-directory codespace to a hard, fixed-size
# quota. Stops it first, moves its current contents into a freshly
# formatted ext4 image of the requested size, and mounts that image
# back at the same path.
enable_hard_quota() {
  local name="$1" quota_mb="$2"
  local rootfs="$CODESPACES_DIR/$name"
  local img
  img=$(quota_image_path "$name")

  if ! hard_quota_supported; then
    echo -e "${RED}Hard quotas aren't supported on this device (needs root + loop-mount).${RESET}"
    return 1
  fi
  if [[ "$quota_mb" -lt 64 ]]; then
    echo -e "${RED}Hard quota must be at least 64 MB (ext4 + your files need room).${RESET}"
    return 1
  fi

  local was_running=0
  if is_running "$name"; then
    was_running=1
    echo -e "${CYAN}[*] Stopping '$name' to convert it...${RESET}"
    stop_filemanager "$name" 2>/dev/null || true
    stop_codespace "$name" --no-fm
  fi
  unmount_hard_quota "$name"   # no-op if it wasn't already hard-mode

  local current_used_mb
  current_used_mb=$(du -sm "$rootfs" 2>/dev/null | awk '{print $1}')
  if [[ -n "$current_used_mb" && "$current_used_mb" -gt 0 ]]; then
    local headroom_mb=$(( current_used_mb + current_used_mb / 5 + 32 ))  # +20% + 32MB slack
    if [[ "$quota_mb" -lt "$headroom_mb" ]]; then
      echo -e "${RED}'$name' currently uses ~${current_used_mb} MB; ${quota_mb} MB leaves too little room.${RESET}"
      echo -e "${YELLOW}Pick at least ~${headroom_mb} MB, or free up space inside the codespace first.${RESET}"
      return 1
    fi
  fi

  echo -e "${CYAN}[*] Creating ${quota_mb} MB ext4 image...${RESET}"
  if ! truncate -s "${quota_mb}M" "$img" 2>/dev/null; then
    echo -e "${RED}Failed to allocate image file.${RESET}"
    return 1
  fi
  if ! mkfs.ext4 -q -F "$img" >/dev/null 2>&1; then
    echo -e "${RED}mkfs.ext4 failed. Is e2fsprogs installed? (pkg install e2fsprogs)${RESET}"
    rm -f "$img"
    return 1
  fi

  local staging
  staging=$(mktemp -d "${QUOTA_IMAGES_DIR}/.mount.${name}.XXXXXX")
  if ! mount -o loop "$img" "$staging" >/dev/null 2>&1; then
    echo -e "${RED}Failed to loop-mount the new image.${RESET}"
    rm -f "$img"; rmdir "$staging" 2>/dev/null
    return 1
  fi

  echo -e "${CYAN}[*] Copying existing data into the quota-capped image...${RESET}"
  if ! cp -a "$rootfs/." "$staging/" 2>/dev/null; then
    echo -e "${RED}Copy failed (image likely too small) - reverting.${RESET}"
    umount "$staging" 2>/dev/null; rmdir "$staging" 2>/dev/null
    rm -f "$img"
    return 1
  fi
  umount "$staging" 2>/dev/null
  rmdir "$staging" 2>/dev/null

  local backup_dir="${rootfs}.pre-hardquota"
  rm -rf "$backup_dir"
  mv "$rootfs" "$backup_dir"
  mkdir -p "$rootfs"

  if ! mount -o loop "$img" "$rootfs" >/dev/null 2>&1; then
    echo -e "${RED}Final mount failed - restoring original directory.${RESET}"
    rmdir "$rootfs" 2>/dev/null
    mv "$backup_dir" "$rootfs"
    rm -f "$img"
    return 1
  fi

  rm -rf "$backup_dir"
  echo "hard" > "$META_DIR/$name.quota.mode"
  set_quota_mb "$name" "$quota_mb"
  rm -f "$META_DIR/$name.quota.exceeded"
  stop_quota_watchdog "$name"   # no longer needed in hard mode

  echo -e "${GREEN}'$name' now has a hard ${quota_mb} MB storage cap.${RESET}"
  [[ "$was_running" -eq 1 ]] && start_codespace "$name"
  return 0
}

# Converts a hard-quota codespace back to a plain directory (data is
# copied out of the image, which is then deleted).
disable_hard_quota() {
  local name="$1"
  local rootfs="$CODESPACES_DIR/$name"
  local img
  img=$(quota_image_path "$name")

  local was_running=0
  if is_running "$name"; then
    was_running=1
    stop_filemanager "$name" 2>/dev/null || true
    stop_codespace "$name" --no-fm
  fi

  mount_hard_quota "$name" || { echo -e "${RED}Could not mount image to read data back out.${RESET}"; return 1; }

  local plain_dir="${rootfs}.plain"
  rm -rf "$plain_dir"
  mkdir -p "$plain_dir"
  if ! cp -a "$rootfs/." "$plain_dir/" 2>/dev/null; then
    echo -e "${RED}Failed to copy data out of the image.${RESET}"
    rm -rf "$plain_dir"
    return 1
  fi

  unmount_hard_quota "$name"
  rmdir "$rootfs" 2>/dev/null
  mv "$plain_dir" "$rootfs"
  rm -f "$img"

  echo "soft" > "$META_DIR/$name.quota.mode"
  echo -e "${GREEN}'$name' is back to a plain directory (soft/no quota enforcement).${RESET}"
  [[ "$was_running" -eq 1 ]] && start_codespace "$name"
  return 0
}

# Grows a mounted hard-quota image online (ext4 supports online grow).
resize_hard_quota() {
  local name="$1" new_mb="$2"
  local img
  img=$(quota_image_path "$name")
  local cur_mb
  cur_mb=$(get_quota_mb "$name")

  if [[ "$new_mb" -le "$cur_mb" ]]; then
    echo -e "${RED}Shrinking a hard quota isn't supported here - disable and re-enable it at a smaller size instead.${RESET}"
    return 1
  fi

  if ! truncate -s "${new_mb}M" "$img" 2>/dev/null; then
    echo -e "${RED}Failed to grow the image file.${RESET}"
    return 1
  fi

  if is_quota_image_mounted "$name"; then
    if ! resize2fs "$img" >/dev/null 2>&1; then
      echo -e "${RED}resize2fs failed. Is e2fsprogs installed? (pkg install e2fsprogs)${RESET}"
      return 1
    fi
  else
    # Offline resize needs a loop mount briefly.
    if command -v losetup >/dev/null 2>&1; then
      local dev
      dev=$(losetup -f --show "$img" 2>/dev/null)
      if [[ -n "$dev" ]]; then
        resize2fs "$dev" >/dev/null 2>&1
        losetup -d "$dev" >/dev/null 2>&1
      fi
    fi
  fi

  set_quota_mb "$name" "$new_mb"
  echo -e "${GREEN}Hard quota for '$name' grown to ${new_mb} MB.${RESET}"
  return 0
}

# Interactive "s" menu action: view usage, set/clear the quota, and
# switch between soft (poll-based) and hard (filesystem-capped)
# enforcement.
set_quota_interactive() {
  local name="$1"
  ensure_quota_files "$name"
  clear; banner
  echo -e "${BOLD}Storage quota: $name${RESET}"
  echo
  echo -e "  Current usage: $(format_quota_usage "$name")"
  if [[ -f "$META_DIR/$name.quota.exceeded" ]]; then
    echo -e "  ${RED}This codespace was last stopped for exceeding its quota.${RESET}"
  fi
  echo

  local mode
  mode=$(get_quota_mode "$name")
  local hq_ok=0
  hard_quota_supported && hq_ok=1

  if [[ "$hq_ok" -eq 1 ]]; then
    echo -e "Enforcement is currently ${BOLD}${mode}${RESET}."
    echo "  1) Set a soft limit (polled every ${QUOTA_CHECK_INTERVAL}s, can be briefly exceeded)"
    echo "  2) Set a hard limit (real filesystem cap - writes fail once full)"
    [[ "$mode" == "hard" ]] && echo "  3) Grow the current hard limit"
    [[ "$mode" == "hard" ]] && echo "  4) Switch back to a plain directory (no quota)"
    echo "  0) Cancel"
    read -rp "> " menu_choice
    case "$menu_choice" in
      1)
        read -rp "Soft limit in MB (0 for unlimited): " new_quota
        if [[ "$new_quota" =~ ^[0-9]+$ ]]; then
          if [[ "$mode" == "hard" ]]; then
            echo -e "${YELLOW}Switching from hard to soft first (data will be copied out of the image)...${RESET}"
            disable_hard_quota "$name" || { press_any_key; return; }
          fi
          set_quota_mb "$name" "$new_quota"
          rm -f "$META_DIR/$name.quota.exceeded"
          if [[ "$new_quota" -eq 0 ]]; then
            echo -e "${GREEN}Quota removed - '$name' is now unlimited.${RESET}"
            stop_quota_watchdog "$name"
          else
            echo -e "${GREEN}Soft quota for '$name' set to ${new_quota} MB.${RESET}"
            is_running "$name" && start_quota_watchdog "$name"
          fi
        else
          echo -e "${RED}Invalid value.${RESET}"
        fi
        ;;
      2)
        read -rp "Hard limit in MB (e.g. 2048 for 2GB): " new_quota
        if [[ "$new_quota" =~ ^[0-9]+$ ]]; then
          enable_hard_quota "$name" "$new_quota"
        else
          echo -e "${RED}Invalid value.${RESET}"
        fi
        ;;
      3)
        if [[ "$mode" == "hard" ]]; then
          read -rp "New (larger) size in MB: " new_quota
          [[ "$new_quota" =~ ^[0-9]+$ ]] && resize_hard_quota "$name" "$new_quota" || echo -e "${RED}Invalid value.${RESET}"
        fi
        ;;
      4)
        [[ "$mode" == "hard" ]] && disable_hard_quota "$name"
        ;;
      0|"") echo "Cancelled." ;;
      *) echo -e "${RED}Invalid choice.${RESET}" ;;
    esac
  else
    echo -e "${YELLOW}Hard (filesystem-enforced) quotas aren't available on this device - they need${RESET}"
    echo -e "${YELLOW}root and working loop-mount support (FUSE mounts are blocked for third-party${RESET}"
    echo -e "${YELLOW}apps by Android's SELinux policy too, so there's no rootless way around this).${RESET}"
    if command -v inotifywait >/dev/null 2>&1; then
      echo -e "${GREEN}Soft quotas here are event-driven (inotify-tools found) - checks react to${RESET}"
      echo -e "${GREEN}actual writes within ~${QUOTA_DEBOUNCE_SECONDS}s instead of a fixed poll.${RESET}"
    else
      echo -e "${YELLOW}Soft quotas will poll every ${QUOTA_CHECK_INTERVAL_FAST}s. For much faster, event-driven${RESET}"
      echo -e "${YELLOW}reaction to writes instead, install: pkg install inotify-tools${RESET}"
    fi
    echo
    echo "Enter a new limit in MB (e.g. 2048 for 2GB), 0 for unlimited,"
    read -rp "or leave blank to keep the current setting: " new_quota
    if [[ -n "$new_quota" ]]; then
      if [[ "$new_quota" =~ ^[0-9]+$ ]]; then
        set_quota_mb "$name" "$new_quota"
        rm -f "$META_DIR/$name.quota.exceeded"
        if [[ "$new_quota" -eq 0 ]]; then
          echo -e "${GREEN}Quota removed - '$name' is now unlimited.${RESET}"
          stop_quota_watchdog "$name"
        else
          echo -e "${GREEN}Soft quota for '$name' set to ${new_quota} MB.${RESET}"
          is_running "$name" && start_quota_watchdog "$name"
        fi
      else
        echo -e "${RED}Invalid value - must be a whole number of MB.${RESET}"
      fi
    else
      echo "No change."
    fi
  fi
  press_any_key
}

is_proxy_enabled() {
  local name="$1"
  local state
  state=$(cat "$META_DIR/$name.proxyenabled" 2>/dev/null || echo "on")
  [[ "$state" == "on" ]]
}

is_proxy_running() {
  local name="$1"
  local pidfile="$META_DIR/$name.proxy.pid"
  if [[ -f "$pidfile" ]]; then
    local pid
    pid=$(cat "$pidfile" 2>/dev/null)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

start_network_proxy() {
  local name="$1"

  ensure_network_files "$name"

  if ! is_proxy_enabled "$name"; then
    # Proxy has been explicitly turned off for this codespace - leave
    # traffic direct/unproxied and don't spin anything up.
    return 1
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo -e "${YELLOW}[!] python3 not found on host - network logging/filtering disabled for '$name'.${RESET}"
    echo -e "${YELLOW}    Install it with: pkg install python -y${RESET}"
    return 1
  fi

  ensure_proxy_script

  if is_proxy_running "$name"; then
    return 0
  fi

  local proxy_port=""
  if [[ -f "$META_DIR/$name.proxyport" ]]; then
    proxy_port=$(cat "$META_DIR/$name.proxyport")
    is_proxy_port_free "$proxy_port" || proxy_port=""
  fi
  [[ -z "$proxy_port" ]] && proxy_port=$(find_free_proxy_port)

  if [[ -z "$proxy_port" ]]; then
    echo -e "${RED}No free proxy ports available in range ${PROXY_PORT_RANGE_START}-${PROXY_PORT_RANGE_END}.${RESET}"
    return 1
  fi
  echo "$proxy_port" > "$META_DIR/$name.proxyport"

  nohup python3 "$NETPROXY_SCRIPT" \
    --port "$proxy_port" \
    --log "$META_DIR/$name.netlog" \
    --mode-file "$META_DIR/$name.netmode" \
    --blocklist "$META_DIR/$name.blocklist" \
    --allowlist "$META_DIR/$name.allowlist" \
    > "$META_DIR/$name.proxy.log" 2>&1 &
  echo $! > "$META_DIR/$name.proxy.pid"
  sleep 1

  if ! is_proxy_running "$name"; then
    echo -e "${YELLOW}[!] Network proxy failed to start for '$name'; traffic will bypass logging/filtering.${RESET}"
    echo -e "${YELLOW}    Check: cat $META_DIR/$name.proxy.log${RESET}"
    return 1
  fi
  return 0
}

stop_network_proxy() {
  local name="$1"
  local pidfile="$META_DIR/$name.proxy.pid"
  if is_proxy_running "$name"; then
    local pid
    pid=$(cat "$pidfile")
    kill "$pid" 2>/dev/null
    sleep 1
    kill -9 "$pid" 2>/dev/null
  fi
  rm -f "$pidfile"
}

FILEMANAGER_SCRIPT="$BASE_DIR/filemanager.php"

ensure_filemanager_script() {
  if [[ -f "$FILEMANAGER_SCRIPT" && -f "$BASE_DIR/.filemanager_v2" ]]; then
    return 0
  fi

  cat > "$FILEMANAGER_SCRIPT" << 'FM_PHPEOF'
<?php
ini_set('session.use_strict_mode', '1');
ini_set('session.use_only_cookies', '1');
ini_set('session.cookie_httponly', '1');
ini_set('session.cookie_samesite', 'Strict');
session_start();

$rootfs   = getenv('FM_ROOTFS') ?: '/';
$passFile = getenv('FM_PASS_FILE') ?: '';
$csName   = getenv('FM_NAME') ?: 'codespace';
$scanner  = getenv('FM_SCANNER') ?: '';

$authPass = '';
if ($passFile !== '' && is_file($passFile) && is_readable($passFile)) {
    $authPass = trim((string) file_get_contents($passFile));
}

function csrf_token(): string {
    if (empty($_SESSION['csrf'])) {
        $_SESSION['csrf'] = bin2hex(random_bytes(32));
    }
    return $_SESSION['csrf'];
}

function check_csrf(?string $token): bool {
    return !empty($_SESSION['csrf']) && hash_equals($_SESSION['csrf'], $token ?? '');
}

function safe_path(string $rel, string $rootfs): ?string {
    $root = realpath($rootfs);
    if ($root === false) return null;
    $rel = str_replace("\0", '', $rel);
    if ($rel === '' || $rel === '.' || $rel === '/') return $root;

    $candidate = $root . DIRECTORY_SEPARATOR . ltrim(str_replace('\\', '/', $rel), '/');
    $real = realpath($candidate);
    if ($real !== false) {
        return ($real === $root || str_starts_with($real, $root . DIRECTORY_SEPARATOR)) ? $real : null;
    }

    $parts = [];
    foreach (explode('/', trim(str_replace('\\', '/', $rel), '/')) as $part) {
        if ($part === '' || $part === '.') continue;
        if ($part === '..') {
            array_pop($parts);
            continue;
        }
        $parts[] = $part;
    }
    $normalized = $root . DIRECTORY_SEPARATOR . implode(DIRECTORY_SEPARATOR, $parts);
    return str_starts_with($normalized, $root . DIRECTORY_SEPARATOR) ? $normalized : null;
}

function delete_dir_recursive(string $dir): bool {
    $items = @scandir($dir);
    if ($items === false) return false;
    $ok = true;
    foreach ($items as $item) {
        if ($item === '.' || $item === '..') continue;
        $path = $dir . DIRECTORY_SEPARATOR . $item;
        if (is_dir($path) && !is_link($path)) {
            $ok = delete_dir_recursive($path) && $ok;
        } else {
            $ok = @unlink($path) && $ok;
        }
    }
    return @rmdir($dir) && $ok;
}

function human_size(int $bytes): string {
    if ($bytes < 1024) return $bytes . ' B';
    if ($bytes < 1048576) return round($bytes / 1024, 1) . ' KB';
    if ($bytes < 1073741824) return round($bytes / 1048576, 1) . ' MB';
    return round($bytes / 1073741824, 2) . ' GB';
}

function enc(string $value): string { return rawurlencode($value); }
function h(string $value): string {
    return htmlspecialchars($value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

function scan_directory_fallback(string $dirPath, string $dirRel): array {
    $entries = @scandir($dirPath);
    if ($entries === false) return [];

    $result = [];
    foreach ($entries as $name) {
        if ($name === '.' || $name === '..') continue;
        $path = $dirPath . DIRECTORY_SEPARATOR . $name;
        $isLink = @is_link($path);
        $stat = @lstat($path);
        $isDir = $stat !== false && !$isLink && (($stat['mode'] & 0170000) === 0040000);
        $bytes = $isDir ? directory_size_php($path) : (int) ($stat['size'] ?? 0);
        $mode = $stat !== false ? ($stat['mode'] & 07777) | ($stat['mode'] & 0170000) : false;
        $result[] = [
            'name' => $name,
            'rel' => ($dirRel !== '' ? $dirRel . '/' : '') . $name,
            'is_dir' => $isDir,
            'is_link' => $isLink,
            'size' => $bytes,
            'size_human' => human_size($bytes),
            'mode_symbolic' => $mode !== false ? permission_string((int)$mode) : '??????????',
            'mode_octal' => $mode !== false ? substr(sprintf('%o', $mode), -4) : '----',
            'mtime' => (int) (@filemtime($path) ?: 0),
        ];
    }
    return $result;
}

function directory_size_php(string $path): int {
    $total = 0;
    $stack = [$path];
    while ($stack) {
        $current = array_pop($stack);
        $items = @scandir($current);
        if ($items === false) continue;
        foreach ($items as $name) {
            if ($name === '.' || $name === '..') continue;
            $child = $current . DIRECTORY_SEPARATOR . $name;
            if (@is_link($child)) continue;
            if (@is_dir($child)) {
                $stack[] = $child;
            } else {
                $total += (int) (@filesize($child) ?: 0);
            }
        }
    }
    return $total;
}

function permission_string(int $mode): string {
    $type = ($mode & 0x4000) ? 'd' : (($mode & 0xA000) === 0xA000 ? 'l' : ((($mode & 0x2000) === 0x2000) ? 'c' : '-'));
    $map = [[0x100,'r'],[0x80,'w'],[0x40,'x'],[0x20,'r'],[0x10,'w'],[0x8,'x'],[0x4,'r'],[0x2,'w'],[0x1,'x']];
    $out = $type;
    foreach ($map as [$bit,$char]) $out .= ($mode & $bit) ? $char : (in_array($char, ['x'], true) ? '-' : '-');
    if ($mode & 0x800) $out[3] = ($mode & 0x40) ? 's' : 'S';
    if ($mode & 0x400) $out[6] = ($mode & 0x8) ? 's' : 'S';
    if ($mode & 0x200) $out[9] = ($mode & 0x1) ? 't' : 'T';
    return $out;
}

function scan_directory(string $scanner, string $rootfs, string $dirRel): array {
    $dirPath = safe_path($dirRel, $rootfs);
    if ($dirPath === null || !is_dir($dirPath)) return [];

    if ($scanner !== '' && is_file($scanner)) {
        $python = trim((string) @shell_exec('command -v python3 2>/dev/null'));
        if ($python !== '') {
            $cmd = escapeshellarg($python) . ' ' . escapeshellarg($scanner) .
                   ' --root ' . escapeshellarg($rootfs) . ' --dir ' . escapeshellarg($dirRel);
            $output = [];
            $status = 1;
            @exec($cmd . ' 2>/dev/null', $output, $status);
            if ($status === 0) {
                $data = json_decode(implode("\n", $output), true);
                if (is_array($data)) return $data;
            }
        }
    }

    return scan_directory_fallback($dirPath, $dirRel);
}

if (!isset($_SESSION['attempts'])) $_SESSION['attempts'] = 0;
if (!isset($_SESSION['lockuntil'])) $_SESSION['lockuntil'] = 0;

$loginError = null;
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $action = $_POST['action'] ?? '';

    if ($action === 'login') {
        if (time() < $_SESSION['lockuntil']) {
            $wait = $_SESSION['lockuntil'] - time();
            http_response_code(429);
            exit("Too many attempts. Try again in {$wait}s.");
        }
        $password = (string) ($_POST['password'] ?? '');
        if ($authPass !== '' && hash_equals($authPass, $password)) {
            $_SESSION['authed'] = true;
            $_SESSION['attempts'] = 0;
            $_SESSION['lockuntil'] = 0;
            session_regenerate_id(true);
            header('Location: /');
            exit;
        }
        $_SESSION['attempts']++;
        if ($_SESSION['attempts'] >= 5) {
            $_SESSION['lockuntil'] = time() + 60;
            $_SESSION['attempts'] = 0;
        }
        $loginError = 'Incorrect password.';
    } elseif ($action === 'logout') {
        $_SESSION = [];
        session_destroy();
        header('Location: /');
        exit;
    } elseif ($action === 'delete') {
        if (empty($_SESSION['authed']) || !check_csrf($_POST['csrf'] ?? null)) {
            http_response_code(403);
            exit('Forbidden.');
        }
        $target = safe_path((string) ($_POST['path'] ?? ''), $rootfs);
        $root = realpath($rootfs);
        if ($target === null || $root === false || $target === $root) {
            http_response_code(400);
            exit('Invalid path.');
        }
        $ok = is_dir($target) && !is_link($target)
            ? delete_dir_recursive($target)
            : @unlink($target);
        if (!$ok) {
            http_response_code(500);
            exit('Delete failed.');
        }
        $parent = dirname((string) ($_POST['path'] ?? ''));
        header('Location: /?dir=' . enc($parent === '.' ? '' : $parent));
        exit;
    }
}

if (empty($_SESSION['authed'])) {
    $err = $loginError;
    ?><!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Recovery File Manager - <?= h($csName) ?></title>
<style>
*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;background:#111827;color:#e5e7eb;font-family:system-ui,sans-serif}.card{width:min(380px,92vw);padding:28px;background:#1f2937;border-radius:14px;box-shadow:0 12px 40px #0006}h1{font-size:1.1rem;text-align:center;margin:0 0 8px;color:#f87171}.sub,.err,.credit{text-align:center;font-size:.8rem;color:#9ca3af}.err{color:#f87171}input,button{width:100%;padding:11px;border-radius:8px;font:inherit}input{margin-top:14px;background:#111827;border:1px solid #374151;color:#fff}button{margin-top:10px;border:0;background:#dc2626;color:#fff;cursor:pointer}button:hover{background:#b91c1c}.credit{margin-top:18px;font-size:.7rem}
</style>
</head>
<body><main class="card">
<h1>Recovery File Manager</h1><p class="sub">Codespace: <?= h($csName) ?><br>Delete-only recovery mode</p>
<form method="post" autocomplete="off"><input type="hidden" name="action" value="login"><input type="password" name="password" placeholder="Password" autocomplete="current-password" autofocus required><button>Unlock</button></form>
<?php if ($err): ?><p class="err"><?= h($err) ?></p><?php endif; ?>
<p class="credit">Made By Aryan Giri | giriaryan694-a11y</p>
</main></body></html>
<?php exit; };

$dirRel = (string) ($_GET['dir'] ?? '');
$dirPath = safe_path($dirRel, $rootfs);
if ($dirPath === null || !is_dir($dirPath)) {
    $dirRel = '';
    $dirPath = realpath($rootfs) ?: $rootfs;
}

$rootReal = realpath($rootfs) ?: $rootfs;
$displayPath = $dirPath === $rootReal
    ? '/'
    : '/' . ltrim(substr($dirPath, strlen($rootReal)), '/');
$crumbs = [['name' => '/', 'rel' => '']];
$acc = '';
foreach (array_filter(explode('/', $displayPath)) as $part) {
    $acc .= '/' . $part;
    $crumbs[] = ['name' => $part, 'rel' => ltrim($acc, '/')];
}

$entries = scan_directory($scanner, $rootfs, $dirRel);
usort($entries, static function (array $a, array $b): int {
    if (($a['is_dir'] ?? false) !== ($b['is_dir'] ?? false)) return $a['is_dir'] ? -1 : 1;
    return strcasecmp($a['name'] ?? '', $b['name'] ?? '');
});
$csrf = csrf_token();
?>
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Recovery File Manager - <?= h($csName) ?></title>
<style>
*{box-sizing:border-box}body{margin:0;padding:16px;background:#111827;color:#e5e7eb;font-family:system-ui,-apple-system,sans-serif}.wrap{max-width:1200px;margin:auto}.header{display:flex;justify-content:space-between;gap:16px;align-items:center;background:#1f2937;padding:16px;border-radius:12px 12px 0 0}.title{font-weight:700;color:#f87171}.info{font-size:.75rem;color:#9ca3af;margin-top:4px}.logout,.del-btn{background:transparent;border:1px solid #ef4444;color:#f87171;border-radius:7px;padding:7px 10px;cursor:pointer}.logout:hover,.del-btn:hover{background:#dc2626;color:#fff}.notice{margin:12px 0;padding:12px;background:#3f1d1d;border:1px solid #7f1d1d;border-radius:8px;color:#fca5a5;font-size:.82rem}.crumbs{display:flex;gap:6px;flex-wrap:wrap;padding:10px 12px;background:#172554}.crumbs a{color:#bfdbfe;text-decoration:none}.table-wrap{overflow:auto;background:#1f2937;border-radius:0 0 12px 12px}table{width:100%;border-collapse:collapse;min-width:850px}th,td{text-align:left;padding:10px 12px;border-bottom:1px solid #374151;font-size:.82rem;vertical-align:middle}th{font-size:.7rem;text-transform:uppercase;color:#9ca3af;white-space:nowrap}.name a{color:#bfdbfe;text-decoration:none}.name a:hover{text-decoration:underline}.size,.mode,.mtime{white-space:nowrap}.size{text-align:right;color:#cbd5e1}.mode{font-family:ui-monospace,SFMono-Regular,monospace;color:#d1d5db}.mode small{display:block;color:#6b7280;font-family:system-ui,sans-serif;font-size:.68rem}.mtime{color:#9ca3af}.empty{text-align:center;color:#6b7280;padding:30px}.footer{text-align:center;color:#6b7280;font-size:.7rem;padding:14px}
</style>
</head>
<body><main class="wrap">
<header class="header"><div><div class="title">Recovery File Manager</div><div class="info">Codespace: <?= h($csName) ?> · Delete-only · Parallel filesystem scan</div><div class="info">Path: <?= h($displayPath) ?></div></div><form method="post"><input type="hidden" name="action" value="logout"><button class="logout">Logout</button></form></header>
<div class="notice">This codespace was stopped after exceeding its storage quota. Browse and delete files to free space. No uploads, edits, renames, or creates.</div>
<nav class="crumbs"><?php foreach ($crumbs as $i => $crumb): ?><?php if ($i): ?><span>/</span><?php endif; ?><a href="/?dir=<?= enc($crumb['rel']) ?>"><?= h($crumb['name']) ?></a><?php endforeach; ?></nav>
<div class="table-wrap"><table><thead><tr><th>Name</th><th>Size</th><th>Permissions</th><th>Modified</th><th>Action</th></tr></thead><tbody>
<?php if (!$entries): ?><tr><td colspan="5" class="empty">Unable to read this directory or it is empty.</td></tr><?php endif; ?>
<?php foreach ($entries as $entry): ?>
<tr><td class="name">
<?php if ($entry['is_dir']): ?><a href="/?dir=<?= enc($entry['rel']) ?>"><?= h($entry['name']) ?></a><?php else: ?><?= h($entry['name']) ?><?php endif; ?>
<?php if ($entry['is_link']): ?> <small>(symlink)</small><?php endif; ?>
</td><td class="size"><?= h($entry['size_human']) ?></td>
<td class="mode" title="<?= h($entry['mode_octal']) ?>"><?= h($entry['mode_symbolic']) ?><small><?= h($entry['mode_octal']) ?></small></td>
<td class="mtime"><?= $entry['mtime'] ? h(date('Y-m-d H:i', (int)$entry['mtime'])) : '-' ?></td>
<td><form method="post" onsubmit="return confirm('Delete <?= h($entry['name']) ?>?\nThis cannot be undone.')"><input type="hidden" name="action" value="delete"><input type="hidden" name="csrf" value="<?= h($csrf) ?>"><input type="hidden" name="path" value="<?= h($entry['rel']) ?>"><button class="del-btn">Delete</button></form></td></tr>
<?php endforeach; ?>
</tbody></table></div><div class="footer">Made By Aryan Giri | giriaryan694-a11y</div>
</main></body></html>
FM_PHPEOF
  chmod 644 "$FILEMANAGER_SCRIPT" 2>/dev/null || true
  touch "$BASE_DIR/.filemanager_v2"

  FILEMANAGER_SCANNER="$BASE_DIR/filemanager_scan.py"
  cat > "$FILEMANAGER_SCANNER" << 'PYEOF'
#!/usr/bin/env python3
import argparse
import json
import os
import stat
from concurrent.futures import ThreadPoolExecutor


def human_size(value):
    units = ('B', 'KB', 'MB', 'GB', 'TB')
    size = float(value)
    for unit in units:
        if size < 1024 or unit == units[-1]:
            return f"{int(size)} {unit}" if unit == 'B' else f"{size:.1f} {unit}"
        size /= 1024


def directory_size(path):
    total = 0
    stack = [path]
    while stack:
        current = stack.pop()
        try:
            with os.scandir(current) as entries:
                for entry in entries:
                    try:
                        if entry.is_symlink():
                            continue
                        if entry.is_dir(follow_symlinks=False):
                            stack.append(entry.path)
                        else:
                            total += entry.stat(follow_symlinks=False).st_size
                    except OSError:
                        continue
        except OSError:
            continue
    return total


def scan_one(item):
    path, rel = item
    try:
        info = os.lstat(path)
    except OSError:
        return None

    is_dir = stat.S_ISDIR(info.st_mode) and not stat.S_ISLNK(info.st_mode)
    size = directory_size(path) if is_dir else info.st_size
    mode = stat.filemode(info.st_mode)
    octal = format(stat.S_IMODE(info.st_mode), '04o')
    return {
        'name': os.path.basename(path),
        'rel': rel,
        'is_dir': is_dir,
        'is_link': stat.S_ISLNK(info.st_mode),
        'size': size,
        'size_human': human_size(size),
        'mode_symbolic': mode,
        'mode_octal': octal,
        'mtime': int(info.st_mtime),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', required=True)
    parser.add_argument('--dir', default='')
    args = parser.parse_args()

    root = os.path.realpath(args.root)
    rel = args.dir.strip('/').replace('\\', '/')
    directory = os.path.realpath(os.path.join(root, rel))
    if directory != root and not directory.startswith(root + os.sep):
        raise SystemExit(2)
    if not os.path.isdir(directory):
        raise SystemExit(3)

    jobs = []
    with os.scandir(directory) as entries:
        for entry in entries:
            if entry.name in ('.', '..'):
                continue
            child_rel = f'{rel}/{entry.name}'.strip('/')
            jobs.append((entry.path, child_rel))

    # Filesystem metadata is I/O-bound. A moderate worker cap is faster on
    # phones than creating dozens of threads and keeps Termux responsive.
    cpu_count = os.cpu_count() or 2
    workers = min(8, max(2, cpu_count), len(jobs) or 1)
    with ThreadPoolExecutor(max_workers=workers) as pool:
        results = [result for result in pool.map(scan_one, jobs, chunksize=1) if result is not None]

    print(json.dumps(results, separators=(',', ':')))


if __name__ == '__main__':
    main()
PYEOF
  chmod 755 "$FILEMANAGER_SCANNER" 2>/dev/null || true
}

is_filemanager_running() {
  local name="$1"
  local pidfile="$META_DIR/$name.fm.pid"
  if [[ -f "$pidfile" ]]; then
    local pid
    pid=$(cat "$pidfile" 2>/dev/null)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

start_filemanager() {
  local name="$1"
  local rootfs="$CODESPACES_DIR/$name"
  local port pass

  [[ -d "$rootfs" ]] || return 1

  is_filemanager_running "$name" && return 0

  if ! command -v php >/dev/null 2>&1; then
    echo -e "${YELLOW}[!] php not found on host - recovery file manager disabled for '$name'.${RESET}"
    echo -e "${YELLOW}    Install it with:  apt install php -y${RESET}"
    return 1
  fi

  port=$(cat "$META_DIR/$name.port" 2>/dev/null)
  pass="$META_DIR/$name.pass"
  [[ -n "$port" ]] || return 1

  ensure_filemanager_script

  # setsid detaches the PHP server into its own session so it survives
  # stop_quota_watchdog's process-group kill (the watchdog calls
  # stop_codespace which calls this, then kills its own subshell).
  if command -v setsid >/dev/null 2>&1; then
    setsid env \
      FM_ROOTFS="$rootfs" \
      FM_PASS_FILE="$pass" \
      FM_NAME="$name" \
      FM_SCANNER="$BASE_DIR/filemanager_scan.py" \
      php -S 0.0.0.0:"$port" "$FILEMANAGER_SCRIPT" \
      > "$META_DIR/$name.fm.log" 2>&1 &
  else
    nohup env \
      FM_ROOTFS="$rootfs" \
      FM_PASS_FILE="$pass" \
      FM_NAME="$name" \
      FM_SCANNER="$BASE_DIR/filemanager_scan.py" \
      php -S 0.0.0.0:"$port" "$FILEMANAGER_SCRIPT" \
      > "$META_DIR/$name.fm.log" 2>&1 &
    disown 2>/dev/null || true
  fi
  echo $! > "$META_DIR/$name.fm.pid"
  sleep 1

  if ! is_filemanager_running "$name"; then
    echo -e "${YELLOW}[!] Recovery file manager failed to start for '$name'.${RESET}"
    echo -e "${YELLOW}    Check: cat $META_DIR/$name.fm.log${RESET}"
    return 1
  fi

  local ip
  ip=$(device_ip)
  echo -e "${GREEN}${BOLD}Recovery File Manager for '$name' is up.${RESET}"
  echo -e "  This codespace exceeded its storage quota and was stopped."
  echo -e "  Browse to it to delete files and free up space:"
  echo -e "  Local:    http://127.0.0.1:${port}"
  [[ -n "$ip" ]] && echo -e "  Network:  http://${ip}:${port}"
  echo -e "  Password: same as the code-server password for this codespace"
  echo -e "  ${YELLOW}Delete-only - no create, write, or upload.${RESET}"
  return 0
}

stop_filemanager() {
  local name="$1"
  local pidfile="$META_DIR/$name.fm.pid"
  if is_filemanager_running "$name"; then
    local pid
    pid=$(cat "$pidfile")
    kill "$pid" 2>/dev/null
    sleep 1
    kill -9 "$pid" 2>/dev/null
    echo -e "${YELLOW}Recovery file manager for '$name' stopped.${RESET}"
  fi
  rm -f "$pidfile"
}


toggle_proxy_enabled() {
  local name="$1"
  ensure_network_files "$name"
  clear; banner
  if is_proxy_enabled "$name"; then
    echo "off" > "$META_DIR/$name.proxyenabled"
    stop_network_proxy "$name"
    rm -f "$CODESPACES_DIR/$name/etc/apt/apt.conf.d/95codespace-proxy" 2>/dev/null
    echo -e "${RED}Network proxy for '$name' turned OFF.${RESET}"
    echo -e "${YELLOW}Traffic will go direct (unlogged, unfiltered) until you turn it back on.${RESET}"
    if is_running "$name"; then
      echo -e "${YELLOW}Note: it's already started with the old proxy env baked into its shell.${RESET}"
      echo -e "${YELLOW}Restart the codespace (t then Enter) for this to fully take effect.${RESET}"
    fi
  else
    echo "on" > "$META_DIR/$name.proxyenabled"
    echo -e "${GREEN}Network proxy for '$name' turned ON.${RESET}"
    if is_running "$name"; then
      start_network_proxy "$name"
      local proxy_port=""
      [[ -f "$META_DIR/$name.proxyport" ]] && proxy_port=$(cat "$META_DIR/$name.proxyport")
      write_apt_proxy_conf "$CODESPACES_DIR/$name" "$proxy_port" "on"
      echo -e "${YELLOW}Note: an already-running codespace shell won't pick up the new"
      echo -e "http_proxy/https_proxy env vars automatically. Restart it (t then Enter)"
      echo -e "or export them manually inside the CLI to route existing sessions.${RESET}"
    fi
  fi
  press_any_key
}

view_network_log() {
  local name="$1"
  ensure_network_files "$name"
  clear; banner
  echo -e "${BOLD}Network log: $name${RESET}"
  local mode
  mode=$(cat "$META_DIR/$name.netmode" 2>/dev/null || echo "open")
  if ! is_proxy_enabled "$name"; then
    echo -e "  Proxy:  ${RED}disabled${RESET} (turned off with 'p' - traffic is direct/unlogged)"
  elif is_proxy_running "$name"; then
    echo -e "  Proxy:  ${GREEN}running${RESET} on 127.0.0.1:$(cat "$META_DIR/$name.proxyport" 2>/dev/null)"
  else
    echo -e "  Proxy:  ${RED}not running${RESET} (starts the codespace to enable logging)"
  fi
  if [[ "$mode" == "restricted" ]]; then
    echo -e "  Mode:   ${RED}restricted${RESET}"
  else
    echo -e "  Mode:   ${GREEN}open${RESET}"
  fi
  echo
  echo -e "${YELLOW}Live-tailing $META_DIR/$name.netlog - press Ctrl+C to return.${RESET}"
  echo

  trap ' ' INT
  tail -n 40 -f "$META_DIR/$name.netlog" &
  local tail_pid=$!
  trap "kill $tail_pid 2>/dev/null" INT
  wait "$tail_pid" 2>/dev/null
  trap - INT
}

manage_domain_lists() {
  local name="$1"
  ensure_network_files "$name"
  while true; do
    clear; banner
    echo -e "${BOLD}Domain policy: $name${RESET}"
    local mode
    mode=$(cat "$META_DIR/$name.netmode" 2>/dev/null || echo "open")
    if [[ "$mode" == "restricted" ]]; then
      echo -e "  Mode: ${RED}restricted (default-deny)${RESET}"
    else
      echo -e "  Mode: ${GREEN}open (default-allow)${RESET}"
    fi
    echo
    echo -e "${BOLD}Blocklist${RESET} (always denied, both modes):"
    if [[ -s "$META_DIR/$name.blocklist" ]]; then
      nl -ba "$META_DIR/$name.blocklist"
    else
      echo "  (empty)"
    fi
    echo
    echo -e "${BOLD}Allowlist${RESET} (only consulted in restricted mode):"
    if [[ -s "$META_DIR/$name.allowlist" ]]; then
      nl -ba "$META_DIR/$name.allowlist"
    else
      echo "  (empty)"
    fi
    echo
    echo -e "${YELLOW}a) block a domain      x) unblock (remove from blocklist)${RESET}"
    echo -e "${YELLOW}w) allow a domain       y) remove from allowlist${RESET}"
    echo -e "${YELLOW}q) back${RESET}"
    echo
    read -rp "> " choice
    case "$choice" in
      a) read -rp "Domain to block (e.g. ads.example.com, or .example.com for all subdomains): " d
         [[ -n "$d" ]] && echo "$d" >> "$META_DIR/$name.blocklist" ;;
      x) read -rp "Line number to remove from blocklist: " ln
         [[ "$ln" =~ ^[0-9]+$ ]] && sed -i "${ln}d" "$META_DIR/$name.blocklist" ;;
      w) read -rp "Domain to allow in restricted mode: " d
         [[ -n "$d" ]] && echo "$d" >> "$META_DIR/$name.allowlist" ;;
      y) read -rp "Line number to remove from allowlist: " ln
         [[ "$ln" =~ ^[0-9]+$ ]] && sed -i "${ln}d" "$META_DIR/$name.allowlist" ;;
      q|Q) return ;;
    esac
  done
}

toggle_restricted_mode() {
  local name="$1"
  ensure_network_files "$name"
  local mode
  mode=$(cat "$META_DIR/$name.netmode" 2>/dev/null || echo "open")
  clear; banner
  if [[ "$mode" == "restricted" ]]; then
    echo "open" > "$META_DIR/$name.netmode"
    echo -e "${GREEN}Network access for '$name' set back to OPEN (blocklist still enforced).${RESET}"
  else
    echo "restricted" > "$META_DIR/$name.netmode"
    echo -e "${RED}Network access for '$name' set to RESTRICTED (default-deny).${RESET}"
    echo -e "${YELLOW}Only domains in its allowlist ('b' menu) will be reachable. Press R again to go back to open.${RESET}"
  fi
  echo -e "${CYAN}(Takes effect immediately - no restart needed.)${RESET}"
  press_any_key
}

fix_l2s_symlinks() {
  local old_rootfs="$1"
  local new_rootfs="$2"

  [[ -d "$new_rootfs/.l2s" ]] || return 0

  echo -e "${CYAN}[*] Rewriting link2symlink (l2s) symlinks...${RESET}"

  local count=0
  while IFS= read -r -d '' link; do
    local target
    target=$(readlink "$link" 2>/dev/null) || continue
    if [[ "$target" == "$old_rootfs"* ]]; then
      local new_target="${target/"$old_rootfs"/"$new_rootfs"}"
      ln -sf "$new_target" "$link"
      (( count++ )) || true
    fi
  done < <(find "$new_rootfs" -type l -print0 2>/dev/null)

  echo -e "${GREEN}    Fixed $count symlink(s).${RESET}"
}

fix_rootfs_permissions() {
  local rootfs="$1"
  echo -e "${CYAN}[*] Fixing file permissions in rootfs (chmod-000 subtrees)...${RESET}"
  find "$rootfs" -type d ! -readable -exec chmod u+rx {} + 2>/dev/null || true
  find "$rootfs" -type f ! -readable -exec chmod u+r {} + 2>/dev/null || true
}

force_https_apt_sources() {
  local rootfs="$1"
  local f
  for f in "$rootfs"/etc/apt/sources.list "$rootfs"/etc/apt/sources.list.d/*.list "$rootfs"/etc/apt/sources.list.d/*.sources; do
    [[ -f "$f" ]] || continue
    sed -i -E "s#http://(archive\.ubuntu\.com|security\.ubuntu\.com|ports\.ubuntu\.com|old-releases\.ubuntu\.com|[a-z]{2}\.archive\.ubuntu\.com)#https://\1#g" "$f" 2>/dev/null || true
  done
}

write_apt_proxy_conf() {
  local rootfs="$1" proxy_port="$2" enabled="$3"
  local conf_dir="$rootfs/etc/apt/apt.conf.d"
  mkdir -p "$conf_dir" 2>/dev/null
  if [[ "$enabled" == "on" && -n "$proxy_port" ]]; then
    cat > "$conf_dir/95codespace-proxy" <<CONF
// Managed by Termux CodeSpace - routes apt's HTTP and HTTPS
// acquisition through the per-codespace logging/filtering proxy.
Acquire::http::Proxy "http://127.0.0.1:${proxy_port}";
Acquire::https::Proxy "http://127.0.0.1:${proxy_port}";
CONF
  else
    rm -f "$conf_dir/95codespace-proxy" 2>/dev/null
  fi
}

prepare_codespace_rootfs() {
  local rootfs="$1"
  mkdir -p "$rootfs/.l2s"
  mkdir -p "$rootfs/tmp"
  chmod 1777 "$rootfs/tmp" 2>/dev/null || true
  mkdir -p "$rootfs/dev/pts"
  mkdir -p "$rootfs/dev/shm"
  mkdir -p "$rootfs/run"

  mkdir -p "$rootfs/proc"
  mkdir -p "$rootfs/sys"

  if [[ ! -s "$rootfs/etc/machine-id" ]]; then
    echo "$(cat /proc/sys/kernel/random/uuid | tr -d '-')" > "$rootfs/etc/machine-id"
  fi

  if [[ ! -f "$rootfs/usr/sbin/policy-rc.d" ]]; then
    printf '#!/bin/sh\nexit 101\n' > "$rootfs/usr/sbin/policy-rc.d"
    chmod +x "$rootfs/usr/sbin/policy-rc.d"
  fi

  if [[ -f "$rootfs/usr/bin/sudo" ]]; then
    chmod u+s "$rootfs/usr/bin/sudo" 2>/dev/null || true
  fi

  if [[ ! -f "$rootfs/usr/local/bin/sudo" ]]; then
    mkdir -p "$rootfs/usr/local/bin"
    cat > "$rootfs/usr/local/bin/sudo" << 'SUDOEOF'
#!/bin/bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|-g|-C|-p) shift 2 ;;
    --)          shift; break ;;
    -*)          shift ;;
    *)           break ;;
  esac
done
exec "$@"
SUDOEOF
    chmod +x "$rootfs/usr/local/bin/sudo"
  fi

  force_https_apt_sources "$rootfs"
}

write_codeserver_settings() {
  local rootfs="$1"
  local settings_dir="$rootfs/root/.local/share/code-server/User"
  mkdir -p "$settings_dir"
  cat > "$settings_dir/settings.json" <<'SETTINGS'
{
  "terminal.integrated.defaultProfile.linux": "bash",
  "terminal.integrated.profiles.linux": {
    "bash": { "path": "/bin/bash", "args": ["-l"] },
    "sh":   { "path": "/bin/sh" }
  },
  "terminal.integrated.env.linux": { "SHELL": "/bin/bash" }
}
SETTINGS
}

prompt_core_count() {
  local total
  total=$(nproc --all 2>/dev/null)
  [[ -z "$total" || ! "$total" =~ ^[0-9]+$ || "$total" -lt 1 ]] && total=1

  local chosen
  read -rp "CPU cores to use for pigz [detected: $total, Enter = all $total]: " chosen >&2
  chosen="${chosen:-$total}"

  if ! [[ "$chosen" =~ ^[0-9]+$ ]] || [[ "$chosen" -lt 1 ]]; then
    echo -e "${YELLOW}Invalid input, using all $total core(s).${RESET}" >&2
    chosen="$total"
  elif [[ "$chosen" -gt "$total" ]]; then
    echo -e "${YELLOW}Only $total core(s) detected, capping to $total.${RESET}" >&2
    chosen="$total"
  fi

  echo "$chosen"
}

require_pigz() {
  if command -v pigz >/dev/null 2>&1; then
    return 0
  fi
  echo -e "${RED}'pigz' is not installed.${RESET}"
  echo "Install it with:  pkg install pigz -y"
  return 1
}

export_codespace() {
  local name="$1"
  clear; banner
  echo -e "${BOLD}Export Codespace: $name${RESET}"
  echo

  if [[ ! -d "$CODESPACES_DIR/$name" ]]; then
    echo -e "${RED}Codespace '$name' not found.${RESET}"
    press_any_key; return
  fi

  require_pigz || { press_any_key; return; }

  if is_running "$name"; then
    echo -e "${YELLOW}'$name' is currently running. For a clean, consistent export it's${RESET}"
    echo -e "${YELLOW}recommended to stop it first.${RESET}"
    read -rp "Stop it now before exporting? [Y/n]: " stop_first
    if [[ ! "$stop_first" =~ ^[Nn]$ ]]; then
      stop_codespace "$name"
    fi
    echo
  fi

  read -rp "Export path (directory or full .tar.gz file path) [default: $HOME/${name}.tar.gz]: " export_path
  export_path="${export_path:-$HOME/${name}.tar.gz}"
  export_path="${export_path/#\~/$HOME}"

  if [[ -d "$export_path" ]]; then
    export_path="${export_path%/}/${name}.tar.gz"
  fi

  if [[ "$export_path" != *.tar.gz && "$export_path" != *.tgz ]]; then
    export_path="${export_path}.tar.gz"
  fi

  local export_dir
  export_dir="$(dirname "$export_path")"
  mkdir -p "$export_dir"

  if [[ -e "$export_path" ]]; then
    read -rp "File '$export_path' already exists. Overwrite? [y/N]: " overwrite
    if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
      echo "Cancelled."
      press_any_key; return
    fi
    rm -f "$export_path"
  fi

  local cores
  cores=$(prompt_core_count)

  local export_unmount_after=0
  if is_hard_quota "$name"; then
    if ! is_quota_image_mounted "$name"; then
      mount_hard_quota "$name" || { press_any_key; return; }
      export_unmount_after=1
    fi
  fi

  fix_rootfs_permissions "$CODESPACES_DIR/$name"

  local tar_excludes=()
  local p
  for p in "${PROOT_BIND_EXCLUDES[@]}"; do
    tar_excludes+=("--exclude=${name}/${p}")
  done

  local tmp_meta_dir
  tmp_meta_dir=$(mktemp -d)
  {
    echo "name=$name"
    echo "port=$(cat "$META_DIR/$name.port" 2>/dev/null)"
    echo "pass=$(cat "$META_DIR/$name.pass" 2>/dev/null)"
  } > "$tmp_meta_dir/codespace.meta"

  echo -e "${CYAN}[*] Compressing codespace '$name' with pigz (${cores} core(s)) - this can take a while for large images...${RESET}"

  tar --ignore-failed-read --warning=no-failed-read \
      "${tar_excludes[@]}" \
      -cf - -C "$CODESPACES_DIR" "$name" \
      -C "$tmp_meta_dir" "codespace.meta" \
    | pigz -p "$cores" > "$export_path"
  local pipe_status=("${PIPESTATUS[@]}")
  rm -rf "$tmp_meta_dir"

  [[ "$export_unmount_after" -eq 1 ]] && unmount_hard_quota "$name"

  if [[ "${pipe_status[0]}" -ge 2 || "${pipe_status[1]}" -ne 0 || ! -s "$export_path" ]]; then
    echo -e "${RED}Export failed (tar=${pipe_status[0]}, pigz=${pipe_status[1]}).${RESET}"
    rm -f "$export_path"
    press_any_key; return
  fi

  if [[ "${pipe_status[0]}" -eq 1 ]]; then
    echo -e "${YELLOW}[!] tar reported minor warnings (files changed during read). Archive is still valid.${RESET}"
  fi

  local size
  size=$(du -h "$export_path" 2>/dev/null | cut -f1)

  echo
  echo -e "${GREEN}${BOLD}Export complete.${RESET}"
  echo -e "  File:  $export_path"
  [[ -n "$size" ]] && echo -e "  Size:  $size"
  echo -e "  Cores: $cores"
  press_any_key
}

import_codespace() {
  clear; banner
  echo -e "${BOLD}Import Codespace${RESET}"
  echo

  require_pigz || { press_any_key; return; }

  if ! command -v tar >/dev/null 2>&1; then
    echo -e "${RED}'tar' is not installed.${RESET}"
    echo "Install it with:  pkg install tar -y"
    press_any_key; return
  fi

  read -rp "Path to codespace archive (.tar.gz / .tgz): " archive_path
  archive_path="${archive_path/#\~/$HOME}"

  if [[ ! -f "$archive_path" ]]; then
    echo -e "${RED}File not found: $archive_path${RESET}"
    press_any_key; return
  fi

  if ! pigz -t "$archive_path" >/dev/null 2>&1; then
    echo -e "${RED}'$archive_path' does not look like a valid pigz/gzip archive.${RESET}"
    press_any_key; return
  fi

  local cores
  cores=$(prompt_core_count)

  local meta name_in_zip port_in_zip pass_in_zip
  meta=$(pigz -dc -p "$cores" "$archive_path" | tar -xO -f - codespace.meta 2>/dev/null) || true
  name_in_zip=$(echo "$meta" | grep '^name=' | cut -d= -f2-)
  port_in_zip=$(echo "$meta" | grep '^port=' | cut -d= -f2-)
  pass_in_zip=$(echo "$meta" | grep '^pass=' | cut -d= -f2-)

  local default_name="${name_in_zip:-imported}"
  local new_name
  read -rp "Name for the imported codespace [default: $default_name]: " new_name
  new_name="${new_name:-$default_name}"
  new_name=$(echo "$new_name" | tr -cd 'A-Za-z0-9_-')

  if [[ -z "$new_name" ]]; then
    echo -e "${RED}Invalid name.${RESET}"
    press_any_key; return
  fi
  if [[ -d "$CODESPACES_DIR/$new_name" ]]; then
    echo -e "${RED}A codespace named '$new_name' already exists.${RESET}"
    press_any_key; return
  fi

  echo -e "${CYAN}[*] Decompressing archive with pigz (${cores} core(s)) - this can take a while for large images...${RESET}"
  local tmp_extract
  tmp_extract=$(mktemp -d)

  if ! pigz -dc -p "$cores" "$archive_path" | tar -xf - -C "$tmp_extract" 2>/dev/null; then
    echo -e "${RED}Extraction failed.${RESET}"
    rm -rf "$tmp_extract"
    press_any_key; return
  fi

  local extracted_dir
  if [[ -n "$name_in_zip" && -d "$tmp_extract/$name_in_zip" ]]; then
    extracted_dir="$tmp_extract/$name_in_zip"
  else
    extracted_dir=$(find "$tmp_extract" -mindepth 1 -maxdepth 1 -type d | head -n1)
  fi

  if [[ -z "$extracted_dir" || ! -d "$extracted_dir" ]]; then
    echo -e "${RED}Could not find a codespace rootfs inside the archive.${RESET}"
    rm -rf "$tmp_extract"
    press_any_key; return
  fi

  mv "$extracted_dir" "$CODESPACES_DIR/$new_name"
  rm -rf "$tmp_extract"

  if [[ -n "$name_in_zip" && "$name_in_zip" != "$new_name" ]]; then
    fix_l2s_symlinks "$CODESPACES_DIR/$name_in_zip" "$CODESPACES_DIR/$new_name"
  fi

  prepare_codespace_rootfs "$CODESPACES_DIR/$new_name"
  write_codeserver_settings "$CODESPACES_DIR/$new_name"
  ensure_quota_files "$new_name"

  local port_prompt="Port (leave blank to auto-assign"
  [[ -n "$port_in_zip" ]] && port_prompt+=", previous was $port_in_zip"
  port_prompt+="): "
  local user_port
  read -rp "$port_prompt" user_port
  local req_port="${user_port:-$port_in_zip}"

  local port
  port=$(find_free_port "$req_port")
  if [[ -z "$port" ]]; then
    echo -e "${RED}No free ports available in range ${PORT_RANGE_START}-${PORT_RANGE_END}.${RESET}"
    rm -rf "$CODESPACES_DIR/$new_name"
    press_any_key; return
  fi

  local pass="${pass_in_zip:-$(random_password)}"

  local cfg_dir="$CODESPACES_DIR/$new_name/root/.config/code-server"
  mkdir -p "$cfg_dir"
  cat > "$cfg_dir/config.yaml" <<CFG
bind-addr: 0.0.0.0:${port}
auth: password
password: ${pass}
cert: false
CFG

  echo "$port" > "$META_DIR/$new_name.port"
  echo "$pass" > "$META_DIR/$new_name.pass"

  echo
  echo -e "${GREEN}${BOLD}Codespace '$new_name' imported successfully.${RESET}"
  echo -e "  Port:     $port"
  echo -e "  Password: $pass"
  press_any_key
}

create_codespace() {
  clear; banner
  echo -e "${BOLD}Create a new Codespace${RESET}"
  echo

  BASE_ROOTFS="$(detect_base_rootfs)"

  if [[ -z "$BASE_ROOTFS" || ! -d "$BASE_ROOTFS" ]]; then
    echo -e "${RED}Base Ubuntu image not found. Run setup first.${RESET}"
    press_any_key; return
  fi

  read -rp "Codespace name: " name
  name=$(echo "$name" | tr -cd 'A-Za-z0-9_-')
  if [[ -z "$name" ]]; then
    echo -e "${RED}Invalid name.${RESET}"; press_any_key; return
  fi
  if [[ -d "$CODESPACES_DIR/$name" ]]; then
    echo -e "${RED}A codespace named '$name' already exists.${RESET}"; press_any_key; return
  fi

  local req_port=""
  read -rp "Port (leave blank to auto-assign from ${PORT_RANGE_START}-${PORT_RANGE_END}): " req_port

  echo -e "${CYAN}[*] Cloning base Ubuntu image - this may take a minute...${RESET}"

  if ! cp -a "$BASE_ROOTFS" "$CODESPACES_DIR/$name"; then
    echo -e "${RED}Clone failed.${RESET}"; press_any_key; return
  fi

  fix_l2s_symlinks "$BASE_ROOTFS" "$CODESPACES_DIR/$name"
  prepare_codespace_rootfs "$CODESPACES_DIR/$name"
  write_codeserver_settings "$CODESPACES_DIR/$name"
  ensure_network_files "$name"
  ensure_quota_files "$name"

  local req_quota
  read -rp "Storage quota in MB (0 or blank = unlimited): " req_quota
  if [[ "$req_quota" =~ ^[0-9]+$ ]]; then
    set_quota_mb "$name" "$req_quota"
  fi

  local port
  port=$(find_free_port "$req_port")
  if [[ -z "$port" ]]; then
    echo -e "${RED}No free ports available in range ${PORT_RANGE_START}-${PORT_RANGE_END}.${RESET}"
    rm -rf "$CODESPACES_DIR/$name"
    press_any_key; return
  fi

  local pass
  pass=$(random_password)

  local cfg_dir="$CODESPACES_DIR/$name/root/.config/code-server"
  mkdir -p "$cfg_dir"
  cat > "$cfg_dir/config.yaml" <<CFG
bind-addr: 0.0.0.0:${port}
auth: password
password: ${pass}
cert: false
CFG

  echo "$port" > "$META_DIR/$name.port"
  echo "$pass" > "$META_DIR/$name.pass"

  echo -e "${GREEN}[*] Codespace '$name' created successfully.${RESET}"
  start_codespace "$name"
}

start_codespace() {
  local name="$1"
  local rootfs="$CODESPACES_DIR/$name"
  local port pass
  port=$(cat "$META_DIR/$name.port" 2>/dev/null)
  pass=$(cat "$META_DIR/$name.pass" 2>/dev/null)

  # Stop the recovery file manager if it's running on this port -
  # code-server needs the port back.
  stop_filemanager "$name" 2>/dev/null || true

  if [[ -z "$port" ]]; then
    echo -e "${RED}No port metadata found for '$name'. Recreate the codespace.${RESET}"
    press_any_key; return
  fi

  ensure_quota_files "$name"

  if is_hard_quota "$name"; then
    if ! mount_hard_quota "$name"; then
      press_any_key; return
    fi
  fi

  local quota_mb used_mb
  quota_mb=$(get_quota_mb "$name")
  if [[ "$quota_mb" -gt 0 ]]; then
    used_mb=$(get_codespace_size_mb "$name")
    if [[ -n "$used_mb" && "$used_mb" -gt "$quota_mb" ]]; then
      echo -e "${RED}Codespace '$name' is already over its storage quota (${used_mb} MB / ${quota_mb} MB).${RESET}"
      echo -e "${YELLOW}Free up space inside it, or raise/clear the quota (press 's' in the menu), before starting.${RESET}"
      echo -e "${CYAN}[*] Launching the recovery file manager so you can delete files to free up space...${RESET}"
      start_filemanager "$name"
      press_any_key; return
    fi
  fi

  if is_running "$name"; then
    echo -e "${YELLOW}Codespace '$name' is already running (PID $(cat "$META_DIR/$name.pid")).${RESET}"
  else
    echo -e "${CYAN}[*] Starting code-server for '$name' on port $port...${RESET}"

    prepare_codespace_rootfs "$rootfs"
    write_codeserver_settings "$rootfs"
    ensure_network_files "$name"

    start_network_proxy "$name"
    local proxy_port="" proxy_env=""
    [[ -f "$META_DIR/$name.proxyport" ]] && proxy_port=$(cat "$META_DIR/$name.proxyport")

    if is_proxy_enabled "$name" && is_proxy_running "$name" && [[ -n "$proxy_port" ]]; then
      # Both HTTP and HTTPS traffic route through the same local proxy:
      # plain HTTP is terminated/re-issued, HTTPS is CONNECT-tunnelled.
      proxy_env="
export http_proxy=\"http://127.0.0.1:${proxy_port}\"
export https_proxy=\"http://127.0.0.1:${proxy_port}\"
export HTTP_PROXY=\"http://127.0.0.1:${proxy_port}\"
export HTTPS_PROXY=\"http://127.0.0.1:${proxy_port}\"
export no_proxy=\"localhost,127.0.0.1\"
export NO_PROXY=\"localhost,127.0.0.1\""
      write_apt_proxy_conf "$rootfs" "$proxy_port" "on"
    else
      write_apt_proxy_conf "$rootfs" "" "off"
    fi

    local launcher="$META_DIR/$name.launcher.sh"
    cat > "$launcher" <<LAUNCHER_EOF
#!/data/data/com.termux/files/usr/bin/bash
set -uo pipefail
unset LD_PRELOAD
mkdir -p "$PREFIX/tmp"

export HOME=/root
export USER=root
export SHELL=/bin/bash
export TERM="${TERM:-xterm-256color}"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PREFIX/bin"
export LANG=C.UTF-8
export MOZ_FAKE_NO_SANDBOX=1
export PULSE_SERVER=127.0.0.1
export PROOT_L2S_DIR="$rootfs/.l2s"
${proxy_env}

exec "$PROOT_BIN" \\
  --kill-on-exit \\
  --link2symlink \\
  --sysvipc \\
  -L \\
  --change-id=0:0 \\
  --kernel-release="6.17.0-PRoot-Distro" \\
  --rootfs="$rootfs" \\
  --cwd=/root \\
  --bind=/dev \\
  --bind=/proc \\
  --bind=/sys \\
  --bind=/dev/urandom:/dev/random \\
  --bind=/proc/self/fd:/dev/fd \\
  --bind="$rootfs/tmp:/dev/shm" \\
  --bind="$PREFIX" \\
  --bind="$PREFIX/tmp:/tmp" \\
  /bin/sh -c "exec /usr/bin/code-server --bind-addr 0.0.0.0:$port --disable-telemetry"
LAUNCHER_EOF

    chmod +x "$launcher"

    nohup bash "$launcher" > "$META_DIR/$name.log" 2>&1 &
    echo $! > "$META_DIR/$name.pid"
    sleep 3

    if ! is_running "$name"; then
      echo -e "${RED}code-server may have failed to start. Check log:${RESET}"
      echo "  cat $META_DIR/$name.log"
      echo
      tail -15 "$META_DIR/$name.log" 2>/dev/null
      echo
      echo -e "${YELLOW}Debugging steps:${RESET}"
      echo "  1. Run manually:  bash $launcher"
      echo "  2. Check proot:   $PROOT_BIN --version"
      echo "  3. Check binary:  file -L $rootfs/usr/bin/code-server"
      echo "  4. Check l2s:     ls -la $rootfs/.l2s/"
      echo "  5. Check loader:  ls -la $PREFIX/libexec/proot/loader"
    else
      rm -f "$META_DIR/$name.quota.exceeded"
      start_quota_watchdog "$name"
    fi
  fi

  local ip
  ip=$(device_ip)
  echo
  echo -e "${GREEN}${BOLD}Codespace '$name' is up.${RESET}"
  echo -e "  Local:    http://127.0.0.1:${port}"
  [[ -n "$ip" ]] && echo -e "  Network:  http://${ip}:${port}"
  echo -e "  Password: ${BOLD}${pass}${RESET}"
  echo -e "  Log:      $META_DIR/$name.log"
  echo -e "  Storage:  $(format_quota_usage "$name")"
  echo -e "${RED}Store the password securely - it won't be shown again automatically.${RESET}"
  press_any_key
}

stop_codespace() {
  local name="$1"
  local skip_fm="${2:-}"
  local pidfile="$META_DIR/$name.pid"
  if is_running "$name"; then
    local pid
    pid=$(cat "$pidfile")
    kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null
    sleep 1
    kill -9 -- -"$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null
    echo -e "${YELLOW}Codespace '$name' terminated.${RESET}"
  else
    echo -e "${YELLOW}Codespace '$name' was not running.${RESET}"
  fi
  rm -f "$pidfile"
  stop_network_proxy "$name"
  # Launch the recovery file manager if this codespace was stopped for
  # exceeding its storage quota (and the caller didn't explicitly skip it
  # with --no-fm). Done BEFORE stop_quota_watchdog because the watchdog
  # kills its own process group - the FM is setsid-detached so it survives.
  if [[ "$skip_fm" != "--no-fm" && -f "$META_DIR/$name.quota.exceeded" ]]; then
    start_filemanager "$name"
  fi
  stop_quota_watchdog "$name"
  is_hard_quota "$name" && unmount_hard_quota "$name"
}

delete_codespace() {
  local name="$1"
  clear; banner
  read -rp "Delete codespace '$name'? This cannot be undone. [y/N]: " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    stop_filemanager "$name" 2>/dev/null || true
    stop_codespace "$name" --no-fm
    rm -rf "$CODESPACES_DIR/$name"
    rm -f "$(quota_image_path "$name")"
    rm -f "$META_DIR/$name."*
    echo -e "${GREEN}Deleted '$name'.${RESET}"
  else
    echo "Cancelled."
  fi
  press_any_key
}

terminate_all() {
  clear; banner
  echo -e "${CYAN}[*] Terminating all running codespaces...${RESET}"
  local name
  while IFS= read -r name; do
    [[ -n "$name" ]] && {
      stop_filemanager "$name" 2>/dev/null || true
      stop_codespace "$name" --no-fm
    }
  done < <(list_codespaces)
  echo -e "${GREEN}All codespaces stopped.${RESET}"
  press_any_key
}

cli_codespace() {
  local name="$1"
  local rootfs="$CODESPACES_DIR/$name"

  clear
  banner
  echo -e "${CYAN}[*] Entering CLI for codespace '$name'...${RESET}"
  echo -e "${YELLOW}Type 'exit' or press Ctrl+D to return to the menu.${RESET}"

  ensure_quota_files "$name"

  if is_hard_quota "$name"; then
    if ! mount_hard_quota "$name"; then
      press_any_key; return
    fi
  fi

  local cli_quota_mb cli_used_mb
  cli_quota_mb=$(get_quota_mb "$name")
  echo -e "${YELLOW}Storage: $(format_quota_usage "$name")${RESET}"
  if [[ "$cli_quota_mb" -gt 0 ]]; then
    cli_used_mb=$(get_codespace_size_mb "$name")
    if [[ -n "$cli_used_mb" && "$cli_used_mb" -gt "$cli_quota_mb" ]]; then
      echo -e "${RED}[!] This codespace is over its storage quota. Free up space before exiting,${RESET}"
      echo -e "${RED}    or it won't be allowed to start normally until you do (or raise the quota).${RESET}"
    fi
  fi
  echo
  sleep 1

  prepare_codespace_rootfs "$rootfs"
  ensure_network_files "$name"
  start_network_proxy "$name"
  local proxy_port=""
  [[ -f "$META_DIR/$name.proxyport" ]] && proxy_port=$(cat "$META_DIR/$name.proxyport")

  if is_proxy_enabled "$name" && is_proxy_running "$name" && [[ -n "$proxy_port" ]]; then
    write_apt_proxy_conf "$rootfs" "$proxy_port" "on"
  else
    write_apt_proxy_conf "$rootfs" "" "off"
  fi

  # Use a subshell to isolate environment variable modifications
  (
    unset LD_PRELOAD
    mkdir -p "$PREFIX/tmp"

    export HOME=/root
    export USER=root
    export SHELL=/bin/bash
    export TERM="${TERM:-xterm-256color}"
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PREFIX/bin"
    export LANG=C.UTF-8
    export MOZ_FAKE_NO_SANDBOX=1
    export PULSE_SERVER=127.0.0.1
    export PROOT_L2S_DIR="$rootfs/.l2s"

    if is_proxy_enabled "$name" && is_proxy_running "$name" && [[ -n "$proxy_port" ]]; then
      export http_proxy="http://127.0.0.1:${proxy_port}"
      export https_proxy="http://127.0.0.1:${proxy_port}"
      export HTTP_PROXY="http://127.0.0.1:${proxy_port}"
      export HTTPS_PROXY="http://127.0.0.1:${proxy_port}"
      export no_proxy="localhost,127.0.0.1"
      export NO_PROXY="localhost,127.0.0.1"
    fi

    exec "$PROOT_BIN" \
      --kill-on-exit \
      --link2symlink \
      --sysvipc \
      -L \
      --change-id=0:0 \
      --kernel-release="6.17.0-PRoot-Distro" \
      --rootfs="$rootfs" \
      --cwd=/root \
      --bind=/dev \
      --bind=/proc \
      --bind=/sys \
      --bind=/dev/urandom:/dev/random \
      --bind="$rootfs/tmp:/dev/shm" \
      --bind="$PREFIX" \
      --bind="$PREFIX/tmp:/tmp" \
      /bin/bash
  )
  
  echo
  echo -e "${GREEN}[*] Exited CLI for codespace '$name'.${RESET}"
  # Only unmount if code-server isn't also running against this same
  # rootfs - otherwise we'd yank the filesystem out from under it.
  if is_hard_quota "$name" && ! is_running "$name"; then
    unmount_hard_quota "$name"
  fi
  press_any_key
}

show_codespace_info() {
  local name="$1"
  clear; banner
  echo -e "${BOLD}Codespace: $name${RESET}"
  echo
  local port pass
  port=$(cat "$META_DIR/$name.port" 2>/dev/null)
  pass=$(cat "$META_DIR/$name.pass" 2>/dev/null)
  echo -e "  Port:     ${port:-unknown}"
  echo -e "  Password: ${pass:-unknown}"
  if is_running "$name"; then
    echo -e "  Status:   ${GREEN}RUNNING${RESET} (PID $(cat "$META_DIR/$name.pid"))"
  else
    echo -e "  Status:   ${RED}STOPPED${RESET}"
  fi
  echo -e "  Rootfs:   $CODESPACES_DIR/$name"
  echo -e "  Log:      $META_DIR/$name.log"
  echo

  ensure_network_files "$name"
  local netmode
  netmode=$(cat "$META_DIR/$name.netmode" 2>/dev/null || echo "open")
  echo -e "${BOLD}Network${RESET}"
  if ! is_proxy_enabled "$name"; then
    echo -e "  Proxy:    ${RED}disabled${RESET} (all traffic direct, unlogged)"
  elif is_proxy_running "$name"; then
    echo -e "  Proxy:    ${GREEN}running${RESET} on 127.0.0.1:$(cat "$META_DIR/$name.proxyport" 2>/dev/null) (HTTP + HTTPS)"
  else
    echo -e "  Proxy:    ${YELLOW}enabled, not running${RESET} (starts with the codespace)"
  fi
  if [[ "$netmode" == "restricted" ]]; then
    echo -e "  Mode:     ${RED}restricted${RESET}"
  else
    echo -e "  Mode:     ${GREEN}open${RESET}"
  fi
  echo -e "  Blocked:  $(wc -l < "$META_DIR/$name.blocklist" 2>/dev/null | tr -d ' ') domain(s)"
  echo -e "  Netlog:   $META_DIR/$name.netlog"
  echo

  echo -e "${BOLD}Recovery File Manager${RESET}"
  if is_filemanager_running "$name"; then
    local fm_port
    fm_port=$(cat "$META_DIR/$name.port" 2>/dev/null)
    echo -e "  Status:   ${GREEN}RUNNING${RESET} on http://127.0.0.1:${fm_port}"
    echo -e "  ${YELLOW}Delete-only file manager (quota recovery mode)${RESET}"
  else
    echo -e "  Status:   ${YELLOW}not running${RESET}"
    echo -e "  ${YELLOW}(starts automatically when the codespace is stopped for exceeding its quota)${RESET}"
  fi
  echo

  ensure_quota_files "$name"
  local q_used q_quota q_mode
  q_used=$(get_codespace_size_mb "$name")
  q_quota=$(get_quota_mb "$name")
  q_mode=$(get_quota_mode "$name")
  echo -e "${BOLD}Storage${RESET}"
  if [[ "$q_quota" -eq 0 ]]; then
    echo -e "  Usage:    ${q_used:-0} MB ${YELLOW}(no quota set)${RESET}"
  else
    local pct=0
    [[ "$q_quota" -gt 0 ]] && pct=$(( q_used * 100 / q_quota ))
    local pct_color="$GREEN"
    [[ "$pct" -ge 100 ]] && pct_color="$RED"
    [[ "$pct" -ge 80 && "$pct" -lt 100 ]] && pct_color="$YELLOW"
    local mode_label="soft, polled"
    [[ "$q_mode" == "hard" ]] && mode_label="${GREEN}hard, filesystem-capped${RESET}"
    echo -e "  Usage:    ${q_used:-0} MB / ${q_quota} MB  (${pct_color}${pct}%${RESET})  [${mode_label}]"
    if [[ "$q_mode" == "hard" ]] && ! is_quota_image_mounted "$name"; then
      echo -e "  ${YELLOW}(image not currently mounted - mounts automatically on start/CLI)${RESET}"
    fi
    if [[ -f "$META_DIR/$name.quota.exceeded" ]]; then
      echo -e "  ${RED}Last stopped for exceeding its quota - see $META_DIR/$name.quota.log${RESET}"
    fi
  fi
  echo
  echo -e "${YELLOW}Actions:${RESET}"
  echo "  Enter  -> Start / Restart"
  echo "  c      -> CLI access (Terminal)"
  echo "  n      -> View live network log"
  echo "  b      -> Manage domain block/allow lists"
  echo "  R      -> Toggle restricted network mode (press again for open)"
  echo "  p      -> Turn the network proxy fully on/off"
  echo "  s      -> Set/view storage quota"
  echo "  d      -> Delete"
  echo "  t      -> Terminate (stop)"
  echo "  e      -> Export to .tar.gz (pigz, multi-core)"
  echo "  i      -> Import from .tar.gz (pigz, multi-core)"
  echo "  q      -> Back"
  press_any_key
}

manage_codespaces_menu() {
  while true; do
    local names=()
    while IFS= read -r n; do
      [[ -n "$n" ]] && names+=("$n")
    done < <(list_codespaces)

    local options=()
    for n in "${names[@]}"; do
      local status_tag size_tag
      if is_running "$n"; then
        status_tag="[running]"
      else
        status_tag="[stopped]"
      fi
      size_tag="$(get_codespace_size_mb "$n") MB"
      local n_quota n_mode
      n_quota=$(get_quota_mb "$n")
      n_mode=$(get_quota_mode "$n")
      if [[ "$n_quota" -gt 0 ]]; then
        size_tag+="/${n_quota} MB"
        [[ "$n_mode" == "hard" ]] && size_tag+=" hard"
      fi
      options+=("$n  $status_tag  ($size_tag)")
    done
    options+=("+ Create New Codespace")
    options+=("Import Codespace from .tar.gz")

    arrow_menu "Manage Codespaces" "${options[@]}"
    local action="${ARROW_MENU_RESULT%%:*}"
    local idx="${ARROW_MENU_RESULT##*:}"

    case "$action" in
      back) return ;;
      cli)
        if [[ $idx -lt ${#names[@]} ]]; then
          cli_codespace "${names[$idx]}"
        else
          clear; banner
          echo -e "${YELLOW}Select an existing codespace to access CLI first.${RESET}"
          press_any_key
        fi
        ;;
      select)
        if [[ $idx -eq ${#names[@]} ]]; then
          create_codespace
        elif [[ $idx -eq $(( ${#names[@]} + 1 )) ]]; then
          import_codespace
        else
          show_codespace_info "${names[$idx]}"
          if ! is_running "${names[$idx]}"; then
            start_codespace "${names[$idx]}"
          fi
        fi
        ;;
      netlog)
        if [[ $idx -lt ${#names[@]} ]]; then
          view_network_log "${names[$idx]}"
        else
          clear; banner
          echo -e "${YELLOW}Select an existing codespace to view its network log first.${RESET}"
          press_any_key
        fi
        ;;
      domains)
        if [[ $idx -lt ${#names[@]} ]]; then
          manage_domain_lists "${names[$idx]}"
        else
          clear; banner
          echo -e "${YELLOW}Select an existing codespace to manage its domain policy first.${RESET}"
          press_any_key
        fi
        ;;
      restrict)
        if [[ $idx -lt ${#names[@]} ]]; then
          toggle_restricted_mode "${names[$idx]}"
        else
          clear; banner
          echo -e "${YELLOW}Select an existing codespace to toggle restricted mode first.${RESET}"
          press_any_key
        fi
        ;;
      toggleproxy)
        if [[ $idx -lt ${#names[@]} ]]; then
          toggle_proxy_enabled "${names[$idx]}"
        else
          clear; banner
          echo -e "${YELLOW}Select an existing codespace to toggle its proxy first.${RESET}"
          press_any_key
        fi
        ;;
      quota)
        if [[ $idx -lt ${#names[@]} ]]; then
          set_quota_interactive "${names[$idx]}"
        else
          clear; banner
          echo -e "${YELLOW}Select an existing codespace to manage its storage quota first.${RESET}"
          press_any_key
        fi
        ;;
      delete)
        [[ $idx -lt ${#names[@]} ]] && delete_codespace "${names[$idx]}"
        ;;
      terminate)
        if [[ $idx -lt ${#names[@]} ]]; then
          clear; banner
          stop_codespace "${names[$idx]}"
          press_any_key
        fi
        ;;
      export)
        if [[ $idx -lt ${#names[@]} ]]; then
          export_codespace "${names[$idx]}"
        else
          clear; banner
          echo -e "${YELLOW}Select an existing codespace to export first.${RESET}"
          press_any_key
        fi
        ;;
      import)
        import_codespace
        ;;
    esac
  done
}

# ------------------------------------------------------------------ #
# Entry point
# ------------------------------------------------------------------ #
BASE_ROOTFS="$(detect_base_rootfs)"

if [[ -z "$BASE_ROOTFS" || ! -d "$BASE_ROOTFS" ]]; then
  run_initial_setup
  BASE_ROOTFS="$(detect_base_rootfs)"
fi

main_menu() {
  while true; do
    arrow_menu "Termux CodeSpace" "Manage Codespaces" "Terminate All" "Exit"
    local action="${ARROW_MENU_RESULT%%:*}"
    local idx="${ARROW_MENU_RESULT##*:}"

    if [[ "$action" == "back" ]]; then
      clear
      exit 0
    fi

    case "$idx" in
      0) manage_codespaces_menu ;;
      1) terminate_all ;;
      2) clear; echo "Goodbye."; exit 0 ;;
    esac
  done
}

main_menu
