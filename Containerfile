# dakota-x13s — ThinkPad X13s (Qualcomm SC8280XP / aarch64) bootc image
#
# Layers Qualcomm X13s hardware support onto the Project Bluefin Dakota image.
# Firmware, pd-mapper, and kernel config are extracted from the jlinton/x13s
# Fedora COPR so no RPM toolchain is needed in the final GNOME OS image.
#
# Build:
#   podman build --platform linux/arm64 -t dakota-x13s .
#
# Switch a running bootc system:
#   sudo bootc switch ghcr.io/<org>/dakota-x13s:latest

# ── Stage 1: Download X13s RPMs from jlinton/x13s COPR ───────────────────────
FROM --platform=linux/arm64 fedora:42 AS x13s-rpms

RUN dnf -y copr enable jlinton/x13s &&     dnf -y install --downloadonly --destdir=/pkgs         qcom-firmware         pd-mapper &&     dnf clean all

# ── Stage 2: Extract RPM contents ────────────────────────────────────────────
FROM --platform=linux/arm64 fedora:42 AS x13s-extracted

COPY --from=x13s-rpms /pkgs /pkgs
RUN cd /pkgs &&     for rpm in *.rpm; do         echo Extracting:
