#!/data/data/com.termux/files/usr/bin/bash
set -uo pipefail
unset LD_PRELOAD

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")"
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
ADMIN_SERVER_SCRIPT="$BASE_DIR/admin_panel.py"
ADMIN_PANEL_PORT_START=8787
ADMIN_PANEL_PORT_END=8807

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

press_any_key() {
    echo
    local _junk
    while IFS= read -r -t 0.01 -n 1 _junk 2>/dev/null; do :; done
    read -n1 -rsp "Press any key to continue..."
    echo
}

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
        if [[ "$title" == "Manage Codespaces" ]]; then
            echo; echo -e "${YELLOW}UP/DOWN move   Enter select   c CLI   n network log   b domain policy${RESET}"
            echo -e "${YELLOW}r revoke codespace creds   R restrict mode   p proxy   s quota   d delete   t stop   q back${RESET}"
        else
            echo; echo -e "${YELLOW}UP/DOWN move   Enter select   v view admin credential   r revoke admin credential   q exit${RESET}"
        fi
        key=$(read_key)
        case "$key" in
            $'\x1b[A') sel=$(( (sel - 1 + count) % count )) ;;
            $'\x1b[B') sel=$(( (sel + 1) % count )) ;;
            "")        ARROW_MENU_RESULT="select:$sel"; return 0 ;;
            c|C)       ARROW_MENU_RESULT="cli:$sel"; return 0 ;;
            n|N)       ARROW_MENU_RESULT="netlog:$sel"; return 0 ;;
            b|B)       ARROW_MENU_RESULT="domains:$sel"; return 0 ;;
            r)         ARROW_MENU_RESULT="revoke:$sel"; return 0 ;;
            v|V)       [[ "$title" != "Manage Codespaces" ]] && { ARROW_MENU_RESULT="reveal:$sel"; return 0; } ;;
            R)         ARROW_MENU_RESULT="restrict:$sel"; return 0 ;;
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
    fix_l2s_symlinks "$legacy_rootfs" "$BASE_ROOTFS"
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
    # Fix dangling symlinks (specifically .l2s hardlink emulation) pointing to the temp container
    fix_l2s_symlinks "$source_rootfs" "$BASE_ROOTFS"
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
    stop_admin_panel 2>/dev/null || true
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
apt-get install -y --no-install-recommends ca-certificates curl wget git openssh-client tar gzip xz-utils sudo bash unzip zip
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


# Return every non-loopback IPv4 assigned to a network interface.
# Termux Android hotspot interfaces vary by device (ap0, wlan0, swlan0, etc.),
# so do not hard-code a single interface name.
device_ipv4_records() {
    local records=""
    if command -v ifconfig >/dev/null 2>&1; then
        records=$(ifconfig -a 2>/dev/null | awk '
            /^[^[:space:]]/ { iface=$1; sub(/:$/, "", iface) }
            {
                for (i=1; i<=NF; i++) {
                    ip=""
                    if ($i == "inet" && i < NF) {
                        ip=$(i+1); sub(/^addr:/, "", ip); sub(/:.*/, "", ip)
                    } else if ($i ~ /^inet[[:space:]]+addr:/) {
                        ip=$i; sub(/^inet[[:space:]]+addr:/, "", ip)
                    } else if ($i ~ /^inet[[:space:]]*addr:/) {
                        ip=$i; sub(/^inet[[:space:]]*addr:/, "", ip)
                    }
                    if (ip ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && ip !~ /^127\./ && ip !~ /^169\.254\./ && iface != "")
                        print iface, ip
                }
            }
        ' | sort -u)
    fi
    # iproute2 is a fallback for installations without a usable ifconfig.
    if [[ -z "$records" ]] && command -v ip >/dev/null 2>&1; then
        records=$(ip -4 -o addr show 2>/dev/null | awk '{ split($4, a, "/"); if (a[1] ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && a[1] !~ /^127\./ && a[1] !~ /^169\.254\./) print $2, a[1] }' | sort -u)
    fi
    printf '%s\n' "$records"
}

admin_panel_enabled() { [[ "$(cat "$META_DIR/admin.enabled" 2>/dev/null)" == "on" ]]; }

ensure_admin_server_script() {
    local marker="$BASE_DIR/.admin_server_v8"
    if [[ -f "$ADMIN_SERVER_SCRIPT" && -f "$marker" ]]; then return 0; fi
    # An older server process cannot load new dashboard routes just because its source file was replaced. Stop it before installing v8.
    if [[ -f "$META_DIR/admin.pid" ]]; then
        stop_admin_panel >/dev/null 2>&1 || true
    fi
    cat > "$ADMIN_SERVER_SCRIPT" << 'ADMINPYEOF'
#!/usr/bin/env python3
"""LAN-only TermuxCodeSpace admin panel. Standard library only."""
import argparse
import base64
import codecs
import fcntl
import hashlib
import hmac
import http.cookies
import json
import os
import posixpath
import pty
import queue
import re
import secrets
import signal
import shutil
import socket
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import termios
import threading
import time
import urllib.parse
import zlib
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

NAME_RE = re.compile(r"^[A-Za-z0-9_-]{1,48}$")
MAX_BODY = 1024 * 1024
MAX_IMPORT_BYTES = 4 * 1024 * 1024 * 1024
MAX_ARCHIVE_MEMBERS = 500000
SESSION_TTL = 12 * 60 * 60
MAX_TERMINALS = 8
TERMINAL_BUFFER_LIMIT = 250_000

HTML = r'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="dark"><meta name="robots" content="noindex,nofollow">
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/css/xterm.css">
<title>TermuxCodeSpace · Admin</title>
<style>
:root{--bg:#0b1020;--panel:#111a2d;--panel2:#172239;--line:#26334d;--text:#e8eef9;--muted:#91a0b8;--accent:#62d6b1;--blue:#7ba7ff;--red:#ff7185;--amber:#f2c36b;--radius:16px;font-family:Inter,ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif}
*{box-sizing:border-box}body{margin:0;background:radial-gradient(900px 500px at 70% -12%,#1b3150 0%,transparent 65%),var(--bg);color:var(--text);min-height:100vh}
button,input,select,textarea{font:inherit}button{cursor:pointer;border:1px solid var(--line);border-radius:10px;padding:9px 13px;color:var(--text);background:#1a2942;transition:.15s}button:hover{border-color:#54739d;transform:translateY(-1px)}button:disabled{opacity:.5;cursor:wait;transform:none}.primary{background:var(--accent);border-color:var(--accent);color:#071a17;font-weight:750}.danger{color:#ffdce2;background:#3b1b2a;border-color:#6b2d43}.quiet{background:transparent}.small{padding:6px 9px;font-size:12px}.muted{color:var(--muted)}.hidden{display:none!important}
#login{min-height:100vh;display:grid;place-items:center;padding:22px}.login-card{width:min(420px,100%);background:rgba(17,26,45,.94);border:1px solid var(--line);border-radius:22px;padding:28px;box-shadow:0 24px 80px #0008}.brand{display:flex;align-items:center;gap:12px}.brand-mark{width:42px;height:42px;border-radius:13px;background:linear-gradient(145deg,#72e4bc,#7da7ff);display:grid;place-items:center;color:#09202a;font-weight:900;font-size:18px}.brand h1{font-size:18px;margin:0}.brand p{margin:3px 0 0;color:var(--muted);font-size:12px}.login-card h2{margin:28px 0 7px;font-size:23px}.login-card label,.field label{display:block;color:var(--muted);font-size:12px;margin:15px 0 7px}.login-card input,.field input,.field select{width:100%;border:1px solid var(--line);background:#0b1426;color:var(--text);border-radius:10px;padding:12px;outline:none}.login-card input:focus,.field input:focus,.field select:focus{border-color:var(--blue)}.login-card button{width:100%;margin-top:18px;padding:12px}.error{color:#ff9aa8;min-height:20px;font-size:13px;margin-top:10px}
#app{display:none}.topbar{height:70px;border-bottom:1px solid var(--line);display:flex;align-items:center;justify-content:space-between;padding:0 28px;background:#0b1020d9;position:sticky;top:0;z-index:5;backdrop-filter:blur(14px)}.topbar .brand-mark{width:36px;height:36px;border-radius:11px}.topbar .brand h1{font-size:15px}.top-right{display:flex;align-items:center;gap:12px}.lan-tag{font-size:11px;color:var(--accent);border:1px solid #285a50;background:#102820;padding:6px 9px;border-radius:20px}.layout{display:grid;grid-template-columns:220px minmax(0,1fr);max-width:1480px;margin:auto;min-height:calc(100vh - 70px)}aside{padding:25px 15px;border-right:1px solid var(--line)}.nav-label{font-size:10px;letter-spacing:1.3px;color:#64748b;padding:8px 12px}.nav{display:flex;align-items:center;gap:11px;width:100%;text-align:left;background:transparent;border-color:transparent;color:#aab8ce;padding:11px 12px;margin:2px 0}.nav.active{color:var(--text);background:#1a2b43;border-color:#304565}.nav .ico{width:18px;text-align:center;color:var(--accent)}main{padding:30px;min-width:0}.page-head{display:flex;justify-content:space-between;gap:18px;align-items:center;margin-bottom:24px}.page-head h2{font-size:25px;letter-spacing:-.5px;margin:0}.page-head p{margin:6px 0 0;color:var(--muted);font-size:13px}.stats{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:14px;margin-bottom:20px}.stat,.card{background:linear-gradient(160deg,#15223a,#111a2c);border:1px solid var(--line);border-radius:var(--radius)}.stat{padding:17px}.stat .label{color:var(--muted);font-size:12px}.stat .value{font-size:27px;font-weight:750;margin-top:8px}.stat .sub{color:#6e809d;font-size:11px;margin-top:3px}.card{padding:19px;margin-bottom:16px}.card-head{display:flex;justify-content:space-between;align-items:center;gap:12px;margin-bottom:14px}.card-head h3{font-size:15px;margin:0}.card-head p{font-size:12px;color:var(--muted);margin:4px 0 0}.table-wrap{overflow:auto}table{width:100%;border-collapse:collapse;min-width:620px}th{text-align:left;font-size:10px;letter-spacing:.8px;text-transform:uppercase;color:#8292aa;font-weight:650;padding:11px;border-bottom:1px solid var(--line)}td{padding:13px 11px;border-bottom:1px solid #202d43;font-size:13px}tr:last-child td{border-bottom:0}.space-name{font-weight:700}.space-port{font-size:11px;color:var(--muted);margin-top:4px}.pill{display:inline-flex;align-items:center;gap:6px;border-radius:30px;padding:5px 8px;font-size:10px;border:1px solid var(--line);color:#b9c8dc}.pill:before{content:"";width:6px;height:6px;border-radius:50%;background:currentColor}.pill.on{color:var(--accent);border-color:#2b6054}.pill.off{color:#93a1b8}.pill.warn{color:var(--amber);border-color:#69552c}.actions{display:flex;flex-wrap:wrap;gap:6px}.actions a.small{display:inline-flex;align-items:center;text-decoration:none}.empty{padding:35px;text-align:center;color:var(--muted)}.toolbar{display:flex;gap:9px;align-items:center;flex-wrap:wrap}.field{min-width:150px}.field input,.field select{padding:9px}.log-box{background:#080e1a;border:1px solid #1d2a40;border-radius:12px;padding:15px;min-height:320px;max-height:58vh;overflow:auto;color:#c7d5e8;font:12px/1.65 ui-monospace,SFMono-Regular,Consolas,monospace;white-space:pre-wrap;overflow-wrap:anywhere}.terminal{background:#070c15;border:1px solid #26334d;border-radius:12px;overflow:hidden}.terminal-top{background:#121d30;padding:10px 13px;display:flex;justify-content:space-between;align-items:center;color:var(--muted);font-size:11px}.terminal-mount{height:min(62vh,620px);min-height:340px;padding:8px;background:#070c15}.terminal-mount .xterm{height:100%;padding:2px}.terminal-mount .xterm-viewport{overflow-y:auto!important}.terminal-keybar{display:flex;gap:6px;flex-wrap:wrap;padding:9px;background:#101a2b;border-top:1px solid #26334d}.terminal-keybar button{min-width:42px;padding:7px 10px;font:12px ui-monospace,monospace}.terminal-keybar button.active{background:var(--accent);color:#071a17;border-color:var(--accent)}.notice{padding:12px 14px;background:#17253b;border:1px solid #2d4568;border-radius:12px;color:#b9c9e1;font-size:12px;line-height:1.5;margin-bottom:16px}.notice.warn{background:#302617;border-color:#69552c;color:#f2d59a}.modal-backdrop{position:fixed;inset:0;background:#030711bf;display:grid;place-items:center;padding:18px;z-index:10}.modal{width:min(560px,100%);max-height:calc(100vh - 36px);overflow:auto;background:#15223a;border:1px solid #344865;border-radius:18px;padding:22px;box-shadow:0 25px 80px #0009}.modal h3{margin:0 0 8px}.modal p{font-size:13px;color:var(--muted);line-height:1.5}.secret{font-family:ui-monospace,monospace;word-break:break-all;background:#08111f;border:1px solid #304565;border-radius:10px;padding:13px;color:#8ce7c8;font-size:13px;margin:13px 0}.modal-actions{display:flex;justify-content:flex-end;gap:9px;margin-top:16px}.footer{color:#64748b;font-size:11px;text-align:center;padding:20px 0}.toast{position:fixed;right:22px;bottom:22px;background:#1d314b;border:1px solid #3e5c7d;border-radius:11px;padding:12px 16px;font-size:13px;z-index:20;box-shadow:0 12px 40px #0008;max-width:min(420px,calc(100vw - 40px))}
@media(max-width:900px){.stats{grid-template-columns:repeat(2,minmax(0,1fr))}.layout{grid-template-columns:1fr}aside{display:flex;gap:5px;overflow:auto;padding:8px 12px;border-right:0;border-bottom:1px solid var(--line);position:sticky;top:70px;background:#0b1020;z-index:4}.nav-label{display:none}.nav{white-space:nowrap;width:auto;margin:0}.nav .ico{display:none}main{padding:22px 16px}}@media(max-width:560px){.topbar{padding:0 14px}.lan-tag{display:none}main{padding:18px 12px}.stats{gap:9px}.stat{padding:13px}.stat .value{font-size:23px}.page-head{align-items:flex-start;flex-direction:column}.card{padding:14px}.terminal-mount{height:52vh;min-height:300px}.terminal-output{height:320px}}
</style>
</head><body>
<section id="login"><div class="login-card"><div class="brand"><div class="brand-mark">TS</div><div><h1>TermuxCodeSpace</h1><p>LOCAL ADMIN CONSOLE</p></div></div><h2>Admin sign in</h2><p class="muted" style="font-size:13px">Enter the randomly generated panel credential shown in Termux.</p><form id="loginForm"><label for="password">Admin credential</label><input id="password" type="password" autocomplete="current-password" required autofocus><button class="primary" type="submit">Unlock dashboard</button></form><div class="error" id="loginError"></div><div class="footer">Made By Aryan Giri | giriaryan694-a11y</div></div></section>
<section id="app"><header class="topbar"><div class="brand"><div class="brand-mark">TS</div><div><h1>TermuxCodeSpace</h1><p>ADMIN CONSOLE</p></div></div><div class="top-right"><span class="lan-tag">● WI-FI LAN ONLY</span><button class="quiet small" id="logoutBtn">Sign out</button></div></header>
<div class="layout"><aside><div class="nav-label">WORKSPACE</div><button class="nav active" data-page="overview"><span class="ico">◫</span>Overview</button><button class="nav" data-page="spaces"><span class="ico">▦</span>Codespaces</button><button class="nav" data-page="logs"><span class="ico">≋</span>Network logs</button><button class="nav" data-page="terminal"><span class="ico">›_</span>Terminal</button><div class="nav-label" style="margin-top:18px">SYSTEM</div><button class="nav" data-page="settings"><span class="ico">⚙</span>Settings</button></aside>
<main>
<div id="page-overview" class="page"><div class="page-head"><div><h2>Overview</h2><p>Manage your local codespaces from another device on the same Wi-Fi.</p></div><button class="primary" onclick="openCreate()">＋ New codespace</button></div><div class="notice">Panel access is restricted to this phone's Wi-Fi IP. Keep this credential private and use a trusted local network.</div><div class="stats"><div class="stat"><div class="label">Total codespaces</div><div class="value" id="statTotal">0</div><div class="sub">Managed environments</div></div><div class="stat"><div class="label">Running</div><div class="value" id="statRunning">0</div><div class="sub">Active code-server instances</div></div><div class="stat"><div class="label">Proxy enabled</div><div class="value" id="statProxy">0</div><div class="sub">Network logging available</div></div><div class="stat"><div class="label">Panel status</div><div class="value" style="font-size:20px;color:var(--accent)">ONLINE</div><div class="sub">Authenticated session</div></div></div><div class="card"><div class="card-head"><div><h3>Codespace activity</h3><p>Quick actions for your environments</p></div><button class="small" onclick="showPage('spaces')">View all →</button></div><div id="overviewSpaces"></div></div><div class="footer">Made By Aryan Giri | giriaryan694-a11y</div></div>
<div id="page-spaces" class="page hidden"><div class="page-head"><div><h2>Codespaces</h2><p>Create, import, export, start, stop, delete, or rotate credentials.</p></div><div class="toolbar"><button onclick="openImport()">＋ Import codespace</button><button class="primary" onclick="openCreate()">＋ New codespace</button></div></div><div class="card"><div class="card-head"><h3>All environments</h3><button class="small" onclick="loadState()">↻ Refresh</button></div><div id="spacesTable" class="table-wrap"></div></div><div class="footer">Made By Aryan Giri | giriaryan694-a11y</div></div>
<div id="page-logs" class="page hidden"><div class="page-head"><div><h2>Network logs</h2><p>HTTP requests and HTTPS CONNECT domains recorded by each codespace proxy.</p></div><button class="small" onclick="loadLogs()">↻ Refresh</button></div><div class="card"><div class="toolbar"><div class="field" style="min-width:220px"><label for="logSpace">Codespace</label><select id="logSpace"></select></div><div class="field"><label for="logLimit">Lines</label><select id="logLimit"><option>100</option><option selected>250</option><option>500</option></select></div><div style="align-self:end"><span id="logProxyStatus" class="pill off">Proxy off</span></div></div><pre class="log-box" id="logOutput">Choose a codespace to view its network log.</pre></div><div class="footer">Logs are per-codespace and stored locally on the phone.</div></div>
<div id="page-terminal" class="page hidden"><div class="page-head"><div><h2>Browser terminal</h2><p>Interactive PRoot shell with ANSI rendering, cursor control, resize, selection and terminal keyboard handling.</p></div></div><div class="notice warn">PRoot is a userspace environment, not a hardened security boundary. The browser terminal runs commands inside the selected codespace with its configured mounts.</div><div class="card"><div class="toolbar"><div class="field" style="min-width:230px"><label for="terminalSpace">Codespace</label><select id="terminalSpace"></select></div><button class="primary" id="terminalConnect">Connect terminal</button><button class="small danger" id="terminalDisconnect" disabled>Disconnect</button><span class="pill off" id="terminalStatus">Disconnected</span></div><div class="terminal" style="margin-top:14px"><div class="terminal-top"><span id="terminalLabel">No active session</span><span id="terminalTransportLabel">xterm.js · PTY</span></div><div id="terminalMount" class="terminal-mount" aria-label="Interactive shell terminal"></div><div class="terminal-keybar" aria-label="Mobile terminal keys"><button type="button" data-terminal-key="CTRL">CTRL</button><button type="button" data-terminal-key="ESC">ESC</button><button type="button" data-terminal-key="TAB">TAB</button><button type="button" data-terminal-key="UP">↑</button><button type="button" data-terminal-key="DOWN">↓</button><button type="button" data-terminal-key="LEFT">←</button><button type="button" data-terminal-key="RIGHT">→</button><button type="button" data-terminal-key="HOME">HOME</button><button type="button" data-terminal-key="END">END</button><button type="button" data-terminal-key="PGUP">PGUP</button><button type="button" data-terminal-key="PGDN">PGDN</button></div></div><p class="muted" style="font-size:12px;margin:10px 2px 0">Tip: tap the terminal to focus it. Select text to copy; use the browser context menu or Ctrl+Shift+V to paste. On mobile, use the extra-key bar for Ctrl, Tab and arrows.</p></div><div class="footer">Terminal sessions close when you disconnect, sign out or the panel server stops.</div></div>
<div id="page-settings" class="page hidden"><div class="page-head"><div><h2>Settings & credentials</h2><p>Control access to this LAN admin panel.</p></div></div><div class="card"><div class="card-head"><div><h3>Admin credential</h3><p>Generate a new random credential and revoke the current one.</p></div><span class="pill on">Protected</span></div><p class="muted" style="font-size:13px;line-height:1.6">The credential is stored in Termux's private app data with restrictive file permissions. Rotating it invalidates existing browser sessions and terminal sessions.</p><button class="danger" id="revokeAdmin">Revoke & generate new credential</button></div><div class="card"><h3 style="margin:0 0 10px">Network & transport</h3><p class="muted" style="font-size:13px;line-height:1.7;margin:0">Choose the network interface and HTTP or HTTPS mode from the Termux menu when enabling this panel. HTTP is plaintext: credentials, session cookies and terminal traffic are not encrypted, so use it only on a trusted private home network. For HTTPS, the panel uses a loopback HTTP backend and the <a href="https://github.com/giriaryan694-a11y/http2https" target="_blank" rel="noopener noreferrer">http2https</a> reverse proxy for browser-facing TLS. Do not expose either port through router forwarding or public Wi-Fi.</p></div><div class="footer">Made By Aryan Giri | giriaryan694-a11y</div></div>
</main></div></section>
<div id="modal" class="modal-backdrop hidden"><div class="modal" id="modalContent"></div></div><div id="toast" class="toast hidden"></div>
<script src="https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/lib/xterm.js" onerror="this.onerror=null;this.src='https://unpkg.com/@xterm/xterm@5.5.0/lib/xterm.js'"></script>
<script src="https://cdn.jsdelivr.net/npm/@xterm/addon-fit@0.10.0/lib/addon-fit.js" onerror="this.onerror=null;this.src='https://unpkg.com/@xterm/addon-fit@0.10.0/lib/addon-fit.js'"></script>
<script>
let csrf='',spaces=[],viewHosts=[],termId='',termCursor=0,pollTimer=null,logTimer=null;
let terminal=null,fitAddon=null,terminalSocket=null,terminalTransport="none",terminalSendQueue=Promise.resolve(),terminalPendingInput="",terminalFlushTimer=null,terminalCtrlSticky=false,terminalManualClose=false,terminalResizeObserver=null;
const $=id=>document.getElementById(id);
function esc(v){return String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}
function toast(msg){$('toast').textContent=msg;$('toast').classList.remove('hidden');setTimeout(()=>$('toast').classList.add('hidden'),3300)}
function modal(title,body,buttons){$('modalContent').innerHTML=`<h3>${title}</h3>${body}<div class="modal-actions">${buttons}</div>`;$('modal').classList.remove('hidden')}
function closeModal(){$('modal').classList.add('hidden')}
async function api(path,options={}){const headers={'Content-Type':'application/json',...(options.headers||{})};if(csrf&&options.method&&options.method!=='GET')headers['X-CSRF-Token']=csrf;const res=await fetch(path,{credentials:'same-origin',...options,headers});let data={};try{data=await res.json()}catch{}if(res.status===401){showLogin();throw new Error(data.error||'Session expired')}if(!res.ok)throw new Error(data.error||`Request failed (${res.status})`);return data}
function showLogin(){$('app').style.display='none';$('login').style.display='grid';csrf='';stopPolling();}
function showApp(){$('login').style.display='none';$('app').style.display='block';}
function showPage(page){document.querySelectorAll('.page').forEach(p=>p.classList.add('hidden'));$('page-'+page).classList.remove('hidden');document.querySelectorAll('.nav').forEach(n=>n.classList.toggle('active',n.dataset.page===page));if(page==='logs')loadLogs();if(page==='terminal')fillSpaceSelects();}
async function init(){try{const s=await api('/api/session');if(s.authenticated){csrf=s.csrf;showApp();await loadState()}else showLogin()}catch{showLogin()}}
$('loginForm').addEventListener('submit',async e=>{e.preventDefault();$('loginError').textContent='';try{const d=await api('/api/login',{method:'POST',body:JSON.stringify({password:$('password').value})});csrf=d.csrf;$('password').value='';showApp();await loadState()}catch(err){$('loginError').textContent=err.message}});
$('logoutBtn').onclick=async()=>{try{await api('/api/logout',{method:'POST',body:'{}'})}catch{}showLogin()};
document.querySelectorAll('.nav').forEach(n=>n.onclick=()=>showPage(n.dataset.page));
function codespaceViewHref(s){if(!s.running)return '';const port=Number(s.port);if(!Number.isInteger(port)||port<1||port>65535)return '';let host=window.location.hostname;const localHost=!host||host==='localhost'||host==='::1'||host==='127.0.0.1'||host.startsWith('127.');if(localHost)host=viewHosts.find(x=>/^\d{1,3}(?:\.\d{1,3}){3}$/.test(x))||'';if(!host)return '';const authority=host.includes(':')?`[${host}]`:host;return `http://${authority}:${port}/`}
function spaceRow(s){const status=s.running?'<span class="pill on">Running</span>':'<span class="pill off">Stopped</span>';const proxy=s.proxy?'<span class="pill on">Proxy on</span>':'<span class="pill off">Proxy off</span>';const net=s.netmode==='restricted'?'Restricted':'Open';const quota=s.quota>0?`${s.quota} MB (${s.quota_mode||'soft'})`:`Unlimited (${s.quota_mode||'soft'})`;const viewHref=codespaceViewHref(s);const viewAction=viewHref?`<a class="small primary" href="${esc(viewHref)}" target="_blank" rel="noopener noreferrer">View ↗</a>`:'';return `<tr><td><div class="space-name">${esc(s.name)}</div><div class="space-port">Port ${esc(s.port||'—')} · ${esc(quota)}</div></td><td>${status}</td><td>${proxy}<div class="space-port">${net} network mode</div></td><td><div class="actions">${viewAction}<button class="small" onclick="spaceAction('${esc(s.name)}','${s.running?'stop':'start'}')">${s.running?'Stop':'Start'}</button><button class="small" onclick="showPage('logs');$('logSpace').value='${esc(s.name)}';loadLogs()">Logs</button><button class="small" onclick="openTerminalFor('${esc(s.name)}')">CLI</button><button class="small" onclick="openDomainPolicy('${esc(s.name)}')">Policy</button><button class="small" onclick="toggleRestrict('${esc(s.name)}')">${s.netmode==='restricted'?'Open mode':'Restrict'}</button><button class="small" onclick="toggleProxy('${esc(s.name)}')">Proxy ${s.proxy?'off':'on'}</button><button class="small" onclick="openQuota('${esc(s.name)}')">Quota</button><button class="small" onclick="downloadExport('${esc(s.name)}')">Export</button><button class="small" onclick="revealSpacePassword('${esc(s.name)}')">Password</button><button class="small" onclick="spaceAction('${esc(s.name)}','revoke')">Revoke</button><button class="small danger" onclick="deleteSpace('${esc(s.name)}')">Delete</button></div></td></tr>`}
async function loadState(){try{const d=await api('/api/state');spaces=d.spaces||[];viewHosts=Array.isArray(d.view_hosts)?d.view_hosts:[];$('statTotal').textContent=spaces.length;$('statRunning').textContent=spaces.filter(s=>s.running).length;$('statProxy').textContent=spaces.filter(s=>s.proxy).length;const html=spaces.length?`<table><thead><tr><th>Codespace</th><th>Status</th><th>Network</th><th>Actions</th></tr></thead><tbody>${spaces.map(spaceRow).join('')}</tbody></table>`:'<div class="empty">No codespaces yet. Create your first environment.</div>';$('spacesTable').innerHTML=html;$('overviewSpaces').innerHTML=spaces.length?`<table><thead><tr><th>Codespace</th><th>Status</th><th>Network</th><th>Actions</th></tr></thead><tbody>${spaces.slice(0,5).map(spaceRow).join('')}</tbody></table>`:'<div class="empty">No environments found.</div>';fillSpaceSelects()}catch(e){toast(e.message)}}
function fillSpaceSelects(){for(const id of ['logSpace','terminalSpace']){const el=$(id),old=el.value;el.innerHTML=spaces.map(s=>`<option value="${esc(s.name)}">${esc(s.name)}</option>`).join('');if(spaces.some(s=>s.name===old))el.value=old}}
async function spaceAction(name,action,extra={}){try{const labels={revoke:'Rotating codespace credential…',start:`Starting ${name}…`,stop:`Stopping ${name}…`,proxy:`Updating ${name} proxy…`,restrict:`Updating ${name} network mode…`,quota:`Saving ${name} quota…`};toast(labels[action]||`Updating ${name}…`);const d=await api('/api/action',{method:'POST',body:JSON.stringify({action,name,...extra})});await loadState();if(d.password)showSecret(`${name} credential rotated`,d.password,`Code-server and recovery manager now use this new credential.`);else toast(d.message||'Action completed')}catch(e){toast(e.message)}}
async function toggleProxy(name){const s=spaces.find(x=>x.name===name);if(!s)return;await spaceAction(name,'proxy',{enabled:s.proxy?'off':'on'})}
async function toggleRestrict(name){const s=spaces.find(x=>x.name===name);if(!s)return;await spaceAction(name,'restrict',{mode:s.netmode==='restricted'?'open':'restricted'})}
async function openDomainPolicy(name){try{const d=await api(`/api/policy?name=${encodeURIComponent(name)}`);renderDomainPolicy(d)}catch(e){toast(e.message)}}
function renderDomainPolicy(p){const list=(items,kind)=>items.length?`<div style="display:grid;gap:7px;margin:8px 0 16px">${items.map((x,i)=>`<div class="toolbar" style="justify-content:space-between;background:#0d1728;border:1px solid #26334d;border-radius:9px;padding:8px 10px"><code>${esc(x)}</code><button class="small danger" onclick="removeDomainRule('${esc(p.name)}','${kind}',${i})">Remove</button></div>`).join('')}</div>`:'<p class="muted">No entries.</p>';modal(`Domain policy · ${esc(p.name)}`,`<p>Restricted mode permits only allowed domains and always denies blocked domains. Rules apply to traffic routed through this codespace proxy.</p><div class="field"><label>Network mode</label><select id="policyMode"><option value="open" ${p.mode==='open'?'selected':''}>Open</option><option value="restricted" ${p.mode==='restricted'?'selected':''}>Restricted</option></select></div><button class="small primary" onclick="savePolicyMode('${esc(p.name)}')">Save mode</button><h4>Blocked domains</h4>${list(p.blocked,'block')}<h4>Allowed domains</h4>${list(p.allowed,'allow')}<div class="field"><label>Domain</label><input id="policyDomain" placeholder="example.com" maxlength="253"></div><div class="toolbar"><button class="small danger" onclick="addDomainRule('${esc(p.name)}','block-add')">Block domain</button><button class="small primary" onclick="addDomainRule('${esc(p.name)}','allow-add')">Allow domain</button></div>`,`<button onclick="closeModal()">Close</button>`)}
async function savePolicyMode(name){try{await api('/api/domain-policy',{method:'POST',body:JSON.stringify({name,operation:'mode',mode:$('policyMode').value})});await loadState();await openDomainPolicy(name);toast('Network mode updated')}catch(e){toast(e.message)}}
async function addDomainRule(name,operation){const domain=$('policyDomain').value.trim();if(!domain){toast('Enter a domain');return}try{await api('/api/domain-policy',{method:'POST',body:JSON.stringify({name,operation,domain})});await openDomainPolicy(name);toast('Domain rule added')}catch(e){toast(e.message)}}
async function removeDomainRule(name,kind,index){try{await api('/api/domain-policy',{method:'POST',body:JSON.stringify({name,operation:`${kind}-remove`,index})});await openDomainPolicy(name);toast('Domain rule removed')}catch(e){toast(e.message)}}
function openQuota(name){const s=spaces.find(x=>x.name===name);if(!s)return;modal(`Storage quota · ${esc(name)}`,`<p>Current limit: <b>${esc(String(s.quota||0))} MB</b> (${esc(s.quota_mode||'soft')}). Set 0 MB for unlimited. Hard quota uses a loop-mounted filesystem and may require supported Android kernel features.</p><div class="field"><label>Quota (MB)</label><input id="quotaValue" type="number" min="0" max="100000" step="1" value="${esc(String(s.quota||0))}"></div><div class="field"><label>Enforcement</label><select id="quotaMode"><option value="soft" ${s.quota_mode!=='hard'?'selected':''}>Soft (monitored)</option><option value="hard" ${s.quota_mode==='hard'?'selected':''}>Hard (filesystem limit)</option></select></div>`,`<button onclick="closeModal()">Cancel</button><button class="primary" onclick="saveQuota('${esc(name)}')">Save quota</button>`)}
async function saveQuota(name){const quota=Number($('quotaValue').value),mode=$('quotaMode').value;if(!Number.isInteger(quota)||quota<0||quota>100000){toast('Quota must be 0–100000 MB');return}closeModal();await spaceAction(name,'quota',{quota,mode})}
async function revealSpacePassword(name){try{const d=await api('/api/reveal-credential',{method:'POST',body:JSON.stringify({name})});showStoredSecret(`${name} password`,d.password)}catch(e){toast(e.message)}}
function showStoredSecret(title,secret){modal(title,`<p>This is the currently stored code-server/recovery-manager password for this codespace.</p><div class="secret" id="secretValue">${esc(secret)}</div><p class="muted">Keep it private. Revealing it does not rotate or change the credential.</p>`,`<button onclick="closeModal()">Close</button><button class="primary" onclick="copySecret()">Copy password</button>`)}
async function deleteSpace(name){modal('Delete codespace',`<p>This permanently deletes <b>${esc(name)}</b> and its stored metadata. This cannot be undone.</p>`,`<button onclick="closeModal()">Cancel</button><button class="danger" onclick="confirmDelete('${esc(name)}')">Delete codespace</button>`)}
async function confirmDelete(name){closeModal();try{await api('/api/action',{method:'POST',body:JSON.stringify({action:'delete',name})});await loadState();toast(`${name} deleted`)}catch(e){toast(e.message)}}
function openImport(){modal('Import codespace',`<p>Import a TermuxCodeSpace <b>.tar.gz</b> or <b>.tgz</b> export. The archive includes the codespace filesystem and its code-server password. Only import archives you trust.</p><div class="field"><label>Archive file</label><input id="importFile" type="file" accept=".tar.gz,.tgz,application/gzip,application/x-gzip"></div><div class="field"><label>New codespace name</label><input id="importName" maxlength="48" placeholder="my-imported-space" pattern="[A-Za-z0-9_-]+"></div><p class="muted">The original archived password is preserved. Existing codespace names cannot be overwritten.</p>`,`<button onclick="closeModal()">Cancel</button><button class="primary" onclick="importSpace()">Import archive</button>`);$('importFile').addEventListener('change',()=>{const f=$('importFile').files[0];if(f&&!$('importName').value){$('importName').value=f.name.replace(/\.(tar\.gz|tgz)$/i,'').replace(/[^A-Za-z0-9_-]/g,'-').slice(0,48)}})}
async function importSpace(){const file=$('importFile').files[0],name=$('importName').value.trim();if(!file){toast('Choose an archive first');return}if(!/^[A-Za-z0-9_-]{1,48}$/.test(name)){toast('Use 1–48 letters, numbers, _ or -');return}closeModal();toast('Uploading and validating codespace archive…');try{const res=await fetch('/api/import',{method:'POST',credentials:'same-origin',headers:{'Content-Type':'application/gzip','X-CSRF-Token':csrf,'X-Codespace-Name':name},body:file});let d={};try{d=await res.json()}catch{}if(res.status===401){showLogin();throw new Error(d.error||'Session expired')}if(!res.ok)throw new Error(d.error||`Import failed (${res.status})`);await loadState();toast(`${name} imported. Original password preserved.`)}catch(e){toast(e.message)}}
async function downloadExport(name){if(!confirm(`Export ${name} as a private .tar.gz archive? The archive contains its code-server password.`))return;toast(`Preparing ${name} export…`);try{const res=await fetch('/api/export',{method:'POST',credentials:'same-origin',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf},body:JSON.stringify({name})});if(res.status===401){let d={};try{d=await res.json()}catch{}showLogin();throw new Error(d.error||'Session expired')}if(!res.ok){let d={};try{d=await res.json()}catch{}throw new Error(d.error||`Export failed (${res.status})`)}const blob=await res.blob(),url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download=`${name}.tar.gz`;document.body.appendChild(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),30000);toast(`${name}.tar.gz downloaded. Store it privately.`)}catch(e){toast(e.message)}}
function openCreate(){modal('Create codespace',`<div class="field"><label>Name</label><input id="newName" maxlength="48" placeholder="my-project" pattern="[A-Za-z0-9_-]+"></div><div class="field"><label>Storage quota (MB, 0 = unlimited)</label><input id="newQuota" type="number" min="0" max="100000" value="0"></div><p>A fresh Ubuntu clone will be created and started automatically. The generated code-server credential is shown once.</p>`,`<button onclick="closeModal()">Cancel</button><button class="primary" onclick="createSpace()">Create & start</button>`)}
async function createSpace(){const name=$('newName').value.trim(),quota=Number($('newQuota').value||0);if(!/^[A-Za-z0-9_-]{1,48}$/.test(name)){toast('Use 1–48 letters, numbers, _ or -');return}if(!Number.isInteger(quota)||quota<0||quota>100000){toast('Invalid quota');return}closeModal();toast('Creating and starting codespace…');try{const d=await api('/api/action',{method:'POST',body:JSON.stringify({action:'create',name,quota})});await loadState();showSecret(`${name} created`,d.password,`Code-server URL: http://${location.hostname}:${d.port}\nSave this credential. It is stored privately on the phone.`)}catch(e){toast(e.message)}}
function showSecret(title,secret,description){modal(title,`<p>${esc(description).replace(/\n/g,'<br>')}</p><div class="secret" id="secretValue">${esc(secret)}</div><p class="muted">Copy this now. The old credential has been revoked.</p>`,`<button onclick="closeModal()">Close</button><button class="primary" onclick="copySecret()">Copy credential</button>`)}
async function copySecret(){try{await navigator.clipboard.writeText($('secretValue').textContent);toast('Credential copied')}catch{toast('Clipboard unavailable; select and copy it manually')}}
$('logSpace').onchange=loadLogs;$('logLimit').onchange=loadLogs;
async function loadLogs(){if(!$('logSpace').value){$('logOutput').textContent='No codespaces available.';return}try{const name=$('logSpace').value,limit=$('logLimit').value,d=await api(`/api/logs?name=${encodeURIComponent(name)}&limit=${limit}`);$('logOutput').textContent=d.lines||'No network activity logged yet.';$('logProxyStatus').textContent=d.proxy?'Proxy on':'Proxy off';$('logProxyStatus').className='pill '+(d.proxy?'on':'off');$('logOutput').scrollTop=$('logOutput').scrollHeight}catch(e){$('logOutput').textContent=e.message}}
$('terminalConnect').onclick=()=>connectTerminal($('terminalSpace').value);$('terminalDisconnect').onclick=disconnectTerminal;
function initTerminalUI(){
 if(terminal)return true;
 if(typeof window.Terminal==='undefined'||typeof window.FitAddon==='undefined'||!$('terminalMount')){
  $('terminalMount').textContent='The terminal renderer could not load. Check the browser internet connection and reload the admin panel.';
  return false;
 }
 terminal=new window.Terminal({cursorBlink:true,convertEol:false,scrollback:6000,allowProposedApi:false,fontSize:13,lineHeight:1.25,fontFamily:'ui-monospace, SFMono-Regular, Consolas, monospace',theme:{background:'#070c15',foreground:'#d7e5f7',cursor:'#62d6b1',selectionBackground:'#365b82',black:'#101827',red:'#ff7185',green:'#62d6b1',yellow:'#f2c36b',blue:'#7ba7ff',magenta:'#c89bff',cyan:'#66d9e8',white:'#d7e5f7',brightBlack:'#52627c',brightRed:'#ff8b9b',brightGreen:'#8ce7c8',brightYellow:'#ffda91',brightBlue:'#9bbcff',brightMagenta:'#d6b5ff',brightCyan:'#8cecf6',brightWhite:'#ffffff'}});
 fitAddon=new window.FitAddon.FitAddon();terminal.loadAddon(fitAddon);terminal.open($('terminalMount'));
 terminal.onData(data=>{if(terminalCtrlSticky&&data.length===1){const c=data.toLowerCase().charCodeAt(0);if(c>=97&&c<=122)data=String.fromCharCode(c-96);else if(data===' ')data='\0';terminalCtrlSticky=false;document.querySelector('[data-terminal-key="CTRL"]').classList.remove('active')}queueTerminalData(data)});
 terminal.onResize(({cols,rows})=>{if(termId)queueTerminalResize(cols,rows)});
 terminalResizeObserver=new ResizeObserver(()=>{if(terminal&&$('page-terminal')&&!$('page-terminal').classList.contains('hidden')){try{fitAddon.fit()}catch{}}});terminalResizeObserver.observe($('terminalMount'));
 document.querySelectorAll('[data-terminal-key]').forEach(btn=>btn.addEventListener('click',()=>sendMobileTerminalKey(btn.dataset.terminalKey,btn)));
 return true;
}
function sendMobileTerminalKey(key,button){if(!terminal)return;const seq={ESC:'\x1b',TAB:'\t',UP:'\x1b[A',DOWN:'\x1b[B',LEFT:'\x1b[D',RIGHT:'\x1b[C',HOME:'\x1b[H',END:'\x1b[F',PGUP:'\x1b[5~',PGDN:'\x1b[6~'};if(key==='CTRL'){terminalCtrlSticky=!terminalCtrlSticky;button.classList.toggle('active',terminalCtrlSticky);terminal.focus();return}const value=seq[key];if(value)queueTerminalData(value);terminal.focus()}
function openTerminalFor(name){showPage('terminal');$('terminalSpace').value=name;connectTerminal(name)}
function terminalSocketUrl(id){const u=new URL('/ws/terminal',location.href);u.protocol=location.protocol==='https:'?'wss:':'ws:';u.searchParams.set('id',id);return u.toString()}
function connectTerminalSocket(id){return new Promise((resolve,reject)=>{let settled=false;const ws=new WebSocket(terminalSocketUrl(id));ws.binaryType='arraybuffer';const timer=setTimeout(()=>{if(!settled){settled=true;try{ws.close()}catch{}reject(new Error('WebSocket handshake timed out'))}},2200);ws.onopen=()=>{if(settled)return;settled=true;clearTimeout(timer);terminalSocket=ws;terminalTransport='websocket';$('terminalTransportLabel').textContent='xterm.js · WebSocket · PTY';ws.send(JSON.stringify({type:'resize',cols:terminal.cols,rows:terminal.rows}));resolve(true)};ws.onmessage=event=>{if(!termId||terminalSocket!==ws)return;if(event.data instanceof ArrayBuffer)terminal.write(new Uint8Array(event.data));else if(typeof event.data==='string')terminal.write(event.data)};ws.onerror=()=>{if(!settled){settled=true;clearTimeout(timer);reject(new Error('WebSocket unavailable'))}};ws.onclose=()=>{if(terminalSocket===ws){terminalSocket=null;if(termId&&!terminalManualClose){$('terminalStatus').textContent='Terminal connection closed';$('terminalStatus').className='pill warn'}}};})}
async function connectTerminal(name){if(!name){toast('Select a codespace');return}if(!initTerminalUI())return;await disconnectTerminal();terminal.clear();terminal.writeln('Connecting to '+name+'…');try{fitAddon.fit();const d=await api('/api/terminal/start',{method:'POST',body:JSON.stringify({name,cols:terminal.cols||100,rows:terminal.rows||28})});termId=d.id;termCursor=0;$('terminalLabel').textContent=`${name} · /root`;$('terminalStatus').textContent='Connected';$('terminalStatus').className='pill on';$('terminalDisconnect').disabled=false;terminal.focus();
 if(location.protocol==='http:'){try{await connectTerminalSocket(termId)}catch{terminalTransport='poll';$('terminalTransportLabel').textContent='xterm.js · HTTP fallback';terminal.writeln('\r\n[WebSocket unavailable; using authenticated HTTP input/output.]')}}else{terminalTransport='poll';$('terminalTransportLabel').textContent='xterm.js · HTTPS proxy fallback';terminal.writeln('\r\n[HTTPS proxy does not currently forward WebSocket upgrades; using authenticated HTTP input/output.]')}
 if(terminalTransport==='poll'){pollTimer=setInterval(pollTerminal,140);await pollTerminal();queueTerminalResize(terminal.cols,terminal.rows)}toast('Terminal connected')}catch(e){terminal.writeln('\r\n[Terminal error] '+e.message);$('terminalStatus').textContent='Error';$('terminalStatus').className='pill warn';toast(e.message)}}
async function pollTerminal(){if(!termId||terminalTransport!=='poll')return;try{const d=await api(`/api/terminal/poll?id=${encodeURIComponent(termId)}&offset=${termCursor}`);if(d.output){terminal.write(d.output);termCursor=d.next}if(d.closed){terminal.writeln('\r\n[Shell exited]');$('terminalStatus').textContent='Exited';$('terminalStatus').className='pill off';stopPolling()}}catch(e){toast(e.message);stopPolling()}}
function queueTerminalData(data){if(!termId||!data)return;if(terminalSocket&&terminalSocket.readyState===WebSocket.OPEN){terminalSocket.send(data);return}terminalPendingInput+=data;if(!terminalFlushTimer)terminalFlushTimer=setTimeout(flushTerminalInput,12)}
async function flushTerminalInput(){terminalFlushTimer=null;const id=termId;if(!id||!terminalPendingInput)return;const chars=Array.from(terminalPendingInput);const batch=chars.slice(0,8000).join('');terminalPendingInput=chars.slice(8000).join('');try{await api('/api/terminal/input',{method:'POST',body:JSON.stringify({id,data:batch})})}catch(e){toast(e.message)}if(terminalPendingInput&&!terminalFlushTimer)terminalFlushTimer=setTimeout(flushTerminalInput,0)}
function queueTerminalResize(cols,rows){if(!termId||!cols||!rows)return;cols=Math.max(20,Math.min(240,cols|0));rows=Math.max(5,Math.min(100,rows|0));if(terminalSocket&&terminalSocket.readyState===WebSocket.OPEN){terminalSocket.send(JSON.stringify({type:'resize',cols,rows}));return}const id=termId;api('/api/terminal/resize',{method:'POST',body:JSON.stringify({id,cols,rows})}).catch(()=>{})}
function stopPolling(){if(pollTimer)clearInterval(pollTimer);pollTimer=null}
async function disconnectTerminal(){stopPolling();if(terminalFlushTimer){clearTimeout(terminalFlushTimer);terminalFlushTimer=null}terminalPendingInput='';terminalManualClose=true;const id=termId;termId='';const ws=terminalSocket;terminalSocket=null;terminalTransport='none';if(ws){try{ws.close(1000,'user disconnect')}catch{}}if(id){try{await api('/api/terminal/stop',{method:'POST',body:JSON.stringify({id})})}catch{}}terminalManualClose=false;$('terminalStatus').textContent='Disconnected';$('terminalStatus').className='pill off';$('terminalDisconnect').disabled=true;if(terminalCtrlSticky){terminalCtrlSticky=false;const b=document.querySelector('[data-terminal-key="CTRL"]');if(b)b.classList.remove('active')}}
$('revokeAdmin').onclick=()=>modal('Revoke admin credential',`<p>This invalidates the current panel password, all browser sessions, and active browser terminals. A new random credential will be generated.</p>`,`<button onclick="closeModal()">Cancel</button><button class="danger" onclick="rotateAdmin()">Revoke credential</button>`);
async function rotateAdmin(){closeModal();try{const d=await api('/api/revoke-admin',{method:'POST',body:'{}'});showLogin();modal('New admin credential',`<p>Old sessions and terminal sessions have been revoked. Save this new credential.</p><div class="secret" id="secretValue">${esc(d.password)}</div>`,`<button class="primary" onclick="copySecret()">Copy credential</button><button onclick="closeModal()">Close</button>`)}catch(e){toast(e.message)}}
$('modal').addEventListener('click',e=>{if(e.target===$('modal'))closeModal()});
init();setInterval(()=>{if($('app').style.display==='block')loadState()},12000);
</script></body></html>'''

class PanelState:
    def __init__(self, args):
        self.base = Path(args.base_dir).resolve()
        self.meta = self.base / "meta"
        self.spaces = self.base / "codespaces"
        self.script = str(Path(args.script).resolve())
        self.prefix = args.prefix
        self.proot = args.proot
        self.bind = args.bind
        self.allowed_hosts = {value.strip().lower() for value in args.allowed_hosts.split(",") if value.strip()}
        self.view_hosts = [value.strip() for value in args.view_hosts.split(",") if value.strip()]
        self.port = args.port
        self.origin_port = args.origin_port
        self.public_protocol = args.public_protocol
        self.secure_cookies = args.secure_cookies == "1"
        self.password_file = self.meta / ".admin.pass"
        self.sessions = {}
        self.failures = {}
        self.terminals = {}
        self.lock = threading.RLock()
        self.archive_lock = threading.Lock()

    def valid_name(self, name):
        return bool(NAME_RE.fullmatch(str(name or ""))) and (self.spaces / str(name)).is_dir()

    def names(self):
        try:
            return sorted(p.name for p in self.spaces.iterdir() if p.is_dir() and NAME_RE.fullmatch(p.name))
        except OSError:
            return []

    def password(self):
        try:
            return self.password_file.read_text(encoding="utf-8").strip()
        except OSError:
            return ""

    def run_action(self, action, *values, timeout=1800):
        cmd = ["bash", self.script, "--admin-action", action, *[str(x) for x in values]]
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=os.environ.copy())
        except subprocess.TimeoutExpired:
            raise RuntimeError("Action timed out. Check the Termux logs and available storage.")
        if proc.returncode != 0:
            detail = (proc.stderr or proc.stdout or "No details returned.").strip()
            raise RuntimeError(detail[-1800:])
        return proc.stdout.strip()

    def space_state(self, name):
        pidfile = self.meta / f"{name}.pid"
        running = False
        try:
            pid = int(pidfile.read_text().strip())
            os.kill(pid, 0)
            cmdline = Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode("utf-8", "replace")
            running = "--rootfs=" + str(self.spaces / name) in cmdline or (self.meta / f"{name}.launcher.sh").name in cmdline or "code-server" in cmdline
        except (OSError, ValueError):
            running = False
        if not running:
            try:
                pidfile.unlink()
            except OSError:
                pass
        def read(suffix, default=""):
            try:
                return (self.meta / f"{name}.{suffix}").read_text(encoding="utf-8").strip()
            except OSError:
                return default
        proxy = read("proxyenabled", "on") == "on"
        quota = read("quota", "0")
        if not quota.isdigit():
            quota = "0"
        quota_mode = read("quota.mode", "soft")
        if quota_mode not in {"soft", "hard"}:
            quota_mode = "soft"
        return {"name": name, "running": running, "proxy": proxy, "netmode": read("netmode", "open"), "port": read("port"), "quota": int(quota), "quota_mode": quota_mode}

    def close_terminal(self, terminal_id):
        term = self.terminals.pop(terminal_id, None)
        if not term:
            return
        proc = term.get("proc")
        try:
            if proc and proc.poll() is None:
                os.killpg(proc.pid, signal.SIGTERM)
                try:
                    proc.wait(timeout=1.2)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
        except (OSError, ProcessLookupError):
            pass
        try:
            os.close(term["master"])
        except OSError:
            pass

    def close_user_terminals(self, owner):
        with self.lock:
            for tid, term in list(self.terminals.items()):
                if term.get("owner") == owner:
                    self.close_terminal(tid)

    def close_space_terminals(self, name):
        with self.lock:
            for tid, term in list(self.terminals.items()):
                if term.get("name") == name:
                    self.close_terminal(tid)

    def clean_sessions(self):
        now = time.time()
        with self.lock:
            for sid, session in list(self.sessions.items()):
                if now - session.get("last", now) > SESSION_TTL:
                    self.close_user_terminals(sid)
                    self.sessions.pop(sid, None)

STATE = None

class AdminServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def _archive_relpath(raw):
    if not isinstance(raw, str) or "\x00" in raw or "\\" in raw:
        raise ValueError("Archive contains an invalid path")
    if raw.startswith("/"):
        raise ValueError("Archive contains an absolute path")
    parts = [part for part in raw.split("/") if part not in ("", ".")]
    if not parts or any(part == ".." for part in parts):
        raise ValueError("Archive contains a path traversal entry")
    return "/".join(parts)


def _ensure_real_directories(root, parts):
    current = root
    for part in parts:
        current = current / part
        try:
            st = current.lstat()
            if not stat.S_ISDIR(st.st_mode):
                raise ValueError("Archive path traverses a non-directory entry")
        except FileNotFoundError:
            current.mkdir(mode=0o755)
    return current


def extract_codespace_archive(archive_path, staging_dir):
    """Validate and extract the existing CLI .tar.gz format without following archive symlinks."""
    staging_dir = Path(staging_dir)
    staging_dir.mkdir(mode=0o700, parents=True, exist_ok=False)
    with tarfile.open(archive_path, mode="r:gz") as tf:
        members = tf.getmembers()
        if not members or len(members) > MAX_ARCHIVE_MEMBERS:
            raise ValueError("Archive is empty or contains too many entries")
        normalized = []
        roots = set()
        seen = set()
        metadata_member = None
        total_size = 0
        for member in members:
            rel = _archive_relpath(member.name)
            if rel in seen:
                raise ValueError("Archive contains duplicate paths")
            seen.add(rel)
            if rel == "codespace.meta":
                if metadata_member is not None or not member.isreg() or member.size > 8192:
                    raise ValueError("Invalid codespace metadata entry")
                metadata_member = member
            else:
                roots.add(rel.split("/", 1)[0])
            if member.isreg():
                total_size += member.size
            elif not (member.isdir() or member.issym() or member.islnk()):
                raise ValueError("Archive contains an unsupported special file")
            normalized.append((member, rel))
        if metadata_member is None or len(roots) != 1:
            raise ValueError("This is not a TermuxCodeSpace export archive")
        original_name = next(iter(roots))
        if not NAME_RE.fullmatch(original_name):
            raise ValueError("Archive contains an invalid codespace name")
        if total_size > shutil.disk_usage(staging_dir.parent).free - 64 * 1024 * 1024:
            raise ValueError("Not enough free storage to extract this archive safely")

        meta_fp = tf.extractfile(metadata_member)
        if meta_fp is None:
            raise ValueError("Codespace metadata is unreadable")
        metadata_raw = meta_fp.read(8193)
        if len(metadata_raw) > 8192:
            raise ValueError("Codespace metadata is too large")
        metadata = {}
        for line in metadata_raw.decode("utf-8", "strict").splitlines():
            key, sep, value = line.partition("=")
            if sep and key in {"name", "port", "pass"}:
                metadata[key] = value
        if metadata.get("name") and not NAME_RE.fullmatch(metadata["name"]):
            raise ValueError("Codespace metadata contains an invalid name")
        if metadata.get("port") and (not metadata["port"].isdigit() or not 1 <= int(metadata["port"]) <= 65535):
            raise ValueError("Codespace metadata contains an invalid port")
        if metadata.get("pass") and not re.fullmatch(r"[A-Za-z0-9_-]{8,256}", metadata["pass"]):
            raise ValueError("Codespace metadata contains an invalid credential")

        if metadata.get("name") != original_name:
            raise ValueError("Codespace metadata name does not match the archive root")
        root_dir = staging_dir / original_name
        root_dir.mkdir(mode=0o755)
        meta_path = staging_dir / "codespace.meta"
        meta_path.write_bytes(metadata_raw)
        hardlinks = []
        directory_modes = [(root_dir, 0o755)]
        for member, rel in normalized:
            if rel == "codespace.meta":
                continue
            parts = rel.split("/")
            if parts[0] != original_name:
                raise ValueError("Archive mixes multiple codespaces")
            if len(parts) == 2 and parts[1] in {".l2s", "data", "dev", "proc", "sys", "storage", "sdcard", "system", "system_ext", "apex", "vendor", "product", "odm", "linkerconfig"}:
                raise ValueError("Archive includes a host-bound directory excluded by the CLI export format")
            subparts = parts[1:]
            if not subparts:
                if not member.isdir():
                    raise ValueError("Codespace archive root must be a directory")
                directory_modes[0] = (root_dir, member.mode & 0o1777 or 0o755)
                continue
            parent = _ensure_real_directories(root_dir, subparts[:-1])
            target = parent / subparts[-1]
            if member.isdir():
                try:
                    existing = target.lstat()
                    if not stat.S_ISDIR(existing.st_mode):
                        raise ValueError("Archive directory conflicts with another entry")
                except FileNotFoundError:
                    target.mkdir(mode=member.mode & 0o777 or 0o755)
                directory_modes.append((target, member.mode & 0o1777 or 0o755))
            elif member.issym():
                if target.exists() or target.is_symlink():
                    raise ValueError("Archive contains duplicate filesystem entries")
                os.symlink(member.linkname, target)
            elif member.islnk():
                link_rel = _archive_relpath(member.linkname)
                if not link_rel.startswith(original_name + "/"):
                    raise ValueError("Archive hard link points outside the codespace")
                hardlinks.append((target, link_rel))
            elif member.isreg():
                source = tf.extractfile(member)
                if source is None:
                    raise ValueError("Archive file data is unreadable")
                flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
                fd = os.open(str(target), flags, member.mode & 0o777 or 0o600)
                with os.fdopen(fd, "wb") as out:
                    shutil.copyfileobj(source, out, length=1024 * 1024)
                try:
                    os.chmod(target, member.mode & 0o777)
                except OSError:
                    pass
        for target, link_rel in hardlinks:
            source_parts = link_rel.split("/")[1:]
            source_parent = _ensure_real_directories(root_dir, source_parts[:-1])
            source = source_parent / source_parts[-1]
            try:
                st = source.lstat()
            except FileNotFoundError:
                raise ValueError("Archive hard-link target is missing")
            if not stat.S_ISREG(st.st_mode):
                raise ValueError("Archive hard-link target is not a regular file")
            if target.exists() or target.is_symlink():
                raise ValueError("Archive contains duplicate filesystem entries")
            os.link(source, target)
        # These directories are touched by prepare_codespace_rootfs and
        # write_codeserver_settings; reject links here to prevent writes escaping staging.
        for rel in ("etc", "usr", "root", "tmp", "dev", "proc", "sys", "run"):
            target = root_dir / rel
            if target.exists() or target.is_symlink():
                if not stat.S_ISDIR(target.lstat().st_mode):
                    raise ValueError("Archive has an unsafe rootfs directory: " + rel)
        for rel in ("root/.local", "root/.local/share", "root/.local/share/code-server", "root/.local/share/code-server/User", "root/.config", "root/.config/code-server", "usr/sbin", "usr/bin", "etc/apt"):
            target = root_dir / rel
            if target.exists() or target.is_symlink():
                if not stat.S_ISDIR(target.lstat().st_mode):
                    raise ValueError("Archive has an unsafe rootfs path: " + rel)
        for rel in ("etc/machine-id", "usr/sbin/policy-rc.d", "usr/bin/sudo", "root/.local/share/code-server/User/settings.json", "root/.config/code-server/config.yaml"):
            target = root_dir / rel
            if target.is_symlink():
                raise ValueError("Archive has an unsafe rootfs file: " + rel)
        for target, mode in reversed(directory_modes):
            try:
                os.chmod(target, mode)
            except OSError:
                pass
        return original_name, metadata


class Handler(BaseHTTPRequestHandler):
    server_version = "TermuxCodeSpaceAdmin/1.0"
    sys_version = ""

    def log_message(self, fmt, *args):
        # Keep credentials and request payloads out of access logs.
        try:
            with open(STATE.meta / "admin.access.log", "a", encoding="utf-8") as f:
                f.write("[{}] {} {}\n".format(time.strftime("%Y-%m-%d %H:%M:%S"), self.client_address[0], fmt % args))
        except OSError:
            pass

    def security_headers(self):
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
        self.send_header("Cache-Control", "no-store")

    def send_json(self, status, obj, headers=None):
        raw = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.security_headers()
        if headers:
            for key, value in headers.items():
                self.send_header(key, value)
        self.end_headers()
        self.wfile.write(raw)

    def send_html(self):
        raw = HTML.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.security_headers()
        self.send_header("Content-Security-Policy", "default-src 'self'; style-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net https://unpkg.com; script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net https://unpkg.com; img-src 'self' data:; connect-src 'self' ws: wss:; object-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
        self.end_headers()
        self.wfile.write(raw)

    def host_ok(self):
        host = self.headers.get("Host", "").strip().lower()
        if host in {f"localhost:{STATE.port}", f"127.0.0.1:{STATE.port}"}:
            return True
        # When bound to 0.0.0.0, accept only IPs actually discovered on this
        # device. This preserves Host-header protection without assuming wlan0.
        if host.count(":") != 1:
            return False
        host_ip, host_port = host.rsplit(":", 1)
        return host_port == str(STATE.port) and host_ip in STATE.allowed_hosts

    def cookie_sid(self):
        cookie = http.cookies.SimpleCookie()
        try:
            cookie.load(self.headers.get("Cookie", ""))
            return cookie.get("TCS_ADMIN_SID").value if cookie.get("TCS_ADMIN_SID") else ""
        except Exception:
            return ""

    def session(self):
        STATE.clean_sessions()
        sid = self.cookie_sid()
        with STATE.lock:
            data = STATE.sessions.get(sid)
            if data and data.get("ip") == self.client_address[0]:
                data["last"] = time.time()
                return sid, data
        return "", None

    def require_auth(self):
        sid, session = self.session()
        if not session:
            self.send_json(401, {"error": "Authentication required"})
            return None
        return sid, session

    def read_body(self):
        try:
            size = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            raise ValueError("Invalid Content-Length")
        if size < 0 or size > MAX_BODY:
            raise ValueError("Request body too large")
        raw = self.rfile.read(size)
        try:
            return json.loads(raw.decode("utf-8") or "{}")
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise ValueError("Invalid JSON body")

    def verify_csrf(self, session):
        token = self.headers.get("X-CSRF-Token", "")
        return bool(token) and hmac.compare_digest(token, session.get("csrf", ""))

    def ws_send_frame(self, opcode, payload=b""):
        if isinstance(payload, str):
            payload = payload.encode("utf-8")
        length = len(payload)
        head = bytearray([0x80 | (opcode & 0x0F)])
        if length < 126:
            head.append(length)
        elif length < 65536:
            head.append(126)
            head.extend(struct.pack("!H", length))
        else:
            head.append(127)
            head.extend(struct.pack("!Q", length))
        self.connection.sendall(bytes(head) + payload)

    def resize_terminal(self, term, cols, rows):
        cols = max(20, min(240, int(cols)))
        rows = max(5, min(100, int(rows)))
        fcntl.ioctl(term["master"], termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    def handle_terminal_websocket(self, parsed):
        # WebSocket authentication uses the existing HttpOnly session cookie plus
        # a strict Origin allowlist. This blocks cross-site WebSocket hijacking.
        sid, session = self.session()
        if not session:
            self.send_json(401, {"error": "Authentication required"})
            return
        origin = urllib.parse.urlsplit(self.headers.get("Origin", ""))
        origin_host = (origin.hostname or "").lower()
        allowed_origins = set(STATE.allowed_hosts) | {"localhost", "127.0.0.1"}
        if origin.scheme != STATE.public_protocol or origin_host not in allowed_origins or origin.port != STATE.origin_port:
            self.send_json(403, {"error": "WebSocket Origin rejected"})
            return
        if self.headers.get("Upgrade", "").lower() != "websocket" or "upgrade" not in self.headers.get("Connection", "").lower():
            self.send_json(426, {"error": "WebSocket upgrade required"}, {"Upgrade": "websocket"})
            return
        key = self.headers.get("Sec-WebSocket-Key", "")
        try:
            decoded_key = base64.b64decode(key, validate=True)
        except Exception:
            decoded_key = b""
        if len(decoded_key) != 16 or self.headers.get("Sec-WebSocket-Version") != "13":
            self.send_json(400, {"error": "Invalid WebSocket handshake"})
            return
        q = urllib.parse.parse_qs(parsed.query)
        tid = (q.get("id") or [""])[0]
        with STATE.lock:
            term = STATE.terminals.get(tid)
            if not term or term.get("owner") != sid:
                self.send_json(404, {"error": "Terminal session not found"})
                return
        accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")).digest()).decode("ascii")
        self.send_response(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        self.wfile.flush()
        self.close_connection = True
        sock = self.connection
        sock.settimeout(0.05)
        recv_buffer = bytearray()
        output_offset = 0
        fragment_opcode = None
        fragment_payload = bytearray()
        try:
            while True:
                with STATE.lock:
                    current = STATE.terminals.get(tid)
                    if not current or current.get("owner") != sid:
                        break
                    base = current["base"]
                    output = current["output"]
                    exited = current["proc"].poll() is not None
                    master = current["master"]
                if output_offset < base:
                    output_offset = base
                start = max(0, output_offset - base)
                outgoing = output[start:]
                if outgoing:
                    self.ws_send_frame(2, outgoing.encode("utf-8", "replace"))
                    output_offset = base + len(output)
                if exited:
                    self.ws_send_frame(8, struct.pack("!H", 1000) + b"shell exited")
                    break
                try:
                    packet = sock.recv(65536)
                except socket.timeout:
                    continue
                if not packet:
                    break
                recv_buffer.extend(packet)
                while len(recv_buffer) >= 2:
                    b1, b2 = recv_buffer[0], recv_buffer[1]
                    fin = bool(b1 & 0x80)
                    opcode = b1 & 0x0F
                    masked = bool(b2 & 0x80)
                    length = b2 & 0x7F
                    pos = 2
                    if length == 126:
                        if len(recv_buffer) < 4: break
                        length = struct.unpack("!H", recv_buffer[2:4])[0]; pos = 4
                    elif length == 127:
                        if len(recv_buffer) < 10: break
                        length = struct.unpack("!Q", recv_buffer[2:10])[0]; pos = 10
                    if length > 1024 * 1024:
                        self.ws_send_frame(8, struct.pack("!H", 1009) + b"frame too large")
                        return
                    if not masked:
                        self.ws_send_frame(8, struct.pack("!H", 1002) + b"client frame must be masked")
                        return
                    if len(recv_buffer) < pos + 4 + length: break
                    mask = recv_buffer[pos:pos + 4]; pos += 4
                    payload = bytes(value ^ mask[i % 4] for i, value in enumerate(recv_buffer[pos:pos + length]))
                    del recv_buffer[:pos + length]
                    if opcode == 8:
                        try: self.ws_send_frame(8, payload[:125])
                        except OSError: pass
                        return
                    if opcode == 9:
                        self.ws_send_frame(10, payload[:125])
                        continue
                    if opcode == 10:
                        continue
                    if opcode in (1, 2):
                        if fragment_opcode is not None:
                            self.ws_send_frame(8, struct.pack("!H", 1002) + b"nested fragment")
                            return
                        if not fin:
                            fragment_opcode = opcode
                            fragment_payload.extend(payload)
                            continue
                    elif opcode == 0:
                        if fragment_opcode is None:
                            self.ws_send_frame(8, struct.pack("!H", 1002) + b"unexpected continuation")
                            return
                        fragment_payload.extend(payload)
                        if len(fragment_payload) > 1024 * 1024:
                            self.ws_send_frame(8, struct.pack("!H", 1009) + b"message too large")
                            return
                        if not fin:
                            continue
                        opcode = fragment_opcode
                        payload = bytes(fragment_payload)
                        fragment_opcode = None
                        fragment_payload.clear()
                    else:
                        self.ws_send_frame(8, struct.pack("!H", 1003) + b"unsupported opcode")
                        return
                    if opcode == 1:
                        try:
                            message = payload.decode("utf-8")
                            control = json.loads(message)
                        except (UnicodeDecodeError, json.JSONDecodeError):
                            control = None
                        if isinstance(control, dict) and control.get("type") == "resize":
                            try:
                                with STATE.lock:
                                    current = STATE.terminals.get(tid)
                                    if current and current.get("owner") == sid:
                                        self.resize_terminal(current, control.get("cols", 80), control.get("rows", 24))
                            except (ValueError, OSError, TypeError):
                                pass
                            continue
                    if payload:
                        with STATE.lock:
                            current = STATE.terminals.get(tid)
                            if not current or current.get("owner") != sid:
                                return
                            view = memoryview(payload)
                            while view:
                                written = os.write(current["master"], view)
                                view = view[written:]
        except (OSError, ValueError, socket.timeout):
            pass

    def handle_import_upload(self):
        auth = self.require_auth()
        if not auth:
            return
        if not self.verify_csrf(auth[1]):
            self.send_json(403, {"error": "Invalid CSRF token"})
            return
        name = self.headers.get("X-Codespace-Name", "").strip()
        content_type = self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
        if not NAME_RE.fullmatch(name):
            self.send_json(400, {"error": "Choose a name using 1–48 letters, numbers, underscores or hyphens."})
            return
        if content_type not in {"application/gzip", "application/x-gzip", "application/octet-stream"}:
            self.send_json(415, {"error": "Upload a .tar.gz or .tgz archive."})
            return
        try:
            size = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            size = 0
        if size <= 0 or size > MAX_IMPORT_BYTES:
            self.send_json(413, {"error": "Archive size is invalid or exceeds the 4 GiB upload limit."})
            return
        if (STATE.spaces / name).exists():
            self.send_json(409, {"error": "A codespace with that name already exists."})
            return
        if not STATE.archive_lock.acquire(blocking=False):
            self.send_json(409, {"error": "Another import or export is already running."})
            return
        temp_dir = None
        try:
            free = shutil.disk_usage(STATE.base).free
            if size > free - 64 * 1024 * 1024:
                self.send_json(413, {"error": "Not enough free storage for this upload."})
                return
            temp_dir = Path(tempfile.mkdtemp(prefix=".admin-import-", dir=str(STATE.base)))
            archive = temp_dir / "upload.tar.gz"
            remaining = size
            self.connection.settimeout(300)
            with archive.open("xb") as output:
                while remaining:
                    chunk = self.rfile.read(min(1024 * 1024, remaining))
                    if not chunk:
                        raise ValueError("Upload ended before the full archive arrived")
                    output.write(chunk)
                    remaining -= len(chunk)
            original_name, metadata = extract_codespace_archive(archive, temp_dir / "extract")
            if (STATE.spaces / name).exists():
                raise ValueError("A codespace with that name already exists.")
            STATE.run_action("import-staged", str(temp_dir / "extract"), name, timeout=3600)
            port_file = STATE.meta / f"{name}.port"
            port = port_file.read_text(encoding="utf-8").strip() if port_file.exists() else ""
            self.send_json(200, {"ok": True, "name": name, "original_name": original_name, "port": port, "message": "Codespace imported. Its archived password was preserved."})
        except (OSError, ValueError, tarfile.TarError, RuntimeError, UnicodeError, EOFError, zlib.error) as exc:
            self.send_json(400, {"error": str(exc)[:700]})
        finally:
            if temp_dir is not None:
                shutil.rmtree(temp_dir, ignore_errors=True)
            STATE.archive_lock.release()

    def do_GET(self):
        if not self.host_ok():
            self.send_json(421, {"error": "Invalid Host header"})
            return
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.path == "/ws/terminal":
            self.handle_terminal_websocket(parsed)
            return
        if parsed.path == "/":
            self.send_html()
            return
        if parsed.path == "/api/session":
            _, s = self.session()
            self.send_json(200, {"authenticated": bool(s), "csrf": s["csrf"] if s else ""})
            return
        auth = self.require_auth()
        if not auth:
            return
        if parsed.path == "/api/state":
            spaces = [STATE.space_state(n) for n in STATE.names()]
            self.send_json(200, {"spaces": spaces, "view_hosts": STATE.view_hosts})
            return
        if parsed.path == "/api/policy":
            q = urllib.parse.parse_qs(parsed.query)
            name = (q.get("name") or [""])[0]
            if not STATE.valid_name(name):
                self.send_json(400, {"error": "Unknown codespace"})
                return
            def read_lines(suffix):
                try:
                    return [line.strip() for line in (STATE.meta / f"{name}.{suffix}").read_text(encoding="utf-8", errors="replace").splitlines() if line.strip()]
                except OSError:
                    return []
            mode = "open"
            try:
                mode = (STATE.meta / f"{name}.netmode").read_text(encoding="utf-8").strip()
            except OSError:
                pass
            if mode not in {"open", "restricted"}:
                mode = "open"
            self.send_json(200, {"name": name, "mode": mode, "blocked": read_lines("blocklist"), "allowed": read_lines("allowlist")})
            return
        if parsed.path == "/api/logs":
            q = urllib.parse.parse_qs(parsed.query)
            name = (q.get("name") or [""])[0]
            try:
                limit = max(1, min(500, int((q.get("limit") or [250])[0])))
            except ValueError:
                limit = 250
            if not STATE.valid_name(name):
                self.send_json(400, {"error": "Unknown codespace"})
                return
            log = STATE.meta / f"{name}.netlog"
            try:
                with log.open("r", encoding="utf-8", errors="replace") as f:
                    lines = deque(f, maxlen=limit)
                content = "".join(lines)
            except OSError:
                content = ""
            self.send_json(200, {"lines": content, "proxy": STATE.space_state(name)["proxy"]})
            return
        if parsed.path == "/api/terminal/poll":
            q = urllib.parse.parse_qs(parsed.query)
            tid = (q.get("id") or [""])[0]
            try:
                offset = max(0, int((q.get("offset") or [0])[0]))
            except ValueError:
                offset = 0
            with STATE.lock:
                term = STATE.terminals.get(tid)
                if not term or term.get("owner") != auth[0]:
                    self.send_json(404, {"error": "Terminal session not found"})
                    return
                base = term["base"]
                data = term["output"]
                if offset < base:
                    offset = base
                start = max(0, offset - base)
                chunk = data[start:]
                next_offset = base + len(data)
                closed = term["proc"].poll() is not None
            self.send_json(200, {"output": chunk, "next": next_offset, "closed": closed})
            return
        self.send_json(404, {"error": "Not found"})

    def do_POST(self):
        if not self.host_ok():
            self.send_json(421, {"error": "Invalid Host header"})
            return
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.path == "/api/import":
            self.handle_import_upload()
            return
        try:
            body = self.read_body()
        except ValueError as exc:
            self.send_json(400, {"error": str(exc)})
            return
        if not isinstance(body, dict):
            self.send_json(400, {"error": "JSON object required"})
            return

        if parsed.path == "/api/login":
            client = self.client_address[0]
            now = time.time()
            count, until = STATE.failures.get(client, (0, 0))
            if now < until:
                self.send_json(429, {"error": "Too many attempts. Wait before trying again."})
                return
            supplied = str(body.get("password", ""))
            stored = STATE.password()
            ok = bool(stored) and hmac.compare_digest(supplied.encode(), stored.encode())
            if not ok:
                count += 1
                STATE.failures[client] = (0, now + 60) if count >= 5 else (count, 0)
                self.send_json(401, {"error": "Invalid credential"})
                return
            STATE.failures.pop(client, None)
            sid = secrets.token_urlsafe(32)
            csrf = secrets.token_urlsafe(32)
            with STATE.lock:
                STATE.sessions[sid] = {"csrf": csrf, "last": now, "ip": client}
            cookie = "TCS_ADMIN_SID={}; Path=/; HttpOnly; SameSite=Strict; Max-Age={}".format(sid, SESSION_TTL)
            if STATE.secure_cookies:
                cookie += "; Secure"
            self.send_json(200, {"ok": True, "csrf": csrf}, {"Set-Cookie": cookie})
            return

        auth = self.require_auth()
        if not auth:
            return
        if not self.verify_csrf(auth[1]):
            self.send_json(403, {"error": "Invalid CSRF token"})
            return

        if parsed.path == "/api/export":
            name = str(body.get("name", ""))
            if not STATE.valid_name(name):
                self.send_json(400, {"error": "Unknown codespace"})
                return
            if not STATE.archive_lock.acquire(blocking=False):
                self.send_json(409, {"error": "Another import or export is already running."})
                return
            temp_dir = None
            response_started = False
            try:
                temp_dir = Path(tempfile.mkdtemp(prefix=".admin-export-", dir=str(STATE.base)))
                archive = temp_dir / f"{name}.tar.gz"
                STATE.close_space_terminals(name)
                STATE.run_action("export", name, str(archive), timeout=3600)
                if not archive.is_file() or archive.stat().st_size <= 0:
                    raise RuntimeError("Export did not produce a valid archive")
                size = archive.stat().st_size
                self.send_response(200)
                self.send_header("Content-Type", "application/gzip")
                self.send_header("Content-Length", str(size))
                self.send_header("Content-Disposition", f'attachment; filename="{name}.tar.gz"')
                self.security_headers()
                self.end_headers()
                response_started = True
                with archive.open("rb") as source:
                    while True:
                        chunk = source.read(1024 * 1024)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
            except (OSError, RuntimeError, ValueError) as exc:
                # Once streaming begins, a disconnect produces a truncated download;
                # never append a second HTTP response to the binary archive.
                if not response_started:
                    try:
                        self.send_json(400, {"error": str(exc)[:700]})
                    except (OSError, BrokenPipeError):
                        pass
            finally:
                if temp_dir is not None:
                    shutil.rmtree(temp_dir, ignore_errors=True)
                STATE.archive_lock.release()
            return

        if parsed.path == "/api/logout":
            STATE.close_user_terminals(auth[0])
            with STATE.lock:
                STATE.sessions.pop(auth[0], None)
            clear_cookie = "TCS_ADMIN_SID=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0" + ("; Secure" if STATE.secure_cookies else "")
            self.send_json(200, {"ok": True}, {"Set-Cookie": clear_cookie})
            return

        if parsed.path == "/api/reveal-credential":
            name = str(body.get("name", ""))
            if not STATE.valid_name(name):
                self.send_json(400, {"error": "Unknown codespace"})
                return
            credential_file = STATE.meta / f"{name}.pass"
            try:
                password = credential_file.read_text(encoding="utf-8").strip()
            except OSError:
                self.send_json(404, {"error": "No stored credential found for this codespace"})
                return
            if not password:
                self.send_json(404, {"error": "Stored credential is empty"})
                return
            self.send_json(200, {"ok": True, "name": name, "password": password})
            return

        if parsed.path == "/api/domain-policy":
            name = str(body.get("name", ""))
            operation = str(body.get("operation", ""))
            if not STATE.valid_name(name):
                self.send_json(400, {"error": "Unknown codespace"})
                return
            try:
                if operation == "mode":
                    mode = str(body.get("mode", ""))
                    if mode not in {"open", "restricted"}:
                        raise ValueError("Mode must be open or restricted")
                    STATE.run_action("restrict", name, mode)
                elif operation in {"block-add", "allow-add"}:
                    domain = str(body.get("domain", "")).strip()
                    if not domain or len(domain) > 253:
                        raise ValueError("Enter a valid domain name")
                    kind = "block" if operation.startswith("block-") else "allow"
                    STATE.run_action("domain-rule", name, "add", kind, domain)
                elif operation in {"block-remove", "allow-remove"}:
                    try:
                        index = int(body.get("index", -1))
                    except (TypeError, ValueError):
                        raise ValueError("Invalid domain-list entry")
                    if index < 0 or index > 10000:
                        raise ValueError("Invalid domain-list entry")
                    kind = "block" if operation.startswith("block-") else "allow"
                    STATE.run_action("domain-rule", name, "remove", kind, index + 1)
                else:
                    raise ValueError("Unsupported domain-policy operation")
                self.send_json(200, {"ok": True, "message": "Domain policy updated"})
                return
            except (RuntimeError, ValueError, OSError) as exc:
                self.send_json(400, {"error": str(exc)})
                return

        if parsed.path == "/api/action":
            action = str(body.get("action", ""))
            name = str(body.get("name", ""))
            if action not in {"create", "delete", "start", "stop", "revoke", "proxy", "restrict", "quota"}:
                self.send_json(400, {"error": "Unsupported action"})
                return
            if action != "create" and not STATE.valid_name(name):
                self.send_json(400, {"error": "Unknown codespace"})
                return
            try:
                if action == "create":
                    if not NAME_RE.fullmatch(name):
                        raise ValueError("Use 1–48 letters, numbers, underscores or hyphens.")
                    if (STATE.spaces / name).exists():
                        raise ValueError("That codespace already exists.")
                    try:
                        quota = int(body.get("quota", 0))
                    except (TypeError, ValueError):
                        raise ValueError("Quota must be a whole number.")
                    if quota < 0 or quota > 100000:
                        raise ValueError("Quota must be between 0 and 100000 MB.")
                    STATE.run_action("create", name, quota)
                    password = (STATE.meta / f"{name}.pass").read_text(encoding="utf-8").strip()
                    port = (STATE.meta / f"{name}.port").read_text(encoding="utf-8").strip()
                    self.send_json(200, {"ok": True, "password": password, "port": port, "message": "Codespace created and started"})
                    return
                if action == "delete":
                    STATE.close_space_terminals(name)
                    STATE.run_action("delete", name)
                    self.send_json(200, {"ok": True, "message": "Codespace deleted"})
                    return
                if action == "start":
                    STATE.run_action("start", name, timeout=240)
                    self.send_json(200, {"ok": True, "message": "Codespace started"})
                    return
                if action == "stop":
                    STATE.close_space_terminals(name)
                    STATE.run_action("stop", name, timeout=90)
                    self.send_json(200, {"ok": True, "message": "Codespace stopped"})
                    return
                if action == "revoke":
                    STATE.close_space_terminals(name)
                    STATE.run_action("revoke", name, timeout=240)
                    password = (STATE.meta / f"{name}.pass").read_text(encoding="utf-8").strip()
                    self.send_json(200, {"ok": True, "password": password, "message": "Codespace credential rotated"})
                    return
                if action == "proxy":
                    desired = str(body.get("enabled", ""))
                    if desired not in {"on", "off"}:
                        raise ValueError("Proxy state must be on or off")
                    STATE.run_action("proxy", name, desired, timeout=240)
                    self.send_json(200, {"ok": True, "message": f"Proxy turned {desired}"})
                    return
                if action == "restrict":
                    mode = str(body.get("mode", ""))
                    if mode not in {"open", "restricted"}:
                        raise ValueError("Network mode must be open or restricted")
                    STATE.run_action("restrict", name, mode)
                    self.send_json(200, {"ok": True, "message": f"Network mode set to {mode}"})
                    return
                if action == "quota":
                    try:
                        quota = int(body.get("quota", 0))
                    except (TypeError, ValueError):
                        raise ValueError("Quota must be a whole number")
                    mode = str(body.get("mode", "soft"))
                    if quota < 0 or quota > 100000 or mode not in {"soft", "hard"}:
                        raise ValueError("Invalid quota settings")
                    STATE.run_action("quota", name, quota, mode, timeout=900)
                    self.send_json(200, {"ok": True, "message": f"{mode.title()} quota saved"})
                    return
            except (RuntimeError, ValueError, OSError) as exc:
                self.send_json(400, {"error": str(exc)})
                return

        if parsed.path == "/api/revoke-admin":
            new_password = secrets.token_urlsafe(36)
            tmp = STATE.password_file.with_suffix(".tmp")
            fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(new_password + "\n")
            os.chmod(tmp, 0o600)
            os.replace(tmp, STATE.password_file)
            with STATE.lock:
                for tid in list(STATE.terminals):
                    STATE.close_terminal(tid)
                STATE.sessions.clear()
            clear_cookie = "TCS_ADMIN_SID=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0" + ("; Secure" if STATE.secure_cookies else "")
            self.send_json(200, {"ok": True, "password": new_password}, {"Set-Cookie": clear_cookie})
            return

        if parsed.path == "/api/terminal/start":
            name = str(body.get("name", ""))
            if not STATE.valid_name(name):
                self.send_json(400, {"error": "Unknown codespace"})
                return
            with STATE.lock:
                owned = [tid for tid, t in STATE.terminals.items() if t.get("owner") == auth[0]]
                if owned:
                    self.send_json(409, {"error": "Disconnect your current terminal first"})
                    return
                if len(STATE.terminals) >= MAX_TERMINALS:
                    self.send_json(429, {"error": "Terminal session limit reached"})
                    return
            try:
                STATE.run_action("prepare-terminal", name, timeout=90)
                rootfs = STATE.spaces / name
                proxy_on = (STATE.meta / f"{name}.proxyenabled").read_text().strip() == "on"
                env = os.environ.copy()
                env.pop("LD_PRELOAD", None)
                env.update({"HOME": "/root", "USER": "root", "SHELL": "/bin/bash", "TERM": "xterm-256color", "LANG": "C.UTF-8", "PROOT_L2S_DIR": str(rootfs / ".l2s"), "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"})
                env.pop("http_proxy", None); env.pop("https_proxy", None); env.pop("HTTP_PROXY", None); env.pop("HTTPS_PROXY", None)
                if proxy_on:
                    port = (STATE.meta / f"{name}.proxyport").read_text().strip()
                    for key in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY"):
                        env[key] = f"http://127.0.0.1:{port}"
                    env["no_proxy"] = "localhost,127.0.0.1,::1"
                    env["NO_PROXY"] = env["no_proxy"]
                os.makedirs(str(Path(STATE.prefix) / "tmp"), exist_ok=True)
                cols = max(40, min(240, int(body.get("cols", 100))))
                rows = max(10, min(80, int(body.get("rows", 28))))
                master, slave = pty.openpty()
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
                cmd = [STATE.proot, "--kill-on-exit", "--link2symlink", "--sysvipc", "-L", "--change-id=0:0", "--kernel-release=6.17.0-PRoot-Distro", f"--rootfs={rootfs}", "--cwd=/root", "--bind=/dev", "--bind=/proc", "--bind=/sys", "--bind=/dev/urandom:/dev/random", f"--bind={rootfs}/tmp:/dev/shm", f"--bind={STATE.prefix}/tmp:/tmp", "/bin/bash", "--login", "-i"]
                proc = subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=slave, env=env, close_fds=True, start_new_session=True)
                os.close(slave)
                tid = secrets.token_urlsafe(18)
                term = {"id": tid, "owner": auth[0], "name": name, "proc": proc, "master": master, "output": "", "base": 0, "decoder": codecs.getincrementaldecoder("utf-8")("replace"), "started": time.time()}
                with STATE.lock:
                    STATE.terminals[tid] = term
                threading.Thread(target=terminal_reader, args=(STATE, tid), daemon=True).start()
                self.send_json(200, {"id": tid, "name": name})
            except Exception as exc:
                self.send_json(500, {"error": "Could not open terminal: " + str(exc)[:500]})
            return

        if parsed.path == "/api/terminal/input":
            tid = str(body.get("id", ""))
            data = str(body.get("data", ""))
            if len(data) > 16384:
                self.send_json(400, {"error": "Input too large"})
                return
            with STATE.lock:
                term = STATE.terminals.get(tid)
                if not term or term.get("owner") != auth[0]:
                    self.send_json(404, {"error": "Terminal session not found"})
                    return
                try:
                    os.write(term["master"], data.encode("utf-8", "replace"))
                except OSError:
                    self.send_json(410, {"error": "Terminal is closed"})
                    return
            self.send_json(200, {"ok": True})
            return

        if parsed.path == "/api/terminal/resize":
            tid = str(body.get("id", ""))
            try:
                cols = int(body.get("cols", 80)); rows = int(body.get("rows", 24))
            except (TypeError, ValueError):
                self.send_json(400, {"error": "Invalid terminal dimensions"})
                return
            with STATE.lock:
                term = STATE.terminals.get(tid)
                if not term or term.get("owner") != auth[0]:
                    self.send_json(404, {"error": "Terminal session not found"})
                    return
                try:
                    self.resize_terminal(term, cols, rows)
                except OSError:
                    self.send_json(410, {"error": "Terminal is closed"})
                    return
            self.send_json(200, {"ok": True, "cols": max(20, min(240, cols)), "rows": max(5, min(100, rows))})
            return

        if parsed.path == "/api/terminal/stop":
            tid = str(body.get("id", ""))
            with STATE.lock:
                term = STATE.terminals.get(tid)
                if not term or term.get("owner") != auth[0]:
                    self.send_json(404, {"error": "Terminal session not found"})
                    return
                STATE.close_terminal(tid)
            self.send_json(200, {"ok": True})
            return

        self.send_json(404, {"error": "Not found"})

    def do_HEAD(self):
        if not self.host_ok():
            self.send_response(421); self.end_headers(); return
        self.send_response(200); self.end_headers()

    def do_OPTIONS(self):
        self.send_json(405, {"error": "Method not allowed"})


def terminal_reader(state, tid):
    while True:
        with state.lock:
            term = state.terminals.get(tid)
            if not term:
                return
            fd = term["master"]
            proc = term["proc"]
        try:
            chunk = os.read(fd, 4096)
            if not chunk:
                break
            with state.lock:
                current = state.terminals.get(tid)
                if not current:
                    return
                text = current["decoder"].decode(chunk, final=False)
                current["output"] += text
                if len(current["output"]) > TERMINAL_BUFFER_LIMIT:
                    drop = len(current["output"]) - TERMINAL_BUFFER_LIMIT
                    current["output"] = current["output"][drop:]
                    current["base"] += drop
        except OSError:
            break
    # Flush any final partial UTF-8 sequence before the browser observes process exit.
    try:
        with state.lock:
            current = state.terminals.get(tid)
            if current:
                tail = current["decoder"].decode(b"", final=True)
                current["output"] += tail
    except Exception:
        pass
    try:
        proc.poll()
    except Exception:
        pass


def main():
    global STATE
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-dir", required=True)
    parser.add_argument("--script", required=True)
    parser.add_argument("--prefix", required=True)
    parser.add_argument("--proot", required=True)
    parser.add_argument("--bind", required=True)
    parser.add_argument("--allowed-hosts", required=True)
    parser.add_argument("--view-hosts", default="")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--origin-port", type=int, required=True)
    parser.add_argument("--public-protocol", choices=("http", "https"), required=True)
    parser.add_argument("--secure-cookies", choices=("0", "1"), default="0")
    args = parser.parse_args()
    STATE = PanelState(args)
    if not STATE.password():
        raise SystemExit("Admin credential file is missing")
    server = AdminServer((args.bind, args.port), Handler)
    print("READY http://{}:{} (browser transport: {})".format(args.bind, args.port, args.public_protocol), flush=True)
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        with STATE.lock:
            for tid in list(STATE.terminals):
                STATE.close_terminal(tid)
        server.server_close()

if __name__ == "__main__":
    main()
ADMINPYEOF
    chmod 700 "$ADMIN_SERVER_SCRIPT" 2>/dev/null || true
    touch "$marker"
}

is_admin_panel_running() {
    local pidfile="$META_DIR/admin.pid" pid cmdline
    [[ -f "$pidfile" ]] || return 1
    pid=$(cat "$pidfile" 2>/dev/null | tr -cd '0-9')
    [[ -n "$pid" ]] || { rm -f "$pidfile"; return 1; }
    kill -0 "$pid" 2>/dev/null || { rm -f "$pidfile"; return 1; }
    if [[ -r "/proc/$pid/cmdline" ]]; then
        cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
        [[ "$cmdline" == *"admin_panel.py"* ]] || { rm -f "$pidfile"; return 1; }
    fi
    return 0
}

stop_admin_panel() {
    local pidfile="$META_DIR/admin.pid" pid
    if is_admin_panel_running; then
        pid=$(cat "$pidfile" 2>/dev/null | tr -cd '0-9')
        kill_tree "$pid" TERM
        sleep 1
        kill_tree "$pid" KILL
    fi
    rm -f "$pidfile"
}

is_admin_port_free() {
    local port="$1" ip="$2" f value
    for f in "$META_DIR"/*.port "$META_DIR"/*.proxyport; do
        [[ -f "$f" && "$f" != "$META_DIR/admin.port" ]] || continue
        value=$(cat "$f" 2>/dev/null || true)
        [[ "$value" == "$port" ]] && return 1
    done
    if command -v ss >/dev/null 2>&1; then
        ! ss -tlnH 2>/dev/null | grep -Eq "(^|[[:space:]])[^[:space:]]*:${port}([[:space:]]|$)"
    elif command -v netstat >/dev/null 2>&1; then
        ! netstat -tln 2>/dev/null | grep -Eq "(^|[[:space:]])[^[:space:]]*:${port}([[:space:]]|$)"
    else
        ! (echo > "/dev/tcp/$ip/$port") >/dev/null 2>&1
    fi
}

admin_panel_port() {
    local saved="$(cat "$META_DIR/admin.port" 2>/dev/null || true)" port ip="$1"
    if [[ "$saved" =~ ^[0-9]+$ ]] && is_admin_port_free "$saved" "$ip"; then echo "$saved"; return 0; fi
    for ((port=ADMIN_PANEL_PORT_START; port<=ADMIN_PANEL_PORT_END; port++)); do
        if is_admin_port_free "$port" "$ip"; then echo "$port"; return 0; fi
    done
    return 1
}

admin_panel_configure() {
    local records current_protocol current_iface current_https_port choice default_iface_index=0
    local record iface addr i=0 selected_iface="" selected_ip=""
    local -a iface_names=() iface_ips=() iface_records=()

    records=$(device_ipv4_records)
    while IFS= read -r record; do
        [[ -n "$record" ]] || continue
        iface="${record%% *}"; addr="${record#* }"
        [[ -n "$iface" && -n "$addr" ]] || continue
        iface_records+=("$record")
        if [[ ! " ${iface_names[*]} " == *" $iface "* ]]; then
            iface_names+=("$iface")
            iface_ips+=("$addr")
        fi
    done <<< "$records"
    if [[ "${#iface_names[@]}" -eq 0 ]]; then
        echo -e "${YELLOW}[!] No active IPv4 interfaces were found. Enable the phone hotspot or connect Wi-Fi, then retry.${RESET}"
        return 1
    fi

    current_protocol=$(cat "$META_DIR/admin.protocol" 2>/dev/null || echo "http")
    current_iface=$(cat "$META_DIR/admin.interface" 2>/dev/null || echo "all")
    current_https_port=$(cat "$META_DIR/admin.httpsport" 2>/dev/null || echo "8443")

    echo -e "${BOLD}Admin Panel transport${RESET}"
    echo "  1) HTTP  - direct LAN access; no transport encryption"
    echo "  2) HTTPS - use the http2https reverse-proxy tool"
    read -rp "Choose protocol [1/2, Enter keeps $current_protocol]: " choice
    case "$choice" in
        1) current_protocol="http" ;;
        2) current_protocol="https" ;;
        "") [[ "$current_protocol" == "https" ]] || current_protocol="http" ;;
        *) echo -e "${RED}[!] Invalid protocol choice.${RESET}"; return 1 ;;
    esac

    echo
    echo -e "${BOLD}Choose network interface${RESET}"
    echo "  a) All detected interfaces"
    for i in "${!iface_names[@]}"; do
        printf '  %d) %s (%s)\n' "$((i + 1))" "${iface_names[$i]}" "${iface_ips[$i]}"
    done
    read -rp "Select interface [a/$(( ${#iface_names[@]} )) , Enter keeps $current_iface]: " choice
    if [[ -z "$choice" ]]; then
        selected_iface="$current_iface"
    elif [[ "$choice" =~ ^[Aa]$ ]]; then
        selected_iface="all"
    elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#iface_names[@]} )); then
        selected_iface="${iface_names[$((choice - 1))]}"
    else
        echo -e "${RED}[!] Invalid interface selection.${RESET}"
        return 1
    fi
    if [[ "$selected_iface" != "all" ]]; then
        local found=0
        for record in "${iface_records[@]}"; do
            iface="${record%% *}"
            if [[ "$iface" == "$selected_iface" ]]; then found=1; break; fi
        done
        if [[ "$found" -ne 1 ]]; then
            echo -e "${YELLOW}[!] Saved interface '$selected_iface' is not active. Select an active interface.${RESET}"
            return 1
        fi
    fi

    if [[ "$current_protocol" == "https" ]]; then
        echo
        read -rp "HTTPS proxy port for http2https [$current_https_port]: " choice
        [[ -n "$choice" ]] && current_https_port="$choice"
        if [[ ! "$current_https_port" =~ ^[0-9]+$ ]] || (( current_https_port < 1024 || current_https_port > 65535 )); then
            echo -e "${RED}[!] HTTPS proxy port must be between 1024 and 65535.${RESET}"
            return 1
        fi
        if [[ "$(cat "$META_DIR/admin.port" 2>/dev/null || true)" == "$current_https_port" ]] || ! is_admin_port_free "$current_https_port" "127.0.0.1"; then
            echo -e "${RED}[!] That HTTPS port is already in use or conflicts with the Admin Panel backend. Choose another port.${RESET}"
            return 1
        fi
        printf '%s\n' "$current_https_port" > "$META_DIR/admin.httpsport"
        chmod 600 "$META_DIR/admin.httpsport" 2>/dev/null || true
    fi

    printf '%s\n' "$current_protocol" > "$META_DIR/admin.protocol"
    printf '%s\n' "$selected_iface" > "$META_DIR/admin.interface"
    chmod 600 "$META_DIR/admin.protocol" "$META_DIR/admin.interface" 2>/dev/null || true
    echo -e "${GREEN}[+] Saved: protocol=$current_protocol interface=$selected_iface${RESET}"
    return 0
}

start_admin_panel() {
    local quiet="${1:-}" ip="0.0.0.0" bind_ip="0.0.0.0" port password_created=0 pass
    local protocol iface_choice https_port secure_cookies="0" records="" record iface addr selected_record="" allowed_hosts="" view_hosts="" mode_key old_mode check_ip
    local -a iface_records=() selected_records=()
    command -v python3 >/dev/null 2>&1 || { [[ "$quiet" != "--quiet" ]] && echo -e "${RED}[!] Python 3 is required for the admin panel.${RESET}"; return 1; }
    protocol=$(cat "$META_DIR/admin.protocol" 2>/dev/null || echo "http")
    iface_choice=$(cat "$META_DIR/admin.interface" 2>/dev/null || echo "all")
    https_port=$(cat "$META_DIR/admin.httpsport" 2>/dev/null || echo "8443")
    [[ "$protocol" == "http" || "$protocol" == "https" ]] || { echo -e "${RED}[!] Invalid saved admin protocol. Reconfigure the panel.${RESET}"; return 1; }
    records=$(device_ipv4_records)
    while IFS= read -r record; do [[ -n "$record" ]] && iface_records+=("$record"); done <<< "$records"
    if [[ "${#iface_records[@]}" -eq 0 ]]; then
        [[ "$quiet" != "--quiet" ]] && echo -e "${YELLOW}[!] No active non-loopback IPv4 interface was found. Connect the hotspot or Wi-Fi and retry.${RESET}"
        return 1
    fi
    if [[ "$iface_choice" == "all" ]]; then
        selected_records=("${iface_records[@]}")
    else
        for record in "${iface_records[@]}"; do
            iface="${record%% *}"
            [[ "$iface" == "$iface_choice" ]] && selected_records+=("$record")
        done
    fi
    if [[ "${#selected_records[@]}" -eq 0 ]]; then
        [[ "$quiet" != "--quiet" ]] && echo -e "${YELLOW}[!] Saved interface '$iface_choice' is not active. Disable/re-enable the panel and select an active interface.${RESET}"
        return 1
    fi
    for record in "${selected_records[@]}"; do
        addr="${record#* }"
        [[ -n "$view_hosts" ]] && view_hosts+="," 
        view_hosts+="$addr"
    done

    if [[ "$protocol" == "https" ]]; then
        # http2https forwards to localhost and rewrites Host to 127.0.0.1:<internal-port>.
        bind_ip="127.0.0.1"
        allowed_hosts="127.0.0.1"
        secure_cookies="1"
    elif [[ "$iface_choice" == "all" ]]; then
        bind_ip="0.0.0.0"
        for record in "${selected_records[@]}"; do
            addr="${record#* }"
            [[ -n "$allowed_hosts" ]] && allowed_hosts+="," 
            allowed_hosts+="$addr"
        done
    else
        # Bind only to the selected interface's first discovered IPv4 address.
        selected_record="${selected_records[0]}"
        bind_ip="${selected_record#* }"
        allowed_hosts="$bind_ip"
        selected_records=("$selected_record")
    fi

    ensure_admin_server_script
    if [[ ! -s "$META_DIR/.admin.pass" ]]; then
        pass=$(python3 -c 'import secrets; print(secrets.token_urlsafe(36))') || return 1
        printf '%s\n' "$pass" > "$META_DIR/.admin.pass"
        chmod 600 "$META_DIR/.admin.pass" 2>/dev/null || true
        password_created=1
    fi
    chmod 600 "$META_DIR/.admin.pass" 2>/dev/null || true
    # The CLI is the local trusted console: show the current credential on
    # every interactive start, even when it was generated in an earlier run.
    pass=$(<"$META_DIR/.admin.pass")
    if [[ -z "$pass" ]]; then
        echo -e "${RED}[!] Admin credential file is empty. Rotate the credential and retry.${RESET}"
        return 1
    fi

    mode_key="$protocol|$iface_choice|$bind_ip|$allowed_hosts|$view_hosts|$https_port"
    if is_admin_panel_running; then
        old_mode=$(cat "$META_DIR/admin.runmode" 2>/dev/null || true)
        if [[ "$old_mode" == "$mode_key" ]]; then
            if [[ "$quiet" != "--quiet" ]]; then
                echo -e "${GREEN}[+] Admin Panel is already running (port $(cat "$META_DIR/admin.port" 2>/dev/null)).${RESET}"
                echo -e "  Admin credential: ${BOLD}$pass${RESET}"
                echo -e "  Stored privately in: $META_DIR/.admin.pass"
            fi
            return 0
        fi
        stop_admin_panel
    fi

    port=$(admin_panel_port "127.0.0.1") || { echo -e "${RED}[!] No free admin panel port in $ADMIN_PANEL_PORT_START-$ADMIN_PANEL_PORT_END.${RESET}"; return 1; }
    echo "$port" > "$META_DIR/admin.port"
    echo "$bind_ip" > "$META_DIR/admin.ip"
    printf '%s\n' "$allowed_hosts" > "$META_DIR/admin.addresses"
    printf '%s\n' "$mode_key" > "$META_DIR/admin.runmode"
    origin_port="$port"
    [[ "$protocol" != "https" ]] || origin_port="$https_port"
    if command -v setsid >/dev/null 2>&1; then
        nohup setsid python3 -u "$ADMIN_SERVER_SCRIPT" \
            --base-dir "$BASE_DIR" --script "$SCRIPT_PATH" --prefix "$PREFIX" --proot "$PROOT_BIN" \
            --bind "$bind_ip" --allowed-hosts "$allowed_hosts" --view-hosts "$view_hosts" --port "$port" --origin-port "$origin_port" \
            --public-protocol "$protocol" --secure-cookies "$secure_cookies" \
            </dev/null > "$META_DIR/admin.log" 2>&1 &
    else
        nohup python3 -u "$ADMIN_SERVER_SCRIPT" \
            --base-dir "$BASE_DIR" --script "$SCRIPT_PATH" --prefix "$PREFIX" --proot "$PROOT_BIN" \
            --bind "$bind_ip" --allowed-hosts "$allowed_hosts" --view-hosts "$view_hosts" --port "$port" --origin-port "$origin_port" \
            --public-protocol "$protocol" --secure-cookies "$secure_cookies" \
            </dev/null > "$META_DIR/admin.log" 2>&1 & disown
    fi
    echo $! > "$META_DIR/admin.pid"
    check_ip="$bind_ip"
    [[ "$bind_ip" == "0.0.0.0" ]] && check_ip="127.0.0.1"
    local ready=0 i
    for ((i=0; i<30; i++)); do
        if is_admin_panel_running && (exec 3<>"/dev/tcp/$check_ip/$port"; exec 3>&-; exec 3<&-) >/dev/null 2>&1; then ready=1; break; fi
        sleep 0.2
    done
    if [[ "$ready" -ne 1 ]]; then
        echo -e "${RED}[!] Admin panel did not become ready. Check $META_DIR/admin.log${RESET}"
        stop_admin_panel
        return 1
    fi
    echo "on" > "$META_DIR/admin.enabled"
    if [[ "$quiet" != "--quiet" ]]; then
        echo -e "${GREEN}${BOLD}[+] Admin Web Panel backend is online${RESET}"
        if [[ "$protocol" == "http" ]]; then
            for record in "${selected_records[@]}"; do
                iface="${record%% *}"; addr="${record#* }"
                echo -e "  URL ($iface): http://$addr:$port"
            done
            echo -e "  Bind: $bind_ip:$port"
            echo -e "  ${YELLOW}HTTP is unencrypted. Use only on a trusted private home LAN.${RESET}"
        else
            echo -e "  Internal backend: http://127.0.0.1:$port"
            echo -e "  HTTPS proxy port: $https_port"
            echo -e "  Set up ${CYAN}http2https${RESET}: https://github.com/giriaryan694-a11y/http2https"
            echo -e "  In its prompts, enter internal HTTP port: ${BOLD}$port${RESET}"
            echo -e "  Enter HTTPS proxy port: ${BOLD}$https_port${RESET}"
            echo -e "  Domains/IPs to secure:"
            for record in "${selected_records[@]}"; do
                iface="${record%% *}"; addr="${record#* }"
                echo -e "    $addr ($iface)"
            done
            echo -e "  Then open:"
            for record in "${selected_records[@]}"; do
                addr="${record#* }"
                echo -e "    https://$addr:$https_port"
            done
            echo -e "  ${YELLOW}The current http2https listener binds all interfaces; interface selection here identifies the LAN address/certificate SAN to use, but does not restrict that proxy listener.${RESET}"
        fi
        if [[ "$password_created" -eq 1 ]]; then
            echo -e "  New admin credential: ${BOLD}$pass${RESET}"
        else
            echo -e "  Admin credential: ${BOLD}$pass${RESET}"
        fi
        echo -e "  Stored privately in: $META_DIR/.admin.pass"
        echo -e "  Press ${BOLD}r${RESET} in the main menu to revoke it and generate a replacement."
        echo -e "  Keep the panel disabled when you are not using it. Do not use router port forwarding."
    fi
}

admin_panel_toggle() {
    clear; banner
    if admin_panel_enabled; then
        stop_admin_panel
        echo "off" > "$META_DIR/admin.enabled"
        echo -e "${YELLOW}Admin Web Panel is OFF. Its credential is retained.${RESET}"
    else
        if ! admin_panel_configure; then
            press_any_key
            return
        fi
        if ! start_admin_panel; then
            echo "off" > "$META_DIR/admin.enabled"
        fi
    fi
    press_any_key
}

reveal_admin_credential() {
    local pass
    clear; banner
    if [[ ! -s "$META_DIR/.admin.pass" ]]; then
        echo -e "${YELLOW}[!] No Admin Web Panel credential has been generated yet.${RESET}"
    else
        chmod 600 "$META_DIR/.admin.pass" 2>/dev/null || true
        pass=$(<"$META_DIR/.admin.pass")
        echo -e "${GREEN}Admin Web Panel credential:${RESET}"
        echo -e "${BOLD}$pass${RESET}"
        echo
        echo "Stored privately in: $META_DIR/.admin.pass"
        echo "This displays the existing credential; it does not rotate it."
    fi
    press_any_key
}

revoke_admin_credential() {
    local pass was_enabled=0
    admin_panel_enabled && was_enabled=1
    [[ -f "$META_DIR/.admin.pass" ]] || mkdir -p "$META_DIR"
    pass=$(python3 -c 'import secrets; print(secrets.token_urlsafe(36))' 2>/dev/null) || { echo -e "${RED}Python 3 is required to generate a secure credential.${RESET}"; press_any_key; return 1; }
    stop_admin_panel
    printf '%s\n' "$pass" > "$META_DIR/.admin.pass"
    chmod 600 "$META_DIR/.admin.pass" 2>/dev/null || true
    if [[ "$was_enabled" -eq 1 ]]; then start_admin_panel --quiet || echo -e "${RED}[!] The panel credential changed, but the panel could not restart.${RESET}"; fi
    clear; banner
    echo -e "${GREEN}[+] Previous admin credential revoked.${RESET}"
    echo -e "New admin credential: ${BOLD}$pass${RESET}"
    echo "Save it now. Existing browser sessions were invalidated by restarting the panel."
    press_any_key
}

revoke_codespace_credential() {
    local name="$1" was_running=0 pass rootfs
    [[ "$name" =~ ^[A-Za-z0-9_-]{1,48}$ && -d "$CODESPACES_DIR/$name" ]] || return 1
    rootfs="$CODESPACES_DIR/$name"
    is_running "$name" && was_running=1
    stop_filemanager "$name" 2>/dev/null || true
    [[ "$was_running" -eq 1 ]] && stop_codespace "$name" --no-fm
    pass=$(random_password)
    mkdir -p "$rootfs/root/.config/code-server"
    cat > "$rootfs/root/.config/code-server/config.yaml" <<CFG
bind-addr: 0.0.0.0:$(cat "$META_DIR/$name.port" 2>/dev/null)
auth: password
password: ${pass}
cert: false
CFG
    printf '%s\n' "$pass" > "$META_DIR/$name.pass"
    chmod 600 "$META_DIR/$name.pass" 2>/dev/null || true
    if [[ "$was_running" -eq 1 ]]; then
        start_codespace "$name" --quiet || { echo -e "${RED}[!] Password changed, but '$name' failed to restart.${RESET}"; return 1; }
    fi
    clear; banner
    echo -e "${GREEN}[+] Previous credentials for '$name' revoked.${RESET}"
    echo -e "New code-server / recovery-manager credential: ${BOLD}$pass${RESET}"
    [[ "$was_running" -eq 0 ]] && echo "The codespace was stopped; the new credential applies on its next start."
    press_any_key
}

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

# The management menu only needs a quick, approximate display value. A fresh
# `du` over a large rootfs can take several seconds on Android storage, so keep
# the last measured size and refresh it in the background. Quota enforcement
# and other correctness-sensitive callers continue to use get_codespace_size_mb.
cached_codespace_size_mb() {
    local name="$1" cache="$META_DIR/$1.sizecache" cached_at cached_size
    if [[ -f "$cache" ]]; then
        read -r cached_at cached_size < "$cache" || true
        if [[ "${cached_size:-}" =~ ^[0-9]+$ ]]; then
            echo "$cached_size"
            return 0
        fi
    fi
    echo "?"
}

refresh_codespace_size_cache_async() {
    local lock_dir="$META_DIR/.size-cache-refresh.lock" lock_pid

    # A directory lock works on a minimal Termux install without requiring
    # flock. Recover stale locks left behind by a killed refresh process.
    if ! mkdir "$lock_dir" 2>/dev/null; then
        lock_pid=$(cat "$lock_dir/pid" 2>/dev/null || true)
        if [[ "$lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
            return 0
        fi
        rm -rf "$lock_dir" 2>/dev/null || return 0
        mkdir "$lock_dir" 2>/dev/null || return 0
    fi

    (
        printf '%s\n' "$BASHPID" > "$lock_dir/pid"
        trap 'rm -rf "$lock_dir"' EXIT

        local name size cache_tmp
        while IFS= read -r name; do
            [[ -n "$name" && -d "$CODESPACES_DIR/$name" ]] || continue
            size=$(get_codespace_size_mb "$name" 2>/dev/null) || continue
            [[ "$size" =~ ^[0-9]+$ ]] || continue

            cache_tmp="$META_DIR/$name.sizecache.tmp.$BASHPID"
            if printf '%s %s\n' "$(date +%s)" "$size" > "$cache_tmp" 2>/dev/null; then
                mv -f "$cache_tmp" "$META_DIR/$name.sizecache" 2>/dev/null || rm -f "$cache_tmp"
            fi
        done < <(list_codespaces)
    ) </dev/null >/dev/null 2>&1 &
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
    local marker="$BASE_DIR/.filemanager_v6"

    if [[ -f "$FILEMANAGER_SCRIPT" && -f "$marker" ]]; then
        return 0
    fi

    cat > "$FILEMANAGER_SCRIPT" << 'FM_PHPEOF'
<?php
date_default_timezone_set('UTC');

if (!defined('SCANDIR_SORT_NONE')) {
    define('SCANDIR_SORT_NONE', 1);
}

$cookieSecure =
    (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') ||
    (($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https');

ini_set('session.use_strict_mode', '1');
ini_set('session.use_only_cookies', '1');
ini_set('session.cookie_httponly', '1');

if ($cookieSecure) {
    ini_set('session.cookie_secure', '1');
}

session_name('FM_RECOVERY_SESSID');

if (PHP_VERSION_ID >= 70300) {
    session_set_cookie_params([
        'lifetime' => 0,
        'path' => '/',
        'domain' => '',
        'secure' => $cookieSecure,
        'httponly' => true,
        'samesite' => 'Lax',
    ]);
} else {
    session_set_cookie_params(0, '/', '', $cookieSecure, true);
}

session_start();

header('X-Content-Type-Options: nosniff');
header('X-Frame-Options: DENY');
header('Referrer-Policy: same-origin');
header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');
header('Pragma: no-cache');

$rootfs = getenv('FM_ROOTFS') ?: '/';
$passFile = getenv('FM_PASS_FILE') ?: '';
$csName = getenv('FM_NAME') ?: 'codespace';

$authPass = '';
if ($passFile !== '' && is_file($passFile)) {
    $authPass = trim((string)file_get_contents($passFile));
}

define('FM_CREDIT', 'Made By Aryan Giri | giriaryan694-a11y');

$rootReal = realpath($rootfs);
if ($rootReal === false) {
    http_response_code(500);
    exit('Invalid FM_ROOTFS.');
}

if (!function_exists('str_starts_with')) {
    function str_starts_with($haystack, $needle) {
        $haystack = (string)$haystack;
        $needle = (string)$needle;

        if ($needle === '') {
            return true;
        }

        return strncmp($haystack, $needle, strlen($needle)) === 0;
    }
}

function csrf_token() {
    if (empty($_SESSION['csrf'])) {
        $_SESSION['csrf'] = bin2hex(random_bytes(32));
    }

    return $_SESSION['csrf'];
}

function check_csrf($token) {
    return !empty($_SESSION['csrf']) && is_string($token) && hash_equals($_SESSION['csrf'], $token);
}

function h($value) {
    return htmlspecialchars((string)$value, ENT_QUOTES, 'UTF-8');
}

function human_size($bytes) {
    $bytes = max(0, (int)$bytes);

    if ($bytes < 1024) {
        return $bytes . ' B';
    }

    if ($bytes < 1048576) {
        return round($bytes / 1024, 1) . ' KB';
    }

    if ($bytes < 1073741824) {
        return round($bytes / 1048576, 1) . ' MB';
    }

    return round($bytes / 1073741824, 2) . ' GB';
}

function fm_url($params = []) {
    $script = isset($_SERVER['SCRIPT_NAME']) ? (string)$_SERVER['SCRIPT_NAME'] : '/';

    if ($script === '') {
        $script = '/';
    }

    $query = http_build_query($params, '', '&');

    if ($query === '') {
        return $script;
    }

    return $script . '?' . $query;
}

function dir_url($dirRel, $page = null) {
    $params = [];

    $dirRel = (string)$dirRel;

    if ($dirRel !== '') {
        $params['dir'] = $dirRel;
    }

    if ($page !== null && $page > 1) {
        $params['page'] = $page;
    }

    return fm_url($params);
}

function path_prefix($root) {
    return $root === '/' ? '/' : $root . '/';
}

function safe_path($rel, $rootfs, $allowSymlink = false) {
    $root = realpath($rootfs);

    if ($root === false) {
        return null;
    }

    $rel = str_replace(["\0", '\\'], ['', '/'], (string)$rel);
    $rel = trim($rel);

    if ($rel === '' || $rel === '.' || $rel === '/') {
        return $root;
    }

    $rel = ltrim($rel, '/');

    $parts = [];

    foreach (explode('/', $rel) as $part) {
        if ($part === '' || $part === '.') {
            continue;
        }

        if ($part === '..') {
            if (!$parts) {
                return null;
            }

            array_pop($parts);
            continue;
        }

        $parts[] = $part;
    }

    if (!$parts) {
        return $root;
    }

    $base = rtrim($root, '/');
    $logical = ($base === '' ? '/' : $base . '/') . implode('/', $parts);

    if (is_link($logical)) {
        return $allowSymlink ? $logical : null;
    }

    if (!file_exists($logical)) {
        return null;
    }

    $real = realpath($logical);

    if ($real === false) {
        return null;
    }

    if ($real === $root) {
        return $real;
    }

    if (!str_starts_with($real, path_prefix($root))) {
        return null;
    }

    return $real;
}

function parent_rel($rel) {
    $rel = str_replace(["\0", '\\'], ['', '/'], (string)$rel);
    $rel = trim($rel);
    $rel = trim($rel, '/');

    if ($rel === '') {
        return '';
    }

    $parts = explode('/', $rel);
    array_pop($parts);

    return implode('/', $parts);
}

function rel_from_root($path, $root) {
    if ($path === $root) {
        return '';
    }

    $rel = substr($path, strlen($root));

    return trim(str_replace('\\', '/', $rel), '/');
}

function verify_password($input, $stored) {
    $stored = trim((string)$stored);
    $input = (string)$input;

    if ($stored === '') {
        return false;
    }

    if (function_exists('password_get_info')) {
        $info = password_get_info($stored);

        if (!empty($info['algo'])) {
            return password_verify($input, $stored);
        }
    }

    return hash_equals($stored, $input);
}

function del_tree($path) {
    if (is_link($path)) {
        return @unlink($path);
    }

    if (!is_dir($path)) {
        return @unlink($path);
    }

    $stack = [$path];
    $removeDirs = [];

    while ($stack) {
        $current = array_pop($stack);

        $items = @scandir($current);

        if ($items === false) {
            return false;
        }

        foreach ($items as $name) {
            if ($name === '.' || $name === '..') {
                continue;
            }

            $p = $current . '/' . $name;

            if (is_link($p)) {
                if (!@unlink($p)) {
                    return false;
                }
                continue;
            }

            if (is_dir($p)) {
                $stack[] = $p;
                continue;
            }

            if (!@unlink($p)) {
                return false;
            }
        }

        $removeDirs[] = $current;
    }

    foreach (array_reverse($removeDirs) as $dir) {
        if (!@rmdir($dir)) {
            return false;
        }
    }

    return true;
}

function php_function_disabled($name) {
    static $disabled = null;

    if ($disabled === null) {
        $disabled = array_map('trim', explode(',', (string)ini_get('disable_functions')));
    }

    return !function_exists($name) || in_array($name, $disabled, true);
}

function shell_run($cmd) {
    if (!php_function_disabled('shell_exec')) {
        $out = @shell_exec($cmd);
        if ($out !== null && $out !== false) {
            return $out;
        }
    }

    if (!php_function_disabled('exec')) {
        $lines = [];
        @exec($cmd, $lines);
        if ($lines) {
            return implode("\n", $lines) . "\n";
        }
    }

    if (!php_function_disabled('popen')) {
        $fp = @popen($cmd, 'r');
        if ($fp) {
            $data = stream_get_contents($fp);
            pclose($fp);
            if ($data !== false && $data !== '') {
                return $data;
            }
        }
    }

    if (!php_function_disabled('proc_open')) {
        $descriptors = [1 => ['pipe', 'w'], 2 => ['pipe', 'w']];
        $pipes = [];
        $proc = @proc_open($cmd, $descriptors, $pipes);
        if (is_resource($proc)) {
            $data = stream_get_contents($pipes[1]);
            fclose($pipes[1]);
            fclose($pipes[2]);
            proc_close($proc);
            if ($data !== false && $data !== '') {
                return $data;
            }
        }
    }

    return null;
}

function dir_sizes_via_du($dir) {
    $escaped = escapeshellarg($dir);
    $timeoutOut = shell_run('command -v timeout 2>/dev/null');
    $cmd = (trim((string)$timeoutOut) !== '')
        ? "timeout 12 du -sb --max-depth=1 $escaped 2>/dev/null"
        : "du -sb --max-depth=1 $escaped 2>/dev/null";

    $out = shell_run($cmd);

    if ($out === null || trim($out) === '') {
        return null;
    }

    $sizes = [];

    foreach (explode("\n", trim($out)) as $line) {
        if ($line === '') {
            continue;
        }

        $parts = preg_split('/\s+/', $line, 2);

        if (count($parts) < 2 || !ctype_digit($parts[0])) {
            continue;
        }

        $sizes[$parts[1]] = (int)$parts[0];
    }

    return $sizes ?: null;
}

function dir_size_native($dir, $deadline) {
    $total = 0;
    $stack = [$dir];
    $timedOut = false;

    while ($stack) {
        $current = array_pop($stack);
        $items = @scandir($current, SCANDIR_SORT_NONE);

        if ($items === false) {
            continue;
        }

        foreach ($items as $name) {
            if ($name === '.' || $name === '..') {
                continue;
            }

            $path = $current . '/' . $name;
            $st = @lstat($path);

            if ($st === false) {
                continue;
            }

            $mode = $st['mode'] & 0170000;

            if ($mode === 0120000) {
                continue;
            }

            if ($mode === 0040000) {
                $stack[] = $path;
            } else {
                $total += (int)($st['size'] ?? 0);
            }
        }

        if (microtime(true) > $deadline) {
            $timedOut = true;
            break;
        }
    }

    return [$total, $timedOut];
}

function scan_fast($dir, $rel) {
    $items = @scandir($dir, SCANDIR_SORT_NONE);

    if ($items === false) {
        return [];
    }

    $dirSizes = dir_sizes_via_du($dir);
    $nativeDeadline = microtime(true) + 8;

    $out = [];

    foreach ($items as $name) {
        if ($name === '.' || $name === '..') {
            continue;
        }

        $path = $dir . '/' . $name;
        $entryRel = ($rel === '' ? $name : $rel . '/' . $name);

        $st = @lstat($path);

        if ($st === false) {
            $out[] = [
                'name' => $name,
                'rel' => $entryRel,
                'is_dir' => false,
                'is_link' => false,
                'size' => 0,
                'size_human' => '-',
                'mtime' => 0,
            ];
            continue;
        }

        $mode = $st['mode'] & 0170000;

        $isLink = ($mode === 0120000);
        $isDir = (!$isLink && $mode === 0040000);

        if ($isDir) {
            if ($dirSizes !== null && isset($dirSizes[$path])) {
                $size = $dirSizes[$path];
                $sizeHuman = human_size($size);
            } elseif ($dirSizes === null && microtime(true) < $nativeDeadline) {
                list($size, $timedOut) = dir_size_native($path, $nativeDeadline);
                $sizeHuman = human_size($size) . ($timedOut ? '+' : '');
            } else {
                $size = 0;
                $sizeHuman = '—';
            }
        } else {
            $size = (int)($st['size'] ?? 0);
            $sizeHuman = human_size($size);
        }

        $out[] = [
            'name' => $name,
            'rel' => $entryRel,
            'is_dir' => $isDir,
            'is_link' => $isLink,
            'size' => $size,
            'size_human' => $sizeHuman,
            'mtime' => (int)($st['mtime'] ?? 0),
        ];
    }

    return $out;
}




if (!isset($_SESSION['attempts'])) {
    $_SESSION['attempts'] = 0;
}

if (!isset($_SESSION['lockuntil'])) {
    $_SESSION['lockuntil'] = 0;
}

$err = null;

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $action = $_POST['action'] ?? '';

    if ($action === 'login') {
        if (!check_csrf($_POST['csrf'] ?? null)) {
            $err = 'Invalid session token.';
        } elseif (time() < $_SESSION['lockuntil']) {
            http_response_code(429);
            exit('Locked. Wait ' . (int)($_SESSION['lockuntil'] - time()) . 's.');
        } else {
            $ok = ($authPass !== '') && verify_password((string)($_POST['password'] ?? ''), $authPass);

            if ($ok) {
                session_regenerate_id(true);

                $_SESSION = [];
                $_SESSION['authed'] = true;
                $_SESSION['csrf'] = bin2hex(random_bytes(32));

                header('Location: ' . fm_url([]));
                exit;
            }

            if (++$_SESSION['attempts'] >= 5) {
                $_SESSION['lockuntil'] = time() + 60;
                $_SESSION['attempts'] = 0;
            }

            $err = 'Bad pass.';
        }
    } elseif ($action === 'logout') {
        if (!empty($_SESSION['authed'])) {
            $_SESSION = [];

            if (ini_get('session.use_cookies')) {
                $params = session_get_cookie_params();

                setcookie(
                    session_name(),
                    '',
                    time() - 42000,
                    $params['path'],
                    $params['domain'],
                    $params['secure'],
                    $params['httponly']
                );
            }

            session_destroy();
        }

        header('Location: ' . fm_url([]));
        exit;
    } elseif ($action === 'delete') {
        if (empty($_SESSION['authed']) || !check_csrf($_POST['csrf'] ?? null)) {
            http_response_code(403);
            exit('Forbidden');
        }

        $rel = (string)($_POST['path'] ?? '');
        $target = safe_path($rel, $rootfs, true);

        if (!$target || $target === $rootReal) {
            http_response_code(400);
            exit('Bad path');
        }

        if (!is_link($target) && !file_exists($target)) {
            http_response_code(404);
            exit('Not found');
        }

        $ok = del_tree($target);

        if (!$ok) {
            http_response_code(500);
            exit('Delete failed');
        }

        $parent = parent_rel($rel);

        if ($parent !== '' && safe_path($parent, $rootfs, false) === null) {
            $parent = '';
        }

        header('Location: ' . dir_url($parent));
        exit;
    }
}

if (empty($_SESSION['authed'])) {
    $loginCsrf = csrf_token();
?>
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<meta name="author" content="<?=h(FM_CREDIT)?>">
<title>Recovery File Manager</title>
<style>
*{box-sizing:border-box}
body{margin:0;min-height:100vh;display:grid;place-items:center;background:#111827;color:#e5e7eb;font-family:system-ui}
.card{width:min(380px,92vw);padding:28px;background:#1f2937;border-radius:14px}
h1{font-size:1.1rem;text-align:center;color:#f87171}
input,button{width:100%;padding:11px;border-radius:8px;font:inherit;margin-top:10px}
input{background:#111827;border:1px solid #374151;color:#fff}
button{border:0;background:#dc2626;color:#fff;cursor:pointer}
button:hover{background:#ef4444}
.error{color:#f87171;text-align:center}
.credit{margin-top:14px;font-size:.72rem;color:#9ca3af;text-align:center}
</style>
</head>
<body>
<main class="card">
<h1>Recovery File Manager</h1>
<form method="post" action="<?=h(fm_url([]))?>">
<input type="hidden" name="action" value="login">
<input type="hidden" name="csrf" value="<?=h($loginCsrf)?>">
<input type="password" name="password" placeholder="Password" autofocus required>
<button>Unlock</button>
</form>
<?php if ($err): ?>
<p class="error"><?=h($err)?></p>
<?php endif; ?>
<footer class="credit"><?=h(FM_CREDIT)?></footer>
</main>
</body>
</html>
<?php
    exit;
}

$dirRelRaw = (string)($_GET['dir'] ?? '');
$dirPath = safe_path($dirRelRaw, $rootfs, false);

if ($dirPath === null || !is_dir($dirPath) || is_link($dirPath)) {
    $dirPath = $rootReal;
}

$dirRel = rel_from_root($dirPath, $rootReal);
$displayPath = '/' . $dirRel;

$crumbs = [['name' => '/', 'rel' => '']];

if ($dirRel !== '') {
    $acc = '';

    foreach (explode('/', $dirRel) as $part) {
        if ($part === '') {
            continue;
        }

        $acc .= '/' . $part;

        $crumbs[] = [
            'name' => $part,
            'rel' => ltrim($acc, '/'),
        ];
    }
}

$entries = scan_fast($dirPath, $dirRel);

usort($entries, function ($a, $b) {
    if ($a['is_dir'] !== $b['is_dir']) {
        return $a['is_dir'] ? -1 : 1;
    }

    if ($a['is_link'] !== $b['is_link']) {
        return $a['is_link'] ? 1 : -1;
    }

    return strcasecmp($a['name'], $b['name']);
});

$total = count($entries);

$perPage = (int)(getenv('FM_PER_PAGE') ?: 500);

if ($perPage < 100) {
    $perPage = 100;
}

if ($perPage > 2000) {
    $perPage = 2000;
}

$page = max(1, (int)($_GET['page'] ?? 1));
$pages = max(1, (int)ceil($total / $perPage));

if ($page > $pages) {
    $page = $pages;
}

$entries = array_slice($entries, ($page - 1) * $perPage, $perPage);
$csrf = csrf_token();
?>
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<meta name="author" content="<?=h(FM_CREDIT)?>">
<title>Recovery File Manager</title>
<style>
*{box-sizing:border-box}
body{margin:0;padding:16px;background:#111827;color:#e5e7eb;font-family:system-ui}
.wrap{max-width:1200px;margin:auto}
.header{display:flex;justify-content:space-between;gap:12px;background:#1f2937;padding:16px;border-radius:12px 12px 0 0}
.title{font-weight:700;color:#f87171}
.meta{font-size:.75rem;color:#9ca3af}
.credit{font-size:.72rem;color:#9ca3af}
.footer{margin-top:12px;text-align:center}
.logout,.del-btn{background:transparent;border:1px solid #ef4444;color:#f87171;border-radius:7px;padding:7px 10px;cursor:pointer}
.logout:hover,.del-btn:hover{background:#dc2626;color:#fff}
.notice{margin:12px 0;padding:12px;background:#3f1d1d;border:1px solid #7f1d1d;border-radius:8px;color:#fca5a5}
.crumbs{display:flex;flex-wrap:wrap;gap:6px;padding:10px 12px;background:#172554}
.crumbs a{color:#bfdbfe;text-decoration:none}
.pager{display:flex;flex-wrap:wrap;gap:10px;align-items:center;justify-content:space-between;padding:10px 12px;background:#1f2937}
.pager a{color:#bfdbfe;text-decoration:none}
.table-wrap{overflow:auto;background:#1f2937;border-radius:0 0 12px 12px}
table{width:100%;border-collapse:collapse}
th,td{text-align:left;padding:10px 12px;border-bottom:1px solid #374151;font-size:.82rem}
th{font-size:.7rem;text-transform:uppercase;color:#9ca3af}
.name a{color:#bfdbfe;text-decoration:none}
.size{text-align:right}
.empty{text-align:center;color:#6b7280;padding:30px}
</style>
</head>
<body>
<main class="wrap">
<header class="header">
<div>
<div class="title">Recovery File Manager</div>
<div class="meta">Codespace: <?=h($csName)?> · Path: <?=h($displayPath)?></div>
<div class="credit"><?=h(FM_CREDIT)?></div>
</div>
<form method="post" action="<?=h(fm_url([]))?>">
<input type="hidden" name="action" value="logout">
<button class="logout">Logout</button>
</form>
</header>

<div class="notice">
Delete-only recovery mode. Directory sizes are calculated recursively (via <code>du</code>) for the folders shown on this page.
</div>

<nav class="crumbs">
<?php foreach ($crumbs as $i => $crumb): ?>
<?php if ($i > 0): ?><span>/</span><?php endif; ?>
<a href="<?=h(dir_url($crumb['rel']))?>"><?=h($crumb['name'])?></a>
<?php endforeach; ?>
</nav>

<?php if ($pages > 1): ?>
<div class="pager">
<div>
<?php if ($page > 1): ?>
<a href="<?=h(dir_url($dirRel, $page - 1))?>">Prev</a>
<?php endif; ?>
<?php if ($page < $pages): ?>
<a href="<?=h(dir_url($dirRel, $page + 1))?>">Next</a>
<?php endif; ?>
</div>
<span>Page <?=h($page)?> / <?=h($pages)?> · <?=h($total)?> items</span>
</div>
<?php endif; ?>

<div class="table-wrap">
<table>
<thead>
<tr>
<th>Name</th>
<th>Size</th>
<th>Modified</th>
<th>Action</th>
</tr>
</thead>
<tbody>
<?php if (!$entries): ?>
<tr>
<td colspan="4" class="empty">Empty or unreadable.</td>
</tr>
<?php endif; ?>

<?php foreach ($entries as $entry): ?>
<tr>
<td class="name">
<?php if ($entry['is_dir']): ?>
<a href="<?=h(dir_url($entry['rel']))?>"><?=h($entry['name'])?>/</a>
<?php elseif ($entry['is_link']): ?>
<span title="Symbolic link"><?=h($entry['name'])?>@</span>
<?php else: ?>
<?=h($entry['name'])?>
<?php endif; ?>
</td>
<td class="size"><?=h($entry['size_human'])?></td>
<td>
<?php if ($entry['mtime']): ?>
<?=h(date('Y-m-d H:i', $entry['mtime']))?>
<?php else: ?>
-
<?php endif; ?>
</td>
<td>
<form method="post" onsubmit="return confirm('Delete this item?')">
<input type="hidden" name="action" value="delete">
<input type="hidden" name="csrf" value="<?=h($csrf)?>">
<input type="hidden" name="path" value="<?=h($entry['rel'])?>">
<button class="del-btn">Delete</button>
</form>
</td>
</tr>
<?php endforeach; ?>
</tbody>
</table>
</div>

<footer class="credit.footer"><?=h(FM_CREDIT)?></footer>
</main>
</body>
</html>
FM_PHPEOF

    chmod 644 "$FILEMANAGER_SCRIPT" 2>/dev/null || true

    rm -f "$BASE_DIR/.filemanager_v5" 2>/dev/null || true
    touch "$marker" 2>/dev/null || true
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

admin_set_proxy_state() {
    local name="$1" desired="$2" rootfs="$CODESPACES_DIR/$1" was_running=0
    [[ "$name" =~ ^[A-Za-z0-9_-]{1,48}$ && -d "$rootfs" ]] || { echo "Unknown codespace" >&2; return 1; }
    [[ "$desired" == "on" || "$desired" == "off" ]] || { echo "Proxy state must be on or off" >&2; return 1; }
    ensure_network_files "$name"
    local current=off; is_proxy_enabled "$name" && current=on
    [[ "$current" == "$desired" ]] && return 0
    is_running "$name" && was_running=1
    echo "$desired" > "$META_DIR/$name.proxyenabled"
    if [[ "$was_running" -eq 1 ]]; then
        stop_codespace "$name" --no-fm
        if ! start_codespace "$name" --quiet; then
            echo "Proxy preference saved, but '$name' could not restart. Check its startup log." >&2
            return 1
        fi
    else
        stop_network_proxy "$name"
    fi
    if [[ "$desired" == "off" ]]; then
        write_apt_proxy_conf "$rootfs" "" "off"
        write_shell_proxy_conf "$rootfs" "" "off"
    fi
}

toggle_proxy_enabled() {
    local name="$1" desired=on
    is_proxy_enabled "$name" && desired=off
    clear; banner
    if admin_set_proxy_state "$name" "$desired"; then
        echo -e "${GREEN}[+] Proxy preference is now ${desired^^}.${RESET}"
    else
        echo -e "${RED}[!] Proxy change failed. Check the codespace and proxy logs.${RESET}"
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
admin_set_network_mode() {
    local name="$1" mode="$2"
    [[ "$name" =~ ^[A-Za-z0-9_-]{1,48}$ && -d "$CODESPACES_DIR/$name" ]] || { echo "Unknown codespace" >&2; return 1; }
    [[ "$mode" == "open" || "$mode" == "restricted" ]] || { echo "Network mode must be open or restricted" >&2; return 1; }
    ensure_network_files "$name"
    printf '%s\n' "$mode" > "$META_DIR/$name.netmode"
}

admin_update_domain_rule() {
    local name="$1" operation="$2" kind="$3" value="$4" file normalized tmp
    [[ "$name" =~ ^[A-Za-z0-9_-]{1,48}$ && -d "$CODESPACES_DIR/$name" ]] || { echo "Unknown codespace" >&2; return 1; }
    [[ "$kind" == "block" || "$kind" == "allow" ]] || { echo "Invalid domain-list type" >&2; return 1; }
    ensure_network_files "$name"
    file="$META_DIR/$name.${kind}list"
    case "$operation" in
        add)
            normalized=$(normalize_domain_input "$value")
            [[ -n "$normalized" ]] || { echo "Invalid domain" >&2; return 1; }
            grep -Fqx -- "$normalized" "$file" 2>/dev/null || printf '%s\n' "$normalized" >> "$file"
            chmod 600 "$file" 2>/dev/null || true
            ;;
        remove)
            [[ "$value" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid list index" >&2; return 1; }
            [[ -f "$file" ]] || return 0
            tmp="$file.tmp.$$"
            awk -v n="$value" 'NR != n { print }' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
            chmod 600 "$tmp" 2>/dev/null || true
            mv "$tmp" "$file"
            ;;
        *) echo "Invalid domain-list operation" >&2; return 1 ;;
    esac
}

admin_set_quota() {
    local name="$1" quota="$2" mode="$3" current_mode current_quota
    [[ "$name" =~ ^[A-Za-z0-9_-]{1,48}$ && -d "$CODESPACES_DIR/$name" ]] || { echo "Unknown codespace" >&2; return 1; }
    [[ "$quota" =~ ^[0-9]{1,6}$ ]] && (( quota <= 100000 )) || { echo "Quota must be between 0 and 100000 MB" >&2; return 1; }
    [[ "$mode" == "soft" || "$mode" == "hard" ]] || { echo "Quota mode must be soft or hard" >&2; return 1; }
    ensure_quota_files "$name"
    current_mode=$(get_quota_mode "$name")
    current_quota=$(get_quota_mb "$name")
    if [[ "$mode" == "soft" ]]; then
        if [[ "$current_mode" == "hard" ]]; then
            disable_hard_quota "$name" || return 1
        fi
        set_quota_mb "$name" "$quota"
        rm -f "$META_DIR/$name.quota.exceeded"
        if [[ "$quota" -eq 0 ]]; then stop_quota_watchdog "$name"
        elif is_running "$name"; then start_quota_watchdog "$name"; fi
        return 0
    fi
    [[ "$quota" -ge 64 ]] || { echo "Hard quota requires at least 64 MB" >&2; return 1; }
    hard_quota_supported || { echo "Hard quotas are unsupported on this device" >&2; return 1; }
    if [[ "$current_mode" == "hard" ]]; then
        [[ "$quota" -eq "$current_quota" ]] && return 0
        [[ "$quota" -gt "$current_quota" ]] || { echo "Hard quota can only be increased here; use the CLI quota menu to disable and recreate it at a lower size" >&2; return 1; }
        resize_hard_quota "$name" "$quota"
    else
        enable_hard_quota "$name" "$quota"
    fi
}

toggle_restricted_mode() {
    local name="$1" mode
    mode=$(cat "$META_DIR/$name.netmode" 2>/dev/null || echo "open")
    [[ "$mode" == "restricted" ]] && mode=open || mode=restricted
    clear; banner
    if admin_set_network_mode "$name" "$mode"; then
        echo -e "${GREEN}[+] Network mode is now ${CYAN}${mode}${RESET}"
    fi
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
    chmod 600 "$META_DIR/$new_name.pass" 2>/dev/null || true
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
    chmod 600 "$META_DIR/$name.pass" 2>/dev/null || true
    start_codespace "$name"
}

start_codespace() {
    local name="$1" quiet="${2:-}"; local rootfs="$CODESPACES_DIR/$name"
    local port pass; port=$(cat "$META_DIR/$name.port" 2>/dev/null); pass=$(cat "$META_DIR/$name.pass" 2>/dev/null)
    [[ -z "$port" ]] && { [[ "$quiet" != "--quiet" ]] && press_any_key; return 1; }
    ensure_quota_files "$name"
    if is_hard_quota "$name"; then mount_hard_quota "$name" || { [[ "$quiet" != "--quiet" ]] && press_any_key; return 1; }; fi
    local quota_mb used_mb; quota_mb=$(get_quota_mb "$name")
    if [[ "$quota_mb" -gt 0 ]]; then
        used_mb=$(get_codespace_size_mb "$name")
        if [[ -n "$used_mb" && "$used_mb" -gt "$quota_mb" ]]; then
            is_filemanager_running "$name" || start_filemanager "$name"
            [[ "$quiet" != "--quiet" ]] && show_codespace_info "$name"
            return 1
        fi
    fi
    stop_filemanager "$name" 2>/dev/null || true
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
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
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

    local ip; ip=$(device_ip)
    echo -e "${GREEN}${BOLD}Codespace '$name' is up.${RESET}"
    echo -e "  Local:    http://127.0.0.1:${port}"
    [[ -n "$ip" ]] && echo -e "  Network:  http://${ip}:${port}"
    echo -e "  Password: ${BOLD}${pass}${RESET}"
    echo -e "  Proxy:    $(proxy_status_colored "$name")"
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
        export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

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
    local quota_mb used_mb over_quota=0
    quota_mb=$(get_quota_mb "$name")
    if [[ "$quota_mb" -gt 0 ]]; then
        used_mb=$(get_codespace_size_mb "$name")
        [[ -n "$used_mb" && "$used_mb" -gt "$quota_mb" ]] && over_quota=1
    fi
    if is_filemanager_running "$name"; then
        echo -e "  File Manager: ${GREEN}RUNNING${RESET} (recovery mode - http://127.0.0.1:${port:-?})"
    elif [[ "$over_quota" -eq 1 ]]; then
        if command -v php >/dev/null 2>&1; then
            echo -e "  File Manager: ${RED}NOT RUNNING${RESET} (over quota, but it failed to start - check $META_DIR/$name.fm.log)"
        else
            echo -e "  File Manager: ${RED}NOT RUNNING${RESET} (over quota, but 'php' is not installed - run: pkg install php)"
        fi
    fi
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
        refresh_codespace_size_cache_async
        local options=()
        for n in "${names[@]}"; do
            local status_tag size_tag proxy_tag
            ensure_network_files "$n"
            is_running "$n" && status_tag="[running]" || status_tag="[stopped]"
            proxy_tag="[$(proxy_status_plain "$n")]"
            size_tag="$(cached_codespace_size_mb "$n") MB"
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
            revoke) [[ $idx -lt ${#names[@]} ]] && revoke_codespace_credential "${names[$idx]}" ;;
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


admin_create_codespace() {
    local name="$1" quota="${2:-0}" rootfs="$CODESPACES_DIR/$1" port pass
    [[ "$name" =~ ^[A-Za-z0-9_-]{1,48}$ ]] || { echo "Invalid codespace name" >&2; return 1; }
    [[ ! -e "$rootfs" ]] || { echo "Codespace already exists" >&2; return 1; }
    [[ -d "$BASE_ROOTFS" ]] || { echo "Base image is unavailable" >&2; return 1; }
    [[ "$quota" =~ ^[0-9]+$ ]] || { echo "Invalid quota" >&2; return 1; }
    parallel_file_task copy "$BASE_ROOTFS" "$rootfs" 4 || { rm -rf "$rootfs"; return 1; }
    fix_l2s_symlinks "$BASE_ROOTFS" "$rootfs"
    prepare_codespace_rootfs "$rootfs"
    write_codeserver_settings "$rootfs"
    ensure_network_files "$name"
    ensure_quota_files "$name"
    set_quota_mb "$name" "$quota"
    port=$(find_free_port)
    [[ -n "$port" ]] || { rm -rf "$rootfs"; echo "No free code-server port" >&2; return 1; }
    pass=$(random_password)
    mkdir -p "$rootfs/root/.config/code-server"
    cat > "$rootfs/root/.config/code-server/config.yaml" <<CFG
bind-addr: 0.0.0.0:${port}
auth: password
password: ${pass}
cert: false
CFG
    echo "$port" > "$META_DIR/$name.port"
    printf '%s\n' "$pass" > "$META_DIR/$name.pass"
    chmod 600 "$META_DIR/$name.pass" 2>/dev/null || true
    start_codespace "$name" --quiet
}

admin_delete_codespace() {
    local name="$1"
    [[ "$name" =~ ^[A-Za-z0-9_-]{1,48}$ && -d "$CODESPACES_DIR/$name" ]] || { echo "Unknown codespace" >&2; return 1; }
    stop_filemanager "$name" 2>/dev/null || true
    stop_codespace "$name" --no-fm
    rm -rf "$CODESPACES_DIR/$name" "$(quota_image_path "$name")"
    rm -f "$META_DIR/$name."*
    [[ ! -e "$CODESPACES_DIR/$name" ]] || { echo "Codespace deletion failed" >&2; return 1; }
}

admin_export_codespace() {
    local name="$1" export_path="$2" cores tmp_meta_dir unmount=0 was_running=0
    [[ "$name" =~ ^[A-Za-z0-9_-]{1,48}$ && -d "$CODESPACES_DIR/$name" ]] || { echo "Unknown codespace" >&2; return 1; }
    [[ "$export_path" == "$BASE_DIR"/.admin-export-*/"$name.tar.gz" ]] || { echo "Invalid export destination" >&2; return 1; }
    command -v pigz >/dev/null 2>&1 || { echo "pigz is required for export" >&2; return 1; }
    [[ ! -e "$export_path" ]] || { echo "Export destination already exists" >&2; return 1; }
    if is_running "$name"; then
        was_running=1
        stop_codespace "$name" --no-fm || { echo "Could not stop codespace for a consistent export" >&2; return 1; }
    fi
    if is_hard_quota "$name" && ! is_quota_image_mounted "$name"; then
        mount_hard_quota "$name" || { [[ "$was_running" -eq 1 ]] && start_codespace "$name" --quiet >/dev/null 2>&1 || true; return 1; }
        unmount=1
    fi
    fix_rootfs_permissions "$CODESPACES_DIR/$name"
    cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)
    [[ "$cores" =~ ^[0-9]+$ ]] || cores=2
    (( cores < 1 )) && cores=1
    (( cores > 8 )) && cores=8
    tmp_meta_dir=$(mktemp -d "$BASE_DIR/.admin-export-meta.XXXXXX") || { [[ "$unmount" -eq 1 ]] && unmount_hard_quota "$name"; [[ "$was_running" -eq 1 ]] && start_codespace "$name" --quiet >/dev/null 2>&1 || true; return 1; }
    { printf 'name=%s\n' "$name"; printf 'port=%s\n' "$(cat "$META_DIR/$name.port" 2>/dev/null)"; printf 'pass=%s\n' "$(cat "$META_DIR/$name.pass" 2>/dev/null)"; } > "$tmp_meta_dir/codespace.meta"
    chmod 600 "$tmp_meta_dir/codespace.meta" 2>/dev/null || true
    local tar_excludes=() p
    for p in "${PROOT_BIND_EXCLUDES[@]}"; do tar_excludes+=("--exclude=${name}/${p}"); done
    tar --ignore-failed-read --warning=no-failed-read "${tar_excludes[@]}" -cf - -C "$CODESPACES_DIR" "$name" -C "$tmp_meta_dir" "codespace.meta" | pigz -p "$cores" > "$export_path"
    local pipe_status=("${PIPESTATUS[@]}")
    rm -rf "$tmp_meta_dir"
    [[ "$unmount" -eq 1 ]] && unmount_hard_quota "$name"
    local ok=1
    if [[ "${pipe_status[0]}" -ge 2 || "${pipe_status[1]}" -ne 0 || ! -s "$export_path" ]]; then rm -f "$export_path"; ok=0; fi
    if [[ "$was_running" -eq 1 ]]; then start_codespace "$name" --quiet >/dev/null 2>&1 || { echo "Export finished, but the codespace could not be restarted" >&2; ok=0; }; fi
    [[ "$ok" -eq 1 ]] || { echo "Codespace export failed" >&2; return 1; }
    echo "Export created"
}

admin_import_staged() {
    local stage_root="$1" new_name="$2" meta name_in_zip port_in_zip pass_in_zip extracted_dir req_port port pass
    [[ "$new_name" =~ ^[A-Za-z0-9_-]{1,48}$ ]] || { echo "Invalid codespace name" >&2; return 1; }
    [[ "$stage_root" == "$BASE_DIR"/.admin-import-*/extract ]] || { echo "Invalid import staging directory" >&2; return 1; }
    [[ -f "$stage_root/codespace.meta" ]] || { echo "Codespace metadata is missing" >&2; return 1; }
    [[ ! -e "$CODESPACES_DIR/$new_name" ]] || { echo "Codespace already exists" >&2; return 1; }
    meta=$(cat "$stage_root/codespace.meta" 2>/dev/null) || return 1
    name_in_zip=$(printf '%s\n' "$meta" | sed -n 's/^name=//p' | head -n1)
    port_in_zip=$(printf '%s\n' "$meta" | sed -n 's/^port=//p' | head -n1)
    pass_in_zip=$(printf '%s\n' "$meta" | sed -n 's/^pass=//p' | head -n1)
    [[ "$name_in_zip" =~ ^[A-Za-z0-9_-]{1,48}$ ]] || { echo "Invalid archived codespace name" >&2; return 1; }
    extracted_dir="$stage_root/$name_in_zip"
    [[ -d "$extracted_dir" ]] || { echo "Archived root filesystem is missing" >&2; return 1; }
    if [[ -n "$port_in_zip" && ! "$port_in_zip" =~ ^[0-9]{1,5}$ ]]; then port_in_zip=""; fi
    if [[ -n "$port_in_zip" ]] && (( port_in_zip < 1 || port_in_zip > 65535 )); then port_in_zip=""; fi
    parallel_file_task move "$extracted_dir" "$CODESPACES_DIR/$new_name" 4 || { echo "Could not move imported root filesystem" >&2; return 1; }
    [[ "$name_in_zip" != "$new_name" ]] && fix_l2s_symlinks "$CODESPACES_DIR/$name_in_zip" "$CODESPACES_DIR/$new_name"
    prepare_codespace_rootfs "$CODESPACES_DIR/$new_name"
    write_codeserver_settings "$CODESPACES_DIR/$new_name"
    ensure_quota_files "$new_name"
    ensure_network_files "$new_name"
    req_port="$port_in_zip"
    port=$(find_free_port "$req_port")
    [[ -n "$port" ]] || { rm -rf "$CODESPACES_DIR/$new_name"; echo "No free code-server port" >&2; return 1; }
    if [[ "$pass_in_zip" =~ ^[A-Za-z0-9_-]{8,256}$ ]]; then pass="$pass_in_zip"; else pass=$(random_password); fi
    mkdir -p "$CODESPACES_DIR/$new_name/root/.config/code-server"
    cat > "$CODESPACES_DIR/$new_name/root/.config/code-server/config.yaml" <<CFG
bind-addr: 0.0.0.0:${port}
auth: password
password: ${pass}
cert: false
CFG
    printf '%s\n' "$port" > "$META_DIR/$new_name.port"
    printf '%s\n' "$pass" > "$META_DIR/$new_name.pass"
    chmod 600 "$META_DIR/$new_name.pass" 2>/dev/null || true
    echo "Imported '$new_name' on port $port"
}

admin_prepare_terminal() {
    local name="$1"
    [[ "$name" =~ ^[A-Za-z0-9_-]{1,48}$ && -d "$CODESPACES_DIR/$name" ]] || { echo "Unknown codespace" >&2; return 1; }
    ensure_quota_files "$name"
    if is_hard_quota "$name" && ! is_quota_image_mounted "$name"; then mount_hard_quota "$name" || return 1; fi
    prepare_codespace_rootfs "$CODESPACES_DIR/$name"
    ensure_network_files "$name"
    if is_proxy_enabled "$name"; then start_network_proxy "$name" || return 1; else stop_network_proxy "$name"; fi
}

admin_action_dispatch() {
    local action="${2:-}" name="${3:-}"
    case "$action" in
        create) admin_create_codespace "$name" "${4:-0}" ;;
        delete) admin_delete_codespace "$name" ;;
        start) start_codespace "$name" --quiet ;;
        stop) stop_codespace "$name" --no-fm ;;
        revoke) revoke_codespace_credential "$name" ;;
        proxy) admin_set_proxy_state "$name" "${4:-}" ;;
        restrict) admin_set_network_mode "$name" "${4:-}" ;;
        domain-rule) admin_update_domain_rule "$name" "${4:-}" "${5:-}" "${6:-}" ;;
        quota) admin_set_quota "$name" "${4:-}" "${5:-soft}" ;;
        export) admin_export_codespace "$name" "${4:-}" ;;
        import-staged) admin_import_staged "$name" "${4:-}" ;;
        prepare-terminal) admin_prepare_terminal "$name" ;;
        *) echo "Unknown admin action" >&2; return 2 ;;
    esac
}

if [[ "${1:-}" == "--admin-action" ]]; then
    admin_action_dispatch "$@"
    exit $?
fi

migrate_legacy_base || exit 1
if ! base_is_ready; then
    if [[ -d "$BASE_ROOTFS" ]]; then
        clear; banner
        read -rp "Rebuild incomplete base? [Y/n]: " r
        [[ ! "$r" =~ ^[Nn]$ ]] && { rm -rf "$BASE_IMAGE_DIR"; rm -f "$STATE_FILE"; } || exit 1
    fi
    run_initial_setup || exit 1
fi

if admin_panel_enabled; then start_admin_panel --quiet || echo -e "${YELLOW}[!] Admin panel is enabled but could not start. Check $META_DIR/admin.log.${RESET}"; fi

main_menu() {
    while true; do
        local admin_label="Admin Web Panel: OFF"
        admin_panel_enabled && admin_label="Admin Web Panel: ON"
        arrow_menu "Termux CodeSpace" "Manage Codespaces" "$admin_label" "Terminate All" "Cleanup Everything" "Exit"
        local action="${ARROW_MENU_RESULT%%:*}" idx="${ARROW_MENU_RESULT##*:}"
        [[ "$action" == "back" ]] && { clear; exit 0; }
        if [[ "$action" == "revoke" ]]; then revoke_admin_credential; continue; fi
        if [[ "$action" == "reveal" ]]; then reveal_admin_credential; continue; fi
        case "$idx" in
            0) manage_codespaces_menu ;;
            1) admin_panel_toggle ;;
            2) terminate_all ;;
            3) cleanup_all ;;
            4) clear; exit 0 ;;
        esac
    done
}
main_menu
