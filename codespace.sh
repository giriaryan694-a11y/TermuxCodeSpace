#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Termux CodeSpace — single-file edition
# Made By Aryan Giri | giriaryan694-a11y
#
# Manages multiple isolated Ubuntu environments in Termux via proot, each
# running its own code-server instance on its own port.
#
# =============================================================================
set -uo pipefail

# ================================================================== #
# CRITICAL: Disable termux-exec BEFORE anything else.
# ================================================================== #
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

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

mkdir -p "$CODESPACES_DIR" "$META_DIR"
mkdir -p "$PREFIX/tmp"

# ================================================================== #
# PROOT_BIND_EXCLUDES — directories that proot creates inside the
# rootfs as bind-mount targets with 000 permissions.
# ================================================================== #
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
        echo -e "  ${CYAN}➤ ${options[$i]}${RESET}"
      else
        echo "    ${options[$i]}"
      fi
    done

    echo
    echo -e "${YELLOW}↑/↓ move   Enter select   c cli   n netlog   b domains   R restrict${RESET}"
    echo -e "${YELLOW}d delete   t terminate   e export   i import   q back${RESET}"

    key=$(read_key)
    case "$key" in
      $'\x1b[A') sel=$(( (sel - 1 + count) % count )) ;;
      $'\x1b[B') sel=$(( (sel + 1) % count )) ;;
      "")        ARROW_MENU_RESULT="select:$sel"; return 0 ;;
      c|C)       ARROW_MENU_RESULT="cli:$sel"; return 0 ;;
      n|N)       ARROW_MENU_RESULT="netlog:$sel"; return 0 ;;
      b|B)       ARROW_MENU_RESULT="domains:$sel"; return 0 ;;
      r|R)       ARROW_MENU_RESULT="restrict:$sel"; return 0 ;;
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

# ================================================================== #
# harden_proot_ubuntu — make Ubuntu safe for proot
# ================================================================== #
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
  '
}

# ================================================================== #
# post_apt_fix — safety net after EVERY apt operation
# ================================================================== #
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
  echo -e "${YELLOW}[*] Base Ubuntu image not found — running setup.${RESET}"
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
    echo -e "${RED}Store this somewhere safe — it will not be shown again.${RESET}"
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
# Termux host (NOT inside proot, and NOT as root — it's a plain
# python3 process owned by your normal Termux user). The launcher sets
# http_proxy/https_proxy inside the container so its traffic routes
# through it.
#
# Because this is an explicit proxy rather than a transparent
# iptables redirect, it stays fully rootless — but it can only see
# and filter what obeys http_proxy/https_proxy (i.e. plain HTTP and
# HTTPS via CONNECT). It logs and can allow/deny at the domain level
# only; it does not decrypt TLS, so paths/bodies of HTTPS requests
# are never inspected. Tools that ignore proxy env vars, or that talk
# raw TCP/UDP/DNS-over-something-else, will bypass it.
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

  if ! command -v python3 >/dev/null 2>&1; then
    echo -e "${YELLOW}[!] python3 not found on host — network logging/filtering disabled for '$name'.${RESET}"
    echo -e "${YELLOW}    Install it with: pkg install python -y${RESET}"
    return 1
  fi

  ensure_proxy_script
  ensure_network_files "$name"

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

view_network_log() {
  local name="$1"
  ensure_network_files "$name"
  clear; banner
  echo -e "${BOLD}Network log: $name${RESET}"
  local mode
  mode=$(cat "$META_DIR/$name.netmode" 2>/dev/null || echo "open")
  if is_proxy_running "$name"; then
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
  echo -e "${YELLOW}Live-tailing $META_DIR/$name.netlog — press Ctrl+C to return.${RESET}"
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
  echo -e "${CYAN}(Takes effect immediately — no restart needed.)${RESET}"
  press_any_key
}

# ================================================================== #
# fix_l2s_symlinks — rewrite absolute .l2s symlinks after cloning
# ================================================================== #
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

# ================================================================== #
# fix_rootfs_permissions — make chmod-000 subtrees readable
# ================================================================== #
fix_rootfs_permissions() {
  local rootfs="$1"
  echo -e "${CYAN}[*] Fixing file permissions in rootfs (chmod-000 subtrees)...${RESET}"
  find "$rootfs" -type d ! -readable -exec chmod u+rx {} + 2>/dev/null || true
  find "$rootfs" -type f ! -readable -exec chmod u+r {} + 2>/dev/null || true
}

# ================================================================== #
# prepare_codespace_rootfs — create required directories + safety
# ================================================================== #
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
}

# ================================================================== #
# write_codeserver_settings — write terminal profile settings.json
# ================================================================== #
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

# ================================================================== #
# prompt_core_count
# ================================================================== #
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

# ================================================================== #
# require_pigz
# ================================================================== #
require_pigz() {
  if command -v pigz >/dev/null 2>&1; then
    return 0
  fi
  echo -e "${RED}'pigz' is not installed.${RESET}"
  echo "Install it with:  pkg install pigz -y"
  return 1
}

# ================================================================== #
# export_codespace
# ================================================================== #
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

  echo -e "${CYAN}[*] Compressing codespace '$name' with pigz (${cores} core(s)) — this can take a while for large images...${RESET}"

  tar --ignore-failed-read --warning=no-failed-read \
      "${tar_excludes[@]}" \
      -cf - -C "$CODESPACES_DIR" "$name" \
      -C "$tmp_meta_dir" "codespace.meta" \
    | pigz -p "$cores" > "$export_path"
  local pipe_status=("${PIPESTATUS[@]}")
  rm -rf "$tmp_meta_dir"

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

# ================================================================== #
# import_codespace
# ================================================================== #
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

  echo -e "${CYAN}[*] Decompressing archive with pigz (${cores} core(s)) — this can take a while for large images...${RESET}"
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

  echo -e "${CYAN}[*] Cloning base Ubuntu image — this may take a minute...${RESET}"

  if ! cp -a "$BASE_ROOTFS" "$CODESPACES_DIR/$name"; then
    echo -e "${RED}Clone failed.${RESET}"; press_any_key; return
  fi

  fix_l2s_symlinks "$BASE_ROOTFS" "$CODESPACES_DIR/$name"
  prepare_codespace_rootfs "$CODESPACES_DIR/$name"
  write_codeserver_settings "$CODESPACES_DIR/$name"

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

# ================================================================== #
# start_codespace
# ================================================================== #
start_codespace() {
  local name="$1"
  local rootfs="$CODESPACES_DIR/$name"
  local port pass
  port=$(cat "$META_DIR/$name.port" 2>/dev/null)
  pass=$(cat "$META_DIR/$name.pass" 2>/dev/null)

  if [[ -z "$port" ]]; then
    echo -e "${RED}No port metadata found for '$name'. Recreate the codespace.${RESET}"
    press_any_key; return
  fi

  if is_running "$name"; then
    echo -e "${YELLOW}Codespace '$name' is already running (PID $(cat "$META_DIR/$name.pid")).${RESET}"
  else
    echo -e "${CYAN}[*] Starting code-server for '$name' on port $port...${RESET}"

    prepare_codespace_rootfs "$rootfs"
    write_codeserver_settings "$rootfs"

    start_network_proxy "$name"
    local proxy_port="" proxy_env=""
    [[ -f "$META_DIR/$name.proxyport" ]] && proxy_port=$(cat "$META_DIR/$name.proxyport")
    if is_proxy_running "$name" && [[ -n "$proxy_port" ]]; then
      proxy_env="
export http_proxy=\"http://127.0.0.1:${proxy_port}\"
export https_proxy=\"http://127.0.0.1:${proxy_port}\"
export HTTP_PROXY=\"http://127.0.0.1:${proxy_port}\"
export HTTPS_PROXY=\"http://127.0.0.1:${proxy_port}\"
export no_proxy=\"localhost,127.0.0.1\"
export NO_PROXY=\"localhost,127.0.0.1\""
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
  echo -e "${RED}Store the password securely — it won't be shown again automatically.${RESET}"
  press_any_key
}

stop_codespace() {
  local name="$1"
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
}

delete_codespace() {
  local name="$1"
  clear; banner
  read -rp "Delete codespace '$name'? This cannot be undone. [y/N]: " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    stop_codespace "$name"
    rm -rf "$CODESPACES_DIR/$name"
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
    [[ -n "$name" ]] && stop_codespace "$name"
  done < <(list_codespaces)
  echo -e "${GREEN}All codespaces stopped.${RESET}"
  press_any_key
}

# ================================================================== #
# cli_codespace — Direct terminal CLI access via proot
# ================================================================== #
cli_codespace() {
  local name="$1"
  local rootfs="$CODESPACES_DIR/$name"

  clear
  banner
  echo -e "${CYAN}[*] Entering CLI for codespace '$name'...${RESET}"
  echo -e "${YELLOW}Type 'exit' or press Ctrl+D to return to the menu.${RESET}"
  echo
  sleep 1

  prepare_codespace_rootfs "$rootfs"
  start_network_proxy "$name"
  local proxy_port=""
  [[ -f "$META_DIR/$name.proxyport" ]] && proxy_port=$(cat "$META_DIR/$name.proxyport")

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

    if is_proxy_running "$name" && [[ -n "$proxy_port" ]]; then
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
  if is_proxy_running "$name"; then
    echo -e "  Proxy:    ${GREEN}running${RESET} on 127.0.0.1:$(cat "$META_DIR/$name.proxyport" 2>/dev/null)"
  else
    echo -e "  Proxy:    ${YELLOW}not running${RESET} (starts with the codespace)"
  fi
  if [[ "$netmode" == "restricted" ]]; then
    echo -e "  Mode:     ${RED}restricted${RESET}"
  else
    echo -e "  Mode:     ${GREEN}open${RESET}"
  fi
  echo -e "  Blocked:  $(wc -l < "$META_DIR/$name.blocklist" 2>/dev/null | tr -d ' ') domain(s)"
  echo -e "  Netlog:   $META_DIR/$name.netlog"
  echo
  echo -e "${YELLOW}Actions:${RESET}"
  echo "  Enter  → Start / Restart"
  echo "  c      → CLI access (Terminal)"
  echo "  n      → View live network log"
  echo "  b      → Manage domain block/allow lists"
  echo "  R      → Toggle restricted network mode (press again for open)"
  echo "  d      → Delete"
  echo "  t      → Terminate (stop)"
  echo "  e      → Export to .tar.gz (pigz, multi-core)"
  echo "  i      → Import from .tar.gz (pigz, multi-core)"
  echo "  q      → Back"
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
      if is_running "$n"; then
        options+=("$n  [running]")
      else
        options+=("$n  [stopped]")
      fi
    done
    options+=("+ Create New Codespace")
    options+=("↓ Import Codespace from .tar.gz")

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
