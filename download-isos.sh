#!/bin/bash
# Windows 11 / VirtIO ISO download logic for win11.sh. Can be sourced by it
# (reuses its already-defined colors/sudo preflight/$ISO_PATH_ROOT), or run
# directly to pre-fetch both ISOs without creating a VM. See CLAUDE.md.
set -e

# Falls back to plain output if not sourced from win11.sh, which defines
# these with ANSI colors.
declare -F info    > /dev/null || info()    { printf '%s\n' "$*"; }
declare -F success > /dev/null || success() { printf '%s\n' "$*"; }
declare -F warn    > /dev/null || warn()    { printf '%s\n' "$*"; }
declare -F error   > /dev/null || error()   { printf '%s\n' "$*" >&2; }
declare -F banner  > /dev/null || banner()  { printf '%s\n' "$*"; }

if ! command -v sudo &> /dev/null; then
    error "Error: sudo is required (this script runs privileged commands via sudo) but isn't installed."
    exit 1
fi
if ! sudo -v; then
    error "Error: sudo authentication failed."
    exit 1
fi

ISO_STORAGE_ID="${ISO_STORAGE_ID:-local}"
VIRTIO_STABLE_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"

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

# --- Standalone mode ---
# Only runs when this file is executed directly (not sourced by win11.sh).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ -z "$ISO_PATH_ROOT" ]; then
        DUMMY_PATH=$(sudo pvesm path "$ISO_STORAGE_ID:iso/dummy.iso" 2>/dev/null) || true
        if [ -z "$DUMMY_PATH" ]; then
            error "Error: Could not resolve path for storage '$ISO_STORAGE_ID'."
            exit 1
        fi
        ISO_PATH_ROOT=$(dirname "$DUMMY_PATH")
    fi

    info "Searching for Windows 11 ISO in $ISO_PATH_ROOT..."
    FOUND_ISO=$(sudo find "$ISO_PATH_ROOT" -maxdepth 1 -name "Win11*.iso" -type f | sudo head -n 1)
    if [ -n "$FOUND_ISO" ]; then
        WIN_ISO=$(sudo basename "$FOUND_ISO")
        success "Found local ISO: $WIN_ISO"
    else
        warn "No Windows 11 ISO found locally."
        download_windows_iso || exit 1
    fi
    validate_iso_filename "Windows 11 ISO" "$WIN_ISO" || exit 1

    info "Searching for VirtIO ISO in $ISO_PATH_ROOT..."
    FOUND_VIRTIO=$(sudo find "$ISO_PATH_ROOT" -maxdepth 1 -iname "virtio-win*.iso" -type f | sudo sort -V | sudo tail -n 1)
    if [ -n "$FOUND_VIRTIO" ]; then
        VIRTIO_ISO=$(sudo basename "$FOUND_VIRTIO")
        success "Found local VirtIO ISO: $VIRTIO_ISO"
    else
        download_virtio_iso || exit 1
    fi
    validate_iso_filename "VirtIO ISO" "$VIRTIO_ISO" || exit 1

    success "Both ISOs are ready in $ISO_PATH_ROOT."
fi
