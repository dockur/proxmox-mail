# syntax=docker/dockerfile:1

FROM debian:trixie

ARG TARGETARCH
ARG VERSION_ARG="0.0"

ARG DEBCONF_NOWARNINGS="yes"
ARG DEBIAN_FRONTEND="noninteractive"
ARG DEBCONF_NONINTERACTIVE_SEEN="true"

SHELL ["/bin/bash", "-c"]

RUN <<EOF

# Break on errors
set -Eeuo pipefail
apt-get update

# Install prerequisites
apt-get --no-install-recommends -y install \
  jq \
  curl \
  ca-certificates
apt-get clean
rm -rf /var/lib/apt/lists/*

# Add Proxmox Datacenter Manager archive keyring
KEY_URL="https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg"
KEY_PATH="/usr/share/keyrings/proxmox-archive-keyring.gpg"
URI="http://download.proxmox.com/debian/pdm"
SUITE="trixie"
COMPONENT="pdm-no-subscription"

curl -fsSL "${KEY_URL}" -o "${KEY_PATH}"

cat > /etc/apt/sources.list.d/pdm.sources <<SOURCES
Types: deb
URIs: ${URI}
Suites: ${SUITE}
Components: ${COMPONENT}
Signed-By: ${KEY_PATH}
SOURCES

# Prevent services from starting during install
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

# Stub commands unavailable / problematic in a Docker build
dpkg-divert --local --rename --add /usr/bin/unshare
printf '#!/bin/sh\nwhile [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done\n[ "$1" = "--" ] && \
shift\n[ $# -gt 0 ] && exec "$"\nexit 0\n' > /usr/bin/unshare
chmod +x /usr/bin/unshare
dpkg-divert --local --rename --add /usr/sbin/update-initramfs
printf '#!/bin/sh\nexit 0\n' > /usr/sbin/update-initramfs
chmod +x /usr/sbin/update-initramfs
dpkg-divert --local --rename --add /usr/sbin/ifreload
printf '#!/bin/sh\n[ "$1" = "-V" ] && printf "%%s\n" "ifupdown2:3.3.0-1+pmx12"\nexit 0\n' > /usr/sbin/ifreload
chmod +x /usr/sbin/ifreload
printf '#!/bin/sh\nexit 0\n' > /usr/local/sbin/systemctl
chmod +x /usr/local/sbin/systemctl

# Update system and install Proxmox Datacenter Manager
apt-get update
apt-get full-upgrade -y
apt-get install -y --no-install-recommends \
  dbus \
  nano \
  wget \
  htop \
  less \
  cpio \
  iotop \
  gnupg \
  procps \
  chrony \
  postfix \
  ethtool \
  dnsmasq \
  dnsutils \
  sysstat \
  locales \
  busybox \
  iptables \
  iproute2 \
  ifupdown2 \
  net-tools \
  nfs-common \
  cifs-utils \
  open-iscsi \
  traceroute \
  systemd-sysv \
  bridge-utils \
  iputils-ping \
  netcat-openbsd \
  isc-dhcp-client \
  proxmox-mail-forward \
  proxmox-datacenter-manager \
  proxmox-offline-mirror-helper

# Generate locales
locale-gen en_US.UTF-8

# Remove enterprise repo added by Proxmox packages — keep only no-subscription
rm -f /etc/apt/sources.list.d/pdm-enterprise.list \
      /etc/apt/sources.list.d/pdm-enterprise.sources \
      /etc/apt/sources.list.d/ceph.list \
      /etc/apt/sources.list.d/ceph.sources

# Prevent system updates
apt-mark hold proxmox-datacenter-manager proxmox-mail-forward proxmox-offline-mirror-helper

# Cleanup
apt-get autoremove -y
apt-get clean

# Mask unneeded services
ln -sf /dev/null /etc/systemd/system/systemd-udevd.service
ln -sf /dev/null /etc/systemd/system/systemd-udevd-kernel.socket
ln -sf /dev/null /etc/systemd/system/systemd-udevd-control.socket
ln -sf /dev/null /etc/systemd/system/systemd-modules-load.service
ln -sf /dev/null /etc/systemd/system/systemd-networkd-wait-online.service

# Config journald
echo "[Journal]\nRuntimeMaxUse=500M" > /etc/systemd/journald.conf.d/container.conf

# Disable keyboard request target (for Docker TTY)
cat >/etc/systemd/system/kbrequest.target <<KBR
[Unit]
Description=Keyboard Request Target

[Target]
KBR

# Fix ifupdown2-pre.service for container (no udev)
mkdir -p /etc/systemd/system/ifupdown2-pre.service.d
cat >/etc/systemd/system/ifupdown2-pre.service.d/override.conf << IUD
[Service]
ExecStart=
ExecStart=/bin/true
IUD

# Remove kernel modules and boot files — useless in a container (~960 MB)
rm -rf /usr/lib/modules /boot

# Remove hardware firmware blobs — no physical hardware in a container (~520 MB)
rm -rf /usr/lib/firmware

# Remove GPU/display/media libs — no display server, no GPU passthrough needed
rm -f \
  /usr/lib/*/libLLVM*.so* \
  /usr/lib/*/libgallium*.so* \
  /usr/lib/*/libvulkan_*.so* \
  /usr/lib/*/libz3.so* \
  /usr/lib/*/libx265.so* \
  /usr/lib/*/libcodec2.so* \
  /usr/lib/*/libavcodec.so* \
  /usr/lib/*/libavfilter.so* \
  /usr/lib/*/libSvtAv1Enc.so* \
  /usr/lib/*/libplacebo.so*

rm -rf \
  /usr/lib/*/dri \
  /usr/lib/*/gstreamer-1.0

# Remove share assets not needed at runtime
rm -rf \
  /usr/share/pocketsphinx \
  /usr/share/X11 \
  /usr/share/alsa \
  /usr/share/fonts \
  /usr/share/grub \
  /usr/share/groff \
  /usr/share/mime \
  /usr/share/man

# Set username and password
echo "root:root" | chpasswd

# Store version number
echo "$VERSION_ARG" > /etc/version

# Remove stub
rm /usr/local/sbin/systemctl

# Mask unneeded services
systemctl mask \
    systemd-udevd.service \
    sys-kernel-debug.mount \
    sys-kernel-config.mount \
    sys-kernel-tracing.mount \
    proc-sys-fs-binfmt_misc.automount

# Cleanup files
rm -rf /tmp/* /var/tmp/* /var/lib/apt/lists/*

EOF

WORKDIR /usr/local/bin
COPY --chmod=755 ./src /usr/local/bin/

ENV PASSWORD="root"

EXPOSE 8443

VOLUME /etc/proxmox-datacenter-manager
VOLUME /var/lib/proxmox-datacenter-manager

STOPSIGNAL SIGRTMIN+3
HEALTHCHECK --interval=60s --timeout=10s --start-period=60s --retries=3 \
  CMD curl -kLfSs http://localhost:8443 >/dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/sbin/init", "--log-target=console", "--log-level=notice"]
