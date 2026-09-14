# Proxmox Windows 11 IDE Automation

![Proxmox + Windows 11 Automated Script](w11prox.png)

This project automates the creation of a fully configured Windows 11 Development VM on Proxmox. It handles VM creation, unattended Windows installation, debloating, and the installation of essential development tools (VS2022, Git, CMake, Python, OpenSSH, RDP).

## ✨ Features

- **Fully Automated VM Creation**: One-command deployment from Proxmox shell — the script starts the VM itself and clears Windows Setup's "Press any key to boot..." prompt for you (see Troubleshooting)
- **Unattended Windows 11 Installation**: No manual intervention required
- **VirtIO Drivers**: Automatically loads storage and network drivers during setup
- **QEMU Guest Agent**: Installed from the VirtIO ISO at first logon, so Proxmox's guest-agent features (IP reporting, graceful shutdown, etc.) work out of the box
- **Debloated Windows**: Telemetry, bloatware, search suggestions, Widgets, Start suggestion ads, Game Bar/GameDVR, and "new Outlook for Windows" all disabled/removed
- **Pre-installed Development Environment**:
  - Visual Studio 2022 Professional with the Desktop development with C++ workload
  - Git, CMake, Python (+ `capstone`)
- **Remote Access Enabled**: OpenSSH and Remote Desktop both pre-configured and open (firewall is disabled — dev/lab use, see the security note below)
- **Resource Optimized**: 8GB RAM and 4 CPU cores by default (customizable), with the pagefile disabled entirely — see below
- **No Pagefile**: Virtual memory/pagefile disabled at first logon, trading crash-dump capability for disk space on a VM that already gets RAM sized deliberately

## 🚀 Quick Start

`win11.sh` needs `autounattend.xml` and `download-isos.sh` next to it (it looks for both in its current directory), so clone the repo on your Proxmox host rather than piping a single file into bash:

```bash
git clone https://github.com/teamzuzu/win11-dev-proxmox-script.git
cd win11-dev-proxmox-script
./win11.sh -i 3000 -n "Dev-VM" -p "SecurePass123"
```

## ⚙️ Configuration

### Command Line Arguments
`win11.sh` accepts the following flags to customize the deployment without editing files:

| Flag | Description | Default |
|------|-------------|---------|
| `-i` | **VM ID**: The unique ID for the new VM. | `1111` |
| `-n` | **VM Name**: The name label for the VM. | `win11-dev` |
| `-m` | **Memory (MB)**: RAM allocated to the VM. | `8192` (8GB) |
| `-c` | **Cores**: Number of CPU cores allocated. | `4` |
| `-p` | **Password**: Local `Admin` user password. | `Password123!` |

**Example:**
```bash
./win11.sh -i 4000 -n "Build-Server" -m 32768 -c 8 -p "MySecretPassword!"
```

> ⚠️ The password is passed as a plain command-line argument, which means it can be visible in your shell history and to other users on the host via `ps`. Prefer a throwaway/non-sensitive password for a dev VM, and change it after first login if it matters.

### Script Variables (Advanced)
Open `win11.sh` to edit these variables if your Proxmox environment differs from the defaults:

*   **`DISK_STORAGE`**: Storage ID for the VM disk (Default: `local-lvm`).
*   **`ISO_STORAGE_ID`**: Storage ID for ISOs (Default: `local`).
*   **`DISK_SIZE`**: Size of the main OS disk in GiB, no unit suffix (Default: `128`).

`VIRTIO_STABLE_URL` (the VirtIO auto-download source) lives in `download-isos.sh`, not `win11.sh` — see below.

Neither `VIRTIO_ISO` nor the Windows ISO filename is a fixed setting you need to maintain — the script searches your ISO storage for any matching file and downloads one automatically if none is found (see below).

### Unattended Installation (`autounattend.xml`)
The answer file handles the Windows setup. Key configurations include:

*   **User**: Creates a local user named `Admin`.
*   **Language/Region**: Defaults to `en-GB` (English - United Kingdom), set in two places — `Microsoft-Windows-International-Core-WinPE` (Setup's own UI) and `Microsoft-Windows-International-Core` (the installed OS's region/keyboard, which is what actually suppresses OOBE's language-selection prompt on first boot). To use a different locale, change all `en-GB` occurrences in both components to your BCP-47 tag (e.g. `en-US`, `en-AU`).
*   **Debloat**: Automatically disables Telemetry, "Consumer Features" (Candy Crush, etc.), Search Suggestions, Widgets, Start Menu/Settings suggestion ads, and Xbox Game Bar/GameDVR (the last one avoids the overlay hooking into D3D11 apps, relevant if you're building a game). Also deprovisions "new Outlook for Windows" at first logon — Windows 11 otherwise installs it via a Store-driven task during OOBE itself, which is the likely cause if you've seen an unexpected region/market prompt during setup.
*   **QEMU Guest Agent**: Installed silently from the VirtIO ISO's `guest-agent\qemu-ga-x64.msi` (the script searches all CD-ROM drive letters for it, since the VirtIO ISO's letter shifts depending on how many optical devices are attached — same reasoning as the storage-driver paths above).
*   **Network**: Forces the network connection to the `Private` category (Windows' own `NetworkLocation` OOBE setting isn't always honored) and **disables Windows Firewall entirely, on all profiles**. This is a dev/lab-only default — see the security note below.
*   **Remote Access**: Enables Remote Desktop (the `Admin` user can connect immediately, since it's a member of `Administrators`) and OpenSSH Server, both with their own firewall-allow rules kept as a fallback even though the firewall is off.
*   **Software**: Automatically installs the following via Chocolatey:
    *   Git
    *   CMake, Python (with the `capstone` pip package)
    *   Visual Studio 2022 Professional with the **Desktop development with C++** workload (native/MSVC, not .NET) — swap `visualstudio2022-workload-nativedesktop` in `autounattend.xml` for a different [VS2022 workload ID](https://learn.microsoft.com/en-us/visualstudio/install/workload-component-id-vs-professional) if your project needs something else instead.
*   **Pagefile**: Disabled entirely at first logon (`AutomaticManagedPagefile` turned off, then any existing pagefile setting removed) — trades away Windows' ability to write a crash dump on a BSOD, in exchange for not burning disk space on virtual memory for what's meant to be a disposable dev VM.

> ⚠️ **Security note:** this VM ships with the firewall fully disabled, RDP and SSH both open, and (by default) a well-known password. That's a reasonable default for an isolated home-lab network, but treat it accordingly — don't expose this VM directly to the internet, and change the password (`-p`) if the VM will be reachable by anyone else.

## 📋 Prerequisites

### 1. Proxmox VE
Tested on Proxmox VE 8.x. Should work on 7.x as well.

### 0. Running as a non-root user
`win11.sh` runs `qm`, `pvesm`, `genisoimage`, and all ISO-storage file operations through `sudo`, so it no longer needs to be run as `root` directly — any user with `sudo` rights can run it. The script checks `sudo -v` up front and exits with a clear error if that fails. Since parts of the ISO-handling flow are unattended (auto-downloading the VirtIO ISO, generating the answer-file ISO), it's worth giving this user passwordless `sudo` for a smooth run rather than being prompted for a password partway through:

```bash
echo "youruser ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/win11-dev-script
```

(Scope this to just the commands the script needs — `qm`, `pvesm`, `genisoimage`, `wget`/`curl`, etc. — if you'd rather not grant blanket `NOPASSWD` access.)

### 2. Required ISOs
You must upload these ISOs to your Proxmox ISO storage (`ISO_STORAGE_ID`, default `local`) before running the script:

**Windows 11 ISO:**
- **Auto-Download:** The script will ask for a download link if no `Win11*.iso` file is found on the storage.
- **Get Link:** Go to [Microsoft](https://www.microsoft.com/software-download/windows11), select "Windows 11 (multi-edition ISO)", choose language, and copy the "64-bit Download" link.
- **Manual Upload:** Alternatively, download it yourself and upload to Proxmox under `ISO_STORAGE_ID`. Any filename starting with `Win11` is picked up automatically.

**VirtIO Drivers ISO:**
- **Auto-Download:** If no `virtio-win*.iso` file is found on the storage, the script downloads the current stable release automatically from the [Fedora Project's stable-virtio redirect](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso) — no manual step needed.
- **Manual Upload:** You can still upload your own version ahead of time; any filename starting with `virtio-win` (case-insensitive) is picked up, and if more than one is present the newest version (by filename) is used.

Both ISOs' search/download logic lives in **`download-isos.sh`**, which `win11.sh` sources automatically. It can also be run on its own (`./download-isos.sh`) to pre-fetch both ISOs without creating a VM.

### 3. Tools
The script requires `genisoimage` to generate the answer file ISO:
```bash
apt install genisoimage
```

## 🎯 Post-Installation

After the VM finishes installing (approximately 30-60 minutes depending on your hardware):

### Default Credentials
- **Username:** `Admin`
- **Password:** As configured via `-p` flag or default `Password123!`

### Access Methods
- **Console:** Via Proxmox web interface
- **RDP:** Port 3389 (use Remote Desktop)
  ```bash
  mstsc /v:<VM-IP>
  ```
- **SSH:** Port 22
  ```bash
  ssh Admin@<VM-IP>
  ```

### Verify Installation
1. Check that Visual Studio 2022 and Git are installed
2. Verify OpenSSH is running:
   ```powershell
   Get-Service sshd
   ```
3. Confirm debloat settings via Registry Editor

## ⚠️ Troubleshooting

### "File not found" errors
Make sure the ISOs are present on the storage identified by `ISO_STORAGE_ID` (check with `pvesm status`), and that `autounattend.xml` and `download-isos.sh` both sit in the same directory as `win11.sh` before you run it.

### Installation appears stalled
The VS2022 installation is large (~10GB download). If the VM seems idle after first login:
- Open Task Manager and check for `choco.exe` or `vs_installer.exe` processes
- Allow 20-30 minutes for Visual Studio to complete
- Check `C:\ProgramData\chocolatey\logs` for installation logs (it's a hidden folder - `dir C:\ /a` if it's not showing up)

### Chocolatey installed but Git/VS2022 didn't
This is a first-logon session/`PATH` timing issue, not a broken package: Chocolatey adds itself to the system `PATH` when it installs, but the `FirstLogonCommands` batch that installs it doesn't pick that change up for the *rest of that same batch* - so a bare `choco install ...` right after can silently fail to find `choco` at all, with nothing written to `chocolatey.log`. Already fixed here by calling Chocolatey via its full path (`C:\ProgramData\chocolatey\bin\choco.exe`) rather than bare `choco` - if you're hitting this on an older-generated answer-file ISO, rebuild it (rerun `win11.sh`).

### `git` (or another choco-installed tool) "not recognized" right after first login
Same root cause as above, one layer further out: Git's installer *does* correctly add itself to the system `PATH`, but a shell/console session that was already open before that happened doesn't see the update - it only reads `PATH` once, at logon. If you're testing from the very first interactive session (the one all the `FirstLogonCommands` ran in), any shell you open there can still show `git` as unrecognized even though it's genuinely installed. Log `Admin` off and back on (or restart the VM once) - a fresh logon re-reads `PATH` from scratch and `git` resolves normally from then on. No answer-file change fixes this, since it's the *session*, not the install, that's stale.

### Network issues
- The VM requires internet access on `vmbr0` during first login to download packages
- Ensure your Proxmox bridge has DHCP or configure static IP in `autounattend.xml`

### Can't reach SSH/RDP
- `FirstLogonCommands` forces the network to `Private` and disables the firewall entirely, so this shouldn't require any manual network-profile change - if you generated the VM's answer-file ISO before this was added, rebuild it (rerun `win11.sh`) rather than reusing an old one.
- These commands run once, at the `Admin` user's first interactive logon - if you're checking immediately after `qm start`, give it a minute to reach that point after the OOBE/AutoLogon screens.

### VirtIO drivers not loading
- Verify the VirtIO ISO is correctly attached to the VM
- The answer file checks drive letters `D:` through `H:` automatically (WinPE's CD-ROM drive letter assignment shifts depending on how many optical devices are attached)
- If needed, manually browse to the VirtIO ISO's `vioscsi\w11\amd64` folder during Windows setup — not `viostor`, since the disk is attached via a VirtIO-SCSI controller

### VM seems stuck at a black/blank console screen right after start
`win11.sh` now starts the VM itself and sends Enter to the console repeatedly for ~15 seconds, to clear Windows Setup's "Press any key to boot from CD or DVD..." UEFI prompt (it only waits a few seconds for a keypress, then falls through to the next boot device — without this it can look like an indefinite hang to whoever isn't watching the console at exactly that moment). If you open the console and it's already past that prompt, this already worked — no action needed. If it's still sitting at that exact prompt after ~15 seconds, press a key manually once and check `qm status <vmid>`/the console for what's actually happening; that's no longer expected behavior. (If this keeps happening on slower hardware, the wait may need lengthening again — see `CLAUDE.md`.)

### Unexpected region/country prompt during setup
Windows 11 installs "new Outlook for Windows" via a Store-driven task that runs during OOBE itself, and that Store interaction can surface a region/market prompt that has nothing to do with the language/locale settings elsewhere in `autounattend.xml`. **This is currently a known, unresolved cosmetic issue** — two different attempts at suppressing it before OOBE runs both crashed Windows Setup instead (see `CLAUDE.md`), so for now nothing runs pre-OOBE to prevent it. The app is still deprovisioned at first logon, which stops it being reinstalled later, but doesn't stop this first prompt. Just click through it — it doesn't indicate anything is actually broken.

### "The computer restarted unexpectedly" during Windows Setup
This is Windows Setup's generic fatal-error message for a `RunSynchronousCommand` returning a nonzero exit code in the `windowsPE`/`specialize` passes — it means something in `autounattend.xml` itself failed, not a hardware/VM problem. Two separate commands have triggered this here in the past (a DISM/Appx-based "new Outlook" removal, then a registry-only variant of the same idea) — both have since been removed from the `specialize` pass entirely, see `CLAUDE.md`. If you're seeing this on a build from before 2026-09-14, rebuild the OEM ISO (rerun `win11.sh`). If it recurs even after rebuilding, the specific broken command won't be obvious from this message alone; the next diagnostic step is pressing Shift+F10 at the failure screen for a command prompt and checking `X:\Windows\Panther\setupact.log`/`setuperr.log`.

## 📝 License

This project is open source and available under the MIT License.

## 🤝 Contributing

Contributions, issues, and feature requests are welcome! Feel free to check the issues page or submit a pull request.
