# Proxmox Windows 11 IDE Automation

This project automates the creation of a fully configured Windows 11 Development VM on Proxmox. It handles VM creation, unattended Windows installation, debloating, and the installation of essential development tools (VS2022, VS Code, Git, OpenSSH).

## ✨ Features

- **Fully Automated VM Creation**: One-command deployment from Proxmox shell
- **Unattended Windows 11 Installation**: No manual intervention required
- **VirtIO Drivers**: Automatically loads storage and network drivers during setup
- **Debloated Windows**: Telemetry, bloatware, and search suggestions disabled
- **Pre-installed Development Environment**:
  - Visual Studio 2022 Professional with .NET Desktop workload
  - Visual Studio Code
  - Git
- **SSH Access Enabled**: OpenSSH server pre-configured and ready
- **Resource Optimized**: 16GB RAM and 6 CPU cores by default (customizable)

## 🚀 Quick Start

`win11.sh` needs `autounattend.xml` next to it (it looks for the answer file in its current directory), so clone the repo on your Proxmox host rather than piping a single file into bash:

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
| `-i` | **VM ID**: The unique ID for the new VM. | `1022` |
| `-n` | **VM Name**: The name label for the VM. | `win11-ide` |
| `-m` | **Memory (MB)**: RAM allocated to the VM. | `16384` (16GB) |
| `-c` | **Cores**: Number of CPU cores allocated. | `6` |
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
*   **`VIRTIO_ISO`**: Filename of your VirtIO drivers ISO (Default: `virtio-win-0.1.240.iso`).
*   **`DISK_SIZE`**: Size of the main OS disk (Default: `130G`).

The Windows ISO is **not** a fixed variable — the script searches your ISO storage for any file matching `Win11*.iso` and offers to use it, or offers to download one interactively if none is found.

### Unattended Installation (`autounattend.xml`)
The answer file handles the Windows setup. Key configurations include:

*   **User**: Creates a local user named `Admin`.
*   **Debloat**: Automatically disables Telemetry, "Consumer Features" (Candy Crush, etc.), and Search Suggestions.
*   **Software**: Automatically installs the following via Chocolatey:
    *   Git
    *   Visual Studio Code
    *   Visual Studio 2022 Professional (NetDesktop Workload)
    *   OpenSSH Server (Enabled & Firewall Rule Added)

## 📋 Prerequisites

### 1. Proxmox VE
Tested on Proxmox VE 8.x. Should work on 7.x as well.

### 2. Required ISOs
You must upload these ISOs to your Proxmox ISO storage (`ISO_STORAGE_ID`, default `local`) before running the script:

**Windows 11 ISO:**
- **Auto-Download:** The script will ask for a download link if no `Win11*.iso` file is found on the storage.
- **Get Link:** Go to [Microsoft](https://www.microsoft.com/software-download/windows11), select "Windows 11 (multi-edition ISO)", choose language, and copy the "64-bit Download" link.
- **Manual Upload:** Alternatively, download it yourself and upload to Proxmox under `ISO_STORAGE_ID`. Any filename starting with `Win11` is picked up automatically.

**VirtIO Drivers ISO:**
- Download from [Fedora Project](https://github.com/virtio-win/virtio-win-pkg-scripts/blob/master/README.md)
- Latest stable release: [virtio-win-0.1.240.iso](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso)
- Filename must match the `VIRTIO_ISO` variable in the script: `virtio-win-0.1.240.iso`

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
1. Check that Visual Studio 2022, VS Code, and Git are installed
2. Verify OpenSSH is running:
   ```powershell
   Get-Service sshd
   ```
3. Confirm debloat settings via Registry Editor

## ⚠️ Troubleshooting

### "File not found" errors
Make sure the ISOs are present on the storage identified by `ISO_STORAGE_ID` (check with `pvesm status`), and that `autounattend.xml` sits in the same directory as `win11.sh` before you run it.

### Installation appears stalled
The VS2022 installation is large (~10GB download). If the VM seems idle after first login:
- Open Task Manager and check for `choco.exe` or `vs_installer.exe` processes
- Allow 20-30 minutes for Visual Studio to complete
- Check `C:\ProgramData\chocolatey\logs` for installation logs

### Network issues
- The VM requires internet access on `vmbr0` during first login to download packages
- Ensure your Proxmox bridge has DHCP or configure static IP in `autounattend.xml`

### VirtIO drivers not loading
- Verify the VirtIO ISO is correctly attached to the VM
- The answer file checks both `E:\` and `F:\` drive letters automatically
- If needed, manually browse to the VirtIO ISO during Windows setup

## 📝 License

This project is open source and available under the MIT License.

## 🤝 Contributing

Contributions, issues, and feature requests are welcome! Feel free to check the issues page or submit a pull request.
