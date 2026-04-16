#!/usr/bin/env bash
# build-iso.sh — ARM64 UEFI-bootable ISO builder for ThinkPad X13s
#
# Adapted from projectbluefin/dakota-iso for aarch64 / Qualcomm SC8280XP:
#   - Uses systemd-bootaa64.efi (not x64)
#   - Embeds X13s kernel arguments in the boot entry
#   - Embeds the SC8280XP DTB in the ESP so the bootloader can pass it
#     to the kernel (required when UEFI firmware doesn't provide a DTB)
#
# Usage: build-iso.sh <boot-tar> <rootfs-squashfs> <output-iso-path>

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Parse arguments & validate input files
# ─────────────────────────────────────────────────────────────────────────────

if [[ $# -ne 3 ]]; then
    echo "Usage: $0 <boot-tar> <rootfs-squashfs> <output-iso-path>"
    exit 1
fi

BOOT_TAR="$1"
ROOTFS_SQUASHFS="$2"
OUTPUT_ISO="$3"

for f in "$BOOT_TAR" "$ROOTFS_SQUASHFS"; do
    [[ -f "$f" ]] || { echo "Error: not found: $f" >&2; exit 1; }
done

# ─────────────────────────────────────────────────────────────────────────────
# Check for required tools
# ─────────────────────────────────────────────────────────────────────────────

for tool in tar mkfs.fat mtools xorriso; do
    command -v "$tool" &>/dev/null || { echo "Error: missing: $tool" >&2; exit 2; }
done

# ─────────────────────────────────────────────────────────────────────────────
# Temporary working directory
# ─────────────────────────────────────────────────────────────────────────────

TMPDIR="${TMPDIR:-/tmp}"
BUILD_DIR=$(mktemp -d "$TMPDIR/dakota-x13s-iso.XXXXXX")
trap "rm -rf '$BUILD_DIR'" EXIT

echo "Building ISO in ${BUILD_DIR}"

# ─────────────────────────────────────────────────────────────────────────────
# Extract kernel modules, EFI files, and DTB from boot tar
# ─────────────────────────────────────────────────────────────────────────────

BOOT_FILES="${BUILD_DIR}/boot-files"
mkdir -p "$BOOT_FILES"

echo "Extracting boot files from ${BOOT_TAR}..."
tar -xf "$BOOT_TAR" -C "$BOOT_FILES"

if [[ ! -d "$BOOT_FILES/usr/lib/modules" ]] || [[ ! -d "$BOOT_FILES/usr/lib/systemd/boot/efi" ]]; then
    echo "Error: boot tar missing expected directory structure" >&2
    exit 3
fi

# ─────────────────────────────────────────────────────────────────────────────
# Locate kernel, initramfs, EFI binary (arm64), and DTB
# ─────────────────────────────────────────────────────────────────────────────

KERNEL=$(ls "$BOOT_FILES/usr/lib/modules" | sort -V | tail -1)
INITRAMFS="$BOOT_FILES/usr/lib/modules/${KERNEL}/initramfs.img"

# arm64 uses BOOTAA64.EFI, not BOOTX64.EFI
SYSTEMD_BOOT_EFI="$BOOT_FILES/usr/lib/systemd/boot/efi/systemd-bootaa64.efi"
if [[ ! -f "$SYSTEMD_BOOT_EFI" ]]; then
    echo "Error: systemd-bootaa64.efi not found (arm64 required)" >&2
    exit 3
fi

[[ -f "$INITRAMFS" ]] || { echo "Error: initramfs.img not found for kernel ${KERNEL}" >&2; exit 3; }

KERNEL_SRC="${BOOT_FILES}/usr/lib/modules/${KERNEL}/vmlinuz"
if [[ ! -f "$KERNEL_SRC" ]]; then
    KERNEL_SRC=$(find "$BOOT_FILES/usr/lib/modules/${KERNEL}" \
        -name "vmlinuz*" -o -name "Image" -o -name "Image.gz" 2>/dev/null | head -1)
    [[ -n "$KERNEL_SRC" && -f "$KERNEL_SRC" ]] || \
        { echo "Error: kernel image not found" >&2; exit 3; }
fi

# Locate the X13s DTB — prefer the copy shipped in the kernel's dtb dir.
# On GNOME OS (freedesktop-sdk kernel), DTBs live at:
#   /usr/lib/modules/$KVER/dtb/qcom/sc8280xp-lenovo-thinkpad-x13s.dtb
X13S_DTB=""
DTB_CANDIDATES=(
    "$BOOT_FILES/usr/lib/modules/${KERNEL}/dtb/qcom/sc8280xp-lenovo-thinkpad-x13s.dtb"
    "$BOOT_FILES/usr/share/dtb/qcom/sc8280xp-lenovo-thinkpad-x13s.dtb"
    "$BOOT_FILES/boot/dtb/qcom/sc8280xp-lenovo-thinkpad-x13s.dtb"
)
for candidate in "${DTB_CANDIDATES[@]}"; do
    if [[ -f "$candidate" ]]; then
        X13S_DTB="$candidate"
        echo "Found DTB: ${X13S_DTB}"
        break
    fi
done

if [[ -z "$X13S_DTB" ]]; then
    echo "Warning: sc8280xp-lenovo-thinkpad-x13s.dtb not found in boot tar." >&2
    echo "  Fetching from Debian linux-image package as fallback..." >&2
    # Fetch DTB from Debian stable arm64 kernel package (same DTB as mainline)
    mkdir -p "${BUILD_DIR}/dtb-fetch"
    DEBIAN_KERNEL_PKG=$(curl -s https://packages.debian.org/stable/arm64/linux-image-arm64/download \
        | grep -oP 'https://[^"]+linux-image-[^"]+_arm64\.deb' | head -1 || true)
    if [[ -n "$DEBIAN_KERNEL_PKG" ]]; then
        curl -L "$DEBIAN_KERNEL_PKG" -o "${BUILD_DIR}/dtb-fetch/kernel.deb"
        cd "${BUILD_DIR}/dtb-fetch"
        ar x kernel.deb
        tar -xf data.tar.* --wildcards '*/sc8280xp-lenovo-thinkpad-x13s.dtb' 2>/dev/null || true
        X13S_DTB=$(find . -name 'sc8280xp-lenovo-thinkpad-x13s.dtb' | head -1)
        [[ -n "$X13S_DTB" ]] && X13S_DTB="${BUILD_DIR}/dtb-fetch/${X13S_DTB#./}"
        cd -
    fi
    [[ -n "$X13S_DTB" && -f "$X13S_DTB" ]] || \
        echo "Warning: Could not obtain DTB — boot may rely on UEFI firmware DTB." >&2
fi

echo "Using kernel: ${KERNEL}"
echo "  Kernel binary:  ${KERNEL_SRC}"
echo "  Initramfs:      ${INITRAMFS}"
echo "  EFI binary:     ${SYSTEMD_BOOT_EFI}"
echo "  DTB:            ${X13S_DTB:-<not found, relying on firmware>}"

# ─────────────────────────────────────────────────────────────────────────────
# Create FAT32 ESP image
# ─────────────────────────────────────────────────────────────────────────────

ESP_IMAGE="${BUILD_DIR}/esp.img"
ESP_SIZE=504  # MB

echo "Creating FAT32 ESP image (${ESP_SIZE} MB)..."
mkfs.fat -F 32 -S 512 -s 1 -C "$ESP_IMAGE" "$ESP_SIZE" >/dev/null

echo "Populating ESP..."

# arm64: BOOTAA64.EFI (not BOOTX64.EFI)
mmd -i "$ESP_IMAGE" EFI EFI/BOOT EFI/systemd-boot images images/pxeboot
[[ -n "$X13S_DTB" ]] && mmd -i "$ESP_IMAGE" dtb dtb/qcom
mcopy -i "$ESP_IMAGE" "$SYSTEMD_BOOT_EFI" "::EFI/BOOT/BOOTAA64.EFI"
mcopy -i "$ESP_IMAGE" "$KERNEL_SRC"        "::images/pxeboot/vmlinuz"
mcopy -i "$ESP_IMAGE" "$INITRAMFS"         "::images/pxeboot/initramfs.img"
mcopy -i "$ESP_IMAGE" "$ROOTFS_SQUASHFS"   "::images/pxeboot/squashfs.img"

# Embed DTB in ESP so systemd-boot can pass it to the kernel
if [[ -n "$X13S_DTB" && -f "$X13S_DTB" ]]; then
    mcopy -i "$ESP_IMAGE" "$X13S_DTB" "::dtb/qcom/sc8280xp-lenovo-thinkpad-x13s.dtb"
    echo "DTB embedded in ESP at /dtb/qcom/sc8280xp-lenovo-thinkpad-x13s.dtb"
fi

# systemd-boot loader.conf
cat > "${BUILD_DIR}/loader.conf" << 'EOF'
default x13s
console-mode max
editor no
auto-firmware no
EOF
mcopy -i "$ESP_IMAGE" "${BUILD_DIR}/loader.conf" "::EFI/systemd-boot/"

# Boot entry — ThinkPad X13s specific kargs + optional DTB handoff
# Kargs:
#   arm64.nopauth     — SC8280XP lacks pointer auth support
#   clk_ignore_unused — keep unused clocks alive (prevents lockups)
#   pd_ignore_unused  — keep unused power domains alive
#   efi=noruntime     — Qualcomm UEFI runtime services not safe
DTB_LINE=""
[[ -n "$X13S_DTB" ]] && \
    DTB_LINE="devicetree /dtb/qcom/sc8280xp-lenovo-thinkpad-x13s.dtb"

cat > "${BUILD_DIR}/x13s.conf" << ENTRYEOF
title Dakota (ThinkPad X13s)
version 1.0
linux /images/pxeboot/vmlinuz
initrd /images/pxeboot/initramfs.img
${DTB_LINE}
options rd.live.image rd.live.dir=/ root=live:/dev/disk/by-label/DAKX13S rd.live.squashfs.image=squashfs.img rd.live.overlay rd.live.overlay.overlayfs=1 selinux=0 arm64.nopauth clk_ignore_unused pd_ignore_unused efi=noruntime quiet
ENTRYEOF

mcopy -i "$ESP_IMAGE" "${BUILD_DIR}/x13s.conf" "::EFI/systemd-boot/entries/"

# ─────────────────────────────────────────────────────────────────────────────
# Build ISO9660 with El Torito EFI boot
# ─────────────────────────────────────────────────────────────────────────────

echo "Building ISO9660..."
xorriso \
    -as mkisofs \
    -volid DAKX13S \
    -efi-boot-part --efi-boot-image \
    -efi-boot ESP.img \
    -appid "Dakota X13s Live ISO" \
    -preparer "xorriso" \
    -output "$OUTPUT_ISO"

[[ -f "$OUTPUT_ISO" ]] || { echo "Error: ISO not created" >&2; exit 1; }

ISO_SIZE=$(du -h "$OUTPUT_ISO" | cut -f1)
echo "✓ ISO: ${OUTPUT_ISO} (${ISO_SIZE})"
echo "Boot via UEFI — systemd-bootaa64.efi loads /EFI/systemd-boot/entries/x13s.conf"
