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

Each codespace runs its own [code-server](https://github.com/coder/code-server) instance, so you get VS Code in the browser with separate ports, separate configs, and separate filesystem clones.

Think of it as **local Codespaces on your phone**.

```text
┌──────────────────────────────────────────────┐
│               Termux (Android)               │
│                                              │
│   ┌───────────┐  ┌───────────┐  ┌──────────┐ │
│   │ Ubuntu #1 │  │ Ubuntu #2 │  │ Ubuntu #3│ │
│   │ port 2000 │  │ port 2001 │  │ port 2002│ │
│   └───────────┘  └───────────┘  └──────────┘ │
│         proot          proot          proot │
└──────────────────────────────────────────────┘
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

## Features

* One-command setup
* Multiple isolated Ubuntu clones
* Automatic port selection
* Unique password per codespace
* Arrow-key menu interface
* Background execution with `nohup`
* Create, start, stop, delete, and terminate all codespaces

## Requirements

* Termux from [F-Droid](https://f-droid.org/packages/com.termux/) or GitHub Releases
* Android 7.0 or newer
* Around 2 GB free storage per codespace

> **Important:** Do not use the Play Store version of Termux. It is outdated and may not work correctly.

## Installation

```bash
apt update && apt upgrade -y
apt install proot proot-distro pigz git -y

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

| Key       | Action                      |
| --------- | --------------------------- |
| `↑` / `↓` | Navigate                    |
| `Enter`   | Select or start a codespace |
| `d`       | Delete a codespace          |
| `t`       | Stop a codespace            |
| `q`       | Go back                     |
| `i`       | Import codespace            |
| `e`       | Export codespace            |

When creating a codespace, you will be asked for:

* **Name** — use letters, numbers, hyphens, or underscores
* **Port** — leave blank for automatic assignment, or enter your own

The script generates a unique password, writes the `code-server` config, and starts the server automatically.

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
        │  proot --rootfs=<clone> ...
        ▼
  code-server on port 2000, 2001, 2002 ...
```

Each codespace is a full independent Ubuntu filesystem. Changes made in one environment do not affect the others.

## File Structure

```text
~/.termux-codespace/
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
    └── myproject.launcher.sh
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

## License

This project is licensed under the **Apache License 2.0**. See the `LICENSE` file for details.

## Author

**Aryan Giri** — [giriaryan694-a11y](https://github.com/giriaryan694-a11y)

---

<div align="center">

**Built for Termux. Powered by proot. No root required.**

</div>
