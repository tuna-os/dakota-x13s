# dakota-x13s — ThinkPad X13s (Qualcomm SC8280XP / aarch64) bootc image
#
# Layers Qualcomm X13s hardware support onto the Project Bluefin Dakota image.
# Firmware blobs (qcom/sc8280xp) are in upstream linux-firmware; pd-mapper is
# a standard Fedora package. No COPR required.
#
# Build:
#   podman build --platform linux/arm64 -t dakota-x13s .
#
# Switch a running bootc system:
#   sudo bootc switch ghcr.io/hanthor/dakota-x13s:latest

# ── Stage 1: Extract X13s files from standard Fedora packages ────────────────
# linux-firmware ships SC8280XP blobs; pd-mapper is in the Fedora main repo.
# Files are selectively COPYed into the GNOME OS layer below.
FROM --platform=linux/arm64 fedora:42 AS x13s-extracted

RUN dnf -y install \
        linux-firmware \
        pd-mapper && \
    dnf clean all

# ── Stage 3: Dakota + X13s hardware support ──────────────────────────────────
FROM ghcr.io/hanthor/dakota:aarch64

# Qualcomm firmware blobs
# Required for: GPU (qcdxkmsuc8280), ADSP (qcadsp8280), CDSP (qccdsp8280),
#               SLPI (qcslpi8280) — enables audio, battery monitoring, sensors
COPY --from=x13s-extracted /usr/lib/firmware/qcom /usr/lib/firmware/qcom

# pd-mapper binary — maps Qualcomm power domain clients to the correct
# PD handles. Must start before qcom_q6v5_pas loads the DSP firmware.
COPY --from=x13s-extracted /usr/bin/pd-mapper /usr/bin/pd-mapper
COPY --from=x13s-extracted /usr/lib/systemd/system/pd-mapper.service \
     /usr/lib/systemd/system/pd-mapper.service

RUN systemctl enable pd-mapper.service

# Load pd-mapper then qcom_q6v5_pas after boot (strict order required).
# qcom_q6v5_pas must NOT load during initrd — it depends on power domains
# that are only ready after userspace pd-mapper is running.
RUN printf 'qcom_pd_mapper\nqcom_q6v5_pas\n' > /etc/modules-load.d/x13s.conf

# Dracut: include QCOM firmware blobs in initrd so the GPU can initialise
# early, but omit qcom_q6v5_pas from the initrd driver set.
RUN printf 'install_items+=" \
/lib/firmware/qcom/sc8280xp/LENOVO/21BX/qcadsp8280.mbn.xz \
/lib/firmware/qcom/sc8280xp/LENOVO/21BX/qcdxkmsuc8280.mbn.xz \
/lib/firmware/qcom/sc8280xp/LENOVO/21BX/qccdsp8280.mbn.xz \
/lib/firmware/qcom/sc8280xp/LENOVO/21BX/qcslpi8280.mbn.xz \
"\n' > /etc/dracut.conf.d/x13s.conf && \
    printf 'omit_drivers+=" qcom_q6v5_pas "\n' >> /etc/dracut.conf.d/x13s.conf

# Kernel arguments applied by bootc at install time.
# Also mirrored in the live ISO boot entry (iso/src/build-iso.sh).
#   arm64.nopauth     — SC8280XP lacks pointer authentication support
#   clk_ignore_unused — keep unused clocks alive (prevents lockups)
#   pd_ignore_unused  — keep unused power domains alive
#   efi=noruntime     — Qualcomm UEFI runtime services are not safe to call
RUN mkdir -p /usr/lib/bootc/kargs.d && \
    printf 'kargs = ["arm64.nopauth", "clk_ignore_unused", "pd_ignore_unused", "efi=noruntime"]\n' \
    > /usr/lib/bootc/kargs.d/01-x13s.toml
