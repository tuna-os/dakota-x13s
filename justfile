# dakota-x13s — ThinkPad X13s live ISO builder
# Adapted from projectbluefin/dakota-iso for aarch64 / Qualcomm SC8280XP.
#
# Prerequisites: podman, just
# On x86_64 hosts: requires qemu-user-static for arm64 cross-build

output_dir := "output"
debug := "0"
installer_channel := "stable"
compression := "fast"

# Build in background; log to output_dir/build.log
build-bg:
    #!/usr/bin/bash
    set -euo pipefail
    mkdir -p {{output_dir}}
    LOG=$(realpath {{output_dir}})/build.log
    echo "Starting background build → ${LOG}"
    setsid sudo just \
        debug={{debug}} \
        installer_channel={{installer_channel}} \
        output_dir={{output_dir}} \
        compression={{compression}} \
        iso-sd-boot x13s \
        > "${LOG}" 2>&1 &
    disown $!
    echo "Build PID $! — tailing log (Ctrl-C safe, build continues)"
    tail -f "${LOG}"

# Build the ISO installer container image
container:
    podman build --cap-add sys_admin --security-opt label=disable \
        --platform linux/arm64 \
        --layers \
        --build-arg DEBUG={{debug}} \
        --build-arg INSTALLER_CHANNEL={{installer_channel}} \
        -t x13s-installer ./iso

# Build the systemd-boot UEFI live ISO
iso-sd-boot:
    #!/usr/bin/bash
    set -euo pipefail

    just debug={{debug}} installer_channel={{installer_channel}} container
    mkdir -p {{output_dir}}
    OUTPUT_DIR=$(realpath "{{output_dir}}")

    if [[ $(id -u) -eq 0 ]]; then
        _ns()    { bash -c "$1"; }
        _ns_rm() { rm -rf "$@"; }
    else
        _ns()    { podman unshare bash -c "$1"; }
        _ns_rm() { podman unshare rm -rf "$@"; }
    fi

    SQUASHFS="${OUTPUT_DIR}/x13s-rootfs.sfs"
    BOOT_TAR="${OUTPUT_DIR}/x13s-boot-files.tar"
    CS_STAGING="${OUTPUT_DIR}/x13s-cs-staging"
    SQUASHFS_ROOT="${OUTPUT_DIR}/x13s-sfs-root"
    PAYLOAD_OCI="${OUTPUT_DIR}/x13s-payload.oci.tar"

    trap "rm -f '${SQUASHFS}' '${BOOT_TAR}' '${PAYLOAD_OCI}'; _ns_rm '${CS_STAGING}' '${SQUASHFS_ROOT}' 2>/dev/null || true" EXIT

    PAYLOAD_REF=$(cat iso/payload_ref | tr -d '[:space:]')

    _ns "
        set -euo pipefail
        MOUNT=\$(podman image mount localhost/x13s-installer)
        PATH=/usr/sbin:/usr/bin:\$PATH

        PAYLOAD_OCI='${PAYLOAD_OCI}'
        CS_STAGING='${CS_STAGING}'
        SQUASHFS_ROOT='${SQUASHFS_ROOT}'
        SQUASHFS_STORAGE=\"\${CS_STAGING}/var/lib/containers/storage\"
        LIVE_RUNROOT=\"\$(mktemp -d '${OUTPUT_DIR}'/live-runroot-XXXXXX)\"
        STORAGE_CONF=\"\$(mktemp '${OUTPUT_DIR}'/live-storage-XXXXXX.conf)\"
        mkdir -p \"\${SQUASHFS_STORAGE}\"
        printf '[storage]\ndriver = \"vfs\"\nrunroot = \"%s\"\ngraphroot = \"%s\"\n' \
            \"\${LIVE_RUNROOT}\" \"\${SQUASHFS_STORAGE}\" > \"\${STORAGE_CONF}\"

        echo 'Exporting dakota-x13s OCI image to archive...'
        skopeo copy \
            containers-storage:${PAYLOAD_REF} \
            oci-archive:\${PAYLOAD_OCI}:${PAYLOAD_REF}

        echo 'Importing into squashfs containers-storage...'
        CONTAINERS_STORAGE_CONF=\"\${STORAGE_CONF}\" \
        skopeo copy \
            oci-archive:\${PAYLOAD_OCI}:${PAYLOAD_REF} \
            containers-storage:${PAYLOAD_REF}

        rm -f \"\${PAYLOAD_OCI}\" \"\${STORAGE_CONF}\"
        rm -rf \"\${LIVE_RUNROOT}\"

        echo 'Building unified squashfs source tree...'
        mkdir -p \"\${SQUASHFS_ROOT}\"
        cp -a --reflink=auto \"\${MOUNT}/.\" \"\${SQUASHFS_ROOT}/\" 2>/dev/null || \
            cp -a \"\${MOUNT}/.\" \"\${SQUASHFS_ROOT}/\"
        mkdir -p \"\${SQUASHFS_ROOT}/var/lib/containers/storage\"
        cp -a \"\${CS_STAGING}/var/lib/containers/storage/.\" \
            \"\${SQUASHFS_ROOT}/var/lib/containers/storage/\"
        rm -rf \"\${CS_STAGING}\"

        SFS_LEVEL=3; SFS_BLOCK=131072
        [[ '{{compression}}' == 'release' ]] && { SFS_LEVEL=15; SFS_BLOCK=1048576; }
        mksquashfs \"\${SQUASHFS_ROOT}\" '${SQUASHFS}' \
            -noappend -comp zstd -Xcompression-level \${SFS_LEVEL} -b \${SFS_BLOCK} \
            -processors 4 \
            -e proc -e sys -e dev -e run -e tmp

        rm -rf \"\${SQUASHFS_ROOT}\"

        # Export boot files: kernel modules (for DTB) + EFI binaries
        tar -C \"\$MOUNT\" \
            -cf '${BOOT_TAR}' \
            ./usr/lib/modules \
            ./usr/lib/systemd/boot/efi
        podman image umount localhost/x13s-installer
    "

    TMPDIR="${OUTPUT_DIR}" \
    PATH="/usr/sbin:/usr/bin:${PATH}" \
        bash "iso/src/build-iso.sh" "${BOOT_TAR}" "${SQUASHFS}" "${OUTPUT_DIR}/x13s-live.iso"

    echo "ISO ready: ${OUTPUT_DIR}/x13s-live.iso"

# Write ISO to USB drive (destructive — double-check device path!)
flash-usb dev:
    @echo "WARNING: This will ERASE {{dev}}"
    @echo "Press Ctrl-C within 5 seconds to cancel..."
    @sleep 5
    sudo dd if=output/x13s-live.iso of={{dev}} bs=4M status=progress conv=fsync

# Boot ISO in QEMU for testing (x86_64 host — no KVM, slow but functional)
boot-iso-qemu:
    #!/usr/bin/bash
    set -euo pipefail
    ISO=$(ls output/x13s-live*.iso 2>/dev/null | head -1)
    [[ -n "$ISO" ]] || { echo "No ISO found — run: just iso-sd-boot" >&2; exit 1; }

    # For arm64 ISO on any host, use qemu-system-aarch64 with software emulation
    QEMU=$(command -v qemu-system-aarch64 || true)
    [[ -n "$QEMU" ]] || { echo "qemu-system-aarch64 not found" >&2; exit 1; }

    # Locate AARCH64 OVMF
    OVMF=""
    for f in \
        /usr/share/AAVMF/AAVMF_CODE.fd \
        /usr/share/edk2/aarch64/QEMU_EFI.fd \
        /usr/share/qemu-efi-aarch64/QEMU_EFI.fd; do
        [[ -f "$f" ]] && { OVMF="$f"; break; }
    done
    [[ -n "$OVMF" ]] || { echo "AARCH64 OVMF not found — install aavmf or qemu-efi-aarch64" >&2; exit 1; }

    echo "Booting ${ISO} (serial console — Ctrl-A X to quit)"
    "$QEMU" \
        -machine virt,gic-version=3 \
        -cpu cortex-a72 \
        -m 4096 \
        -smp 4 \
        -drive if=pflash,format=raw,readonly=on,file="${OVMF}" \
        -drive if=none,id=live,file="${ISO}",media=cdrom,readonly=on \
        -device virtio-scsi-pci -device scsi-cd,drive=live \
        -net nic,model=virtio -net user \
        -serial mon:stdio \
        -display none \
        -no-reboot
