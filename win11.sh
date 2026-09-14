#!/bin/bash
set -e

# --- Default Configuration ---
VMID="1111"
VM_NAME="win11-dev"
VM_MEMORY="8192"       
VM_CORES="4"
ADMIN_PASSWORD="Password123!" # Default Password (Change this!)
DISK_STORAGE="local-lvm"      # Where the VM disk goes
ISO_STORAGE_ID="local"        # Storage ID for ISOs
VIRTIO_ISO="virtio-win-0.1.240.iso" #
OEM_ISO="win11-unattend-${VMID}.iso" # Generated ISO name
ANSWER_FILE="autounattend.xml"
DISK_SIZE="128" # GiB, no unit suffix required

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

# Runs a command with both stdout and stderr captured (silent on success);
# on failure, dumps the captured output before returning its exit code, so
# set -e/the cleanup trap still fire and no diagnostic detail is lost (see CLAUDE.md)
run_quiet() {
    local output status
    output=$("$@" 2>&1)
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "$output" >&2
    fi
    return $status
}

# --- sudo preflight ---
if ! command -v sudo &> /dev/null; then
    error "Error: sudo is required (this script runs privileged commands via sudo) but isn't installed."
    exit 1
fi
if ! sudo -v; then
    error "Error: sudo authentication failed. This user needs sudo access to run win11.sh."
    exit 1
fi


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

# ISO download functions (validate_iso_filename, download_windows_iso,
# download_virtio_iso) live in download-isos.sh - see CLAUDE.md.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/download-isos.sh"

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

run_quiet sudo genisoimage -o "$ISO_PATH_ROOT/$OEM_ISO" -J -R -V "OEMDRV" "$TMP_ISO_DIR"
sudo rm -rf "$TMP_ISO_DIR"
success "Answer-file ISO generated."

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
  --scsihw virtio-scsi-single \
  --cpu host \
  --machine q35 \
  --balloon 0 \
  --bios ovmf
VM_CREATED=1

# 2. Allocate the main disk
info "Allocating Main Disk..."
sudo qm set "$VMID" --scsi0 "$DISK_STORAGE:$DISK_SIZE,ssd=1,discard=on,iothread=1"
success "Main disk allocated."

# 3. EFI disk + TPM 
info "Configuring TPM and UEFI..."
sudo qm set "$VMID" --efidisk0 "$DISK_STORAGE:0,efitype=4m,pre-enrolled-keys=1"
sudo qm set "$VMID" --tpmstate0 "$DISK_STORAGE:0,version=v2.0"
success "EFI/TPM configured."

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

# 6. Start the VM and clear the "Press any key to boot from CD or DVD..."
# prompt by injecting Enter via qm sendkey for the boot window - see CLAUDE.md
info "Starting VM $VMID..."
# run_quiet - this is where swtpm_setup generates output
run_quiet sudo qm start "$VMID"
info "Sending keypresses to clear the boot prompt (up to ~15s)..."
for _ in $(seq 1 15); do
    sudo qm sendkey "$VMID" ret 2>/dev/null || true
    sleep 1
done

success "VM $VMID created and started successfully!"
echo "Windows ISO used: $WIN_ISO"
echo ""
echo "Next Steps:"
echo "1. Open Console to monitor installation progress"
echo "2. The installation will proceed automatically (30-60 minutes)"
