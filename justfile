# dakota-x13s — ThinkPad X13s live ISO builder
# Adapted from projectbluefin/dakota-iso for aarch64 / Qualcomm SC8280XP.
#
# Prerequisites: podman, just
# On x86_64 hosts: requires qemu-user-static for arm64 cross-build

output_dir := "output"
debug := "0"
installer_channel := "stable"
compression := "fast"
skip_build := "0"

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

    echo "=== df before container build ===" && df -h
    if [[ '{{skip_build}}' != '1' ]]; then
        just debug={{debug}} installer_channel={{installer_channel}} container
        echo "=== df after container build ===" && df -h

        # Free intermediate layers: keeps x13s-installer, removes debian:sid,
        # fedora:42, and dangling build cache from the multi-stage build.
        podman image prune -f
        echo "=== df after image prune ===" && df -h
    fi

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

    trap "rm -f '${SQUASHFS}' '${BOOT_TAR}'; rm -rf '${CS_STAGING}' 2>/dev/null || true" EXIT

    PAYLOAD_REF=$(cat iso/payload_ref | tr -d '[:space:]')

    _ns "
        set -euo pipefail
        SFS_PID=\"\"
        MERGED_ROOT=\"\"
        _inner_cleanup() {
            [[ -n \"\${SFS_PID}\" ]] && kill \"\${SFS_PID}\" 2>/dev/null || true
            if [[ -n \"\${MERGED_ROOT}\" ]]; then
                umount \"\${MERGED_ROOT}/var/lib/containers/storage\" 2>/dev/null || true
                umount \"\${MERGED_ROOT}\" 2>/dev/null || true
                rmdir \"\${MERGED_ROOT}\" 2>/dev/null || true
            fi
            podman image umount localhost/x13s-installer 2>/dev/null || true
        }
        trap _inner_cleanup EXIT
        MOUNT=\$(podman image mount localhost/x13s-installer)
        PATH=/usr/sbin:/usr/bin:\$PATH

        CS_STAGING='${CS_STAGING}'
        SQUASHFS_STORAGE=\"\${CS_STAGING}/var/lib/containers/storage\"
        LIVE_RUNROOT=\"\${CS_STAGING}/live-runroot\"
        STORAGE_CONF=\"\${CS_STAGING}/live-storage.conf\"
        mkdir -p \"\${SQUASHFS_STORAGE}\" \"\${LIVE_RUNROOT}\"
        printf '[storage]\ndriver = \"vfs\"\nrunroot = \"%s\"\ngraphroot = \"%s\"\n' \
            \"\${LIVE_RUNROOT}\" \"\${SQUASHFS_STORAGE}\" > \"\${STORAGE_CONF}\"

        # Pull payload image directly from registry into VFS containers-storage.
        # Using docker:// avoids pulling to overlay on the host (saves ~65 GB disk).
        echo 'Importing payload into VFS containers-storage...'
        CONTAINERS_STORAGE_CONF=\"\${STORAGE_CONF}\" \
        skopeo copy \
            docker://${PAYLOAD_REF} \
            containers-storage:${PAYLOAD_REF}

        rm -f \"\${STORAGE_CONF}\"
        rm -rf \"\${LIVE_RUNROOT}\"
        echo \"=== df after VFS import ===\" && df -h

        # Bind-mount installer rootfs + VFS store for mksquashfs.
        # Avoids ~65 GB cp -a; mksquashfs reads both through the merged view.
        MERGED_ROOT=\"\$(mktemp -d '${OUTPUT_DIR}'/merged-XXXXXX)\"
        mount --bind \"\${MOUNT}\" \"\${MERGED_ROOT}\"
        mkdir -p \"\${MERGED_ROOT}/var/lib/containers/storage\"
        mount --bind \"\${SQUASHFS_STORAGE}\" \"\${MERGED_ROOT}/var/lib/containers/storage\"

        # fast = lz4 (4× faster than zstd-3, slightly larger output)
        # release = zstd-15 at 1MB blocks (max compression ratio)
        if [[ '{{compression}}' == 'release' ]]; then
            SFS_COMP=\"zstd\"; SFS_COMP_OPTS=\"-Xcompression-level 15\"; SFS_BLOCK=1048576
        else
            SFS_COMP=\"lz4\"; SFS_COMP_OPTS=\"\"; SFS_BLOCK=524288
        fi
        # Compress squashfs in background; export boot files in parallel
        mksquashfs \"\${MERGED_ROOT}\" '${SQUASHFS}' \
            -noappend -comp \${SFS_COMP} \${SFS_COMP_OPTS} -b \${SFS_BLOCK} \
            -processors 4 \
            -e proc -e sys -e dev -e run -e tmp &
        SFS_PID=\$!

        tar -C \"\${MOUNT}\" \
            -cf '${BOOT_TAR}' \
            ./usr/lib/modules \
            ./usr/lib/systemd/boot/efi
        wait \${SFS_PID}
        SFS_PID=\"\"

        umount \"\${MERGED_ROOT}/var/lib/containers/storage\"
        umount \"\${MERGED_ROOT}\"
        rmdir \"\${MERGED_ROOT}\"
        MERGED_ROOT=\"\"
        rm -rf '${CS_STAGING}'

        trap - EXIT
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
