#!/data/data/com.termux/files/usr/bin/bash
set -uo pipefail
unset LD_PRELOAD

BASE_DIR="$HOME/.termux-codespace"
CODESPACES_DIR="$BASE_DIR/codespaces"
META_DIR="$BASE_DIR/meta"
STATE_FILE="$BASE_DIR/.setup_done"
BASE_READY_FILE="$BASE_DIR/base/.ready"
PROOT_DISTRO_DIR="$PREFIX/var/lib/proot-distro"
BASE_IMAGE_DIR="$BASE_DIR/base"
BASE_ROOTFS="$BASE_IMAGE_DIR/rootfs"
TEMP_DISTRO_NAME="termux-codespace-base"
TEMP_ROOTFS_V5="$PROOT_DISTRO_DIR/containers/$TEMP_DISTRO_NAME/rootfs"
TEMP_ROOTFS_V4="$PROOT_DISTRO_DIR/installed-rootfs/$TEMP_DISTRO_NAME"
LEGACY_UBUNTU_ROOTFS_V5="$PROOT_DISTRO_DIR/containers/ubuntu/rootfs"
LEGACY_UBUNTU_ROOTFS_V4="$PROOT_DISTRO_DIR/installed-rootfs/ubuntu"
PROOT_BIN="$PREFIX/bin/proot"

detect_distro_rootfs() {
    local name="$1"
    local v5="$PROOT_DISTRO_DIR/containers/$name/rootfs"
    local v4="$PROOT_DISTRO_DIR/installed-rootfs/$name"
    if [[ -d "$v5" ]]; then echo "$v5"
    elif [[ -d "$v4" ]]; then echo "$v4"
    else echo ""; fi
}

TEMP_ROOTFS="$(detect_distro_rootfs "$TEMP_DISTRO_NAME")"
PORT_RANGE_START=2000
PORT_RANGE_END=3000
PROXY_PORT_RANGE_START=8000
PROXY_PORT_RANGE_END=9000
NETPROXY_SCRIPT="$BASE_DIR/proxy_server.py"

DEFAULT_QUOTA_MB=0
QUOTA_CHECK_INTERVAL=30
QUOTA_CHECK_INTERVAL_FAST=5
QUOTA_DEBOUNCE_SECONDS=1
QUOTA_IMAGES_DIR="$BASE_DIR/quota_images"
HARD_QUOTA_CAPABILITY_FILE="$BASE_DIR/.hard_quota_supported"
mkdir -p "$QUOTA_IMAGES_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
mkdir -p "$CODESPACES_DIR" "$META_DIR" "$PREFIX/tmp"

PROOT_BIND_EXCLUDES=(".l2s" "data" "dev" "proc" "sys" "storage" "sdcard" "system" "system_ext" "apex" "vendor" "product" "odm" "linkerconfig")

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

press_any_key() { echo; read -n1 -rsp "Press any key to continue..."; echo; }

read_key() {
    local key rest
    IFS= read -rsn1 key
    if [[ $key == $'\x1b' ]]; then IFS= read -rsn2 -t 0.10 rest; key+="$rest"; fi
    printf '%s' "$key"
}

ARROW_MENU_RESULT=""
arrow_menu() {
    local title="$1"; shift; local options=("$@"); local count=${#options[@]}; local sel=0; local key
    while true; do
        clear; banner; echo -e "${BOLD}${title}${RESET}"; echo
        for i in "${!options[@]}"; do
            if [[ $i -eq $sel ]]; then echo -e "  ${CYAN}> ${options[$i]}${RESET}"
            else echo "    ${options[$i]}"; fi
        done
        echo; echo -e "${YELLOW}UP/DOWN move   Enter select   c cli   n netlog   b domains   R restrict${RESET}"
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

is_port_free() {
    local port="$1"
    if grep -qs "^${port}$" "$META_DIR"/*.port 2>/dev/null; then return 1; fi
    if command -v ss >/dev/null 2>&1; then
        if ss -tlnH 2>/dev/null | grep -q ":${port} "; then return 1; fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -tln 2>/dev/null | grep -q ":${port} "; then return 1; fi
    else
        if (echo > "/dev/tcp/127.0.0.1/${port}") >/dev/null 2>&1; then return 1; fi
    fi
    return 0
}

find_free_port() {
    local preferred="${1:-}"
    if [[ -n "$preferred" ]]; then
        if is_port_free "$preferred"; then echo "$preferred"; return 0; fi
        echo -e "${YELLOW}Port $preferred is busy, picking the next free one...${RESET}" >&2
    fi
    local port
    for (( port=PORT_RANGE_START; port<=PORT_RANGE_END; port++ )); do
        if is_port_free "$port"; then echo "$port"; return 0; fi
    done
    return 1
}

is_proxy_port_free() {
    local port="$1" owner="${2:-}" f reserved

    # Ignore the requesting codespace's own saved port, but honor all others.
    for f in "$META_DIR"/*.proxyport; do
        [[ -f "$f" ]] || continue
        if [[ -n "$owner" && "$f" == "$META_DIR/$owner.proxyport" ]]; then continue; fi
        reserved=$(cat "$f" 2>/dev/null || true)
        [[ "$reserved" == "$port" ]] && return 1
    done

    if command -v ss >/dev/null 2>&1; then
        if ss -tlnH 2>/dev/null | grep -Eq "(^|[[:space:]])[^[:space:]]*:${port}([[:space:]]|$)"; then return 1; fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -tln 2>/dev/null | grep -Eq "(^|[[:space:]])[^[:space:]]*:${port}([[:space:]]|$)"; then return 1; fi
    else
        if (echo > "/dev/tcp/127.0.0.1/${port}") >/dev/null 2>&1; then return 1; fi
    fi
    return 0
}

find_free_proxy_port() {
    local owner="${1:-}" port
    for (( port=PROXY_PORT_RANGE_START; port<=PROXY_PORT_RANGE_END; port++ )); do
        if is_proxy_port_free "$port" "$owner"; then echo "$port"; return 0; fi
    done
    return 1
}

harden_proot_ubuntu() {
    proot-distro login "$TEMP_DISTRO_NAME" -- bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
if [[ ! -s /etc/machine-id ]]; then
    echo "$(cat /proc/sys/kernel/random/uuid | tr -d "-")" > /etc/machine-id
fi
printf "%s\n" "#!/bin/sh" "exit 101" > /usr/sbin/policy-rc.d
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
    printf "%s\n" "#!/bin/sh" "exit 0" > "$binpath"
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
        printf "%s\n" "#!/bin/sh" "exit 0" > "$script"
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

for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [[ -f "$f" ]] || continue
    sed -i -E "s#http://(archive\.ubuntu\.com|security\.ubuntu\.com|ports\.ubuntu\.com|old-releases\.ubuntu\.com|[a-z]{2}\.archive\.ubuntu\.com)#https://\1#g" "$f" 2>/dev/null || true
done
'
}

post_apt_fix() {
    proot-distro login "$TEMP_DISTRO_NAME" -- bash -c '
export DEBIAN_FRONTEND=noninteractive
for pkg in systemd systemd-sysv systemd-timesyncd systemd-resolved \
    systemd-cryptsetup libsystemd-shared libpam-systemd \
    libnss-systemd dbus dbus-user-session; do
    script="/var/lib/dpkg/info/${pkg}.postinst"
    if [[ -f "$script" ]]; then
        printf "%s\n" "#!/bin/sh" "exit 0" > "$script"
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

migrate_legacy_base() {
    [[ -d "$BASE_ROOTFS" ]] && return 0
    [[ -f "$STATE_FILE" ]] || return 0
    local legacy_rootfs=""
    if [[ -d "$LEGACY_UBUNTU_ROOTFS_V5" ]]; then legacy_rootfs="$LEGACY_UBUNTU_ROOTFS_V5"
    elif [[ -d "$LEGACY_UBUNTU_ROOTFS_V4" ]]; then legacy_rootfs="$LEGACY_UBUNTU_ROOTFS_V4"; fi
    [[ -n "$legacy_rootfs" ]] || return 0
    clear; banner
    echo -e "${CYAN}[*] Migrating the existing CodeSpace Ubuntu base...${RESET}"
    mkdir -p "$BASE_IMAGE_DIR"
    if ! cp -a "$legacy_rootfs" "$BASE_ROOTFS"; then
        echo -e "${RED}Failed to migrate the existing Ubuntu base.${RESET}"
        press_any_key; return 1
    fi
    if proot-distro remove ubuntu >/dev/null 2>&1; then
        echo -e "${GREEN}[+] Legacy CodeSpace Ubuntu container removed.${RESET}"
    else
        echo -e "${YELLOW}[!] Could not remove the legacy Ubuntu registration automatically.${RESET}"
    fi
    press_any_key; return 0
}

prepare_base_image() {
    local source_rootfs="$1"
    mkdir -p "$BASE_IMAGE_DIR"
    rm -f "$BASE_READY_FILE"
    rm -rf "$BASE_ROOTFS"
    if ! cp -a "$source_rootfs" "$BASE_ROOTFS"; then
        echo -e "${RED}Failed to copy the configured Ubuntu base into $BASE_ROOTFS${RESET}"
        return 1
    fi
    chmod 755 "$BASE_ROOTFS" 2>/dev/null || true
    return 0
}

resolve_rootfs_path() {
    local path="$1"
    local tgt i
    for (( i=0; i<8; i++ )); do
        if [[ -L "$path" ]]; then
            tgt=$(readlink "$path" 2>/dev/null)
            [[ -n "$tgt" ]] || return 1
            if [[ "$tgt" == /* ]]; then path="$BASE_ROOTFS$tgt"
            else path="$(dirname "$path")/$tgt"; fi
        else break; fi
    done
    if [[ -e "$path" ]]; then printf '%s' "$path"; return 0; fi
    return 1
}

base_is_ready() {
    [[ -f "$BASE_READY_FILE" && -d "$BASE_ROOTFS" ]] || return 1
    [[ -x "$BASE_ROOTFS/usr/bin/bash" ]] || return 1
    local cs candidate resolved
    for cs in usr/bin/code-server root/.local/bin/code-server usr/local/bin/code-server; do
        candidate="$BASE_ROOTFS/$cs"
        resolved=$(resolve_rootfs_path "$candidate") || continue
        [[ -x "$resolved" ]] && return 0
    done
    return 1
}

mark_base_ready() {
    mkdir -p "$BASE_IMAGE_DIR"
    printf 'ready\n' > "$BASE_READY_FILE"
    touch "$STATE_FILE"
}

cleanup_all() {
    clear; banner
    echo -e "${RED}${BOLD}Cleanup Everything${RESET}"
    echo "This permanently removes all TermuxCodeSpace data."
    read -rp "Type CLEAN to continue: " confirm
    [[ "$confirm" == "CLEAN" ]] || { echo "Cancelled."; press_any_key; return; }
    local name
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        stop_filemanager "$name" 2>/dev/null || true
        stop_codespace "$name" --no-fm 2>/dev/null || true
    done < <(list_codespaces)
    if proot-distro list 2>/dev/null | grep -q "^[[:space:]]*$TEMP_DISTRO_NAME"; then
        proot-distro remove "$TEMP_DISTRO_NAME" >/dev/null 2>&1 || true
    fi
    rm -rf "$BASE_DIR"
    mkdir -p "$CODESPACES_DIR" "$META_DIR" "$BASE_IMAGE_DIR" "$QUOTA_IMAGES_DIR"
    echo -e "${GREEN}${BOLD}TermuxCodeSpace cleanup complete.${RESET}"
    press_any_key
}

bootstrap_ca_bundle() {
    local host_ca=""
    if command -v curl-config >/dev/null 2>&1; then host_ca=$(curl-config --ca 2>/dev/null || true); fi
    if [[ -z "$host_ca" || ! -f "$host_ca" ]]; then
        for candidate in "$PREFIX/etc/tls/cert.pem" "$PREFIX/etc/ssl/certs/ca-certificates.crt" "$PREFIX/etc/ssl/cert.pem"; do
            if [[ -f "$candidate" ]]; then host_ca="$candidate"; break; fi
        done
    fi
    if [[ -n "$host_ca" && -f "$host_ca" ]]; then
        mkdir -p "$TEMP_ROOTFS/etc/ssl/certs" "$TEMP_ROOTFS/etc/ssl"
        cp -f "$host_ca" "$TEMP_ROOTFS/etc/ssl/certs/ca-certificates.crt" || true
        cp -f "$host_ca" "$TEMP_ROOTFS/etc/ssl/cert.pem" || true
        return 0
    fi
    return 0
}

apt_bootstrap_and_update() {
    proot-distro login "$TEMP_DISTRO_NAME" -- bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
CA_FILE="/etc/ssl/certs/ca-certificates.crt"
APT_CA_CONF="/etc/apt/apt.conf.d/99-codespace-ca"
write_ca_config() {
    if [[ -f "$CA_FILE" ]]; then
        printf "%s\n" "Acquire::https::CAInfo \"$CA_FILE\";" > "$APT_CA_CONF"
    fi
}
write_ca_config
if apt-get update; then
    if apt-get install -y --no-install-recommends ca-certificates 2>/dev/null; then
        update-ca-certificates 2>/dev/null || true
        rm -f "$APT_CA_CONF"
    fi
    exit 0
fi
backup_dir=$(mktemp -d)
cp -a /etc/apt/sources.list "$backup_dir/sources.list" 2>/dev/null || true
cp -a /etc/apt/sources.list.d "$backup_dir/sources.list.d" 2>/dev/null || true
restore_sources() {
    if [[ -f "$backup_dir/sources.list" ]]; then cp -f "$backup_dir/sources.list" /etc/apt/sources.list; fi
    if [[ -d "$backup_dir/sources.list.d" ]]; then rm -rf /etc/apt/sources.list.d; cp -a "$backup_dir/sources.list.d" /etc/apt/sources.list.d; fi
    rm -rf "$backup_dir"
}
trap restore_sources EXIT
for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [[ -f "$f" ]] || continue
    sed -i -E "s#https://#http://#g" "$f"
done
rm -rf /var/lib/apt/lists/*
apt-get clean
apt-get update
apt-get install -y --no-install-recommends ca-certificates openssl
update-ca-certificates
restore_sources
trap - EXIT
write_ca_config
rm -rf /var/lib/apt/lists/*
apt-get clean
update_ok=0
for attempt in 1 2 3 4 5; do
    if apt-get update; then update_ok=1; break; fi
    sleep $((attempt * 3))
done
rm -f "$APT_CA_CONF"
if [[ "$update_ok" -ne 1 ]]; then exit 20; fi
'
}

install_code_server_with_retry() {
    local attempt
    for attempt in 1 2 3 4 5; do
        if proot-distro login "$TEMP_DISTRO_NAME" -- bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/bin:/usr/local/sbin:$HOME/.local/bin:$PATH"
arch="$(dpkg --print-architecture)"
case "$arch" in
    arm64) release_arch="linux-arm64" ;;
    amd64) release_arch="linux-amd64" ;;
    *) exit 31 ;;
esac
latest_url="$(curl -fsSLI --retry 5 --retry-all-errors --connect-timeout 15 --max-time 60 -o /dev/null -w "%{url_effective}" https://github.com/coder/code-server/releases/latest)"
version="$(printf "%s" "$latest_url" | sed -n "s#.*/tag/v\([^/?#]*\).*#\1#p")"
if [[ -z "$version" ]]; then exit 32; fi
archive="code-server-${version}-${release_arch}.tar.gz"
archive_url="https://github.com/coder/code-server/releases/download/v${version}/${archive}"
tmpdir="$(mktemp -d)"
trap "rm -rf \"$tmpdir\"" EXIT
curl -fL --retry 5 --retry-delay 5 --retry-max-time 300 --retry-all-errors --connect-timeout 20 --max-time 600 "$archive_url" -o "$tmpdir/$archive"
test -s "$tmpdir/$archive"
topdir="$(tar -tzf "$tmpdir/$archive" | head -n1 | cut -d/ -f1)"
[[ -n "$topdir" ]]
tar -xzf "$tmpdir/$archive" -C "$tmpdir"
[[ -d "$tmpdir/$topdir" ]]
rm -rf "/usr/local/lib/code-server-${version}"
mkdir -p /usr/local/lib /usr/local/bin
mv "$tmpdir/$topdir" "/usr/local/lib/code-server-${version}"
ln -sfn "/usr/local/lib/code-server-${version}/bin/code-server" /usr/local/bin/code-server
command -v code-server >/dev/null 2>&1
code-server --version
mkdir -p /root/.config/code-server
'; then return 0; fi
        sleep $((attempt * 5))
    done
    return 1
}

run_initial_setup() {
    clear; banner
    if ! command -v proot-distro >/dev/null 2>&1; then exit 1; fi
    if [[ ! -x "$PROOT_BIN" ]]; then exit 1; fi
    proot-distro install ubuntu --name "$TEMP_DISTRO_NAME"
    TEMP_ROOTFS="$(detect_distro_rootfs "$TEMP_DISTRO_NAME")"
    if [[ -z "$TEMP_ROOTFS" || ! -d "$TEMP_ROOTFS" ]]; then exit 1; fi
    harden_proot_ubuntu
    bootstrap_ca_bundle
    if ! apt_bootstrap_and_update; then
        proot-distro remove "$TEMP_DISTRO_NAME" 2>/dev/null || true
        return 1
    fi
    if ! proot-distro login "$TEMP_DISTRO_NAME" -- bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
cat >/etc/apt/apt.conf.d/99-codespace-performance <<APTCONF
Acquire::Retries "5";
Acquire::http::Timeout "60";
Acquire::https::Timeout "60";
Acquire::http::Pipeline-Depth "0";
Acquire::ForceIPv4 "true";
APTCONF
apt-get install -y --no-install-recommends ca-certificates curl wget git openssh-client tar gzip xz-utils sudo bash
'; then
        proot-distro remove "$TEMP_DISTRO_NAME" 2>/dev/null || true
        return 1
    fi
    post_apt_fix
    if ! install_code_server_with_retry; then return 1; fi
    post_apt_fix
    if ! command -v php >/dev/null 2>&1; then apt update -y && apt install -y php; fi
    ensure_filemanager_script
    proot-distro login "$TEMP_DISTRO_NAME" -- bash -c '
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
    if ! proot-distro login "$TEMP_DISTRO_NAME" -- bash -c '
set -e
command -v code-server >/dev/null 2>&1
code-server --version >/dev/null 2>&1
command -v git >/dev/null 2>&1
'; then return 1; fi

    TEMP_ROOTFS="$(detect_distro_rootfs "$TEMP_DISTRO_NAME")"
    if [[ -z "$TEMP_ROOTFS" || ! -d "$TEMP_ROOTFS" ]]; then return 1; fi
    if ! prepare_base_image "$TEMP_ROOTFS"; then return 1; fi
    if proot-distro remove "$TEMP_DISTRO_NAME" >/dev/null 2>&1; then :; fi
    mark_base_ready
    press_any_key
}

list_codespaces() {
    local d
    for d in "$CODESPACES_DIR"/*/; do
        [[ -d "$d" ]] && basename "$d"
    done 2>/dev/null | sort
}

kill_tree() {
    local pid="$1" sig="${2:-TERM}"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    local kids c
    if command -v pgrep >/dev/null 2>&1; then
        kids=$(pgrep -P "$pid" 2>/dev/null || true)
    else
        kids=$(
            for st in /proc/[0-9]*/stat; do
                [[ -r "$st" ]] || continue
                c="${st#/proc/}"; c="${c%/stat}"
                p=$(awk '{print $4}' "$st" 2>/dev/null)
                [[ "$p" == "$pid" ]] && printf '%s\n' "$c"
            done
        )
    fi
    for c in $kids; do
        kill_tree "$c" "$sig"
    done
    kill -s "$sig" "$pid" 2>/dev/null || true
}

is_running() {
    local name="$1"
    local pidfile="$META_DIR/$name.pid"
    local rootfs="$CODESPACES_DIR/$name"
    local launcher="$META_DIR/$name.launcher.sh"
    [[ -f "$pidfile" ]] || return 1
    local pid
    pid=$(cat "$pidfile" 2>/dev/null | tr -cd '0-9')
    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
        rm -f "$pidfile"; return 1
    fi
    if [[ -r "/proc/$pid/cmdline" ]]; then
        local cmdline
        cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
        if [[ "$cmdline" == *"--rootfs=$rootfs"* || "$cmdline" == *"$launcher"* || "$cmdline" == *"code-server"* ]]; then
            return 0
        fi
        rm -f "$pidfile"; return 1
    fi
    return 0
}

random_password() { head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16; }
device_ip() { ip addr show 2>/dev/null | grep -oE 'inet [0-9.]+' | grep -v '127.0.0.1' | head -n1 | awk '{print $2}'; }

ensure_proxy_script() {
    cat > "$NETPROXY_SCRIPT" << 'PYEOF'
#!/usr/bin/env python3
import argparse
import datetime
import http.client
import select
import socket
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

LOG_LOCK = threading.Lock()
HOP_BY_HOP = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "proxy-connection", "te", "trailer", "transfer-encoding", "upgrade",
}


def normalize_host(value):
    value = (value or "").strip().lower().rstrip(".")
    if value.startswith("[") and value.endswith("]"):
        value = value[1:-1]
    try:
        return value.encode("idna").decode("ascii")
    except (UnicodeError, UnicodeDecodeError):
        return value


def normalize_domain_rule(value):
    value = (value or "").strip()
    if not value or value.startswith("#"):
        return ""

    value = value.lstrip(".")
    try:
        parsed = urlsplit(value if "://" in value else "//" + value)
        return normalize_host(parsed.hostname or "")
    except ValueError:
        return ""


def format_authority(host, port):
    shown = "[{}]".format(host) if ":" in host else host
    return "{}:{}".format(shown, port)


def log_line(logfile, verdict, scheme, method, host, port):
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = "[{}] {:5} {:5} {:8} {}\n".format(
        ts, verdict, scheme.upper(), method.upper(), format_authority(host, port)
    )
    try:
        with LOG_LOCK, open(logfile, "a", encoding="utf-8") as f:
            f.write(line)
            f.flush()
    except OSError:
        pass


def read_domain_list(path):
    domains = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                domain = normalize_domain_rule(line)
                if domain:
                    domains.append(domain)
    except OSError:
        pass
    return domains


def read_mode(path):
    try:
        with open(path, encoding="utf-8") as f:
            mode = f.read().strip().lower()
            if mode in ("open", "restricted"):
                return mode
    except OSError:
        pass
    return "open"


def host_matches(host, pattern):
    host = normalize_host(host)
    pattern = normalize_domain_rule(pattern)
    return bool(pattern) and (host == pattern or host.endswith("." + pattern))


def is_allowed(host, args):
    host = normalize_host(host)
    mode = read_mode(args.mode_file)
    blocklist = read_domain_list(args.blocklist)
    if any(host_matches(host, pattern) for pattern in blocklist):
        return False, mode
    if mode == "restricted":
        allowlist = read_domain_list(args.allowlist)
        return any(host_matches(host, pattern) for pattern in allowlist), mode
    return True, mode


def parse_authority(authority, require_port=False, default_port=None):
    try:
        parsed = urlsplit("//" + authority)
        host = normalize_host(parsed.hostname or "")
        port = parsed.port
    except ValueError as exc:
        raise ValueError("invalid authority") from exc

    if not host:
        raise ValueError("missing host")
    if port is None:
        if require_port:
            raise ValueError("missing port")
        port = default_port
    if not isinstance(port, int) or not 1 <= port <= 65535:
        raise ValueError("invalid port")
    return host, port


class ProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    args = None

    def log_message(self, fmt, *args):
        pass

    def _send_simple(self, status, message):
        body = (message + "\n").encode("utf-8", "replace")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
        self.close_connection = True

    def _plain_target(self):
        parsed = urlsplit(self.path)
        if parsed.scheme and parsed.hostname:
            scheme = parsed.scheme.lower()
            if scheme not in ("http", "https"):
                raise ValueError("unsupported URL scheme")
            host = normalize_host(parsed.hostname)
            port = parsed.port or (443 if scheme == "https" else 80)
            path = parsed.path or "/"
            if parsed.query:
                path += "?" + parsed.query
            return scheme, host, port, path

        host_header = self.headers.get("Host", "")
        host, port = parse_authority(host_header, default_port=80)
        path = self.path if self.path.startswith("/") else "/" + self.path
        return "http", host, port, path

    def do_CONNECT(self):
        try:
            host, port = parse_authority(self.path, require_port=True)
        except ValueError:
            self._send_simple(400, "Bad CONNECT target")
            return

        allowed, _ = is_allowed(host, self.args)
        log_line(self.args.log, "ALLOW" if allowed else "DENY", "https", "CONNECT", host, port)
        if not allowed:
            self._send_simple(403, "Domain blocked by codespace proxy")
            return

        try:
            upstream = socket.create_connection((host, port), timeout=20)
        except OSError as exc:
            self._send_simple(502, "Upstream connection failed: {}".format(exc))
            return

        self.send_response(200, "Connection Established")
        self.end_headers()
        self.wfile.flush()
        self.close_connection = True
        self._relay(self.connection, upstream)

    def _handle_plain(self, method):
        try:
            scheme, host, port, path = self._plain_target()
        except ValueError as exc:
            self._send_simple(400, "Bad proxy request: {}".format(exc))
            return

        allowed, _ = is_allowed(host, self.args)
        log_line(self.args.log, "ALLOW" if allowed else "DENY", scheme, method, host, port)
        if not allowed:
            self._send_simple(403, "Domain blocked by codespace proxy")
            return

        if "chunked" in self.headers.get("Transfer-Encoding", "").lower():
            self._send_simple(501, "Chunked request bodies are not supported")
            return

        try:
            length = int(self.headers.get("Content-Length", "0") or "0")
        except ValueError:
            self._send_simple(400, "Invalid Content-Length")
            return

        body = self.rfile.read(length) if length else None
        headers = {}
        for key, value in self.headers.items():
            if key.lower() in HOP_BY_HOP or key.lower() == "host":
                continue
            headers[key] = value
        headers["Host"] = format_authority(host, port) if port not in (80, 443) else host
        headers["Connection"] = "close"

        connection_class = http.client.HTTPSConnection if scheme == "https" else http.client.HTTPConnection
        upstream = connection_class(host, port, timeout=30)
        try:
            upstream.request(method, path, body=body, headers=headers)
            response = upstream.getresponse()
            self.send_response(response.status, response.reason)
            has_length = False
            for key, value in response.getheaders():
                lower = key.lower()
                if lower in HOP_BY_HOP:
                    continue
                if lower == "content-length":
                    has_length = True
                self.send_header(key, value)
            if not has_length:
                self.send_header("Connection", "close")
                self.close_connection = True
            self.end_headers()

            if method != "HEAD":
                while True:
                    chunk = response.read(65536)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
        except (OSError, http.client.HTTPException) as exc:
            if not self.wfile.closed:
                try:
                    self._send_simple(502, "Upstream request failed: {}".format(exc))
                except OSError:
                    pass
        finally:
            upstream.close()

    def do_GET(self): self._handle_plain("GET")
    def do_POST(self): self._handle_plain("POST")
    def do_PUT(self): self._handle_plain("PUT")
    def do_DELETE(self): self._handle_plain("DELETE")
    def do_HEAD(self): self._handle_plain("HEAD")
    def do_OPTIONS(self): self._handle_plain("OPTIONS")
    def do_PATCH(self): self._handle_plain("PATCH")

    @staticmethod
    def _relay(client, upstream):
        sockets = [client, upstream]
        try:
            while True:
                readable, _, exceptional = select.select(sockets, [], sockets, 300)
                if exceptional or not readable:
                    break
                for current in readable:
                    other = upstream if current is client else client
                    data = current.recv(65536)
                    if not data:
                        return
                    other.sendall(data)
        except OSError:
            pass
        finally:
            for current in (client, upstream):
                try:
                    current.close()
                except OSError:
                    pass


class ProxyServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--mode-file", required=True)
    parser.add_argument("--blocklist", required=True)
    parser.add_argument("--allowlist", required=True)
    args = parser.parse_args()

    ProxyHandler.args = args
    server = ProxyServer(("127.0.0.1", args.port), ProxyHandler)
    print("READY codespace proxy listening on 127.0.0.1:{}".format(args.port), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
PYEOF
    chmod 700 "$NETPROXY_SCRIPT" 2>/dev/null || true
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
    local name="$1"; ensure_quota_files "$name"
    local v; v=$(cat "$META_DIR/$name.quota" 2>/dev/null)
    [[ "$v" =~ ^[0-9]+$ ]] || v=0; echo "$v"
}
set_quota_mb() { local name="$1" mb="$2"; ensure_quota_files "$name"; echo "$mb" > "$META_DIR/$name.quota"; }
get_quota_mode() { local name="$1"; ensure_quota_files "$name"; local m; m=$(cat "$META_DIR/$name.quota.mode" 2>/dev/null); [[ "$m" == "hard" ]] && echo "hard" || echo "soft"; }
is_hard_quota() { [[ "$(get_quota_mode "$1")" == "hard" ]]; }
quota_image_path() { echo "$QUOTA_IMAGES_DIR/$1.img"; }

is_quota_image_mounted() {
    local name="$1"; local rootfs="$CODESPACES_DIR/$name"
    [[ -d "$rootfs" ]] || return 1
    if command -v mountpoint >/dev/null 2>&1; then mountpoint -q "$rootfs" 2>/dev/null
    else grep -qs " $(printf '%s' "$rootfs") " /proc/mounts 2>/dev/null; fi
}

get_codespace_size_mb() {
    local name="$1"; local rootfs="$CODESPACES_DIR/$name"
    if is_hard_quota "$name" && ! is_quota_image_mounted "$name"; then
        local img; img=$(quota_image_path "$name")
        [[ -f "$img" ]] || { echo 0; return; }
        du -sm "$img" 2>/dev/null | awk '{print $1}' | head -n1; return
    fi
    [[ -d "$rootfs" ]] || { echo 0; return; }
    local du_excludes=() p
    for p in "${PROOT_BIND_EXCLUDES[@]}"; do du_excludes+=(--exclude="$p"); done
    local out; out=$(du -sm "${du_excludes[@]}" "$rootfs" 2>/dev/null)
    if [[ -z "$out" ]]; then out=$(du -sm "$rootfs" 2>/dev/null); fi
    echo "$out" | awk '{print $1}' | head -n1
}

format_quota_usage() {
    local name="$1"; local used quota mode
    used=$(get_codespace_size_mb "$name"); quota=$(get_quota_mb "$name"); mode=$(get_quota_mode "$name")
    if [[ "$quota" -eq 0 ]]; then echo "${used:-0} MB / unlimited"
    elif [[ "$mode" == "hard" ]]; then echo "${used:-0} MB / ${quota} MB (hard)"
    elif command -v inotifywait >/dev/null 2>&1; then echo "${used:-0} MB / ${quota} MB (soft, event-driven)"
    else echo "${used:-0} MB / ${quota} MB (soft, polled)"; fi
}

is_quota_watchdog_running() {
    local name="$1"; local pidfile="$META_DIR/$name.quota.pid"
    [[ -f "$pidfile" ]] || return 1
    local pid; pid=$(cat "$pidfile" 2>/dev/null | tr -cd '0-9')
    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then rm -f "$pidfile"; return 1; fi
    if [[ -r "/proc/$pid/cmdline" ]]; then
        local cmdline; cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
        if [[ "$cmdline" == *"inotifywait"* || "$cmdline" == *"sleep"* ]]; then return 0; fi
        rm -f "$pidfile"; return 1
    fi
    return 0
}

start_quota_watchdog() {
    local name="$1"; ensure_quota_files "$name"
    is_hard_quota "$name" && return 0
    local quota; quota=$(get_quota_mb "$name")
    [[ "$quota" -eq 0 ]] && return 0
    is_quota_watchdog_running "$name" && return 0
    local rootfs="$CODESPACES_DIR/$name"
    local events_file="$META_DIR/$name.quota.events"
    : > "$events_file"
    _quota_check_once() {
        is_running "$name" || return 2
        is_hard_quota "$name" && return 2
        local q used ts; q=$(get_quota_mb "$name")
        [[ "$q" -eq 0 ]] && return 2
        used=$(get_codespace_size_mb "$name")
        if [[ -n "$used" && "$used" -gt "$q" ]]; then
            ts=$(date "+%Y-%m-%d %H:%M:%S")
            echo "[$ts] QUOTA EXCEEDED: ${used}MB > ${q}MB" >> "$META_DIR/$name.quota.log"
            touch "$META_DIR/$name.quota.exceeded"
            stop_codespace "$name"
            return 1
        fi
        return 0
    }
    (
        local iw_pid=""
        if command -v inotifywait >/dev/null 2>&1; then
            inotifywait -m -r -q -e close_write,create,moved_to,delete,modify --exclude '/(proc|sys|dev|tmp|run)(/|$)' "$rootfs" >> "$events_file" 2>>"$META_DIR/$name.quota.log" &
            iw_pid=$!
            sleep 1
            if ! kill -0 "$iw_pid" 2>/dev/null; then iw_pid=""; fi
        fi
        if [[ -n "$iw_pid" ]]; then
            while kill -0 "$iw_pid" 2>/dev/null; do
                _quota_check_once; local rc=$?
                [[ "$rc" -ne 0 ]] && break
                if [[ -s "$events_file" ]]; then : > "$events_file"; fi
                sleep "$QUOTA_DEBOUNCE_SECONDS"
            done
            kill "$iw_pid" 2>/dev/null
        else
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
    local name="$1"; local pidfile="$META_DIR/$name.quota.pid"
    if is_quota_watchdog_running "$name"; then
        local pid; pid=$(cat "$pidfile" 2>/dev/null | tr -cd '0-9')
        kill_tree "$pid" TERM; sleep 1; kill_tree "$pid" KILL
    fi
    rm -f "$pidfile" "$META_DIR/$name.quota.events"
    if command -v pkill >/dev/null 2>&1; then pkill -f "inotifywait.*${CODESPACES_DIR}/${name}\$" 2>/dev/null || true; fi
}

hard_quota_supported() {
    if [[ -f "$HARD_QUOTA_CAPABILITY_FILE" ]]; then [[ "$(cat "$HARD_QUOTA_CAPABILITY_FILE" 2>/dev/null)" == "yes" ]]; return; fi
    local result="no"
    if command -v mount >/dev/null 2>&1 && command -v umount >/dev/null 2>&1 && command -v mkfs.ext4 >/dev/null 2>&1 && [[ "$(id -u)" -eq 0 ]]; then
        local test_img test_mnt
        test_img=$(mktemp -u "${QUOTA_IMAGES_DIR}/.cap_test.XXXXXX.img")
        test_mnt=$(mktemp -d "${QUOTA_IMAGES_DIR}/.cap_test.XXXXXX.mnt")
        if truncate -s 8M "$test_img" 2>/dev/null && mkfs.ext4 -q -F "$test_img" >/dev/null 2>&1 && mount -o loop "$test_img" "$test_mnt" >/dev/null 2>&1; then
            umount "$test_mnt" >/dev/null 2>&1; result="yes"
        fi
        rm -f "$test_img"; rmdir "$test_mnt" 2>/dev/null
    fi
    echo "$result" > "$HARD_QUOTA_CAPABILITY_FILE"
    [[ "$result" == "yes" ]]
}

mount_hard_quota() {
    local name="$1"; local rootfs="$CODESPACES_DIR/$name"; local img
    img=$(quota_image_path "$name")
    is_quota_image_mounted "$name" && return 0
    [[ -f "$img" ]] || { echo -e "${RED}Hard-quota image missing.${RESET}"; return 1; }
    mkdir -p "$rootfs"
    mount -o loop "$img" "$rootfs" >/dev/null 2>&1 || { echo -e "${RED}Mount failed.${RESET}"; return 1; }
    return 0
}

unmount_hard_quota() {
    local name="$1"; local rootfs="$CODESPACES_DIR/$name"
    is_quota_image_mounted "$name" || return 0
    sync 2>/dev/null
    umount "$rootfs" >/dev/null 2>&1 || { sleep 1; umount "$rootfs" >/dev/null 2>&1; }
}

enable_hard_quota() {
    local name="$1" quota_mb="$2"; local rootfs="$CODESPACES_DIR/$name"; local img
    img=$(quota_image_path "$name")
    hard_quota_supported || { echo -e "${RED}Hard quotas unsupported.${RESET}"; return 1; }
    [[ "$quota_mb" -lt 64 ]] && { echo -e "${RED}Min 64MB.${RESET}"; return 1; }
    local was_running=0
    if is_running "$name"; then was_running=1; stop_filemanager "$name" 2>/dev/null || true; stop_codespace "$name" --no-fm; fi
    unmount_hard_quota "$name"
    local current_used_mb; current_used_mb=$(du -sm "$rootfs" 2>/dev/null | awk '{print $1}')
    if [[ -n "$current_used_mb" && "$current_used_mb" -gt 0 ]]; then
        local headroom_mb=$(( current_used_mb + current_used_mb / 5 + 32 ))
        [[ "$quota_mb" -lt "$headroom_mb" ]] && { echo -e "${RED}Too small.${RESET}"; return 1; }
    fi
    truncate -s "${quota_mb}M" "$img" 2>/dev/null || { echo -e "${RED}Alloc failed.${RESET}"; return 1; }
    mkfs.ext4 -q -F "$img" >/dev/null 2>&1 || { rm -f "$img"; return 1; }
    local staging; staging=$(mktemp -d "${QUOTA_IMAGES_DIR}/.mount.${name}.XXXXXX")
    mount -o loop "$img" "$staging" >/dev/null 2>&1 || { rm -f "$img"; rmdir "$staging"; return 1; }
    cp -a "$rootfs/." "$staging/" 2>/dev/null || { umount "$staging"; rmdir "$staging"; rm -f "$img"; return 1; }
    umount "$staging"; rmdir "$staging"
    local backup_dir="${rootfs}.pre-hardquota"
    rm -rf "$backup_dir"; mv "$rootfs" "$backup_dir"; mkdir -p "$rootfs"
    mount -o loop "$img" "$rootfs" >/dev/null 2>&1 || { rmdir "$rootfs"; mv "$backup_dir" "$rootfs"; rm -f "$img"; return 1; }
    rm -rf "$backup_dir"
    echo "hard" > "$META_DIR/$name.quota.mode"
    set_quota_mb "$name" "$quota_mb"
    rm -f "$META_DIR/$name.quota.exceeded"
    stop_quota_watchdog "$name"
    [[ "$was_running" -eq 1 ]] && start_codespace "$name"
    return 0
}

disable_hard_quota() {
    local name="$1"; local rootfs="$CODESPACES_DIR/$name"; local img
    img=$(quota_image_path "$name")
    local was_running=0
    if is_running "$name"; then was_running=1; stop_filemanager "$name" 2>/dev/null || true; stop_codespace "$name" --no-fm; fi
    mount_hard_quota "$name" || return 1
    local plain_dir="${rootfs}.plain"; rm -rf "$plain_dir"; mkdir -p "$plain_dir"
    cp -a "$rootfs/." "$plain_dir/" 2>/dev/null || { rm -rf "$plain_dir"; return 1; }
    unmount_hard_quota "$name"; rmdir "$rootfs"; mv "$plain_dir" "$rootfs"; rm -f "$img"
    echo "soft" > "$META_DIR/$name.quota.mode"
    [[ "$was_running" -eq 1 ]] && start_codespace "$name"
    return 0
}

resize_hard_quota() {
    local name="$1" new_mb="$2"; local img; img=$(quota_image_path "$name")
    local cur_mb; cur_mb=$(get_quota_mb "$name")
    [[ "$new_mb" -le "$cur_mb" ]] && return 1
    truncate -s "${new_mb}M" "$img" 2>/dev/null || return 1
    if is_quota_image_mounted "$name"; then resize2fs "$img" >/dev/null 2>&1
    else
        if command -v losetup >/dev/null 2>&1; then
            local dev; dev=$(losetup -f --show "$img" 2>/dev/null)
            if [[ -n "$dev" ]]; then resize2fs "$dev" >/dev/null 2>&1; losetup -d "$dev" >/dev/null 2>&1; fi
        fi
    fi
    set_quota_mb "$name" "$new_mb"; return 0
}

set_quota_interactive() {
    local name="$1"; ensure_quota_files "$name"; clear; banner
    echo -e "${BOLD}Storage quota: $name${RESET}"
    echo -e "  Current usage: $(format_quota_usage "$name")"
    local mode; mode=$(get_quota_mode "$name")
    local hq_ok=0; hard_quota_supported && hq_ok=1
    if [[ "$hq_ok" -eq 1 ]]; then
        echo "  1) Set soft limit  2) Set hard limit  3) Grow hard  4) Disable hard  0) Cancel"
        read -rp "> " menu_choice
        case "$menu_choice" in
            1) read -rp "Soft MB (0=unlim): " q; [[ "$q" =~ ^[0-9]+$ ]] && { [[ "$mode" == "hard" ]] && disable_hard_quota "$name"; set_quota_mb "$name" "$q"; [[ "$q" -eq 0 ]] && stop_quota_watchdog "$name" || { is_running "$name" && start_quota_watchdog "$name"; }; } ;;
            2) read -rp "Hard MB: " q; [[ "$q" =~ ^[0-9]+$ ]] && enable_hard_quota "$name" "$q" ;;
            3) [[ "$mode" == "hard" ]] && { read -rp "New MB: " q; [[ "$q" =~ ^[0-9]+$ ]] && resize_hard_quota "$name" "$q"; } ;;
            4) [[ "$mode" == "hard" ]] && disable_hard_quota "$name" ;;
        esac
    else
        read -rp "Soft MB (0=unlim, blank=keep): " q
        if [[ -n "$q" && "$q" =~ ^[0-9]+$ ]]; then
            set_quota_mb "$name" "$q"
            [[ "$q" -eq 0 ]] && stop_quota_watchdog "$name" || { is_running "$name" && start_quota_watchdog "$name"; }
        fi
    fi
    press_any_key
}

is_proxy_enabled() { local name="$1"; local state; state=$(cat "$META_DIR/$name.proxyenabled" 2>/dev/null || echo "on"); [[ "$state" == "on" ]]; }


proxy_status_plain() {
    local name="$1" port
    ensure_network_files "$name"
    if ! is_proxy_enabled "$name"; then
        echo "proxy:off"
    elif is_proxy_running "$name"; then
        port=$(cat "$META_DIR/$name.proxyport" 2>/dev/null || true)
        echo "proxy:on:${port:-?}"
    elif is_running "$name"; then
        echo "proxy:on:error"
    else
        echo "proxy:on"
    fi
}

proxy_status_colored() {
    local name="$1" port
    ensure_network_files "$name"
    if ! is_proxy_enabled "$name"; then
        echo -e "${RED}OFF${RESET} (press p to enable)"
    elif is_proxy_running "$name"; then
        port=$(cat "$META_DIR/$name.proxyport" 2>/dev/null || true)
        echo -e "${GREEN}ON${RESET} (running on 127.0.0.1:${port:-?})"
    elif is_running "$name"; then
        echo -e "${RED}ON but proxy failed to start${RESET}"
    else
        echo -e "${YELLOW}ON${RESET} (starts automatically with the codespace)"
    fi
}

recent_domains() {
    local name="$1" limit="${2:-20}" logf="$META_DIR/$name.netlog"
    [[ -f "$logf" ]] || return 0
    awk 'NF { print $NF }' "$logf" 2>/dev/null \
        | sed -E 's/:([0-9]+)$//; s/^\[//; s/\]$//' \
        | awk 'NF && !seen[$0]++' \
        | tail -n "$limit"
}

normalize_domain_input() {
    local raw="$1"
    python3 - "$raw" <<'PYEOF'
import sys
from urllib.parse import urlsplit
raw = sys.argv[1].strip().lstrip(".")
try:
    parsed = urlsplit(raw if "://" in raw else "//" + raw)
    host = (parsed.hostname or "").strip().lower().rstrip(".")
    if host:
        print(host.encode("idna").decode("ascii"))
except (ValueError, UnicodeError):
    pass
PYEOF
}

proxy_pid_alive() {
    local name="$1" pidfile="$META_DIR/$1.proxy.pid" pid
    [[ -f "$pidfile" ]] || return 1
    pid=$(cat "$pidfile" 2>/dev/null | tr -cd '0-9')
    [[ -n "$pid" ]] || { rm -f "$pidfile"; return 1; }
    kill -0 "$pid" 2>/dev/null || { rm -f "$pidfile"; return 1; }
    return 0
}

proxy_port_is_listening() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (exec 3<>"/dev/tcp/127.0.0.1/$port"; exec 3>&-; exec 3<&-) >/dev/null 2>&1
}

is_proxy_running() {
    local name="$1" port
    proxy_pid_alive "$name" || return 1
    port=$(cat "$META_DIR/$name.proxyport" 2>/dev/null || true)
    proxy_port_is_listening "$port"
}

wait_for_proxy_ready() {
    local name="$1" attempts="${2:-50}" port i
    port=$(cat "$META_DIR/$name.proxyport" 2>/dev/null || true)
    for ((i=0; i<attempts; i++)); do
        proxy_pid_alive "$name" || return 1
        proxy_port_is_listening "$port" && return 0
        sleep 0.1
    done
    return 1
}

start_network_proxy() {
    local name="$1" proxy_port="" pid logf
    ensure_network_files "$name"
    is_proxy_enabled "$name" || return 1

    if ! command -v python3 >/dev/null 2>&1; then
        echo -e "${RED}[!] python3 is not installed in Termux.${RESET}" >&2
        echo -e "${YELLOW}    Install it with: pkg install python${RESET}" >&2
        return 1
    fi

    ensure_proxy_script
    is_proxy_running "$name" && return 0

    # Kill a stale process recorded in the PID file before starting another one.
    if proxy_pid_alive "$name"; then stop_network_proxy "$name"; fi

    if [[ -f "$META_DIR/$name.proxyport" ]]; then
        proxy_port=$(cat "$META_DIR/$name.proxyport" 2>/dev/null || true)
        is_proxy_port_free "$proxy_port" "$name" || proxy_port=""
    fi
    [[ -z "$proxy_port" ]] && proxy_port=$(find_free_proxy_port "$name")
    if [[ -z "$proxy_port" ]]; then
        echo -e "${RED}[!] No free proxy port in $PROXY_PORT_RANGE_START-$PROXY_PORT_RANGE_END.${RESET}" >&2
        return 1
    fi

    echo "$proxy_port" > "$META_DIR/$name.proxyport"
    logf="$META_DIR/$name.proxy.log"
    : > "$logf"

    if command -v setsid >/dev/null 2>&1; then
        nohup setsid python3 -u "$NETPROXY_SCRIPT" \
            --port "$proxy_port" \
            --log "$META_DIR/$name.netlog" \
            --mode-file "$META_DIR/$name.netmode" \
            --blocklist "$META_DIR/$name.blocklist" \
            --allowlist "$META_DIR/$name.allowlist" \
            </dev/null >"$logf" 2>&1 &
    else
        nohup python3 -u "$NETPROXY_SCRIPT" \
            --port "$proxy_port" \
            --log "$META_DIR/$name.netlog" \
            --mode-file "$META_DIR/$name.netmode" \
            --blocklist "$META_DIR/$name.blocklist" \
            --allowlist "$META_DIR/$name.allowlist" \
            </dev/null >"$logf" 2>&1 &
    fi
    pid=$!
    echo "$pid" > "$META_DIR/$name.proxy.pid"

    if ! wait_for_proxy_ready "$name" 50; then
        echo -e "${RED}[!] Proxy failed to become ready.${RESET}" >&2
        echo -e "${YELLOW}    Python: $(python3 --version 2>&1)${RESET}" >&2
        echo -e "${YELLOW}    Script: $NETPROXY_SCRIPT${RESET}" >&2
        echo -e "${YELLOW}    PID: $pid   Port: $proxy_port${RESET}" >&2
        if [[ -s "$logf" ]]; then
            echo -e "${YELLOW}---- proxy log ----${RESET}" >&2
            tail -n 30 "$logf" >&2
            echo -e "${YELLOW}-------------------${RESET}" >&2
        else
            echo -e "${YELLOW}    Proxy log is empty.${RESET}" >&2
        fi
        stop_network_proxy "$name"
        return 1
    fi
    return 0
}

stop_network_proxy() {
    local name="$1" pidfile="$META_DIR/$1.proxy.pid" pid
    if [[ -f "$pidfile" ]]; then
        pid=$(cat "$pidfile" 2>/dev/null | tr -cd '0-9')
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill_tree "$pid" TERM
            sleep 1
            kill -0 "$pid" 2>/dev/null && kill_tree "$pid" KILL
        fi
    fi
    rm -f "$pidfile"
}

FILEMANAGER_SCRIPT="$BASE_DIR/filemanager.php"
ensure_filemanager_script() {
    if [[ -f "$FILEMANAGER_SCRIPT" && -f "$BASE_DIR/.filemanager_v3" ]]; then return 0; fi
    cat > "$FILEMANAGER_SCRIPT" << 'FM_PHPEOF'
<?php
ini_set('session.use_strict_mode', '1'); ini_set('session.use_only_cookies', '1'); ini_set('session.cookie_httponly', '1'); session_start();
$rootfs = getenv('FM_ROOTFS') ?: '/'; $passFile = getenv('FM_PASS_FILE') ?: ''; $csName = getenv('FM_NAME') ?: 'codespace';
$authPass = ''; if ($passFile !== '' && is_file($passFile)) $authPass = trim(file_get_contents($passFile));
function csrf_token() { if (empty($_SESSION['csrf'])) $_SESSION['csrf'] = bin2hex(random_bytes(32)); return $_SESSION['csrf']; }
function check_csrf($t) { return !empty($_SESSION['csrf']) && hash_equals($_SESSION['csrf'], $t ?? ''); }
function safe_path($rel, $rootfs) {
    $root = realpath($rootfs); if (!$root) return null; $rel = str_replace("\0", '', $rel);
    if ($rel === '' || $rel === '.' || $rel === '/') return $root;
    $c = $root . DIRECTORY_SEPARATOR . ltrim(str_replace('\\', '/', $rel), '/'); $r = realpath($c);
    if ($r) return ($r === $root || str_starts_with($r, $root . DIRECTORY_SEPARATOR)) ? $r : null;
    $parts = []; foreach (explode('/', trim(str_replace('\\', '/', $rel), '/')) as $p) { if ($p === '' || $p === '.') continue; if ($p === '..') { array_pop($parts); continue; } $parts[] = $p; }
    $n = $root . DIRECTORY_SEPARATOR . implode(DIRECTORY_SEPARATOR, $parts); return str_starts_with($n, $root . DIRECTORY_SEPARATOR) ? $n : null;
}
function del_dir($d) { $i = @scandir($d); if (!$i) return false; $ok = true; foreach ($i as $x) { if ($x === '.' || $x === '..') continue; $p = $d.'/'.$x; $ok = (is_dir($p) && !is_link($p) ? del_dir($p) : @unlink($p)) && $ok; } return @rmdir($d) && $ok; }
function h($v) { return htmlspecialchars($v, ENT_QUOTES, 'UTF-8'); }
function enc($v) { return rawurlencode($v); }
function human_size($b) { if ($b<1024) return $b.' B'; if ($b<1048576) return round($b/1024,1).' KB'; if ($b<1073741824) return round($b/1048576,1).' MB'; return round($b/1073741824,2).' GB'; }
function dir_size($p) { $t=0; $s=[$p]; while($s) { $c=array_pop($s); $i=@scandir($c); if(!$i) continue; foreach($i as $n) { if($n=='.'||$n=='..') continue; $ch=$c.'/'.$n; if(@is_link($ch)) continue; if(@is_dir($ch)) $s[]=$ch; else $t+=(int)(@filesize($ch)?:0); } } return $t; }
function scan($d, $r) {
    $e = @scandir($d); if (!$e) return []; $res = [];
    foreach ($e as $n) { if ($n==='.'||$n==='..') continue; $p=$d.'/'.$n; $il=@is_link($p); $st=@lstat($p); $id=$st&&!$il&&(($st['mode']&0170000)===0040000);
        $b=$id?dir_size($p):(int)($st['size']??0); $res[]=['name'=>$n, 'rel'=>($r?$r.'/':'').$n, 'is_dir'=>$id, 'is_link'=>$il, 'size'=>$b, 'size_human'=>human_size($b), 'mtime'=>(int)(@filemtime($p)?:0)]; }
    return $res;
}
if (!isset($_SESSION['attempts'])) $_SESSION['attempts']=0; if (!isset($_SESSION['lockuntil'])) $_SESSION['lockuntil']=0; $err=null;
if ($_SERVER['REQUEST_METHOD']==='POST') {
    $a=$_POST['action']??'';
    if ($a==='login') {
        if (time()<$_SESSION['lockuntil']) { http_response_code(429); exit("Wait ".($_SESSION['lockuntil']-time())."s."); }
        if ($authPass!=='' && hash_equals($authPass, (string)($_POST['password']??''))) { $_SESSION['authed']=true; session_regenerate_id(true); header('Location: /'); exit; }
        if (++$_SESSION['attempts']>=5) { $_SESSION['lockuntil']=time()+60; $_SESSION['attempts']=0; } $err='Bad pass.';
    } elseif ($a==='logout') { session_destroy(); header('Location: /'); exit; }
    elseif ($a==='delete') {
        if (empty($_SESSION['authed'])||!check_csrf($_POST['csrf']??null)) { http_response_code(403); exit('Forbidden'); }
        $t=safe_path($_POST['path']??'', $rootfs); $root=realpath($rootfs);
        if (!$t||!$root||$t===$root) { http_response_code(400); exit('Bad path'); }
        $ok = is_dir($t)&&!is_link($t) ? del_dir($t) : @unlink($t); if (!$ok) { http_response_code(500); exit('Del fail'); }
        header('Location: /?dir='.enc(dirname($_POST['path']??'')==='.'?'':dirname($_POST['path']??''))); exit;
    }
}
if (empty($_SESSION['authed'])) { ?>
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Recovery</title><style>*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;background:#111827;color:#e5e7eb;font-family:system-ui}.card{width:min(380px,92vw);padding:28px;background:#1f2937;border-radius:14px}h1{font-size:1.1rem;text-align:center;color:#f87171}input,button{width:100%;padding:11px;border-radius:8px;font:inherit;margin-top:10px}input{background:#111827;border:1px solid #374151;color:#fff}button{border:0;background:#dc2626;color:#fff}</style></head><body><main class="card"><h1>Recovery File Manager</h1><form method="post"><input type="hidden" name="action" value="login"><input type="password" name="password" placeholder="Password" autofocus required><button>Unlock</button></form><?php if($err): ?><p style="color:#f87171;text-align:center"><?=h($err)?></p><?php endif; ?></main></body></html>
<?php exit; }
$dirRel = $_GET['dir']??''; $dirPath = safe_path($dirRel, $rootfs); if (!$dirPath||!is_dir($dirPath)) { $dirRel=''; $dirPath=realpath($rootfs); }
$rootReal = realpath($rootfs); $dp = $dirPath===$rootReal ? '/' : '/'.ltrim(substr($dirPath, strlen($rootReal)), '/');
$crumbs = [['name'=>'/', 'rel'=>'']]; $acc=''; foreach (array_filter(explode('/', $dp)) as $p) { $acc.='/'.$p; $crumbs[]=['name'=>$p, 'rel'=>ltrim($acc, '/')]; }
$entries = scan($dirPath, $dirRel); usort($entries, function($a,$b){ if($a['is_dir']!==$b['is_dir']) return $a['is_dir']?-1:1; return strcasecmp($a['name'], $b['name']); });
$csrf = csrf_token();
?>
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Recovery</title><style>*{box-sizing:border-box}body{margin:0;padding:16px;background:#111827;color:#e5e7eb;font-family:system-ui}.wrap{max-width:1200px;margin:auto}.header{display:flex;justify-content:space-between;background:#1f2937;padding:16px;border-radius:12px 12px 0 0}.title{font-weight:700;color:#f87171}.logout,.del-btn{background:transparent;border:1px solid #ef4444;color:#f87171;border-radius:7px;padding:7px 10px;cursor:pointer}.logout:hover,.del-btn:hover{background:#dc2626;color:#fff}.notice{margin:12px 0;padding:12px;background:#3f1d1d;border:1px solid #7f1d1d;border-radius:8px;color:#fca5a5}.crumbs{display:flex;gap:6px;padding:10px 12px;background:#172554}.crumbs a{color:#bfdbfe;text-decoration:none}.table-wrap{overflow:auto;background:#1f2937;border-radius:0 0 12px 12px}table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:10px 12px;border-bottom:1px solid #374151;font-size:.82rem}th{font-size:.7rem;text-transform:uppercase;color:#9ca3af}.name a{color:#bfdbfe;text-decoration:none}.size{text-align:right}.empty{text-align:center;color:#6b7280;padding:30px}</style></head><body><main class="wrap"><header class="header"><div><div class="title">Recovery File Manager</div><div style="font-size:.75rem;color:#9ca3af">Codespace: <?=h($csName)?> · Path: <?=h($dp)?></div></div><form method="post"><input type="hidden" name="action" value="logout"><button class="logout">Logout</button></form></header><div class="notice">Delete-only recovery mode. Free up space.</div><nav class="crumbs"><?php foreach($crumbs as $i=>$c): ?><?php if($i): ?><span>/</span><?php endif; ?><a href="/?dir=<?=enc($c['rel'])?>"><?=h($c['name'])?></a><?php endforeach; ?></nav><div class="table-wrap"><table><thead><tr><th>Name</th><th>Size</th><th>Modified</th><th>Action</th></tr></thead><tbody><?php if(!$entries): ?><tr><td colspan="4" class="empty">Empty or unreadable.</td></tr><?php endif; ?><?php foreach($entries as $e): ?><tr><td class="name"><?php if($e['is_dir']): ?><a href="/?dir=<?=enc($e['rel'])?>"><?=h($e['name'])?></a><?php else: ?><?=h($e['name'])?><?php endif; ?></td><td class="size"><?=h($e['size_human'])?></td><td><?=$e['mtime']?h(date('Y-m-d H:i', $e['mtime'])):'-'?></td><td><form method="post" onsubmit="return confirm('Delete <?=h($e['name'])?>?')"><input type="hidden" name="action" value="delete"><input type="hidden" name="csrf" value="<?=h($csrf)?>"><input type="hidden" name="path" value="<?=h($e['rel'])?>"><button class="del-btn">Delete</button></form></td></tr><?php endforeach; ?></tbody></table></div></main></body></html>
FM_PHPEOF
    chmod 644 "$FILEMANAGER_SCRIPT" 2>/dev/null || true
    touch "$BASE_DIR/.filemanager_v3"
}

is_filemanager_running() {
    local name="$1"; local pidfile="$META_DIR/$name.fm.pid"
    [[ -f "$pidfile" ]] || return 1
    local pid; pid=$(cat "$pidfile" 2>/dev/null | tr -cd '0-9')
    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then rm -f "$pidfile"; return 1; fi
    if [[ -r "/proc/$pid/cmdline" ]]; then
        local cmdline; cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
        if [[ "$cmdline" == *"php"* && "$cmdline" == *"filemanager.php"* ]]; then return 0; fi
        rm -f "$pidfile"; return 1
    fi
    return 0
}

start_filemanager() {
    local name="$1"; local rootfs="$CODESPACES_DIR/$name"; local port pass
    [[ -d "$rootfs" ]] || return 1
    is_filemanager_running "$name" && return 0
    command -v php >/dev/null 2>&1 || return 1
    port=$(cat "$META_DIR/$name.port" 2>/dev/null); pass="$META_DIR/$name.pass"
    [[ -n "$port" ]] || return 1
    ensure_filemanager_script
    if command -v setsid >/dev/null 2>&1; then
        setsid env FM_ROOTFS="$rootfs" FM_PASS_FILE="$pass" FM_NAME="$name" php -S 0.0.0.0:"$port" "$FILEMANAGER_SCRIPT" > "$META_DIR/$name.fm.log" 2>&1 &
    else
        nohup env FM_ROOTFS="$rootfs" FM_PASS_FILE="$pass" FM_NAME="$name" php -S 0.0.0.0:"$port" "$FILEMANAGER_SCRIPT" > "$META_DIR/$name.fm.log" 2>&1 & disown
    fi
    echo $! > "$META_DIR/$name.fm.pid"
    sleep 1
    is_filemanager_running "$name" || return 1
    return 0
}

stop_filemanager() {
    local name="$1"; local pidfile="$META_DIR/$name.fm.pid"
    if is_filemanager_running "$name"; then
        local pid; pid=$(cat "$pidfile" 2>/dev/null | tr -cd '0-9')
        kill_tree "$pid" TERM; sleep 1; kill_tree "$pid" KILL
        echo -e "${YELLOW}Recovery file manager for '$name' stopped.${RESET}"
    fi
    rm -f "$pidfile"
}

toggle_proxy_enabled() {
    local name="$1" rootfs="$CODESPACES_DIR/$1" was_running=0
    ensure_network_files "$name"
    is_running "$name" && was_running=1

    clear; banner
    if is_proxy_enabled "$name"; then
        echo "off" > "$META_DIR/$name.proxyenabled"
        if [[ "$was_running" -eq 1 ]]; then
            echo -e "${YELLOW}Turning proxy OFF and restarting '$name' to remove proxy variables...${RESET}"
            stop_codespace "$name" --no-fm
            if ! start_codespace "$name" --quiet; then
                echo -e "${RED}[!] The codespace could not be restarted after disabling the proxy.${RESET}"
            fi
        else
            stop_network_proxy "$name"
        fi
        write_apt_proxy_conf "$rootfs" "" "off"
        write_shell_proxy_conf "$rootfs" "" "off"
        echo -e "${GREEN}[+] Proxy preference is now OFF.${RESET}"
    else
        echo "on" > "$META_DIR/$name.proxyenabled"
        if [[ "$was_running" -eq 1 ]]; then
            echo -e "${YELLOW}Turning proxy ON and restarting '$name' to apply proxy variables...${RESET}"
            stop_codespace "$name" --no-fm
            if ! start_codespace "$name" --quiet; then
                echo -e "${RED}[!] Proxy is enabled, but the codespace remains stopped because the proxy could not start.${RESET}"
            fi
        else
            stop_network_proxy "$name"
        fi
        echo -e "${GREEN}[+] Proxy preference is now ON.${RESET}"
        echo -e "${YELLOW}    It will start automatically whenever the codespace starts.${RESET}"
    fi

    echo -e "  Proxy: $(proxy_status_colored "$name")"
    press_any_key
}
view_network_log() {
    local name="$1"; ensure_network_files "$name"; clear; banner
    echo -e "${BOLD}Network domains: $name${RESET}"
    echo -e "  Proxy: $(proxy_status_colored "$name")"
    echo -e "${YELLOW}HTTP requests and HTTPS CONNECT domains are shown below.${RESET}"
    echo -e "${YELLOW}Press Ctrl+C to return.${RESET}"
    echo
    trap ' ' INT
    tail -n 40 -f "$META_DIR/$name.netlog" & local tail_pid=$!
    trap "kill $tail_pid 2>/dev/null" INT
    wait "$tail_pid" 2>/dev/null
    trap - INT
}

manage_domain_lists() {
    local name="$1" choice d normalized ln mode observed
    ensure_network_files "$name"
    while true; do
        clear; banner
        mode=$(cat "$META_DIR/$name.netmode" 2>/dev/null || echo "open")
        echo -e "${BOLD}Domain policy: $name${RESET}"
        echo -e "  Proxy: $(proxy_status_colored "$name")"
        echo -e "  Mode:  ${CYAN}${mode}${RESET}"
        echo

        echo -e "${BOLD}Observed domains (HTTP + HTTPS):${RESET}"
        observed=$(recent_domains "$name" 30)
        if [[ -n "$observed" ]]; then
            printf '%s\n' "$observed" | nl -ba -w2 -s') '
        else
            echo "  No domains logged yet."
        fi
        echo

        echo -e "${BOLD}Blocked domains:${RESET}"
        if [[ -s "$META_DIR/$name.blocklist" ]]; then nl -ba -w2 -s') ' "$META_DIR/$name.blocklist"
        else echo "  (empty)"; fi
        echo

        echo -e "${BOLD}Allowed domains (used in restricted mode):${RESET}"
        if [[ -s "$META_DIR/$name.allowlist" ]]; then nl -ba -w2 -s') ' "$META_DIR/$name.allowlist"
        else echo "  (empty)"; fi
        echo

        echo -e "${YELLOW}a) block  x) unblock  w) allow  y) remove allow  q) back${RESET}"
        read -rp "> " choice
        case "$choice" in
            a|A)
                read -rp "Domain or URL to block: " d
                normalized=$(normalize_domain_input "$d")
                if [[ -n "$normalized" ]]; then
                    grep -Fqx "$normalized" "$META_DIR/$name.blocklist" 2>/dev/null || echo "$normalized" >> "$META_DIR/$name.blocklist"
                else
                    echo -e "${RED}Invalid domain.${RESET}"; sleep 1
                fi
                ;;
            x|X)
                read -rp "Blocked-list line number: " ln
                [[ "$ln" =~ ^[0-9]+$ ]] && sed -i "${ln}d" "$META_DIR/$name.blocklist"
                ;;
            w|W)
                read -rp "Domain or URL to allow: " d
                normalized=$(normalize_domain_input "$d")
                if [[ -n "$normalized" ]]; then
                    grep -Fqx "$normalized" "$META_DIR/$name.allowlist" 2>/dev/null || echo "$normalized" >> "$META_DIR/$name.allowlist"
                else
                    echo -e "${RED}Invalid domain.${RESET}"; sleep 1
                fi
                ;;
            y|Y)
                read -rp "Allowed-list line number: " ln
                [[ "$ln" =~ ^[0-9]+$ ]] && sed -i "${ln}d" "$META_DIR/$name.allowlist"
                ;;
            q|Q) return ;;
        esac
    done
}
toggle_restricted_mode() {
    local name="$1"; ensure_network_files "$name"; local mode
    mode=$(cat "$META_DIR/$name.netmode" 2>/dev/null || echo "open"); clear; banner
    if [[ "$mode" == "restricted" ]]; then echo "open" > "$META_DIR/$name.netmode"
    else echo "restricted" > "$META_DIR/$name.netmode"; fi
    press_any_key
}

fix_l2s_symlinks() {
    local old_rootfs="$1" new_rootfs="$2"
    [[ -d "$new_rootfs/.l2s" ]] || return 0
    while IFS= read -r -d '' link; do
        local target; target=$(readlink "$link" 2>/dev/null) || continue
        if [[ "$target" == "$old_rootfs"* ]]; then ln -sf "${target/"$old_rootfs"/"$new_rootfs"}" "$link"; fi
    done < <(find "$new_rootfs" -type l -print0 2>/dev/null)
}

fix_rootfs_permissions() {
    local rootfs="$1"
    find "$rootfs" -type d ! -readable -exec chmod u+rx {} + 2>/dev/null || true
    find "$rootfs" -type f ! -readable -exec chmod u+r {} + 2>/dev/null || true
}

force_https_apt_sources() {
    local rootfs="$1" f
    for f in "$rootfs"/etc/apt/sources.list "$rootfs"/etc/apt/sources.list.d/*.list "$rootfs"/etc/apt/sources.list.d/*.sources; do
        [[ -f "$f" ]] || continue
        sed -i -E "s#http://(archive\.ubuntu\.com|security\.ubuntu\.com|ports\.ubuntu\.com|old-releases\.ubuntu\.com|[a-z]{2}\.archive\.ubuntu\.com)#https://\1#g" "$f" 2>/dev/null || true
    done
}

write_apt_proxy_conf() {
    local rootfs="$1" proxy_port="$2" enabled="$3"
    local conf_dir="$rootfs/etc/apt/apt.conf.d"; mkdir -p "$conf_dir" 2>/dev/null
    if [[ "$enabled" == "on" && -n "$proxy_port" ]]; then
        cat > "$conf_dir/95codespace-proxy" <<CONF
Acquire::http::Proxy "http://127.0.0.1:${proxy_port}";
Acquire::https::Proxy "http://127.0.0.1:${proxy_port}";
CONF
    else rm -f "$conf_dir/95codespace-proxy" 2>/dev/null; fi
}

write_shell_proxy_conf() {
    local rootfs="$1" proxy_port="$2" enabled="$3"
    local pdir="$rootfs/etc/profile.d"; mkdir -p "$pdir" 2>/dev/null
    local pfile="$pdir/00-codespace-proxy.sh"
    if [[ "$enabled" == "on" && -n "$proxy_port" ]]; then
        cat > "$pfile" <<CONF
export http_proxy="http://127.0.0.1:${proxy_port}"
export https_proxy="http://127.0.0.1:${proxy_port}"
export HTTP_PROXY="http://127.0.0.1:${proxy_port}"
export HTTPS_PROXY="http://127.0.0.1:${proxy_port}"
export no_proxy="localhost,127.0.0.1,::1"
export NO_PROXY="localhost,127.0.0.1,::1"
CONF
    else rm -f "$pfile" 2>/dev/null; fi
}

repair_usrmerge_symlinks() {
    local rootfs="$1"
    local -a mappings=("bin:usr/bin" "sbin:usr/sbin" "lib:usr/lib" "lib32:usr/lib32" "lib64:usr/lib64" "libx32:usr/libx32")
    local entry
    for entry in "${mappings[@]}"; do
        local link="${entry%%:*}" target="${entry#*:}"
        [[ -e "$rootfs/$link" || -L "$rootfs/$link" ]] && continue
        [[ -d "$rootfs/$target" ]] || continue
        ln -s "$target" "$rootfs/$link" 2>/dev/null || true
    done
}

prepare_codespace_rootfs() {
    local rootfs="$1"
    mkdir -p "$rootfs/.l2s" "$rootfs/tmp" "$rootfs/dev/pts" "$rootfs/dev/shm" "$rootfs/run" "$rootfs/proc" "$rootfs/sys"
    chmod 1777 "$rootfs/tmp" 2>/dev/null || true
    repair_usrmerge_symlinks "$rootfs"
    [[ -s "$rootfs/etc/machine-id" ]] || echo "$(cat /proc/sys/kernel/random/uuid | tr -d '-')" > "$rootfs/etc/machine-id"
    [[ -f "$rootfs/usr/sbin/policy-rc.d" ]] || { printf "%s\n" "#!/bin/sh" "exit 101" > "$rootfs/usr/sbin/policy-rc.d"; chmod +x "$rootfs/usr/sbin/policy-rc.d"; }
    [[ -f "$rootfs/usr/bin/sudo" ]] && chmod u+s "$rootfs/usr/bin/sudo" 2>/dev/null || true
    force_https_apt_sources "$rootfs"
}

write_codeserver_settings() {
    local rootfs="$1"; local settings_dir="$rootfs/root/.local/share/code-server/User"
    mkdir -p "$settings_dir"
    cat > "$settings_dir/settings.json" <<'SETTINGS'
{ "terminal.integrated.defaultProfile.linux": "bash", "terminal.integrated.profiles.linux": { "bash": { "path": "/bin/bash", "args": ["-l"] } } }
SETTINGS
}

prompt_core_count() {
    local total; total=$(nproc --all 2>/dev/null)
    [[ -z "$total" || ! "$total" =~ ^[0-9]+$ || "$total" -lt 1 ]] && total=1
    local chosen; read -rp "CPU cores [detected: $total, Enter = all]: " chosen >&2
    chosen="${chosen:-$total}"
    [[ "$chosen" =~ ^[0-9]+$ && "$chosen" -ge 1 ]] || chosen="$total"
    [[ "$chosen" -gt "$total" ]] && chosen="$total"
    echo "$chosen"
}

prompt_fs_cores() { prompt_core_count; }

parallel_file_task() {
    local operation="$1" src="$2" dst="${3:-}" workers="$4"
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$operation" "$src" "$dst" "$workers" <<'PYEOF'
import os, shutil, sys
from concurrent.futures import ThreadPoolExecutor
op = sys.argv[1]; src = os.path.abspath(sys.argv[2]); dst = os.path.abspath(sys.argv[3]) if sys.argv[3] else ""; workers = max(1, int(sys.argv[4]))
def copy_one(item):
    s, d = item
    try:
        if os.path.islink(s):
            os.makedirs(os.path.dirname(d), exist_ok=True)
            if os.path.lexists(d): os.unlink(d)
            os.symlink(os.readlink(s), d)
        else:
            os.makedirs(os.path.dirname(d), exist_ok=True)
            shutil.copy2(s, d, follow_symlinks=False)
        return True
    except OSError: return False
def collect(root):
    files, dirs = [], []
    if os.path.islink(root) or os.path.isfile(root): return [root], []
    dirs.append(root)
    for base, dirnames, filenames in os.walk(root, topdown=True, followlinks=False):
        symlink_dirs = [d for d in dirnames if os.path.islink(os.path.join(base, d))]
        dirnames[:] = [d for d in dirnames if not os.path.islink(os.path.join(base, d))]
        for d in dirnames: dirs.append(os.path.join(base, d))
        for f in filenames: files.append(os.path.join(base, f))
        for s in symlink_dirs: files.append(os.path.join(base, s))
    return files, dirs
def parallel_copy():
    if os.path.islink(src) or os.path.isfile(src): return copy_one((src, dst))
    files, dirs = collect(src); os.makedirs(dst, exist_ok=True)
    for d in dirs:
        rel = os.path.relpath(d, src); os.makedirs(dst if rel == "." else os.path.join(dst, rel), exist_ok=True)
    jobs = [(f, os.path.join(dst, os.path.relpath(f, src))) for f in files]
    ok = True
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for result in pool.map(copy_one, jobs): ok = result and ok
    return ok
def parallel_delete():
    files, dirs = collect(src)
    if os.path.islink(src) or os.path.isfile(src):
        try: os.unlink(src); return True
        except OSError: return False
    ok = True
    with ThreadPoolExecutor(max_workers=workers) as pool:
        def _unlink_one(f):
            try:
                if os.path.exists(f) or os.path.islink(f): os.unlink(f)
                return True
            except OSError:
                return False
        for result in pool.map(_unlink_one, files): ok = result and ok
    for d in sorted(dirs, key=lambda x: x.count(os.sep), reverse=True):
        try: os.rmdir(d)
        except OSError: ok = False
    return ok
def parallel_move():
    try:
        if os.stat(src).st_dev == os.stat(os.path.dirname(dst) or ".").st_dev:
            os.makedirs(os.path.dirname(dst), exist_ok=True); os.replace(src, dst); return True
    except OSError: pass
    if not parallel_copy(): return False
    return parallel_delete()
if op == "copy": ok = parallel_copy()
elif op == "delete": ok = parallel_delete()
elif op == "move": ok = parallel_move()
else: ok = False
raise SystemExit(0 if ok else 1)
PYEOF
}

require_pigz() { command -v pigz >/dev/null 2>&1 || { echo -e "${RED}pigz missing${RESET}"; return 1; }; }

export_codespace() {
    local name="$1"; clear; banner
    [[ -d "$CODESPACES_DIR/$name" ]] || { press_any_key; return; }
    require_pigz || { press_any_key; return; }
    if is_running "$name"; then
        read -rp "Stop it first? [Y/n]: " s
        [[ ! "$s" =~ ^[Nn]$ ]] && stop_codespace "$name"
    fi
    read -rp "Path [~/${name}.tar.gz]: " export_path
    export_path="${export_path:-$HOME/${name}.tar.gz}"; export_path="${export_path/#\~/$HOME}"
    [[ -d "$export_path" ]] && export_path="${export_path%/}/${name}.tar.gz"
    [[ "$export_path" != *.tar.gz && "$export_path" != *.tgz ]] && export_path="${export_path}.tar.gz"
    mkdir -p "$(dirname "$export_path")"
    [[ -e "$export_path" ]] && { read -rp "Overwrite? [y/N]: " o; [[ ! "$o" =~ ^[Yy]$ ]] && return; rm -f "$export_path"; }
    local cores; cores=$(prompt_core_count)
    if is_hard_quota "$name" && ! is_quota_image_mounted "$name"; then mount_hard_quota "$name" || return; local unmount=1; else local unmount=0; fi
    fix_rootfs_permissions "$CODESPACES_DIR/$name"
    local tar_excludes=() p; for p in "${PROOT_BIND_EXCLUDES[@]}"; do tar_excludes+=("--exclude=${name}/${p}"); done
    local tmp_meta_dir; tmp_meta_dir=$(mktemp -d)
    { echo "name=$name"; echo "port=$(cat "$META_DIR/$name.port" 2>/dev/null)"; echo "pass=$(cat "$META_DIR/$name.pass" 2>/dev/null)"; } > "$tmp_meta_dir/codespace.meta"
    tar --ignore-failed-read --warning=no-failed-read "${tar_excludes[@]}" -cf - -C "$CODESPACES_DIR" "$name" -C "$tmp_meta_dir" "codespace.meta" | pigz -p "$cores" > "$export_path"
    local pipe_status=("${PIPESTATUS[@]}")
    rm -rf "$tmp_meta_dir"
    [[ "$unmount" -eq 1 ]] && unmount_hard_quota "$name"
    if [[ "${pipe_status[0]}" -ge 2 || "${pipe_status[1]}" -ne 0 || ! -s "$export_path" ]]; then rm -f "$export_path"; else echo -e "${GREEN}Exported to $export_path${RESET}"; fi
    press_any_key
}

import_codespace() {
    clear; banner; require_pigz || { press_any_key; return; }
    read -rp "Archive path: " archive_path; archive_path="${archive_path/#\~/$HOME}"
    [[ -f "$archive_path" ]] || { press_any_key; return; }
    pigz -t "$archive_path" >/dev/null 2>&1 || { press_any_key; return; }
    local cores; cores=$(prompt_core_count)
    local meta name_in_zip port_in_zip pass_in_zip
    meta=$(pigz -dc -p "$cores" "$archive_path" | tar -xO -f - codespace.meta 2>/dev/null) || true
    name_in_zip=$(echo "$meta" | grep '^name=' | cut -d= -f2-)
    port_in_zip=$(echo "$meta" | grep '^port=' | cut -d= -f2-)
    pass_in_zip=$(echo "$meta" | grep '^pass=' | cut -d= -f2-)
    local default_name="${name_in_zip:-imported}"
    read -rp "Name [$default_name]: " new_name; new_name="${new_name:-$default_name}"
    new_name=$(echo "$new_name" | tr -cd 'A-Za-z0-9_-')
    [[ -z "$new_name" ]] && { press_any_key; return; }
    [[ -d "$CODESPACES_DIR/$new_name" ]] && { echo -e "${RED}Exists${RESET}"; press_any_key; return; }
    local tmp_extract; tmp_extract=$(mktemp -d)
    pigz -dc -p "$cores" "$archive_path" | tar -xf - -C "$tmp_extract" 2>/dev/null || { rm -rf "$tmp_extract"; press_any_key; return; }
    local extracted_dir
    if [[ -n "$name_in_zip" && -d "$tmp_extract/$name_in_zip" ]]; then extracted_dir="$tmp_extract/$name_in_zip"
    else extracted_dir=$(find "$tmp_extract" -mindepth 1 -maxdepth 1 -type d | head -n1); fi
    [[ -z "$extracted_dir" || ! -d "$extracted_dir" ]] && { rm -rf "$tmp_extract"; press_any_key; return; }
    local move_cores; move_cores=$(prompt_fs_cores)
    parallel_file_task move "$extracted_dir" "$CODESPACES_DIR/$new_name" "$move_cores" || { rm -rf "$tmp_extract"; press_any_key; return; }
    rm -rf "$tmp_extract"
    [[ -n "$name_in_zip" && "$name_in_zip" != "$new_name" ]] && fix_l2s_symlinks "$CODESPACES_DIR/$name_in_zip" "$CODESPACES_DIR/$new_name"
    prepare_codespace_rootfs "$CODESPACES_DIR/$new_name"
    write_codeserver_settings "$CODESPACES_DIR/$new_name"
    ensure_quota_files "$new_name"
    local req_port="${port_in_zip}"
    local port; port=$(find_free_port "$req_port")
    [[ -z "$port" ]] && { rm -rf "$CODESPACES_DIR/$new_name"; press_any_key; return; }
    local pass="${pass_in_zip:-$(random_password)}"
    mkdir -p "$CODESPACES_DIR/$new_name/root/.config/code-server"
    cat > "$CODESPACES_DIR/$new_name/root/.config/code-server/config.yaml" <<CFG
bind-addr: 0.0.0.0:${port}
auth: password
password: ${pass}
cert: false
CFG
    echo "$port" > "$META_DIR/$new_name.port"
    echo "$pass" > "$META_DIR/$new_name.pass"
    echo -e "${GREEN}Imported '$new_name' on port $port${RESET}"
    press_any_key
}

create_codespace() {
    clear; banner
    [[ -d "$BASE_ROOTFS" ]] || { press_any_key; return; }
    read -rp "Name: " name; name=$(echo "$name" | tr -cd 'A-Za-z0-9_-')
    [[ -z "$name" || -d "$CODESPACES_DIR/$name" ]] && { press_any_key; return; }
    read -rp "Port (blank=auto): " req_port
    local clone_cores; clone_cores=$(prompt_fs_cores)
    parallel_file_task copy "$BASE_ROOTFS" "$CODESPACES_DIR/$name" "$clone_cores" || { press_any_key; return; }
    fix_l2s_symlinks "$BASE_ROOTFS" "$CODESPACES_DIR/$name"
    prepare_codespace_rootfs "$CODESPACES_DIR/$name"
    write_codeserver_settings "$CODESPACES_DIR/$name"
    ensure_network_files "$name"; ensure_quota_files "$name"
    read -rp "Quota MB (0=unlim): " req_quota
    [[ "$req_quota" =~ ^[0-9]+$ ]] && set_quota_mb "$name" "$req_quota"
    local port; port=$(find_free_port "$req_port")
    [[ -z "$port" ]] && { rm -rf "$CODESPACES_DIR/$name"; press_any_key; return; }
    local pass; pass=$(random_password)
    mkdir -p "$CODESPACES_DIR/$name/root/.config/code-server"
    cat > "$CODESPACES_DIR/$name/root/.config/code-server/config.yaml" <<CFG
bind-addr: 0.0.0.0:${port}
auth: password
password: ${pass}
cert: false
CFG
    echo "$port" > "$META_DIR/$name.port"; echo "$pass" > "$META_DIR/$name.pass"
    start_codespace "$name"
}

start_codespace() {
    local name="$1" quiet="${2:-}"; local rootfs="$CODESPACES_DIR/$name"
    local port pass; port=$(cat "$META_DIR/$name.port" 2>/dev/null); pass=$(cat "$META_DIR/$name.pass" 2>/dev/null)
    stop_filemanager "$name" 2>/dev/null || true
    [[ -z "$port" ]] && { [[ "$quiet" != "--quiet" ]] && press_any_key; return 1; }
    ensure_quota_files "$name"
    if is_hard_quota "$name"; then mount_hard_quota "$name" || { [[ "$quiet" != "--quiet" ]] && press_any_key; return 1; }; fi
    local quota_mb used_mb; quota_mb=$(get_quota_mb "$name")
    if [[ "$quota_mb" -gt 0 ]]; then
        used_mb=$(get_codespace_size_mb "$name")
        if [[ -n "$used_mb" && "$used_mb" -gt "$quota_mb" ]]; then
            start_filemanager "$name"; [[ "$quiet" != "--quiet" ]] && [[ "$quiet" != "--quiet" ]] && press_any_key; return 1
        fi
    fi
    if is_running "$name"; then echo -e "${YELLOW}Already running.${RESET}"
    else
        prepare_codespace_rootfs "$rootfs"; write_codeserver_settings "$rootfs"; ensure_network_files "$name"
        if is_proxy_enabled "$name"; then
            if ! start_network_proxy "$name"; then
                echo -e "${RED}[!] Codespace was not started because its proxy is enabled but unavailable.${RESET}"
                echo -e "${YELLOW}    Fix the proxy error, or press p to explicitly turn the proxy OFF.${RESET}"
                [[ "$quiet" != "--quiet" ]] && press_any_key
                return 1
            fi
        else
            stop_network_proxy "$name"
        fi
        local proxy_port="" proxy_env=""
        [[ -f "$META_DIR/$name.proxyport" ]] && proxy_port=$(cat "$META_DIR/$name.proxyport")
        if is_proxy_enabled "$name" && is_proxy_running "$name" && [[ -n "$proxy_port" ]]; then
            proxy_env="export http_proxy=\"http://127.0.0.1:${proxy_port}\"; export https_proxy=\"http://127.0.0.1:${proxy_port}\"; export HTTP_PROXY=\"http://127.0.0.1:${proxy_port}\"; export HTTPS_PROXY=\"http://127.0.0.1:${proxy_port}\"; export no_proxy=\"localhost,127.0.0.1,::1\"; export NO_PROXY=\"localhost,127.0.0.1,::1\""
            write_apt_proxy_conf "$rootfs" "$proxy_port" "on"
            write_shell_proxy_conf "$rootfs" "$proxy_port" "on"
        else write_apt_proxy_conf "$rootfs" "" "off"; write_shell_proxy_conf "$rootfs" "" "off"; fi
        local launcher="$META_DIR/$name.launcher.sh"
        cat > "$launcher" <<LAUNCHER_EOF
#!/data/data/com.termux/files/usr/bin/bash
set -uo pipefail; unset LD_PRELOAD; mkdir -p "$PREFIX/tmp"
export HOME=/root USER=root SHELL=/bin/bash TERM="${TERM:-xterm-256color}" LANG=C.UTF-8 PROOT_L2S_DIR="$rootfs/.l2s"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PREFIX/bin"
${proxy_env}
exec "$PROOT_BIN" --kill-on-exit --link2symlink --sysvipc -L --change-id=0:0 --kernel-release="6.17.0-PRoot-Distro" --rootfs="$rootfs" --cwd=/root --bind=/dev --bind=/proc --bind=/sys --bind=/dev/urandom:/dev/random --bind=/proc/self/fd:/dev/fd --bind="$rootfs/tmp:/dev/shm" --bind="$PREFIX" --bind="$PREFIX/tmp:/tmp" /bin/sh -c "exec /usr/local/bin/code-server --bind-addr 0.0.0.0:$port --disable-telemetry"
LAUNCHER_EOF
        chmod +x "$launcher"
        nohup bash "$launcher" > "$META_DIR/$name.log" 2>&1 &
        echo $! > "$META_DIR/$name.pid"
        sleep 3
        if ! is_running "$name"; then
            echo -e "${RED}Failed to start. Check log: $META_DIR/$name.log${RESET}"
            tail -10 "$META_DIR/$name.log" 2>/dev/null
            rm -f "$META_DIR/$name.pid"
            press_any_key; return 1
        fi
        rm -f "$META_DIR/$name.quota.exceeded"
        start_quota_watchdog "$name"
    fi
    [[ "$quiet" == "--quiet" ]] && return 0

    local ip domains; ip=$(device_ip)
    echo -e "${GREEN}${BOLD}Codespace '$name' is up.${RESET}"
    echo -e "  Local:    http://127.0.0.1:${port}"
    [[ -n "$ip" ]] && echo -e "  Network:  http://${ip}:${port}"
    echo -e "  Password: ${BOLD}${pass}${RESET}"
    echo -e "  Proxy:    $(proxy_status_colored "$name")"
    domains=$(recent_domains "$name" 15)
    if [[ -n "$domains" ]]; then
        echo -e "  Domains seen (HTTP + HTTPS):"
        while IFS= read -r domain; do [[ -n "$domain" ]] && echo -e "    ${CYAN}- $domain${RESET}"; done <<< "$domains"
    else
        echo -e "  Domains seen (HTTP + HTTPS): ${YELLOW}none yet${RESET}"
    fi
    press_any_key
}

stop_codespace() {
    local name="$1" skip_fm="${2:-}"
    local pidfile="$META_DIR/$name.pid"
    if is_running "$name"; then
        local pid; pid=$(cat "$pidfile" 2>/dev/null | tr -cd '0-9')
        kill_tree "$pid" TERM; sleep 1; kill_tree "$pid" KILL
        echo -e "${YELLOW}Terminated.${RESET}"
    fi
    rm -f "$pidfile"
    stop_network_proxy "$name"
    [[ "$skip_fm" != "--no-fm" && -f "$META_DIR/$name.quota.exceeded" ]] && start_filemanager "$name"
    stop_quota_watchdog "$name"
    is_hard_quota "$name" && unmount_hard_quota "$name"
}

delete_codespace() {
    local name="$1"; clear; banner
    read -rp "Delete '$name'? [y/N]: " c
    if [[ "$c" =~ ^[Yy]$ ]]; then
        stop_filemanager "$name" 2>/dev/null || true; stop_codespace "$name" --no-fm
        local del_cores; del_cores=$(prompt_fs_cores)
        parallel_file_task delete "$CODESPACES_DIR/$name" "" "$del_cores"
        if [[ -d "$CODESPACES_DIR/$name" ]]; then
            echo -e "${YELLOW}[!] Parallel delete didn't fully clear it - retrying with rm -rf...${RESET}"
            rm -rf "$CODESPACES_DIR/$name" 2>/dev/null
        fi
        rm -f "$(quota_image_path "$name")" "$META_DIR/$name."*
        if [[ -d "$CODESPACES_DIR/$name" ]]; then
            echo -e "${RED}Failed to delete '$name'. Something is still holding it open${RESET}"
            echo -e "${RED}(often a leftover mount from /dev, /proc, or /sys inside it).${RESET}"
            echo -e "${YELLOW}Try: mount | grep '$name'   -- and umount anything listed, then delete again.${RESET}"
        else
            echo -e "${GREEN}Deleted '$name'.${RESET}"
        fi
    fi
    press_any_key
}

terminate_all() {
    clear; banner
    while IFS= read -r name; do [[ -n "$name" ]] && { stop_filemanager "$name" 2>/dev/null || true; stop_codespace "$name" --no-fm; }; done < <(list_codespaces)
    press_any_key
}

cli_codespace() {
    local name="$1"
    local rootfs="$CODESPACES_DIR/$name"
    local proxy_port=""
    clear
    banner
    ensure_quota_files "$name"

    if is_hard_quota "$name"; then
        mount_hard_quota "$name" || { press_any_key; return 1; }
    fi

    prepare_codespace_rootfs "$rootfs"
    ensure_network_files "$name"

    if is_proxy_enabled "$name"; then
        if ! start_network_proxy "$name"; then
            write_apt_proxy_conf "$rootfs" "" "off"
            write_shell_proxy_conf "$rootfs" "" "off"
            echo -e "${RED}[!] CLI was not opened because the proxy is enabled but unavailable.${RESET}"
            echo -e "${YELLOW}    Fix the proxy error, or press p to explicitly turn the proxy OFF.${RESET}"
            if is_hard_quota "$name" && ! is_running "$name"; then
                unmount_hard_quota "$name"
            fi
            press_any_key
            return 1
        fi

        proxy_port=$(cat "$META_DIR/$name.proxyport" 2>/dev/null || true)
        if [[ -z "$proxy_port" ]] || ! is_proxy_running "$name"; then
            echo -e "${RED}[!] CLI was not opened because proxy readiness could not be verified.${RESET}"
            if is_hard_quota "$name" && ! is_running "$name"; then
                unmount_hard_quota "$name"
            fi
            press_any_key
            return 1
        fi

        write_apt_proxy_conf "$rootfs" "$proxy_port" "on"
        write_shell_proxy_conf "$rootfs" "$proxy_port" "on"
    else
        stop_network_proxy "$name"
        write_apt_proxy_conf "$rootfs" "" "off"
        write_shell_proxy_conf "$rootfs" "" "off"
    fi

    (
        unset LD_PRELOAD
        mkdir -p "$PREFIX/tmp"
        export HOME=/root
        export USER=root
        export SHELL=/bin/bash
        export TERM="${TERM:-xterm-256color}"
        export LANG=C.UTF-8
        export PROOT_L2S_DIR="$rootfs/.l2s"
        export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PREFIX/bin"

        if is_proxy_enabled "$name"; then
            export http_proxy="http://127.0.0.1:${proxy_port}"
            export https_proxy="http://127.0.0.1:${proxy_port}"
            export HTTP_PROXY="http://127.0.0.1:${proxy_port}"
            export HTTPS_PROXY="http://127.0.0.1:${proxy_port}"
            export no_proxy="localhost,127.0.0.1,::1"
            export NO_PROXY="localhost,127.0.0.1,::1"
        else
            unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy no_proxy NO_PROXY 2>/dev/null || true
            echo -e "${YELLOW}[!] Proxy is explicitly OFF; CLI has direct network access.${RESET}"
            sleep 1
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

    if is_hard_quota "$name" && ! is_running "$name"; then
        unmount_hard_quota "$name"
    fi
    press_any_key
}

show_codespace_info() {
    local name="$1" domains mode
    clear; banner; ensure_network_files "$name"
    echo -e "${BOLD}Codespace: $name${RESET}"
    local port pass; port=$(cat "$META_DIR/$name.port" 2>/dev/null); pass=$(cat "$META_DIR/$name.pass" 2>/dev/null)
    echo -e "  Port: ${port:-?}  Pass: ${pass:-?}"
    is_running "$name" && echo -e "  Status: ${GREEN}RUNNING${RESET}" || echo -e "  Status: ${RED}STOPPED${RESET}"
    echo -e "  Storage: $(format_quota_usage "$name")"
    echo -e "  Proxy:   $(proxy_status_colored "$name")"
    mode=$(cat "$META_DIR/$name.netmode" 2>/dev/null || echo "open")
    echo -e "  Network policy: ${CYAN}${mode}${RESET}"

    domains=$(recent_domains "$name" 20)
    if [[ -n "$domains" ]]; then
        echo
        echo -e "${BOLD}Domains seen through the proxy (HTTP + HTTPS):${RESET}"
        while IFS= read -r domain; do [[ -n "$domain" ]] && echo -e "  ${CYAN}- $domain${RESET}"; done <<< "$domains"
    else
        echo -e "  Domains seen (HTTP + HTTPS): ${YELLOW}none yet${RESET}"
    fi
    press_any_key
}
manage_codespaces_menu() {
    while true; do
        local names=()
        while IFS= read -r n; do [[ -n "$n" ]] && names+=("$n"); done < <(list_codespaces)
        local options=()
        for n in "${names[@]}"; do
            local status_tag size_tag proxy_tag
            ensure_network_files "$n"
            is_running "$n" && status_tag="[running]" || status_tag="[stopped]"
            proxy_tag="[$(proxy_status_plain "$n")]"
            size_tag="$(get_codespace_size_mb "$n") MB"
            options+=("$n  $status_tag  $proxy_tag  ($size_tag)")
        done
        options+=("+ Create New Codespace" "Import Codespace")
        arrow_menu "Manage Codespaces" "${options[@]}"
        local action="${ARROW_MENU_RESULT%%:*}" idx="${ARROW_MENU_RESULT##*:}"
        case "$action" in
            back) return ;;
            cli) [[ $idx -lt ${#names[@]} ]] && cli_codespace "${names[$idx]}" ;;
            select)
                if [[ $idx -eq ${#names[@]} ]]; then create_codespace
                elif [[ $idx -eq $(( ${#names[@]} + 1 )) ]]; then import_codespace
                else is_running "${names[$idx]}" && show_codespace_info "${names[$idx]}" || start_codespace "${names[$idx]}"; fi ;;
            netlog) [[ $idx -lt ${#names[@]} ]] && view_network_log "${names[$idx]}" ;;
            domains) [[ $idx -lt ${#names[@]} ]] && manage_domain_lists "${names[$idx]}" ;;
            restrict) [[ $idx -lt ${#names[@]} ]] && toggle_restricted_mode "${names[$idx]}" ;;
            toggleproxy) [[ $idx -lt ${#names[@]} ]] && toggle_proxy_enabled "${names[$idx]}" ;;
            quota) [[ $idx -lt ${#names[@]} ]] && set_quota_interactive "${names[$idx]}" ;;
            delete) [[ $idx -lt ${#names[@]} ]] && delete_codespace "${names[$idx]}" ;;
            terminate) [[ $idx -lt ${#names[@]} ]] && { stop_codespace "${names[$idx]}"; press_any_key; } ;;
            export) [[ $idx -lt ${#names[@]} ]] && export_codespace "${names[$idx]}" ;;
            import) import_codespace ;;
        esac
    done
}

migrate_legacy_base || exit 1
if ! base_is_ready; then
    if [[ -d "$BASE_ROOTFS" ]]; then
        clear; banner
        read -rp "Rebuild incomplete base? [Y/n]: " r
        [[ ! "$r" =~ ^[Nn]$ ]] && { rm -rf "$BASE_IMAGE_DIR"; rm -f "$STATE_FILE"; } || exit 1
    fi
    run_initial_setup || exit 1
fi

main_menu() {
    while true; do
        arrow_menu "Termux CodeSpace" "Manage Codespaces" "Terminate All" "Cleanup Everything" "Exit"
        local action="${ARROW_MENU_RESULT%%:*}" idx="${ARROW_MENU_RESULT##*:}"
        [[ "$action" == "back" ]] && { clear; exit 0; }
        case "$idx" in
            0) manage_codespaces_menu ;;
            1) terminate_all ;;
            2) cleanup_all ;;
            3) clear; exit 0 ;;
        esac
    done
}
main_menu

