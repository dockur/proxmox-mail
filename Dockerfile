# syntax=docker/dockerfile:1

FROM debian:trixie-slim

ARG TARGETARCH
ARG VERSION_ARG="9.1"

ARG DEBCONF_NOWARNINGS="yes"
ARG DEBIAN_FRONTEND="noninteractive"
ARG DEBCONF_NONINTERACTIVE_SEEN="true"

SHELL ["/bin/bash", "-c"]

RUN <<EOF

# Break on errors
set -Eeuo pipefail

# Install prerequisites
apt-get update
apt-get install -y --no-install-recommends \
  jq \
  curl \
  tini \
  nano \
  wget \
  htop \
  less \
  dpkg \
  sudo \
  gnupg \
  procps \
  locales \
  postfix \
  rsyslog \
  iproute2 \
  net-tools \
  dnsutils \
  postgresql \
  iputils-ping \
  clamav-daemon \
  netcat-openbsd \
  ca-certificates \
  clamav-freshclam

# Prevent services from starting during install
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

# Block unneeded packages in container
cat >/etc/apt/preferences.d/99-pmg-unneeded-packages <<BLK
Package: proxmox-default-kernel proxmox-kernel-* pve-firmware
Pin: release *
Pin-Priority: -1
BLK

# Stub commands unavailable / problematic in a Docker build
dpkg-divert --local --rename --add /usr/bin/unshare
printf '#!/bin/sh\nwhile [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done\n[ "$1" = "--" ] && \
shift\n[ $# -gt 0 ] && exec "$@"\nexit 0\n' > /usr/bin/unshare
chmod +x /usr/bin/unshare
dpkg-divert --local --rename --add /usr/sbin/update-initramfs
printf '#!/bin/sh\nexit 0\n' > /usr/sbin/update-initramfs
chmod +x /usr/sbin/update-initramfs
printf '#!/bin/sh\nexit 0\n' > /usr/local/sbin/systemctl
chmod +x /usr/local/sbin/systemctl

# Install Proxmox Mail Gateway

if [[ "$TARGETARCH" == "amd64" ]]; then

  # Add Proxmox Mail Gateway repository
  curl -sL https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
       -o /usr/share/keyrings/proxmox-archive-keyring.gpg

  cat <<'DEB' | sed 's/^[[:space:]]*//' >/etc/apt/sources.list.d/pmg-no-subs.sources
    Types: deb
    URIs: http://download.proxmox.com/debian/pmg
    Suites: trixie
    Components: pmg-no-subscription
    Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
DEB

  apt-get update
  apt-get install -y --no-install-recommends \
    pmg-api \
    pmg-gui \
    pmg-docs \
    pmg-i18n \
    pmg-log-tracker \
    proxmox-spamassassin

else

  apt-get install -y --no-install-recommends \
    git \
    dpkg-dev \
    apt-transport-https

  tmpdir="/tmp/deb"
  mkdir -p "$tmpdir"

  # Download packages from repo qemus/proxmox-mail-arm64
  git clone --depth 1 https://github.com/qemus/proxmox-mail-arm64.git "$tmpdir"
  chmod +x "$tmpdir/build.sh"

  (cd "$tmpdir" && ./build.sh "install=${VERSION_ARG}")
  rm -rf "$tmpdir"

  apt-get remove -y \
    git \
    dpkg-dev \
    apt-transport-https

fi

# Prevent system updates
apt-mark hold \
  pmg-api \
  pmg-gui \
  pmg-docs \
  pmg-i18n \
  pmg-log-tracker

# Backup packaged PMG state files outside /var/lib/pmg because /var/lib/pmg
# may be mounted as a volume and hide files installed by PMG packages.
mkdir -p /usr/share/pmg/var-lib-pmg.dist

if [ -d /var/lib/pmg ]; then
  cp -a /var/lib/pmg/. /usr/share/pmg/var-lib-pmg.dist/
fi

if [ ! -f /usr/share/pmg/var-lib-pmg.dist/templates/main.cf.in ]; then
  echo "ERROR: PMG template backup failed: /usr/share/pmg/var-lib-pmg.dist/templates/main.cf.in missing" >&2
  echo "Files under /var/lib/pmg:" >&2
  find /var/lib/pmg -maxdepth 4 -type f 2>/dev/null | sort >&2 || true
  exit 20
fi

# Install supercronic
if [[ "$TARGETARCH" == "amd64" ]]; then

  SUPERCRONIC=supercronic-linux-amd64
  SUPERCRONIC_URL=https://github.com/aptible/supercronic/releases/download/v0.2.46/supercronic-linux-amd64

else

  SUPERCRONIC=supercronic-linux-arm64
  SUPERCRONIC_URL=https://github.com/aptible/supercronic/releases/download/v0.2.46/supercronic-linux-arm64

fi

curl -fsSLO "$SUPERCRONIC_URL"
chmod +x "$SUPERCRONIC"
mv "$SUPERCRONIC" "/usr/local/bin/${SUPERCRONIC}"
ln -s "/usr/local/bin/${SUPERCRONIC}" /usr/local/bin/supercronic

# Remove enterprise repo added by Proxmox packages — keep only no-subscription
rm -f /etc/apt/sources.list.d/pmg-enterprise.list \
      /etc/apt/sources.list.d/pmg-enterprise.sources \
      /etc/apt/sources.list.d/ceph.list \
      /etc/apt/sources.list.d/ceph.sources

# Cleanup
apt-get autoremove -y
apt-get clean

# Generate locales
locale-gen en_US.UTF-8

# Set username and password
echo "root:root" | chpasswd

# Redirect rsyslog
sed -i '/.*imklog.*/d' /etc/rsyslog.conf && \
    echo '*.* -/proc/1/fd/' >> /etc/rsyslog.conf

# Store version number
echo "$VERSION_ARG" > /etc/version

# Remove stub
rm /usr/local/sbin/systemctl

# Cleanup files
rm -rf /tmp/* /var/tmp/* /var/lib/apt/lists/*

EOF

WORKDIR /usr/local/bin
COPY --chmod=755 ./src /usr/local/bin/

ENV PASSWORD="root"

EXPOSE 25
EXPOSE 26
EXPOSE 8006

VOLUME /etc/pmg
VOLUME /var/lib/pmg
VOLUME /var/spool/pmg
VOLUME /var/lib/postgresql

HEALTHCHECK --interval=60s --timeout=10s --start-period=60s --retries=3 \
    CMD ["curl", "-kLfSs", "https://localhost:8006/"]

ENTRYPOINT ["/usr/bin/tini", "-s", "/usr/local/bin/entrypoint.sh"]
