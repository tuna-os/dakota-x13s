# ISO assembly builder image (Debian arm64)
#
# Used by: just iso-sd-boot x13s
#
# Contains all tools to assemble a systemd-boot UEFI live ISO from the
# dakota-x13s rootfs tarball (produced by `podman export`).
FROM --platform=linux/arm64 debian:sid

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        xorriso \
        isomd5sum \
        squashfs-tools \
        dosfstools \
        mtools \
        curl \
        binutils \
    && rm -rf /var/lib/apt/lists/*

COPY src/build-iso.sh /build-iso.sh
RUN chmod +x /build-iso.sh

ENTRYPOINT ["/build-iso.sh"]
