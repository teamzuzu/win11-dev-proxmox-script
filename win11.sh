#!/bin/bash
set -e

# --- Colors ---
# Disabled automatically when stdout isn't a terminal 
if [ -t 1 ]; then
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_CYAN='\033[0;36m'
    C_BOLD='\033[1m'
    C_RESET='\033[0m'
else
    C_RED='' C_GREEN='' C_YELLOW='' C_CYAN='' C_BOLD='' C_RESET=''
fi

info()    { printf '%b%s%b\n' "$C_CYAN" "$*" "$C_RESET"; }
success() { printf '%b%s%b\n' "$C_GREEN" "$*" "$C_RESET"; }
warn()    { printf '%b%s%b\n' "$C_YELLOW" "$*" "$C_RESET"; }
error()   { printf '%b%s%b\n' "$C_RED" "$*" "$C_RESET" >&2; }
banner()  { printf '%b%s%b\n' "$C_BOLD$C_CYAN" "$*" "$C_RESET"; }

# --- sudo preflight ---
if ! command -v sudo &> /dev/null; then
    error "Error: sudo is required (this script runs privileged commands via sudo) but isn't installed."
    exit 1
fi
if ! sudo -v; then
    error "Error: sudo authentication failed. This user needs sudo access to run win11.sh."
    exit 1
fi

# --- Default Configuration ---
VMID="1022"
VM_NAME="win11"
VM_MEMORY="16384"       # 16GB 
VM_CORES="6"            
ADMIN_PASSWORD="Password123!" # Default Password (Change this!)

while getopts "i:n:m:c:p:h" opt; do
  case $opt in
    i) VMID="$OPTARG" ;;
    n) VM_NAME="$OPTARG" ;;
    m) VM_MEMORY="$OPTARG" ;;
    c) VM_CORES="$OPTARG" ;;
    p) ADMIN_PASSWORD="$OPTARG" ;;
    h) echo "Usage: $0 [-i VMID] [-n NAME] [-m MEMORY] [-c CORES] [-p PASSWORD]" ; exit 0 ;;
    *) error "Invalid option: -$OPTARG" ; exit 1 ;;
  esac
done

DISK_STORAGE="local-lvm"      # Where the VM disk goes
ISO_STORAGE_ID="local"        # Storage ID for ISOs

VIRTIO_ISO="virtio-win-0.1.240.iso" # Overwritten by search/download below
VIRTIO_STABLE_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
OEM_ISO="win11-unattend-${VMID}.iso" # Generated ISO name
ANSWER_FILE="autounattend.xml"

DISK_SIZE="128" # GiB, no unit suffix required

# --- Filename Validation ---
# Rejects filenames that would break qm's volid syntax (see CLAUDE.md).
validate_iso_filename() {
    local label="$1" filename="$2"
    if [[ "$filename" != *.iso ]]; then
        error "Error: $label filename '$filename' does not end in .iso - refusing to use it."
        return 1
    fi
    if [[ "$filename" == *[,\;=\"\']* ]]; then
        error "Error: $label filename '$filename' contains characters (, ; = \" ') that break Proxmox's volume syntax."
        error "This usually means a broken download saved raw header text into the filename - rename the file (keeping only the part up to and including .iso) and try again."
        return 1
    fi
}

# --- Dynamic Path Resolution ---
get_iso_path() {
    local filename="$1"
    sudo pvesm path "$ISO_STORAGE_ID:iso/$filename" 2>/dev/null
}

# Probe filename must end in .iso - Proxmox's volid parser requires an
# extension (see CLAUDE.md). "|| true" stops set -e swallowing the error below.
DUMMY_PATH=$(sudo pvesm path "$ISO_STORAGE_ID:iso/dummy.iso" 2>/dev/null) || true
if [ -z "$DUMMY_PATH" ]; then
    error "Error: Could not resolve path for storage '$ISO_STORAGE_ID'."
    error "Please check if the Storage ID exists and is active in Proxmox."
    exit 1
fi
ISO_PATH_ROOT=$(dirname "$DUMMY_PATH")

# --- Cleanup Trap --- (see CLAUDE.md)
VM_CREATED=0
cleanup() {
    if sudo test -f "$ISO_PATH_ROOT/$OEM_ISO"; then
        warn "Cleaning up generated ISO..."
        sudo rm -f "$ISO_PATH_ROOT/$OEM_ISO"
    fi
    if [ "$VM_CREATED" = "1" ]; then
        warn "Cleaning up partially created VM $VMID..."
        sudo qm destroy "$VMID" --purge 1 2>/dev/null || true
    fi
}
trap cleanup ERR

# --- Download Windows ISO ---
download_windows_iso() {
    banner "================================================"
    banner "Windows 11 ISO Setup"
    banner "================================================"
    echo "To download the latest Windows 11 ISO:"
    echo "1. Go to: https://www.microsoft.com/software-download/windows11"
    echo "2. Scroll to 'Download Windows 11 Disk Image (ISO) for x64 devices'"
    echo "3. Select 'Windows 11 (multi-edition ISO)' and click Download"
    echo "4. Select your language and click Confirm"
    echo "5. Right-click the '64-bit Download' button and Copy Link Address"
    echo ""
    read -p "Paste the download link here: " DOWNLOAD_URL
    echo ""

    if [ -z "$DOWNLOAD_URL" ]; then
        error "Error: No URL provided."
        return 1
    fi

    info "Analyzing link..."

    # Fallback filename if header parsing below fails
    local target_filename="Win11_English_x64.iso"

    # Handles an unquoted filename= plus a trailing filename*= param (see CLAUDE.md)
    if command -v curl &> /dev/null; then
        local header_name=$(sudo curl -sI "$DOWNLOAD_URL" | sudo grep -i "content-disposition" | sudo sed -n 's/.*[Ff]ilename="\?\([^";]*\)"\?.*/\1/p' | sudo tr -d '\r')
        if [ -n "$header_name" ]; then
            target_filename="$header_name"
        fi
    fi

    echo "Target filename: $target_filename"
    info "Downloading to: $ISO_PATH_ROOT/$target_filename"

    if command -v wget &> /dev/null; then
        sudo wget --progress=bar:force --show-progress -O "$ISO_PATH_ROOT/$target_filename" \
            "$DOWNLOAD_URL" || {
            error "Error: Download failed."
            return 1
        }
    elif command -v curl &> /dev/null; then
        sudo curl -L --progress-bar -o "$ISO_PATH_ROOT/$target_filename" \
            "$DOWNLOAD_URL" || {
            error "Error: Download failed."
            return 1
        }
    else
        error "Error: Neither wget nor curl found."
        return 1
    fi

    if sudo test -f "$ISO_PATH_ROOT/$target_filename"; then
        FILE_SIZE=$(sudo stat -c%s "$ISO_PATH_ROOT/$target_filename" 2>/dev/null || sudo stat -f%z "$ISO_PATH_ROOT/$target_filename" 2>/dev/null)
        if [ "$FILE_SIZE" -lt 4000000000 ]; then
            warn "Warning: Downloaded file seems small ($FILE_SIZE bytes)"
            read -p "Continue anyway? (y/n): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                return 1
            fi
        fi
        success "Download successful!"
        WIN_ISO="$target_filename"
        return 0
    else
        return 1
    fi
}

# --- Download VirtIO ISO ---
download_virtio_iso() {
    info "No local VirtIO ISO found. Downloading latest stable release..."
    echo "Source: $VIRTIO_STABLE_URL"

    if ! command -v curl &> /dev/null; then
        error "Error: curl is required to resolve the VirtIO download filename."
        return 1
    fi

    # Resolve the redirect to get the real versioned filename
    local resolved_url
    resolved_url=$(sudo curl -sIL -o /dev/null -w '%{url_effective}' "$VIRTIO_STABLE_URL")
    local target_filename
    target_filename=$(sudo basename "$resolved_url" 2>/dev/null)
    if [ -z "$target_filename" ] || [[ "$target_filename" != *.iso ]]; then
        error "Error: Could not resolve a versioned filename for the VirtIO ISO."
        return 1
    fi

    echo "Latest stable version: $target_filename"
    info "Downloading to: $ISO_PATH_ROOT/$target_filename"

    if command -v wget &> /dev/null; then
        sudo wget --progress=bar:force --show-progress -O "$ISO_PATH_ROOT/$target_filename" \
            "$VIRTIO_STABLE_URL" || {
            error "Error: VirtIO download failed."
            return 1
        }
    else
        sudo curl -L --progress-bar -o "$ISO_PATH_ROOT/$target_filename" \
            "$VIRTIO_STABLE_URL" || {
            error "Error: VirtIO download failed."
            return 1
        }
    fi

    if ! sudo test -f "$ISO_PATH_ROOT/$target_filename"; then
        error "Error: VirtIO ISO not found after download."
        return 1
    fi

    success "Download successful!"
    VIRTIO_ISO="$target_filename"
    return 0
}

# --- Checks ---

if sudo qm status "$VMID" &>/dev/null; then
    error "Error: VM ID $VMID already exists"
    exit 1
fi

if ! sudo pvesm status | sudo grep -q "^$DISK_STORAGE"; then
    error "Error: Disk Storage '$DISK_STORAGE' not found"
    exit 1
fi

if ! sudo pvesm status | sudo grep -q "^$ISO_STORAGE_ID"; then
    error "Error: ISO Storage '$ISO_STORAGE_ID' not found"
    exit 1
fi

info "Searching for Windows 11 ISO in $ISO_PATH_ROOT..."
FOUND_ISO=$(sudo find "$ISO_PATH_ROOT" -maxdepth 1 -name "Win11*.iso" -type f | sudo head -n 1)

if [ -n "$FOUND_ISO" ]; then
    WIN_ISO=$(sudo basename "$FOUND_ISO")
    success "Found local ISO: $WIN_ISO"
    echo ""
    read -p "Use this ISO? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        if ! download_windows_iso; then
            error "Setup cancelled."
            exit 1
        fi
    fi
else
    warn "No Windows 11 ISO found locally."
    if ! download_windows_iso; then
        error "Please download the ISO manually and place it in $ISO_PATH_ROOT"
        exit 1
    fi
fi

if ! validate_iso_filename "Windows 11 ISO" "$WIN_ISO"; then
    exit 1
fi

# Pick the newest by version if more than one is present
info "Searching for VirtIO ISO in $ISO_PATH_ROOT..."
FOUND_VIRTIO=$(sudo find "$ISO_PATH_ROOT" -maxdepth 1 -iname "virtio-win*.iso" -type f | sudo sort -V | sudo tail -n 1)

if [ -n "$FOUND_VIRTIO" ]; then
    VIRTIO_ISO=$(sudo basename "$FOUND_VIRTIO")
    success "Found local VirtIO ISO: $VIRTIO_ISO"
else
    if ! download_virtio_iso; then
        error "Error: VirtIO ISO not found and automatic download failed."
        error "Download manually from: https://github.com/virtio-win/virtio-win-pkg-scripts/blob/master/README.md"
        exit 1
    fi
fi

if ! validate_iso_filename "VirtIO ISO" "$VIRTIO_ISO"; then
    exit 1
fi

if [ ! -f "$ANSWER_FILE" ]; then
    error "Error: '$ANSWER_FILE' not found in current directory."
    error "Please upload it to the same folder as this script."
    exit 1
fi

if ! command -v genisoimage &> /dev/null; then
    error "Error: 'genisoimage' is not installed. Install it with: apt install genisoimage"
    exit 1
fi

# --- ISO Generation ---

info "Generating Unattended ISO from $ANSWER_FILE..."
TMP_ISO_DIR=$(sudo mktemp -d)
sudo cp "$ANSWER_FILE" "$TMP_ISO_DIR/"

# Delimiter other than / in case the password contains one
sudo sed -i "s|PASSWORD_PLACEHOLDER|$ADMIN_PASSWORD|g" "$TMP_ISO_DIR/$ANSWER_FILE"

sudo genisoimage -o "$ISO_PATH_ROOT/$OEM_ISO" -J -R -V "OEMDRV" "$TMP_ISO_DIR"
sudo rm -rf "$TMP_ISO_DIR"

# --- VM Creation ---

info "Creating VM $VMID ($VM_NAME)..."

# 1. Create the base VM
sudo qm create "$VMID" \
  --name "$VM_NAME" \
  --memory "$VM_MEMORY" \
  --cores "$VM_CORES" \
  --sockets "1" \
  --net0 virtio,bridge=vmbr0 \
  --ostype "win11" \
  --scsihw virtio-scsi-pci \
  --cpu host \
  --machine q35 \
  --bios ovmf
VM_CREATED=1

# 2. Allocate the main disk
info "Allocating Main Disk..."
sudo qm set "$VMID" --scsi0 "$DISK_STORAGE:$DISK_SIZE,ssd=1,discard=on"

# 3. EFI disk + TPM (required for Win11)
info "Configuring TPM and UEFI..."
sudo qm set "$VMID" --efidisk0 "$DISK_STORAGE:0,efitype=4m,pre-enrolled-keys=1"
sudo qm set "$VMID" --tpmstate0 "$DISK_STORAGE:0,version=v2.0"

# 4. Attach ISOs (quoted - WIN_ISO/VIRTIO_ISO filenames may contain spaces, see CLAUDE.md)
info "Attaching ISOs..."
sudo qm set "$VMID" --ide2 "$ISO_STORAGE_ID:iso/$WIN_ISO,media=cdrom"
sudo qm set "$VMID" --ide3 "$ISO_STORAGE_ID:iso/$VIRTIO_ISO,media=cdrom"
sudo qm set "$VMID" --sata0 "$ISO_STORAGE_ID:iso/$OEM_ISO,media=cdrom"

# 5. Set Boot Order and Other Settings
info "Finalizing Configuration..."
sudo qm set "$VMID" --boot order='ide2;ide3;sata0;scsi0'
sudo qm set "$VMID" --agent enabled=1,fstrim_cloned_disks=1
sudo qm set "$VMID" --tablet 1

banner "================================================"
success "VM $VMID created successfully!"
banner "================================================"
echo "Windows ISO used: $WIN_ISO"
echo ""
echo "Next Steps:"
echo "1. Start the VM: sudo qm start $VMID"
echo "2. Open Console to monitor installation progress"
echo "3. The installation will proceed automatically (30-60 minutes)"
echo "   - Windows setup: ~10 minutes"
echo "   - Software installation (VS2022, VS Code, Git): ~20-30 minutes"
banner "================================================"
