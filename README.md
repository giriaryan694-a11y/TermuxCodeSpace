# TermuxCodeSpace

<div align="center">

**Multiple isolated Ubuntu codespaces for Termux, powered by proot**

[![Platform](https://img.shields.io/badge/platform-Termux%20\(Android\)-green)](https://termux.dev)
[![Shell](https://img.shields.io/badge/shell-Bash-blue)](https://www.gnu.org/software/bash/)
[![License](https://img.shields.io/badge/license-Apache%202.0-orange)](LICENSE)

</div>

---

## Overview

TermuxCodeSpace is a single-file Bash script that lets you create **multiple isolated Ubuntu environments** on Android through Termux.

Each codespace runs its own [code-server](https://github.com/coder/code-server) instance, so you get VS Code in the browser with separate ports, separate configs, and separate filesystem clones. Each codespace also gets its own lightweight network proxy, so you can see what it's talking to and, if you want, restrict it — or turn the proxy off entirely and run direct.

Think of it as **local Codespaces on your phone**.

```text
┌──────────────────────────────────────────────────────┐
│                    Termux (Android)                  │
│                                                       │
│   ┌───────────┐  ┌───────────┐  ┌──────────┐          │
│   │ Ubuntu #1 │  │ Ubuntu #2 │  │ Ubuntu #3│          │
│   │ port 2000 │  │ port 2001 │  │ port 2002│          │
│   │ proxy 8000│  │ proxy 8001│  │proxy 8002│          │
│   └───────────┘  └───────────┘  └──────────┘          │
│         proot          proot          proot          │
└──────────────────────────────────────────────────────┘
```

## Why use this?

When you develop directly on your main machine, project dependencies, libraries, and extra packages can slowly mess up your system. Different projects often need different versions of the same tools, and that can turn into conflicts very fast.

TermuxCodeSpace solves that by giving each project its own isolated Ubuntu environment.

It is useful because:

* your main system stays clean
* every project gets its own separate packages and libraries
* you can test different setups without breaking anything else
* it runs directly on your phone with Termux
* it is lightweight, portable, and easy to launch anywhere
* you can watch, and optionally restrict, what each codespace talks to on the network — or switch that off entirely per codespace

## Features

* One-command setup
* Multiple isolated Ubuntu clones
* Automatic port selection
* Unique password per codespace
* Arrow-key menu interface
* Background execution with `nohup`
* Create, start, stop, delete, and terminate all codespaces
* Recovery file manager for quota-exceeded codespaces (delete-only)
* Parallel filesystem scanning with file/directory sizes and permissions
* Recursive directory size calculation with a PHP fallback when the Python scanner is unavailable
* Per-codespace network activity log, covering both HTTP and HTTPS traffic
* Per-codespace domain block/allow list
* Per-codespace "restricted" (default-deny) network mode toggle
* Per-codespace proxy on/off switch — turn logging/filtering off for direct, unproxied traffic when you don't need it
* Optional Wi-Fi LAN Admin Web Panel with a responsive dashboard
* Create, start, stop, delete, inspect network logs, and rotate credentials from another device
* Interactive browser terminal scoped to a selected PRoot codespace
* Random admin credential, session authentication, CSRF checks, login throttling, and selectable HTTP or HTTPS transport
* `apt` traffic (both the base image and every cloned codespace) is routed through the local proxy and forced onto `https://` mirrors instead of `http://`

## Requirements

* Termux from [F-Droid](https://f-droid.org/packages/com.termux/) or GitHub Releases
* Android 7.0 or newer
* Around 2 GB free storage per codespace
* `python3` on the Termux host, for network logging/filtering and the Admin Web Panel

> **Important:** Do not use the Play Store version of Termux. It is outdated and may not work correctly.

## Installation

```bash
apt update && apt upgrade -y
apt install proot proot-distro pigz git python -y

git clone https://github.com/giriaryan694-a11y/TermuxCodeSpace.git
cd TermuxCodeSpace

chmod +x codespace.sh
```

## Usage

Start the tool with:

```bash
./codespace.sh
```

On first run, the script will:

1. Install a base Ubuntu image with `proot-distro`
2. Rewrite its `apt` sources to use `https://` mirrors instead of `http://`
3. Set up the required packages
4. Install `code-server`
5. Prepare the base environment for cloning

After that, new codespaces are created much faster because they are cloned from the base Ubuntu rootfs.

## Main Menu

```text
> Manage Codespaces
> Admin Web Panel: OFF
> Terminate All
> Cleanup Everything
> Exit
```

Select **Admin Web Panel: OFF** to enable the LAN dashboard. Its state is retained across normal script exits; selecting it again turns the server off.

## Creating and Managing Codespaces

Example codespace list:

```text
> myproject    [running]
  backend-api   [stopped]
  + Create New Codespace
```

### Controls

| Key       | Action                                                |
| --------- | ------------------------------------------------------ |
| `UP` / `DOWN` | Navigate                                                |
| `Enter`   | Select or start a codespace                             |
| `c`       | Connect to codespace shell                              |
| `n`       | View live network activity log                          |
| `b`       | Manage domain block/allow lists                         |
| `r`       | Revoke and regenerate the selected codespace's password |
| `R`       | Toggle restricted network mode (press again for open)    |
| `p`       | Turn the network proxy fully on/off for that codespace   |
| `s`       | Open storage quota settings                              |
| `d`       | Delete a codespace                                       |
| `t`       | Stop a codespace                                         |
| `q`       | Go back                                                  |
| `i`       | Import codespace                                         |
| `e`       | Export codespace                                         |

When creating a codespace, you will be asked for:

* **Name** — use letters, numbers, hyphens, or underscores
* **Port** — leave blank for automatic assignment, or enter your own

The script generates a unique password, writes the `code-server` config, and starts the server automatically. It also starts that codespace's network proxy (unless you've turned it off with `p`), so logging is active as soon as the codespace is up.


## Admin Web Panel (Wi-Fi LAN)

The Admin Web Panel lets you manage TermuxCodeSpace from a laptop, tablet, or another phone connected through the phone hotspot, Wi-Fi, USB tethering, or another reachable private LAN interface. You do not need to open Termux for routine codespace management.

### Enable and configure it

1. Connect the client device to the phone hotspot or to the same trusted private Wi-Fi/LAN.
2. Run `./codespace.sh` on the phone and select **Admin Web Panel: OFF**.
3. Choose the transport:
   * **HTTP** — direct access to the panel. No TLS setup is required.
   * **HTTPS** — the panel backend stays on `127.0.0.1`; use the [`http2https`](https://github.com/giriaryan694-a11y/http2https) reverse-proxy tool for browser-facing TLS.
4. Choose **All detected interfaces** or one discovered interface, such as `ap0` (phone hotspot) or `wlan0` (Wi-Fi). Addresses are detected with `ifconfig -a`, with `ip` as a fallback.
5. Enter the randomly generated admin credential printed by Termux whenever the panel is enabled from the CLI. If the panel was automatically restarted quietly at launch, press lowercase `v` in the main menu to reveal the saved credential again.

The admin credential is retained across panel off/on cycles and stored in `~/.termux-codespace/meta/.admin.pass` with restrictive permissions. Press lowercase `r` in the main menu to revoke it and generate a replacement.

The choice is saved in `~/.termux-codespace/meta/` and is reused when the panel is automatically restarted. Disable the panel from the main menu when you are done.

### HTTP mode

HTTP mode binds either to the selected interface's IPv4 address or to `0.0.0.0` when **All detected interfaces** is selected. Termux prints the matching URL(s), for example:

```text
http://192.168.43.1:8787
```

**Security:** HTTP is plaintext. The admin password, session cookie, terminal keystrokes/output, and dashboard data are not encrypted in transit. Use HTTP only on a trusted private home LAN where you trust every connected device. Do not use it on public/guest Wi-Fi, and do not expose the port with router port forwarding. A random password and CSRF protection do not encrypt network traffic.

### HTTPS mode with http2https

TermuxCodeSpace does not generate a self-signed certificate for the Admin Panel. Instead, it runs the panel backend on `127.0.0.1:<internal-port>` and prints the values needed by [`http2https`](https://github.com/giriaryan694-a11y/http2https).

Set up the tool on the phone:

```bash
git clone https://github.com/giriaryan694-a11y/http2https.git
cd http2https
pkg install python python-cryptography
pip install pyfiglet termcolor colorama requests
python main.py
```

When `http2https` asks for configuration, enter:

* **Certificate title:** `TermuxCodeSpace Admin`
* **Domains/IPs to secure:** the interface IP address(es) printed by Termux for your selected interface
* **Internal HTTP port:** the Admin Panel's printed `127.0.0.1` backend port
* **HTTPS port:** the HTTPS proxy port selected in TermuxCodeSpace

Then open `https://<selected-LAN-IP>:<HTTPS-port>` from the laptop or other client device. Install/trust the generated certificate on that client device using the instructions in the `http2https` repository; otherwise the browser will warn that the certificate is not trusted.

The current `http2https` implementation binds its HTTPS listener to `0.0.0.0`. In HTTPS mode, choosing an interface in TermuxCodeSpace selects the intended address(es) and certificate SANs, but does **not** restrict the `http2https` listener to that interface. The Admin Panel's own HTTP backend remains loopback-only. Keep the proxy on a trusted network and do not configure router port forwarding.

### Dashboard features

* Create a codespace, set an optional storage quota, and start it
* A **View** link appears only while a codespace is running. It opens `http://<same-host-as-admin-panel>:<codespace-port>/` in a new tab, using the exact IP/hostname you used to reach the dashboard. This keeps the link aligned with the hotspot or Wi-Fi interface the laptop is currently using. If the dashboard is opened through `localhost` or a loopback address on the phone itself, it falls back to the first active IPv4 address from the selected interface list.
* The codeserver listener currently uses plain HTTP (`bind-addr 0.0.0.0:<port>`). Therefore, **View opens HTTP even when the Admin Panel itself uses HTTPS through `http2https`**; that HTTPS proxy is configured for the panel backend only. Use this direct codeserver URL on a trusted private LAN, and do not expose its port through router port forwarding.
* Import a `.tar.gz` / `.tgz` codespace export directly from the browser, choosing a new name
* Export any codespace to a downloadable `.tar.gz` archive directly from its action row
* Start and stop codespaces; a **View** action appears only while a codespace is running and opens its code-server on the same LAN IP used to access the Admin Panel, at that codespace's assigned port
* Permanently delete selected codespaces
* View the selected codespace's HTTP and HTTPS proxy log
* Edit block/allow domain rules, switch open/restricted network mode, and toggle its proxy from the dashboard
* View and change soft or hard storage quotas from the dashboard (hard quotas depend on device support)
* Reveal the currently stored password for an individual codespace from its **Password** action, then copy it from the credential dialog. Passwords are fetched only after admin authentication and a CSRF check; they are not included in the dashboard state response. Revealing a password does not rotate it.
* Open an xterm.js browser terminal backed by a real PTY inside a selected PRoot codespace, with ANSI escape rendering, cursor movement, Backspace, Ctrl key combinations, copy/paste, and automatic terminal resize
* Revoke and regenerate a codespace password; the same new password is used by code-server and the recovery manager
* Revoke and regenerate the admin panel credential from **Settings**

### Codespace import and export

The dashboard's **Export** action uses the same archive layout as the existing Termux CLI export: a compressed `.tar.gz` containing the codespace root filesystem and a top-level `codespace.meta` file with its original name, code-server port, and code-server password. If the codespace is running, the panel stops it to create a consistent filesystem snapshot, then attempts to start it again after the export completes. Any browser PTY sessions attached to that codespace are closed before export.

Use **Import codespace** at the top of the Codespaces page to select a `.tar.gz` / `.tgz` archive and choose the destination name. The panel refuses to overwrite an existing codespace, validates archive paths and filesystem entry types before extraction, checks available storage, and preserves the password stored in the archive. Imported codespaces are created stopped; start them from the dashboard when ready. The compressed upload limit is 4 GiB, subject to available storage.

**Archive contents are sensitive.** The export contains the code-server password in `codespace.meta` and in the codeserver configuration inside the root filesystem. Store it privately and do not send it to people or upload it to a public repository. The current CLI archive format does not include separate Termux metadata such as network logs, domain allow/block lists, proxy state, or quota settings; those remain local to the source device and are initialized to defaults on import.

### Browser terminal: xterm.js + PTY

The Admin Panel terminal uses [xterm.js](https://xtermjs.org/) as the browser-side terminal emulator and launches an interactive Bash process through a real pseudo-terminal (PTY) inside the selected PRoot codespace. This is fundamentally different from a command textbox: keystrokes are forwarded to the PTY, and the PTY output (including ANSI control sequences) is rendered by xterm.js.

* Backspace is sent as the terminal's configured erase character and is handled by the shell/PTY line discipline.
* Enter, Tab, Escape, arrows, Home/End, Page Up/Down and Ctrl combinations are forwarded as terminal input. A mobile extra-key bar provides keys that are awkward to type on a phone keyboard.
* ANSI colors, cursor movement, interactive prompts, terminal resizing, selection and browser copy/paste are supported by the terminal emulator. Full-screen applications should be substantially more usable than in the previous textarea-based interface, although Android/PRoot compatibility varies by application.
* In direct **HTTP** mode, the browser uses an authenticated WebSocket for a low-latency, bidirectional PTY stream.
* In **HTTPS** mode, the current `http2https` proxy does not tunnel WebSocket upgrade connections. The browser therefore uses authenticated HTTP input/output polling (140 ms interval) while retaining xterm.js rendering and PTY resize. This is functional but less responsive than WebSocket, especially for full-screen interactive programs.
* The xterm.js and fit-addon libraries are loaded from jsDelivr, with an unpkg fallback. The browser needs internet access to load these libraries. No external terminal service receives shell input; the CDN provides the client-side JavaScript libraries only.
* Disconnecting the terminal, signing out, expiring the admin session, or stopping the panel closes the PTY session. This build does not yet provide Cloud-Shell-style `tmux` persistence across browser reconnects.

Google Cloud Shell documents browser terminal features such as keyboard shortcuts, copy/paste, multiple terminal sessions and terminal preferences. TermuxCodeSpace adopts the browser-terminal/PTY model, but it is not a drop-in recreation of Cloud Shell's session-management infrastructure.

### Credential revocation shortcuts

* In the **main menu**, press lowercase `v` to display the saved admin panel credential in the Termux CLI.
* In the **main menu**, press lowercase `r` to revoke the admin panel credential. The new credential is printed immediately; existing browser and terminal sessions are invalidated.
* In **Manage Codespaces**, select a codespace and press lowercase `r` to rotate that codespace's credential. If it was running, it is restarted so the old password stops working.
* Uppercase `R` remains the network restricted-mode shortcut. Case matters here, because apparently keyboards enjoy having opinions.

Turning the panel off stops its backend but retains its credential and selected transport/interface settings. In HTTPS mode, stop the separate `http2https` process with Ctrl+C in the terminal where it is running as well; TermuxCodeSpace does not own that external proxy process. Cleanup Everything stops the panel and removes its stored settings. Exiting the menu does not turn the panel off.

> **Security note:** The Admin Panel can delete codespaces and provides a shell inside a selected PRoot environment. PRoot is userspace isolation, not a hardened container or Android security boundary. Use the panel only on a trusted private network, disable it when finished, and do not expose it through router port forwarding or use it on untrusted/public networks.

## Recovery File Manager

If a codespace is stopped because it exceeds its storage quota, TermuxCodeSpace can launch a **delete-only recovery file manager** so you can free storage without starting the full codespace.

The recovery manager provides:

* Browse the codespace filesystem
* File sizes and recursive directory sizes
* Full symbolic permissions such as `drwxr-xr-x`
* Octal permissions such as `0755`
* Modification timestamps
* Delete files or directories
* Parallel filesystem scanning for faster browsing
* A PHP filesystem fallback if the Python scanner cannot be executed
* No file creation, uploads, edits, or renames

The recovery manager is intentionally restricted to deletion so it can be used to recover space safely after a quota stop.

Example:

```text
Recovery File Manager for 'myproject' is up.
  This codespace exceeded its storage quota and was stopped.
  Browse to it to delete files and free up space:
  Local:    http://127.0.0.1:2000
  Password: same as the code-server password for this codespace
  Delete-only - no create, write, or upload.
```

## Direct Shell Access

For quick work on your phone, you can connect directly to a codespace without opening VS Code.

Select a running codespace and press:

```text
c
```

You will enter the isolated Ubuntu environment directly from the Termux terminal.

```text
Connecting to "myproject"...

root@myproject:~#
```

When finished, simply run:

```bash
exit
```

or press **Ctrl+D**.

You will automatically return to the TermuxCodeSpace manager.

This provides a lightweight workflow for package management, Git operations, compiling code, and other terminal-based tasks without requiring a browser or large display. CLI sessions go through the same network proxy as code-server (when the proxy is enabled), so anything you `curl`, `git clone`, `apt install`, or `pip install` here shows up in the network log too.

## Accessing code-server

Once a codespace is running, the terminal will show something like this:

```text
Codespace 'myproject' is up.
  Local:    http://127.0.0.1:2000
  Network:  http://192.168.1.42:2000
  Password: aB3xK9mQpL2wR7nT
```

Use it like this:

* On the same device: open `http://127.0.0.1:<port>`
* On another device in the same network: open `http://<device-ip>:<port>`
* Enter the generated password shown in the terminal

Passwords are also stored in:

```bash
~/.termux-codespace/meta/<name>.pass
```

## Network Logging & Filtering

Every codespace has its own forward proxy that starts and stops alongside it. The launcher points the container's `http_proxy` / `https_proxy` at it, so code-server, `c` shell sessions, and `apt` all route through it automatically — nothing to configure per-tool.

```text
┌──────────────┐   http_proxy   ┌─────────────────┐        ┌────────────┐
│  codespace    │   https_proxy  │  per-codespace    │───────▶│  internet  │
│  (proot)      │───────────────▶│  proxy (Termux,   │        │            │
│               │◀──────────────│  no root)         │◀───────│            │
└──────────────┘                └─────────────────┘        └────────────┘
                                        │
                                        ▼
                              ~/.termux-codespace/meta/
                                <name>.netlog
```

**What it can do:**

* Log every request: timestamp, allow/deny verdict, method, host, port — for both plain HTTP and HTTPS (`CONNECT`)
* Block or unblock individual domains (`b` menu)
* Flip a codespace into "restricted" mode (`R`) — default-deny, only domains you've explicitly allowed can be reached; press `R` again to go back to open
* Turn the proxy off entirely (`p`) for a codespace that needs to run fully direct — no logging, no filtering, until you switch it back on
* Route `apt update` / `apt install` through the same proxy as everything else, via an `Acquire::http::Proxy` / `Acquire::https::Proxy` config written into the codespace automatically
* Rewrite that codespace's `apt` sources to use `https://` mirrors instead of `http://`, so package downloads are encrypted end-to-end and not just tunnelled in the clear to the proxy

**What it can't do (by design):**

* It's a domain-level filter, not deep packet inspection. HTTPS is tunnelled via `CONNECT` and never decrypted, so only the hostname is ever visible — not the path, headers, or body.
* It only sees traffic that respects the `http_proxy` / `https_proxy` environment variables (or, for `apt`, its own `Acquire::*::Proxy` settings). A process using raw sockets, a custom DNS resolver, or hardcoded IPs can bypass it.
* It runs as a normal, unprivileged process on the Termux host — no `iptables`, no root, no network namespace tricks. That's intentional (keeps the whole setup rootless), but it's a cooperative proxy, not a transparent firewall.

### Viewing the log

Select a codespace and press `n`:

```text
Network log: myproject
  Proxy:  running on 127.0.0.1:8000
  Mode:   open

[2026-08-12 10:14:02] ALLOW CONNECT   github.com:443
[2026-08-12 10:14:03] ALLOW GET      raw.githubusercontent.com:443
[2026-08-12 10:14:04] ALLOW CONNECT   archive.ubuntu.com:443
[2026-08-12 10:14:11] DENY  CONNECT   ads.example.com:443
```

If the proxy has been turned off for that codespace (`p`), this screen shows `Proxy: disabled` instead, and the log simply won't be receiving new entries.

Press `Ctrl+C` to return to the menu.

### Managing block/allow lists

Select a codespace and press `b`:

```text
Domain policy: myproject
  Mode: open (default-allow)

Blocklist (always denied, both modes):
   1  ads.example.com

Allowlist (only consulted in restricted mode):
  (empty)

a) block a domain      x) unblock (remove from blocklist)
w) allow a domain       y) remove from allowlist
q) back
```

* Domains can be exact (`example.com`) or match all subdomains with a leading dot (`.example.com`).
* The blocklist is always enforced, in both open and restricted mode.
* The allowlist only matters once restricted mode is on.
* Changes apply immediately — no restart needed.
* This policy only has anything to enforce while the proxy itself is on (`p`); with the proxy off, traffic goes direct and bypasses block/allow lists entirely.

### Restricted mode

Press `R` on a codespace to flip it into restricted (default-deny) mode. Only domains on its allowlist will be reachable; everything else gets a `403` from the proxy. Press `R` again to go back to open mode (blocklist-only).

### Turning the proxy on/off

Press `p` on a codespace to turn its network proxy fully off, or back on:

```text
Network proxy for 'myproject' turned OFF.
Traffic will go direct (unlogged, unfiltered) until you turn it back on.
```

A few things worth knowing:

* This is separate from restricted mode (`R`). Restricted mode still needs the proxy running to enforce its policy — turning the proxy off with `p` bypasses logging *and* filtering entirely, regardless of `R`.
* If the codespace is currently running, toggling `p` won't rewire an already-open shell or code-server session — the script will tell you to restart it (`t`, then start it again) for the change to fully apply.
* The state is remembered per codespace (`~/.termux-codespace/meta/<name>.proxyenabled`), so it persists across restarts until you toggle it again.

### `apt` and HTTPS

Two things happen automatically so `apt` behaves consistently with everything else in a codespace:

1. **Sources are rewritten to `https://`.** The standard Ubuntu mirrors (`archive.ubuntu.com`, `security.ubuntu.com`, `ports.ubuntu.com`, and the country-code mirrors like `us.archive.ubuntu.com`) are switched from `http://` to `https://` in both the classic `sources.list` and the newer deb822 `*.sources` format. This happens once on the base image and again on every codespace clone, so it applies even if you import an older codespace.
2. **`apt` is pointed at the local proxy.** As long as the codespace's proxy is on (`p`), an `Acquire::http::Proxy` / `Acquire::https::Proxy` config is written into `/etc/apt/apt.conf.d/95codespace-proxy` so `apt update` / `apt install` traffic shows up in the network log the same way `curl` or `git` traffic does. Turning the proxy off removes this file again, and `apt` falls back to a direct HTTPS connection.

## How It Works

```text
First run:
  proot-distro install ubuntu
        │
        ▼
  Base Ubuntu rootfs, apt sources switched to https://
  ($PREFIX/var/lib/proot-distro/containers/ubuntu/rootfs)
        │
        │  cp -a
        ▼
  ~/.termux-codespace/codespaces/
    ├── project-a/
    ├── project-b/
    └── project-c/
        │
        │  proot --rootfs=<clone> ...  (http_proxy/https_proxy → 127.0.0.1:<proxy-port>, if enabled)
        ▼
  code-server on port 2000, 2001, 2002 ...
```

Each codespace is a full independent Ubuntu filesystem. Changes made in one environment do not affect the others. Each codespace's network proxy, log, domain policy, and proxy on/off state are likewise independent.

## File Structure

```text
~/.termux-codespace/
├── proxy_server.py
├── admin_panel.py
├── admin-panel.crt
├── admin-panel.key
├── codespaces/
│   ├── myproject/
│   │   ├── bin/
│   │   ├── usr/
│   │   ├── etc/
│   │   │   └── apt/
│   │   │       ├── sources.list          (rewritten to https://)
│   │   │       └── apt.conf.d/
│   │   │           └── 95codespace-proxy (present only while the proxy is on)
│   │   ├── root/
│   │   │   └── .config/code-server/config.yaml
│   │   ├── .l2s/
│   │   └── tmp/
│   └── backend-api/
└── meta/
    ├── .admin.pass
    ├── admin.enabled
    ├── admin.ip
    ├── admin.port
    ├── admin.pid
    ├── admin.log
    ├── myproject.port
    ├── myproject.pass
    ├── myproject.pid
    ├── myproject.log
    ├── myproject.launcher.sh
    ├── myproject.proxyport
    ├── myproject.proxyenabled
    ├── myproject.proxy.pid
    ├── myproject.proxy.log
    ├── myproject.netlog
    ├── myproject.netmode
    ├── myproject.blocklist
    └── myproject.allowlist
```

## Troubleshooting

### `proot error: can't chmod .../tmp/proot-...`

```bash
mkdir -p "$PREFIX/tmp"
unset LD_PRELOAD
```

### `the program is a foreign binary but qemu was not specified`

This usually means `LD_PRELOAD` is interfering with `proot`.

```bash
unset LD_PRELOAD
proot-distro login ubuntu
```

### `env: unknown error: execvp failed`

Do not use `env -i` when launching `proot`. Use the full binary path instead.

```bash
export HOME=/root
exec "$PREFIX/bin/proot" ...
```

### `code-server` will not start

Check the log:

```bash
cat ~/.termux-codespace/meta/<name>.log
```

You can also run the launcher manually:

```bash
bash ~/.termux-codespace/meta/<name>.launcher.sh
```

### Network log is empty / requests aren't showing up

* Check whether the proxy is turned on for that codespace: on the codespace info screen, `Proxy:` should say `running`, not `disabled`. If it says `disabled`, press `p` to turn it back on.
* Check `python3` is installed on the **Termux host** (not inside the codespace): `command -v python3`. Without it the proxy is skipped entirely and the codespace runs with unfiltered, unlogged networking.
* Check the proxy actually started: `cat ~/.termux-codespace/meta/<name>.proxy.log`
* Some tools ignore `http_proxy`/`https_proxy` (see [Network Logging & Filtering](#network-logging--filtering)) — those requests won't appear.

### A codespace can't reach anything after enabling restricted mode

That's expected — restricted mode is default-deny. Press `b` on that codespace and add the domains it needs (e.g. `.githubusercontent.com`, `pypi.org`, `.npmjs.org`, `archive.ubuntu.com`, `security.ubuntu.com`) to its allowlist, or press `R` again to go back to open mode.

### `apt update` fails or times out after turning the proxy on/off

If you toggled `p` while the codespace was already running, its current shell or code-server session is still using the old environment. Stop the codespace (`t`) and start it again — the launcher regenerates the `http_proxy`/`https_proxy` exports and the `apt` proxy config from the current state each time it starts.

### Reset everything

```bash
rm -rf ~/.termux-codespace
proot-distro remove ubuntu
./codespace.sh
```

## Auto-installed Dependencies

The script checks for and uses:

* `proot`
* `proot-distro`
* `bash`
* `coreutils`
* `findutils`
* `python3` (host-side — powers the network log/filter proxy and Admin Web Panel)

## License

This project is licensed under the **Apache License 2.0**. See the `LICENSE` file for details.

## Author

**Made By Aryan Giri** — [giriaryan694-a11y](https://github.com/giriaryan694-a11y)

---

<div align="center">

**Built for Termux. Powered by proot. No root required.**

</div>
