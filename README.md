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

Each codespace runs its own [code-server](https://github.com/coder/code-server) instance, so you get VS Code in the browser with separate ports, separate configs, and separate filesystem clones. Each codespace also gets its own lightweight network proxy, so you can see what it's talking to and, if you want, restrict it.

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
* you can watch, and optionally restrict, what each codespace talks to on the network

## Features

* One-command setup
* Multiple isolated Ubuntu clones
* Automatic port selection
* Unique password per codespace
* Arrow-key menu interface
* Background execution with `nohup`
* Create, start, stop, delete, and terminate all codespaces
* Per-codespace network activity log
* Per-codespace domain block/allow list
* Per-codespace "restricted" (default-deny) network mode toggle

## Requirements

* Termux from [F-Droid](https://f-droid.org/packages/com.termux/) or GitHub Releases
* Android 7.0 or newer
* Around 2 GB free storage per codespace
* `python3` on the Termux host, for the network log/filter proxy (optional — everything else still works without it, you just lose logging/filtering)

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
2. Set up the required packages
3. Install `code-server`
4. Prepare the base environment for cloning

After that, new codespaces are created much faster because they are cloned from the base Ubuntu rootfs.

## Main Menu

```text
➤ Manage Codespaces
➤ Terminate All
➤ Exit
```

## Creating and Managing Codespaces

Example codespace list:

```text
➤ myproject    [running]
  backend-api   [stopped]
  + Create New Codespace
```

### Controls

| Key       | Action                                             |
| --------- | --------------------------------------------------- |
| `↑` / `↓` | Navigate                                            |
| `Enter`   | Select or start a codespace                         |
| `c`       | Connect to codespace shell                          |
| `n`       | View live network activity log                      |
| `b`       | Manage domain block/allow lists                     |
| `R`       | Toggle restricted network mode (press again for open)|
| `d`       | Delete a codespace                                  |
| `t`       | Stop a codespace                                    |
| `q`       | Go back                                             |
| `i`       | Import codespace                                    |
| `e`       | Export codespace                                    |

When creating a codespace, you will be asked for:

* **Name** — use letters, numbers, hyphens, or underscores
* **Port** — leave blank for automatic assignment, or enter your own

The script generates a unique password, writes the `code-server` config, and starts the server automatically. It also starts that codespace's network proxy, so logging is active as soon as the codespace is up.

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

This provides a lightweight workflow for package management, Git operations, compiling code, and other terminal-based tasks without requiring a browser or large display. CLI sessions go through the same network proxy as code-server, so anything you `curl`, `git clone`, or `pip install` here shows up in the network log too.

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

Every codespace has its own forward proxy that starts and stops alongside it. The launcher points the container's `http_proxy` / `https_proxy` at it, so both code-server and `c` shell sessions route through it automatically — nothing to configure per-tool.

```text
┌──────────────┐   http_proxy   ┌─────────────────┐        ┌────────────┐
│  codespace    │──────────────▶│  per-codespace    │───────▶│  internet  │
│  (proot)      │                │  proxy (Termux,   │        │            │
│               │◀──────────────│  no root)         │◀───────│            │
└──────────────┘                └─────────────────┘        └────────────┘
                                        │
                                        ▼
                              ~/.termux-codespace/meta/
                                <name>.netlog
```

**What it can do:**

* Log every request: timestamp, allow/deny verdict, method, host, port
* Block or unblock individual domains (`b` menu)
* Flip a codespace into "restricted" mode (`R`) — default-deny, only domains you've explicitly allowed can be reached; press `R` again to go back to open

**What it can't do (by design):**

* It's a domain-level filter, not deep packet inspection. HTTPS is tunnelled via `CONNECT` and never decrypted, so only the hostname is ever visible — not the path, headers, or body.
* It only sees traffic that respects the `http_proxy` / `https_proxy` environment variables. A process using raw sockets, a custom DNS resolver, or hardcoded IPs can bypass it.
* It runs as a normal, unprivileged process on the Termux host — no `iptables`, no root, no network namespace tricks. That's intentional (keeps the whole setup rootless), but it's a cooperative proxy, not a transparent firewall.

### Viewing the log

Select a codespace and press `n`:

```text
Network log: myproject
  Proxy:  running on 127.0.0.1:8000
  Mode:   open

[2026-08-12 10:14:02] ALLOW CONNECT   github.com:443
[2026-08-12 10:14:03] ALLOW GET      raw.githubusercontent.com:443
[2026-08-12 10:14:11] DENY  CONNECT   ads.example.com:443
```

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

### Restricted mode

Press `R` on a codespace to flip it into restricted (default-deny) mode. Only domains on its allowlist will be reachable; everything else gets a `403` from the proxy. Press `R` again to go back to open mode (blocklist-only).

## How It Works

```text
First run:
  proot-distro install ubuntu
        │
        ▼
  Base Ubuntu rootfs
  ($PREFIX/var/lib/proot-distro/containers/ubuntu/rootfs)
        │
        │  cp -a
        ▼
  ~/.termux-codespace/codespaces/
    ├── project-a/
    ├── project-b/
    └── project-c/
        │
        │  proot --rootfs=<clone> ...  (http_proxy → 127.0.0.1:<proxy-port>)
        ▼
  code-server on port 2000, 2001, 2002 ...
```

Each codespace is a full independent Ubuntu filesystem. Changes made in one environment do not affect the others. Each codespace's network proxy, log, and domain policy are likewise independent.

## File Structure

```text
~/.termux-codespace/
├── proxy_server.py
├── codespaces/
│   ├── myproject/
│   │   ├── bin/
│   │   ├── usr/
│   │   ├── root/
│   │   │   └── .config/code-server/config.yaml
│   │   ├── .l2s/
│   │   └── tmp/
│   └── backend-api/
└── meta/
    ├── myproject.port
    ├── myproject.pass
    ├── myproject.pid
    ├── myproject.log
    ├── myproject.launcher.sh
    ├── myproject.proxyport
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

* Check `python3` is installed on the **Termux host** (not inside the codespace): `command -v python3`. Without it the proxy is skipped entirely and the codespace runs with unfiltered, unlogged networking.
* Check the proxy actually started: `cat ~/.termux-codespace/meta/<name>.proxy.log`
* Some tools ignore `http_proxy`/`https_proxy` (see [Network Logging & Filtering](#network-logging--filtering)) — those requests won't appear.

### A codespace can't reach anything after enabling restricted mode

That's expected — restricted mode is default-deny. Press `b` on that codespace and add the domains it needs (e.g. `.githubusercontent.com`, `pypi.org`, `.npmjs.org`) to its allowlist, or press `R` again to go back to open mode.

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
* `python3` (host-side, optional — powers the network log/filter proxy)

## License

This project is licensed under the **Apache License 2.0**. See the `LICENSE` file for details.

## Author

**Aryan Giri** — [giriaryan694-a11y](https://github.com/giriaryan694-a11y)

---

<div align="center">

**Built for Termux. Powered by proot. No root required.**

</div>
