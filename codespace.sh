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

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

mkdir -p "$CODESPACES_DIR" "$META_DIR"
mkdir -p "$PREFIX/tmp"

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
    echo -e "${YELLOW}↑/↓ move   Enter select   d delete   t terminate   q back${RESET}"

    key=$(read_key)
    case "$key" in
      $'\x1b[A') sel=$(( (sel - 1 + count) % count )) ;;
      $'\x1b[B') sel=$(( (sel + 1) % count )) ;;
      "")        ARROW_MENU_RESULT="select:$sel"; return 0 ;;
      d|D)       ARROW_MENU_RESULT="delete:$sel"; return 0 ;;
      t|T)       ARROW_MENU_RESULT="terminate:$sel"; return 0 ;;
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

# ================================================================== #
# harden_proot_ubuntu — make Ubuntu safe for proot
#
# Uses dpkg-divert to permanently redirect systemd binaries.
# Unlike postinst stubbing (which dpkg overwrites on unpack),
# diversions are stored in dpkg's database and respected for
# ALL future installs AND upgrades.
#
# Ref: https://man7.org/linux/man-pages/man1/dpkg-divert.1.html
# Ref: https://github.com/sabamdarif/termux-desktop/issues/306
# ================================================================== #
harden_proot_ubuntu() {
  proot-distro login ubuntu -- bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive

    # ============================================================
    # 1. PRE-CREATE /etc/machine-id with valid UUID + newline
    # ============================================================
    if [[ ! -s /etc/machine-id ]]; then
      echo "$(cat /proc/sys/kernel/random/uuid | tr -d "-")" > /etc/machine-id
    fi

    # ============================================================
    # 2. PREVENT SERVICES FROM STARTING (no init in proot)
    # ============================================================
    printf "#!/bin/sh\nexit 101\n" > /usr/sbin/policy-rc.d
    chmod +x /usr/sbin/policy-rc.d

    # ============================================================
    # 3. dpkg-divert SYSTEMD BINARIES
    #
    # This is the KEY fix. dpkg-divert registers a permanent
    # redirect in dpkg database. When ANY package (new install
    # or upgrade) tries to install these files, dpkg puts the
    # real binary at the .real path and leaves our fake in place.
    #
    # Unlike stubbing postinst scripts (which dpkg overwrites
    # during unpack), diversions survive everything.
    # ============================================================
    divert_binary() {
      local binpath="$1"
      local divert="${binpath}.real"
      # Register diversion (--rename moves existing file if present)
      if [[ -f "$binpath" && ! -L "$binpath" ]]; then
        dpkg-divert --add --rename --divert "$divert" "$binpath" 2>/dev/null || true
      else
        dpkg-divert --add --divert "$divert" "$binpath" 2>/dev/null || true
      fi
    }

    # The binaries that systemd postinst calls and that fail in proot:
    divert_binary /usr/bin/systemd-machine-id-setup
    divert_binary /bin/systemctl
    divert_binary /usr/bin/systemctl
    divert_binary /usr/bin/systemd-sysusers
    divert_binary /usr/bin/systemd-tmpfiles
    divert_binary /usr/lib/systemd/systemd-sysusers
    divert_binary /usr/lib/systemd/systemd-tmpfiles
    divert_binary /usr/bin/systemd-firstboot
    divert_binary /usr/lib/systemd/systemd-network-generator

    # Create fake no-op scripts at the original paths
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
# proot shim — systemd binaries do not work under proot.
# This no-op replacement prevents postinst failures.
# Ref: https://github.com/sabamdarif/termux-desktop/issues/306
exit 0
FAKEBIN
      chmod +x "$binpath"
    done

    # Special case: systemd-machine-id-setup should ensure machine-id exists
    cat > /usr/bin/systemd-machine-id-setup << "MIDEOF"
#!/bin/sh
# proot shim for systemd-machine-id-setup
# Ensures /etc/machine-id exists with a valid UUID, then exits.
# The real binary calls lseek() which proot cannot emulate.
if [ ! -s /etc/machine-id ]; then
  echo "$(cat /proc/sys/kernel/random/uuid | tr -d "-")" > /etc/machine-id
fi
exit 0
MIDEOF
    chmod +x /usr/bin/systemd-machine-id-setup

    # ============================================================
    # 4. STUB POSTINST SCRIPTS (belt-and-suspenders)
    #    These WILL be overwritten by dpkg unpack, but the
    #    diverted binaries above prevent the actual failure.
    # ============================================================
    for pkg in systemd systemd-sysv systemd-timesyncd systemd-resolved \
               systemd-cryptsetup libsystemd-shared libpam-systemd \
               libnss-systemd dbus dbus-user-session; do
      script="/var/lib/dpkg/info/${pkg}.postinst"
      if [[ -f "$script" ]]; then
        printf "#!/bin/sh\nexit 0\n" > "$script"
      fi
    done

    # ============================================================
    # 5. FIX BROKEN DPKG STATE (if any from previous attempts)
    # ============================================================
    dpkg --configure --force-all -a 2>/dev/null || true
    apt --fix-broken install -y 2>/dev/null || true

    # ============================================================
    # 6. HOLD SYSTEMD PACKAGES (prevent future upgrades)
    # ============================================================
    apt-mark hold systemd systemd-sysv systemd-timesyncd \
      systemd-resolved systemd-cryptsetup libsystemd-shared \
      libpam-systemd libnss-systemd 2>/dev/null || true

    # ============================================================
    # 7. FIX SUDO for proot
    # ============================================================
    if command -v sudo >/dev/null 2>&1; then
      chmod u+s "$(command -v sudo)" 2>/dev/null || true
    fi

    mkdir -p /usr/local/bin
    cat > /usr/local/bin/sudo << "SUDOEOF"
#!/bin/bash
# proot sudo shim — already root via --change-id=0:0
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

    # ============================================================
    # 8. MASK SYSTEMD UNITS
    # ============================================================
    mkdir -p /etc/systemd/system
    for unit in systemd-resolved systemd-timesyncd systemd-networkd \
                getty@tty1 remote-fs systemd-pstore; do
      ln -sf /dev/null "/etc/systemd/system/${unit}.service" 2>/dev/null || true
    done
  '
}

# ================================================================== #
# post_apt_fix — safety net after EVERY apt operation
#
# dpkg unpack replaces postinst scripts with the real ones from
# the .deb. This function re-stubs them and re-fixes sudo.
# The dpkg-diverted binaries (from harden_proot_ubuntu) are the
# real protection; this is just belt-and-suspenders.
# ================================================================== #
post_apt_fix() {
  proot-distro login ubuntu -- bash -c '
    export DEBIAN_FRONTEND=noninteractive

    # Re-stub postinst scripts (dpkg unpack may have replaced them)
    for pkg in systemd systemd-sysv systemd-timesyncd systemd-resolved \
               systemd-cryptsetup libsystemd-shared libpam-systemd \
               libnss-systemd dbus dbus-user-session; do
      script="/var/lib/dpkg/info/${pkg}.postinst"
      if [[ -f "$script" ]]; then
        printf "#!/bin/sh\nexit 0\n" > "$script"
      fi
    done

    # Fix any broken dpkg state
    dpkg --configure --force-all -a 2>/dev/null || true

    # Re-fix sudo SUID bit (apt may have reset it)
    if command -v sudo >/dev/null 2>&1; then
      chmod u+s "$(command -v sudo)" 2>/dev/null || true
    fi

    # Re-hold systemd packages
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

  # ============================================================== #
  # STEP 1: Install Ubuntu
  # ============================================================== #
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

  # ============================================================== #
  # STEP 2: Harden proot environment (BEFORE any apt install)
  #
  # dpkg-divert systemd binaries so that when ANY future apt
  # operation installs/upgrades systemd, the real binaries go
  # to .real paths and our no-op fakes stay in place.
  # ============================================================== #
  echo -e "${CYAN}[*] Hardening proot environment (dpkg-divert, sudo, machine-id)...${RESET}"
  harden_proot_ubuntu

  # ============================================================== #
  # STEP 3: Base tooling
  # ============================================================== #
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

  # ============================================================== #
  # STEP 4: Common dev & GUI / Electron / Chromium libraries
  # ============================================================== #
  echo -e "${CYAN}[*] Installing common dev & GUI/Electron libraries...${RESET}"
  proot-distro login ubuntu -- bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive

    # --- Electron / Chromium runtime dependencies ---
    apt-get install -y --no-install-recommends \
      libatk1.0-0 \
      libatk-bridge2.0-0 \
      libcups2 \
      libdrm2 \
      libxkbcommon0 \
      libxcomposite1 \
      libxdamage1 \
      libxfixes3 \
      libxrandr2 \
      libgbm1 \
      libasound2t64 \
      libpango-1.0-0 \
      libcairo2 \
      libnss3 \
      libxshmfence1 \
      libnspr4 \
      libx11-xcb1 \
      libxcb-dri3-0 \
      libxss1 \
      libxtst6 \
      2>/dev/null || true

    # --- GTK / GUI toolkit ---
    apt-get install -y --no-install-recommends \
      libgtk-3-0 \
      libgdk-pixbuf-2.0-0 \
      libnotify4 \
      libsecret-1-0 \
      libxslt1.1 \
      2>/dev/null || true

    # --- X11 / display / virtual framebuffer ---
    apt-get install -y --no-install-recommends \
      xvfb \
      xauth \
      x11-utils \
      x11-xserver-utils \
      dbus-x11 \
      xdg-utils \
      2>/dev/null || true

    # --- Graphics / rendering ---
    apt-get install -y --no-install-recommends \
      libgl1 \
      libglu1-mesa \
      libvulkan1 \
      mesa-utils \
      2>/dev/null || true

    # --- Fonts ---
    apt-get install -y --no-install-recommends \
      fonts-liberation \
      fonts-dejavu-core \
      fonts-noto-color-emoji \
      fontconfig \
      2>/dev/null || true

    # --- Multimedia / audio ---
    apt-get install -y --no-install-recommends \
      libpulse0 \
      2>/dev/null || true
  '
  post_apt_fix

  # ============================================================== #
  # STEP 5: Install code-server
  # ============================================================== #
  echo -e "${CYAN}[*] Installing code-server...${RESET}"
  proot-distro login ubuntu -- bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    curl -fsSL https://code-server.dev/install.sh | sh
    mkdir -p /root/.config/code-server
  '
  post_apt_fix

  # ============================================================== #
  # STEP 6: Configure code-server terminal profile
  # ============================================================== #
  echo -e "${CYAN}[*] Configuring code-server terminal profile...${RESET}"
  proot-distro login ubuntu -- bash -c '
    mkdir -p /root/.local/share/code-server/User
    cat > /root/.local/share/code-server/User/settings.json <<SETTINGS
{
  "terminal.integrated.defaultProfile.linux": "bash",
  "terminal.integrated.profiles.linux": {
    "bash": {
      "path": "/bin/bash",
      "args": ["-l"]
    },
    "sh": {
      "path": "/bin/sh"
    }
  },
  "terminal.integrated.env.linux": {
    "SHELL": "/bin/bash"
  }
}
SETTINGS
  '

  # ============================================================== #
  # STEP 7: Final summary
  # ============================================================== #
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

  # Ensure machine-id exists in the clone
  if [[ ! -s "$rootfs/etc/machine-id" ]]; then
    echo "$(cat /proc/sys/kernel/random/uuid | tr -d '-')" > "$rootfs/etc/machine-id"
  fi

  # Ensure policy-rc.d exists in the clone
  if [[ ! -f "$rootfs/usr/sbin/policy-rc.d" ]]; then
    printf '#!/bin/sh\nexit 101\n' > "$rootfs/usr/sbin/policy-rc.d"
    chmod +x "$rootfs/usr/sbin/policy-rc.d"
  fi

  # Ensure sudo SUID bit is set in the clone
  if [[ -f "$rootfs/usr/bin/sudo" ]]; then
    chmod u+s "$rootfs/usr/bin/sudo" 2>/dev/null || true
  fi

  # Ensure sudo wrapper exists in the clone
  if [[ ! -f "$rootfs/usr/local/bin/sudo" ]]; then
    mkdir -p "$rootfs/usr/local/bin"
    cat > "$rootfs/usr/local/bin/sudo" << 'SUDOEOF'
#!/bin/bash
# proot sudo shim — already root via --change-id=0:0
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
    "bash": {
      "path": "/bin/bash",
      "args": ["-l"]
    },
    "sh": {
      "path": "/bin/sh"
    }
  },
  "terminal.integrated.env.linux": {
    "SHELL": "/bin/bash"
  }
}
SETTINGS
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
# start_codespace — launch code-server inside a cloned rootfs
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

    local launcher="$META_DIR/$name.launcher.sh"
    cat > "$launcher" <<LAUNCHER_EOF
#!/data/data/com.termux/files/usr/bin/bash
# Auto-generated launcher for codespace '$name' — do not edit
set -uo pipefail

# CRITICAL: disable termux-exec
unset LD_PRELOAD

# Ensure proot temp dir exists
mkdir -p "$PREFIX/tmp"

# --- Environment (matches proot-distro v5 _build_normal_env) ---
export HOME=/root
export USER=root
export SHELL=/bin/bash
export TERM="${TERM:-xterm-256color}"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PREFIX/bin"
export LANG=C.UTF-8
export MOZ_FAKE_NO_SANDBOX=1
export PULSE_SERVER=127.0.0.1
export PROOT_L2S_DIR="$rootfs/.l2s"

# --- Launch proot with full path ---
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
  echo -e "${YELLOW}Actions:${RESET}"
  echo "  Enter  → Start / Restart"
  echo "  d      → Delete"
  echo "  t      → Terminate (stop)"
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

    arrow_menu "Manage Codespaces" "${options[@]}"
    local action="${ARROW_MENU_RESULT%%:*}"
    local idx="${ARROW_MENU_RESULT##*:}"

    case "$action" in
      back) return ;;
      select)
        if [[ $idx -eq ${#names[@]} ]]; then
          create_codespace
        else
          show_codespace_info "${names[$idx]}"
          if ! is_running "${names[$idx]}"; then
            start_codespace "${names[$idx]}"
          fi
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
