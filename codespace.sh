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

  echo -e "${CYAN}[*] Updating packages and installing base tooling...${RESET}"
  proot-distro login ubuntu -- bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt update
    apt install -y sudo curl wget git python3 python3-pip ca-certificates bash
    apt upgrade -y
    # Ensure bash is the default shell for root
    chsh -s /bin/bash root 2>/dev/null || true
  '

  echo -e "${CYAN}[*] Installing code-server...${RESET}"
  proot-distro login ubuntu -- bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    curl -fsSL https://code-server.dev/install.sh | sh
    mkdir -p /root/.config/code-server
  '

  # ----------------------------------------------------------
  # NEW: Write code-server settings.json with explicit terminal
  # profile so VS Code knows exactly which shell to use.
  # Without this, VS Code auto-detects and fails in proot.
  # ----------------------------------------------------------
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

  echo -e "${CYAN}[*] Reading the generated password (if any)...${RESET}"
  local pass=""
  pass=$(proot-distro login ubuntu -- bash -c \
    'cat /root/.config/code-server/config.yaml 2>/dev/null' \
    | grep '^password:' | awk '{print $2}' 2>/dev/null) || true

  echo
  echo -e "${GREEN}${BOLD}Base setup complete.${RESET}"
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
# prepare_codespace_rootfs — create required directories
#
# proot-distro v5 creates these upfront:
#   - $ROOTFS/.l2s    (PROOT_L2S_DIR)
#   - $ROOTFS/tmp     (bound as /dev/shm, chmod 1777)
#   - $ROOTFS/dev/pts (PTY slave devices for terminal support)
# ================================================================== #
prepare_codespace_rootfs() {
  local rootfs="$1"
  mkdir -p "$rootfs/.l2s"
  mkdir -p "$rootfs/tmp"
  chmod 1777 "$rootfs/tmp" 2>/dev/null || true
  # NEW: Ensure /dev/pts exists for terminal PTY allocation
  mkdir -p "$rootfs/dev/pts"
  mkdir -p "$rootfs/dev/shm"
  mkdir -p "$rootfs/run"
}

# ================================================================== #
# write_codeserver_settings — write terminal profile settings.json
#
# Without an explicit terminal profile, VS Code auto-detects
# shells and fails in proot with "execvp(3) failed".
# Ref: https://github.com/microsoft/vscode/issues/103962
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

  # NEW: Ensure terminal settings exist in the clone
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

# Uncomment for debugging:
# export PROOT_VERBOSE=9
# export PROOT_NO_SECCOMP=1

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
