#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables
: "${DEBUG:="N"}"         # Disable debugging
: "${PASSWORD:="root"}"   # Default password

# Helper functions

info () { printf "%b%s%b" "\E[1;34m❯ \E[1;36m" "${1:-}" "\E[0m\n"; }
error () { printf "%b%s%b" "\E[1;31m❯ " "ERROR: ${1:-}" "\E[0m\n" >&2; }
warn () { printf "%b%s%b" "\E[1;31m❯ " "Warning: ${1:-}" "\E[0m\n" >&2; }

# Check environment
[ "$(id -u)" -ne "0" ] && error "Script must be executed with root privileges." && exit 11
[ ! -f "/usr/local/bin/entrypoint.sh" ] && error "Script must be run inside the container!" && exit 12

# Display version number
info "Starting Proxmox Datacenter Manager for Docker v$(</etc/version)..."
info "For support visit https://github.com/dockur/proxmox-dm"
echo ""

# Update password for root
printf 'root:%s\n' "$PASSWORD" | chpasswd

# Get the capability bounding set
CAP_BND=$(grep '^CapBnd:' /proc/$$/status | awk '{print $2}')
CAP_BND=$(printf "%d" "0x${CAP_BND}")

# Get the last capability number
LAST_CAP=$(cat /proc/sys/kernel/cap_last_cap)

# Calculate the maximum capability value
MAX_CAP=$(((1 << (LAST_CAP + 1)) - 1))

# Check if container is privileged
if [ "${CAP_BND}" -ne "${MAX_CAP}" ]; then
  error "Please start the container with the --privileged flag!"
  [[ "${DEBUG:-}" != [Yy1]* ]] && exit 14
fi

# If missing timezone and localtime set them
set_timezone() {
  local zone="$1"

  if [ ! -f "/usr/share/zoneinfo/$zone" ]; then
    echo "Invalid timezone: $zone" >&2
    exit 18
  fi

  ln -snf "/usr/share/zoneinfo/$zone" /etc/localtime
  echo "$zone" > /etc/timezone
}

check_localtime() {
  if [ ! -e /etc/localtime ] && [ ! -L /etc/localtime ]; then
    return 1
  fi

  local target
  target="$(readlink -f /etc/localtime 2>/dev/null || true)"

  if [ -z "$target" ] || [ ! -f "$target" ] || [ ! -s "$target" ]; then
    echo "Invalid TZ value." >&2
    exit 1
  fi

  return 0
}

if [ -n "${TZ:-}" ]; then
  set_timezone "$TZ"
elif ! check_localtime; then
  set_timezone "UTC"
fi

# Ensure directory permissions
user="www-data"
dir="/etc/proxmox-datacenter-manager"

mkdir -p "$dir"
chmod 1770 "$dir" || :
chown "$user:$user" "$dir" || :

dir="/etc/proxmox-datacenter-manager/auth"
mkdir -p "$dir"
chmod 750 "$dir" || :
chown "root:$user" "$dir" || :

dir="/var/lib/proxmox-datacenter-manager"
mkdir -p "$dir"
chown "$user:$user" "$dir" || :

dir="/var/log/proxmox-datacenter-manager"
mkdir -p "$dir"
chown "root:$user" "$dir" || :

dir="/run/proxmox-datacenter-manager"
mkdir -p "$dir/shmem"
chmod 1770 "$dir" || :
chown "root:$user" "$dir" || :
chown "root:root" "$dir/shmem" || :
mount -t tmpfs -o rw tmpfs "$dir/shmem"

# Generate keys
keys="/etc/proxmox-datacenter-manager/auth"

if [[ ! -f "$keys/authkey.key" ]]; then
  info "Generating authentication keys..."
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "$keys/authkey.key" 2>/dev/null
  openssl pkey -in "$keys/authkey.key" -pubout -out "$keys/authkey.pub" 2>/dev/null
  chmod 640 "$keys/authkey.key"
  chmod 644 "$keys/authkey.pub"
  chown "root:$user" "$keys/authkey.key"
fi

if [[ ! -f "$keys/csrf.key" ]]; then
  info "Generating CSRF key..."
  openssl rand -base64 32 > "$keys/csrf.key"
  chmod 640 "$keys/csrf.key"
  chown "root:$user" "$keys/csrf.key"
fi

if [ ! -f "$keys/api.key" ] || [ ! -f "$keys/api.pem" ]; then
  info "Generating API key..."

  openssl req -x509 -newkey rsa:4096 -keyout "$keys/api.key" -out "$keys/api.pem" -sha256 -days 3650 -nodes \
              -subj "/C=XX/ST=StateName/L=CityName/O=CompanyName/OU=CompanySectionName/CN=CommonNameOrHostname" 2>/dev/null
  chmod 640 "$keys/api.key"
  chmod 640 "$keys/api.pem"
  chown "root:$user" "$keys/api.key"
  chown "root:$user" "$keys/api.pem"
fi

_trap() {
  local func="$1"; shift
  local sig
  TRAP_PID=$BASHPID

  for sig; do
    trap "$func $sig" "$sig"
  done
}

cleanup() {

  [ -f /proxmox.end ] && return 0
  [[ $BASHPID != "$TRAP_PID" ]] && return 0

  touch /proxmox.end
  echo "Shutting down PDM services..."

  # Stop in reverse order
  if [[ -n "${API_PID:-}" ]] && kill -0 "$API_PID" 2>/dev/null; then
    kill -TERM "$API_PID" 2>/dev/null || :
  fi

  if [[ -n "${PRIV_API_PID:-}" ]] && kill -0 "$PRIV_API_PID" 2>/dev/null; then
    kill -TERM "$PRIV_API_PID" 2>/dev/null || :
  fi

  # Wait for processes
  wait -n "${PRIV_API_PID:-}" "${API_PID:-}" 2>/dev/null || :

  echo ""
  echo "Shutdown completed successfully."
  exit 0
}

# Init trap
rm -f /proxmox.end
_trap cleanup SIGTERM SIGINT

# Start PDM Services
dir="/usr/libexec/proxmox"
echo "Starting proxmox-datacenter-privileged-api..."

"$dir/proxmox-datacenter-privileged-api" &

PRIV_API_PID=$!
sock="/run/proxmox-datacenter-manager/priv.sock"

# Wait for the privileged API socket to be ready
for i in $(seq 1 30); do
  [[ -S "$sock" ]] && break
  info "Waiting for privileged API socket ($i/30)..."
  sleep 1
done

if [[ ! -S "$sock" ]]; then
  warn "Privileged API socket not found after 30s, starting API anyway."
fi

echo "Starting proxmox-datacenter-api as $user on port ${PORT:-8443}..."
msg="failed to collect blockdev statistics for "

runuser -u www-data -- \
    "$dir/proxmox-datacenter-api" \
    2> >(grep -v "$msg" >&2) &
API_PID=$!

echo ""
info "------------------------------------------------------------------------------"
info ""
info ". Welcome to the Proxmox Datacenter Manager v$(</etc/version). Connect your web browser to:"
info ""
info ".   https://127.0.0.1:${PORT:-8443}"
info ""
info "------------------------------------------------------------------------------"
info ""

# Wait for processes
wait -n "${PRIV_API_PID:-}" "${API_PID:-}" 2>/dev/null || :

info "A PDM process exited unexpectedly. Shutting down..."
cleanup
