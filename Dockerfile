# syntax=docker/dockerfile:1

FROM debian:trixie-slim

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

# Add Proxmox Datacenter Manager repository
curl -sL https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
     -o /usr/share/keyrings/proxmox-archive-keyring.gpg

cat >/etc/apt/sources.list.d/pdm-no-subs.sources <<DEB
Types: deb
URIs: http://download.proxmox.com/debian/pdm
Suites: trixie
Components: pdm-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
DEB

# Block unneeded packages in container
cat >/etc/apt/preferences.d/99-pdm-unneeded-packages <<BLK
Package: proxmox-default-kernel proxmox-kernel-* pve-firmware
Pin: release *
Pin-Priority: -1
BLK

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
  procps \
  locales \
  iptables \
  iproute2 \
  ifupdown2 \
  net-tools \
  nfs-common \
  cifs-utils \
  traceroute \
  systemd-sysv \
  iputils-ping \
  netcat-openbsd \
  isc-dhcp-client

apt-get install -y \
  proxmox-mail-forward \
  proxmox-datacenter-manager \
  proxmox-offline-mirror-helper

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

# Generate locales
locale-gen en_US.UTF-8

# Mask unneeded services 
ln -sf /dev/null /etc/systemd/system/systemd-udevd.service
ln -sf /dev/null /etc/systemd/system/systemd-udevd-kernel.socket
ln -sf /dev/null /etc/systemd/system/systemd-udevd-control.socket
ln -sf /dev/null /etc/systemd/system/systemd-modules-load.service
ln -sf /dev/null /etc/systemd/system/systemd-networkd-wait-online.service

# Mask unneeded mounts
systemctl mask \
    sys-kernel-debug.mount \
    sys-kernel-config.mount \
    sys-kernel-tracing.mount \
    proc-sys-fs-binfmt_misc.automount

# Config journald
mkdir -p /etc/systemd/journald.conf.d
echo "[Journal]\nRuntimeMaxUse=500M" > /etc/systemd/journald.conf.d/container.conf

# Disable keyboard request target (for Docker TTY)
cat >/etc/systemd/system/kbrequest.target <<KBR
[Unit]
Description=Keyboard Request Target

[Target]
KBR

# Fix ifupdown2-pre.service for container (no udev)
mkdir -p /etc/systemd/system/ifupdown2-pre.service.d
cat >/etc/systemd/system/ifupdown2-pre.service.d/override.conf <<IUD
[Service]
ExecStart=
ExecStart=/bin/true
IUD

# Set username and password
echo "root:root" | chpasswd

# Store version number
echo "$VERSION_ARG" > /etc/version

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
  CMD curl -kLfSs https://localhost:8443/api2/json/version >/dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/sbin/init", "--log-target=console", "--log-level=notice"]
