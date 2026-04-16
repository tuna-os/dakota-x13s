#!/usr/bin/env bash
# build-iso.sh — ARM64 UEFI-bootable ISO builder for ThinkPad X13s
#
# Adapted from tuna-os/bonito-x13s make-systemd-boot-iso.sh for dakota-x13s.
# ISO layout mirrors ironrobin/archiso-x13s:
#   boot/aarch64/{vmlinuz,initramfs.img,x13s.dtb}  — kernel + live boot files
#   EFI/BOOT/BOOTAA64.EFI                           — systemd-boot (arm64)
#   loader/loader.conf                               — boot menu config
#   loader/entries/x13s.conf                        — X13s boot entry
#   LiveOS/squashfs.img                             — root filesystem
#   images/efiboot.img                              — FAT32 ESP (El Torito)
#
# Usage: build-iso.sh <boot-tar> <rootfs-squashfs> <output-iso-path>
#
# <boot-tar>        : tar of {usr/lib/modules, usr/lib/systemd/boot/efi}
# <rootfs-squashfs> : pre-built squashfs of the live rootfs
# <output-iso-path> : destination .iso file

set -euo pipefail

LABEL="DAKX13S"

# ─────────────────────────────────────────────────────────────────────────────
# Args & validation
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

for tool in tar mkfs.vfat mtools xorriso mksquashfs; do
    command -v "$tool" &>/dev/null || { echo "Error: missing tool: $tool" >&2; exit 2; }
done

# ─────────────────────────────────────────────────────────────────────────────
# Working directory
# ─────────────────────────────────────────────────────────────────────────────

TMPDIR="${TMPDIR:-/tmp}"
BUILD_DIR=$(mktemp -d "$TMPDIR/dakota-x13s-iso.XXXXXX")
trap "rm -rf '$BUILD_DIR'" EXIT

echo "Building ISO in ${BUILD_DIR}"

# ─────────────────────────────────────────────────────────────────────────────
# Extract boot tar → locate kernel, initramfs, EFI binary, DTB
# ─────────────────────────────────────────────────────────────────────────────

BOOT_FILES="${BUILD_DIR}/boot-files"
mkdir -p "$BOOT_FILES"
tar -xf "$BOOT_TAR" -C "$BOOT_FILES"

[[ -d "$BOOT_FILES/usr/lib/modules" ]] || \
    { echo "Error: boot tar missing usr/lib/modules" >&2; exit 3; }
[[ -d "$BOOT_FILES/usr/lib/systemd/boot/efi" ]] || \
    { echo "Error: boot tar missing usr/lib/systemd/boot/efi" >&2; exit 3; }

KERNEL=$(ls "$BOOT_FILES/usr/lib/modules" | sort -V | tail -1)
INITRAMFS="$BOOT_FILES/usr/lib/modules/${KERNEL}/initramfs.img"
[[ -f "$INITRAMFS" ]] || { echo "Error: initramfs.img not found for ${KERNEL}" >&2; exit 3; }

SYSTEMD_BOOT_EFI="$BOOT_FILES/usr/lib/systemd/boot/efi/systemd-bootaa64.efi"
[[ -f "$SYSTEMD_BOOT_EFI" ]] || \
    { echo "Error: systemd-bootaa64.efi not found" >&2; exit 3; }

KERNEL_SRC="$BOOT_FILES/usr/lib/modules/${KERNEL}/vmlinuz"
if [[ ! -f "$KERNEL_SRC" ]]; then
    KERNEL_SRC=$(find "$BOOT_FILES/usr/lib/modules/${KERNEL}" \
        \( -name "vmlinuz*" -o -name "Image" -o -name "Image.gz" \) 2>/dev/null | head -1)
    [[ -n "$KERNEL_SRC" && -f "$KERNEL_SRC" ]] || \
        { echo "Error: kernel image not found" >&2; exit 3; }
fi

# Locate X13s DTB
X13S_DTB=""
for candidate in \
    "$BOOT_FILES/usr/lib/modules/${KERNEL}/dtb/qcom/sc8280xp-lenovo-thinkpad-x13s.dtb" \
    "$BOOT_FILES/usr/share/dtb/qcom/sc8280xp-lenovo-thinkpad-x13s.dtb" \
    "$BOOT_FILES/boot/dtb/qcom/sc8280xp-lenovo-thinkpad-x13s.dtb"; do
    if [[ -f "$candidate" ]]; then
        X13S_DTB="$candidate"
        echo "Found DTB: ${X13S_DTB}"
        break
    fi
done

if [[ -z "$X13S_DTB" ]]; then
    echo "Warning: DTB not found in boot tar — boot may rely on firmware DTB" >&2
fi

echo "Kernel: ${KERNEL}"
echo "  vmlinuz:    ${KERNEL_SRC}"
echo "  initramfs:  ${INITRAMFS}"
echo "  EFI binary: ${SYSTEMD_BOOT_EFI}"
echo "  DTB:        ${X13S_DTB:-<not found>}"

# ─────────────────────────────────────────────────────────────────────────────
# Build ISO directory tree
# ─────────────────────────────────────────────────────────────────────────────
#
# Layout (matches bonito-x13s / ironrobin archiso-x13s):
#   iso/
#     boot/aarch64/           ← kernel, initramfs, dtb (readable by ISO9660)
#     EFI/BOOT/BOOTAA64.EFI   ← systemd-boot
#     loader/loader.conf       ← menu config
#     loader/entries/x13s.conf ← boot entry
#     LiveOS/squashfs.img      ← root filesystem (ISO9660)
#     images/efiboot.img       ← FAT32 ESP (El Torito EFI boot record)

ISO_ROOT="${BUILD_DIR}/iso"
mkdir -p \
    "${ISO_ROOT}/boot/aarch64" \
    "${ISO_ROOT}/EFI/BOOT" \
    "${ISO_ROOT}/loader/entries" \
    "${ISO_ROOT}/LiveOS" \
    "${ISO_ROOT}/images"

cp "$KERNEL_SRC"   "${ISO_ROOT}/boot/aarch64/vmlinuz"
cp "$INITRAMFS"    "${ISO_ROOT}/boot/aarch64/initramfs.img"
[[ -n "$X13S_DTB" ]] && cp "$X13S_DTB" "${ISO_ROOT}/boot/aarch64/x13s.dtb"

cp "$SYSTEMD_BOOT_EFI" "${ISO_ROOT}/EFI/BOOT/BOOTAA64.EFI"

# Squashfs goes directly in ISO9660 — not inside FAT (FAT32 4 GB limit)
echo "Copying squashfs to LiveOS/..."
cp "$ROOTFS_SQUASHFS" "${ISO_ROOT}/LiveOS/squashfs.img"

# loader.conf
cat > "${ISO_ROOT}/loader/loader.conf" << 'EOF'
timeout 15
default x13s.conf
console-mode max
editor no
auto-firmware no
beep on
EOF

# Boot entry — X13s kargs mirror /usr/lib/bootc/kargs.d/01-x13s.toml
DTB_LINE=""
[[ -n "$X13S_DTB" ]] && \
    DTB_LINE="devicetree /boot/aarch64/x13s.dtb"

cat > "${ISO_ROOT}/loader/entries/x13s.conf" << ENTRYEOF
title      Dakota (ThinkPad X13s)
sort-key   01
linux      /boot/aarch64/vmlinuz
initrd     /boot/aarch64/initramfs.img
${DTB_LINE}
options    root=live:CDLABEL=${LABEL} rd.live.image rd.live.overlay.thin efi=noruntime arm64.nopauth clk_ignore_unused pd_ignore_unused enforcing=0 quiet
ENTRYEOF

cat > "${ISO_ROOT}/loader/entries/x13s-debug.conf" << ENTRYEOF
title      Dakota X13s (debug shell)
sort-key   02
linux      /boot/aarch64/vmlinuz
initrd     /boot/aarch64/initramfs.img
${DTB_LINE}
options    root=live:CDLABEL=${LABEL} rd.live.image efi=noruntime arm64.nopauth clk_ignore_unused pd_ignore_unused enforcing=0 rd.shell
ENTRYEOF

# ─────────────────────────────────────────────────────────────────────────────
# Create FAT32 EFI boot image
#
# Contains EFI/BOOT/BOOTAA64.EFI + loader/ + boot/aarch64/ so UEFI firmware
# can read the bootloader and its config from the FAT partition.
# squashfs stays in ISO9660 only.
# ─────────────────────────────────────────────────────────────────────────────

EFI_STAGING="${BUILD_DIR}/efi-staging"
mkdir -p "$EFI_STAGING"
cp -a "${ISO_ROOT}/EFI"    "$EFI_STAGING/"
cp -a "${ISO_ROOT}/loader"  "$EFI_STAGING/"
cp -a "${ISO_ROOT}/boot"    "$EFI_STAGING/"

EFI_SIZE_MB=$(du -sm "$EFI_STAGING" | awk '{print int($1 * 1.15 + 8)}')
echo "FAT32 ESP size: ${EFI_SIZE_MB} MB"

EFI_IMG="${ISO_ROOT}/images/efiboot.img"
dd if=/dev/zero of="$EFI_IMG" bs=1M count="$EFI_SIZE_MB" status=none
mkfs.vfat -n "EFIBOOT" "$EFI_IMG"
mcopy -s -i "$EFI_IMG" "${EFI_STAGING}/EFI"    ::
mcopy -s -i "$EFI_IMG" "${EFI_STAGING}/loader"  ::
mcopy -s -i "$EFI_IMG" "${EFI_STAGING}/boot"    ::
rm -rf "$EFI_STAGING"

echo "EFI image contents:"
mdir -i "$EFI_IMG" -/ ::

# ─────────────────────────────────────────────────────────────────────────────
# Assemble final ISO (hybrid ISO9660 + GPT with EFI system partition)
# ─────────────────────────────────────────────────────────────────────────────

echo "Assembling ISO..."
xorriso -as mkisofs \
    -o "$OUTPUT_ISO" \
    -R -J \
    -V "$LABEL" \
    -e images/efiboot.img \
    -no-emul-boot \
    -append_partition 2 C12A7328-F81F-11D2-BA4B-00A0C93EC93B "$EFI_IMG" \
    -appended_part_as_gpt \
    "$ISO_ROOT"

[[ -f "$OUTPUT_ISO" ]] || { echo "Error: ISO not created" >&2; exit 1; }

ISO_SIZE=$(du -h "$OUTPUT_ISO" | cut -f1)
echo "ISO: ${OUTPUT_ISO} (${ISO_SIZE})"
echo "Label: ${LABEL}"
echo "Boot: systemd-bootaa64.efi → loader/entries/x13s.conf"
