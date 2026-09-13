# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this repo is

A small collection of files that automate building a Windows 11 development VM on Proxmox VE from the host shell:

- **`win11.sh`** — the only script in the repo. Creates the VM (`qm create`/`qm set`), locates or downloads a Windows 11 ISO, builds an unattended-answer-file ISO from `autounattend.xml` (via `genisoimage`), and attaches everything to the new VM.
- **`autounattend.xml`** — Windows unattended-setup answer file. Creates a local `Admin` user, disables telemetry/consumer features/search suggestions, and uses `FirstLogonCommands` to install Chocolatey, then Git, VS Code, and Visual Studio 2022 Professional, plus OpenSSH server.
- **`README.md`** — user-facing usage docs.

There used to be a separate `install.sh` wrapper and a file named `Proxmox script.sh`; both were removed/renamed to `win11.sh` in history. Don't reintroduce references to either filename.

This script is meant to run **on the Proxmox host** (needs `qm`, `pvesm`, `genisoimage` on PATH) with `autounattend.xml` present in the same working directory. There is no test suite — it can't be meaningfully unit tested outside a real Proxmox host, so treat any change as needing careful manual/read-through review rather than `npm test`-style verification.

## Fixed 2026-09-13 — `ISO_PATH_ROOT` undefined, no error handling, CRLF line endings

Commit `457da5c` ("Refactor Proxmox script for clarity and updates") had deleted the block that dynamically resolved `ISO_PATH_ROOT` via `pvesm path "$ISO_STORAGE_ID:iso/dummy"` and the accompanying `ERR` cleanup trap, while `win11.sh` still referenced `$ISO_PATH_ROOT` in several places (ISO search, download destination, VirtIO ISO check). With the variable always empty, `download_windows_iso` would write multi-GB downloads to `/` (the host filesystem root, since this runs as root) instead of Proxmox ISO storage, and the VirtIO/local-ISO checks would never find anything real.

This has been restored (`get_iso_path`/`DUMMY_PATH`/`ISO_PATH_ROOT` resolution + `trap cleanup ERR`, matching what existed pre-`457da5c`), plus:

- Added `set -e` right after the shebang so a failed `qm create`/`qm set` actually stops the script instead of it reporting "VM created successfully!" over a half-configured VM. The restored `DUMMY_PATH=$(pvesm path ...) || true` line is deliberately guarded so a storage-resolution failure still prints the friendly error message instead of dying silently under `set -e`.
- Converted the file from CRLF to LF line endings — it had been CRLF since before the rename (the earlier "Fix line endings" commit only ever touched the old `install.sh`), which made `bash win11.sh` fail with a syntax error on the `case ... in` line. **If you see CRLF creep back in (e.g. someone edits/saves the file on Windows), reflow it (`sed -i 's/\r$//' win11.sh`) — the script does not run at all as CRLF.**

If you touch the ISO-handling or error-handling logic again, keep these in mind:
- Avoid combining `set -e` with `set -o pipefail` here without auditing every pipeline first — `download_windows_iso`'s `curl | grep | sed | tr` relies on `tr` (always exit 0) being last so a header-not-found `grep` miss doesn't kill the script; `pipefail` would break that.
- `pvesm path ...`/similar lookups that feed a "did this fail?" `if [ -z ... ]` check need `|| true` (or equivalent) so `set -e` doesn't short-circuit past the friendly error message.

## VirtIO ISO auto-download (added 2026-09-13)

`win11.sh` now searches ISO storage for any `virtio-win*.iso` (newest by `sort -V` if several) and, if none is found, downloads the current stable release automatically via `download_virtio_iso()`, from `$VIRTIO_STABLE_URL` (Fedora's `stable-virtio` redirect, which 301s to a version-specific filename — resolved with `curl -sIL -w '%{url_effective}'` so the file is saved under its real name). This source has no auth/anti-bot layer and is safe to script against.

**Windows 11 ISO auto-download was deliberately NOT added.** It was investigated live on 2026-09-13: Microsoft's current download flow (`microsoft.com/software-download-connector/api/...`) sits behind a purpose-built, multi-step bot-detection handshake (`vlscppe.microsoft.com/tags` session whitelisting, then an `ov-df.microsoft.com` timing/fingerprint challenge requiring a `w`/`rticks` exchange, before the SKU/download-link calls will succeed) — this is confirmed by Fido (`pbatard/Fido`, the tool Rufus uses), whose own source comments call it Microsoft's "protection". The download page's markup also carries explicit anti-automation/anti-anonymization language with a threat of banning entities/locations that trigger it. Reproducing that handshake would mean baking a browser-spoofing bypass of a service's stated anti-bot control into this repo, on top of being fragile (breaks whenever Microsoft tweaks the handshake). Don't add this without the user explicitly re-confirming they want that trade-off; if asked again, point at this note rather than re-researching from scratch. The interactive "paste the direct link" flow in `download_windows_iso()` remains the supported path for the Windows ISO.

## Other things to keep in mind when touching `win11.sh`

- The admin password is passed as a plaintext CLI arg (`-p`) and written in plaintext into the generated `autounattend.xml` (`PlainText>true`), so it lands in shell history, `ps` output, and on the ISO storage as an unencrypted file. Treat this as a dev/lab-only tool, not something to point at production credentials. Not fixed — flagged for awareness only.
- `autounattend.xml` sets `LogonCount>999` under `AutoLogon`, i.e. the VM auto-logs-in as `Admin` indefinitely across reboots. That's convenient for a throwaway dev VM but worth calling out if this is ever adapted for anything longer-lived.

## Conventions

- Bash, `#!/bin/bash`, matches the existing style in `win11.sh` (plain functions, `getopts` for flags, human-readable `echo` progress banners).
- Keep the flags table in `README.md` (`-i -n -m -c -p`) in sync with the `getopts` string in `win11.sh` if either changes.
- Git remote is `teamzuzu/win11-dev-proxmox-script` on GitHub, default branch `main`. Commits so far are a mix of the original author (`Nicholas Fusaro`) and this user — commit as the actual person working, never attribute commits to Claude/an AI author.
