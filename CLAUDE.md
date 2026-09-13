# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this repo is

A small collection of files that automate building a Windows 11 development VM on Proxmox VE from the host shell:

- **`win11.sh`** — the only script in the repo. Creates the VM (`qm create`/`qm set`), locates or downloads a Windows 11 ISO, builds an unattended-answer-file ISO from `autounattend.xml` (via `genisoimage`), and attaches everything to the new VM.
- **`autounattend.xml`** — Windows unattended-setup answer file. Creates a local `Admin` user, disables telemetry/consumer features/search suggestions, and uses `FirstLogonCommands` to install Chocolatey, then Git, VS Code, and Visual Studio 2022 Professional, plus OpenSSH server.
- **`README.md`** — user-facing usage docs.

There used to be a separate `install.sh` wrapper and a file named `Proxmox script.sh`; both were removed/renamed to `win11.sh` in history. Don't reintroduce references to either filename.

This script is meant to run **on the Proxmox host** (needs `qm`, `pvesm`, `genisoimage` on PATH) with `autounattend.xml` present in the same working directory. There is no test suite — it can't be meaningfully unit tested outside a real Proxmox host, so treat any change as needing careful manual/read-through review rather than `npm test`-style verification.

## Known issue — `ISO_PATH_ROOT` is undefined

Commit `457da5c` ("Refactor Proxmox script for clarity and updates") deleted the block that dynamically resolved `ISO_PATH_ROOT` via `pvesm path "$ISO_STORAGE_ID:iso/dummy"` (and the accompanying cleanup trap), but `win11.sh` still references `$ISO_PATH_ROOT` in several places (ISO search, download destination, VirtIO ISO check). As it stands the variable is always empty, so:

- The `find "$ISO_PATH_ROOT" ...` ISO search effectively searches an empty/invalid path.
- `download_windows_iso` writes the downloaded ISO to `"$ISO_PATH_ROOT/$target_filename"`, i.e. `/$target_filename` — the **root of the host filesystem**, not Proxmox ISO storage. Since this script is normally run as root on the Proxmox node, that write can silently succeed and dump a multi-GB file at `/`, while the later `qm set --ide2 $ISO_STORAGE_ID:iso/$WIN_ISO` looks for it inside the storage's actual iso directory and fails (or worse, half-succeeds against unrelated storage).
- The VirtIO ISO existence check (`$ISO_PATH_ROOT/$VIRTIO_ISO`) will always fail unless something coincidentally exists at that path off `/`.

**Do not treat the script as working out of the box.** If asked to fix or extend `win11.sh`, restore path resolution (e.g. reinstate the `pvesm path` lookup that was deleted in `457da5c`) before relying on any of the ISO-handling logic. This was flagged during review on 2026-09-13 and intentionally left unfixed pending the user's direction — check history/README for whether it's since been addressed.

## Other things to keep in mind when touching `win11.sh`

- No `set -e`/`set -euo pipefail` — failed `qm set` calls after a successful `qm create` won't stop the script, so partially-configured VMs can be reported as "created successfully". Consider this when adding new steps.
- The admin password is passed as a plaintext CLI arg (`-p`) and written in plaintext into the generated `autounattend.xml` (`PlainText>true`), so it lands in shell history, `ps` output, and on the ISO storage as an unencrypted file. Treat this as a dev/lab-only tool, not something to point at production credentials.
- The cleanup `trap` that deleted the generated OEM ISO on failure was removed in the same refactor that broke `ISO_PATH_ROOT` — failed runs can now leave orphaned `win11-unattend-*.iso` files on ISO storage.
- `autounattend.xml` sets `LogonCount>999` under `AutoLogon`, i.e. the VM auto-logs-in as `Admin` indefinitely across reboots. That's convenient for a throwaway dev VM but worth calling out if this is ever adapted for anything longer-lived.

## Conventions

- Bash, `#!/bin/bash`, matches the existing style in `win11.sh` (plain functions, `getopts` for flags, human-readable `echo` progress banners).
- Keep the flags table in `README.md` (`-i -n -m -c -p`) in sync with the `getopts` string in `win11.sh` if either changes.
- Git remote is `teamzuzu/win11-dev-proxmox-script` on GitHub, default branch `main`. Commits so far are a mix of the original author (`Nicholas Fusaro`) and this user — commit as the actual person working, never attribute commits to Claude/an AI author.
