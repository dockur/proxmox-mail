#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables
: "${DEBUG:="N"}"            # Enable debugging
: "${PASSWORD:="root"}"      # Default password
: "${DOMAIN:="pmg.local"}"   # FQDN for mailserver

# Optional service toggles
: "${CLAMAV:="Y"}"           # Start clamd for virus scanning
: "${FRESHCLAM:="Y"}"        # Start freshclam for virus database updates
: "${FETCHMAIL:="N"}"        # Start fetchmail, only useful if configured
: "${PMGMIRROR:="N"}"        # Start pmgmirror, only useful for clustering/mirroring
: "${PMGTUNNEL:="N"}"        # Start pmgtunnel, only useful for clustering

# Helper functions
info () { printf "%b%s%b" "\E[1;34m❯ \E[1;36m" "${1:-}" "\E[0m\n"; }
error () { printf "%b%s%b" "\E[1;31m❯ " "ERROR: ${1:-}" "\E[0m\n" >&2; }
warn () { printf "%b%s%b" "\E[1;31m❯ " "Warning: ${1:-}" "\E[0m\n" >&2; }

is_enabled() {
  case "${1:-}" in
    Y|y|YES|yes|TRUE|true|1|ON|on) return 0 ;;
    *) return 1 ;;
  esac
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    error "Required command not found: $1"
    exit 21
  }
}

process_alive() {
  local pid="${1:-}"

  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

wait_process_alive() {
  local pid="${1:-}"
  local name="${2:-process}"
  local seconds="${3:-1}"

  sleep "$seconds"

  if ! process_alive "$pid"; then
    warn "$name exited shortly after startup."
    return 1
  fi

  return 0
}

read_pidfile() {
  local file

  for file; do
    if [ -f "$file" ]; then
      read -r REPLY < "$file"
      [ -n "${REPLY:-}" ] && return 0
    fi
  done

  REPLY=""
  return 1
}

configure_hostname() {
  local fqdn="$DOMAIN"
  local short
  local mail_domain
  local nameservers

  if [[ "$fqdn" == *.* ]]; then
    short="${fqdn%%.*}"
    mail_domain="${fqdn#*.}"
  else
    short="$fqdn"
    mail_domain="local"
    fqdn="$short.$mail_domain"
    DOMAIN="$fqdn"
  fi

  if [ -z "$short" ] || [ -z "$mail_domain" ] || [ "$short" = "$mail_domain" ]; then
    error "Invalid DOMAIN setting: DOMAIN='$DOMAIN'"
    exit 22
  fi

  echo "Configuring hostname: $fqdn"

  echo "$short" > /etc/hostname
  echo "$fqdn" > /etc/mailname

  sed -i \
    -e "/[[:space:]]${short}[[:space:]]*/d" \
    -e "/[[:space:]]${fqdn}[[:space:]]*/d" \
    /etc/hosts 2>/dev/null || :

  cat >>/etc/hosts <<EOF
127.0.1.1 $fqdn $short
EOF

  # PMG derives dns.domain from the resolver search domain.
  # Without this, pmgconfig sync can generate "mydomain =".
  nameservers="$(
    awk '
      $1 == "nameserver" { print }
    ' /etc/resolv.conf 2>/dev/null || true
  )"

  {
    echo "search $mail_domain"

    if [ -n "$nameservers" ]; then
      printf '%s\n' "$nameservers"
    else
      echo "nameserver 1.1.1.1"
      echo "nameserver 8.8.8.8"
    fi
  } >/etc/resolv.conf

  PMG_HOSTNAME="$short"
  PMG_MAIL_DOMAIN="$mail_domain"
  PMG_FQDN="$fqdn"

  # Seed Postfix too, but pmgconfig sync may overwrite this from templates.
  postconf -e "myhostname = $fqdn" || :
  postconf -e "mydomain = $mail_domain" || :
  postconf -e "myorigin = \$mydomain" || :
}

detect_domain_change() {
  DOMAIN_STATE_FILE="/etc/pmg/.docker-domain"
  OLD_DOMAIN=""

  if [ -f "$DOMAIN_STATE_FILE" ]; then
    OLD_DOMAIN="$(cat "$DOMAIN_STATE_FILE" 2>/dev/null || true)"
  fi

  DOMAIN_CHANGED="N"

  if [ "$OLD_DOMAIN" != "$PMG_FQDN" ]; then
    DOMAIN_CHANGED="Y"

    if [ -n "$OLD_DOMAIN" ]; then
      echo "Domain changed from '$OLD_DOMAIN' to '$PMG_FQDN'."
    else
      echo "Initializing domain state for '$PMG_FQDN'."
    fi
  fi
}

# Check environment
[ "$(id -u)" -ne "0" ] && error "Script must be executed with root privileges." && exit 11
[ ! -f "/usr/local/bin/entrypoint.sh" ] && error "Script must be run inside the container!" && exit 12

# Check required binaries early.
require_cmd openssl
require_cmd chpasswd
require_cmd pmgconfig
require_cmd pmgdb
require_cmd pg_ctlcluster
require_cmd pg_createcluster
require_cmd pg_dropcluster
require_cmd pg_isready
require_cmd psql
require_cmd createuser
require_cmd runuser
require_cmd supercronic
require_cmd pmgdaemon
require_cmd pmgproxy
require_cmd pmg-smtp-filter
require_cmd pmgpolicy

if is_enabled "$CLAMAV" && ! command -v clamd >/dev/null 2>&1; then
  warn "CLAMAV=Y but clamd is missing."
fi

if is_enabled "$FRESHCLAM" && ! command -v freshclam >/dev/null 2>&1; then
  warn "FRESHCLAM=Y but freshclam is missing."
fi

if is_enabled "$FETCHMAIL" && ! command -v fetchmail >/dev/null 2>&1; then
  warn "FETCHMAIL=Y but fetchmail is missing."
fi

if is_enabled "$PMGTUNNEL" && ! command -v pmgtunnel >/dev/null 2>&1; then
  warn "PMGTUNNEL=Y but pmgtunnel is missing."
fi

if is_enabled "$PMGMIRROR" && ! command -v pmgmirror >/dev/null 2>&1; then
  warn "PMGMIRROR=Y but pmgmirror is missing."
fi

# Display version number
info "Starting Proxmox Mail Gateway for Docker v$(</etc/version)..."
info "For support visit https://github.com/dockur/proxmox-mail"
echo ""

# Update password for root
printf 'root:%s\n' "$PASSWORD" | chpasswd

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

dir="/etc/pmg"
mkdir -p "$dir"
chmod 0750 "$dir" || :
chown "root:$user" "$dir" || :

dir="/etc/pmg/dkim"
mkdir -p "$dir"
chmod 0750 "$dir" || :
chown "root:$user" "$dir" || :

dir="/var/lib/pmg"
mkdir -p "$dir"
chown "root:$user" "$dir" || :

dir="/var/spool/pmg"
mkdir -p "$dir"
chown "root:$user" "$dir" || :

dir="/var/log/pmg"
mkdir -p "$dir"
chown "root:$user" "$dir" || :

dir="/run/pmg"
mkdir -p "$dir"
chmod 0755 "$dir" || :
chown "root:root" "$dir" || :

# Remove stale PID files.
#
# This matters when /run is mounted or when the previous container stop was not clean.
rm -f \
  /run/clamav/clamd.pid \
  /run/clamav/freshclam.pid \
  /var/run/clamav/clamd.pid \
  /var/run/clamav/freshclam.pid \
  /var/spool/postfix/pid/master.pid \
  /run/pmgdaemon.pid \
  /run/pmgproxy.pid \
  /run/pmg-smtp-filter.pid \
  /run/pmgpolicy.pid \
  /run/pmgmirror.pid \
  /run/pmgtunnel.pid

# Start rsyslog early because PMG tools expect /dev/log
echo "Starting rsyslog..."

cat >/etc/rsyslog.conf <<'EOF'
module(load="imuxsock")
input(type="imuxsock" Socket="/dev/log")
template(name="DockerFormat" type="string" string="%programname%:%msg%\n")

if $msg contains '#000' then stop
if $msg contains 'IORITY' then stop
if $msg contains 'F_LOG_TARGET' then stop
if $msg contains 'SYSLOG_IDENTIFIER' then stop

if $programname == 'runuser' then stop
if $programname == 'rsyslogd' and $msg contains '[origin software="rsyslogd"' then stop

*.* action(type="omfile" file="/var/log/system.log" template="DockerFormat")
EOF

rm -f /dev/log /var/log/system.log
touch /var/log/system.log
chmod 0644 /etc/rsyslog.conf /var/log/system.log

rsyslogd -n -iNONE -f /etc/rsyslog.conf &
RSYSLOG_PID=$!

while [ ! -S /dev/log ]; do
  sleep 0.2
done

mkdir -p /run/systemd/journal
ln -sf /dev/log /run/systemd/journal/syslog
ln -sf /dev/log /run/systemd/journal/socket

tail -F /var/log/system.log &
TAIL_PID=$!

# Generate keys
keys="/etc/pmg"

if [[ ! -f "$keys/pmg-authkey.key" ]]; then
  info "Generating authentication keys..."
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "$keys/pmg-authkey.key" 2>/dev/null
  openssl pkey -in "$keys/pmg-authkey.key" -pubout -out "$keys/pmg-authkey.pub" 2>/dev/null
  chmod 640 "$keys/pmg-authkey.key"
  chmod 644 "$keys/pmg-authkey.pub"
  chown "root:$user" "$keys/pmg-authkey.key"
fi

if [[ ! -f "$keys/pmg-csrf.key" ]]; then
  info "Generating CSRF key..."
  openssl rand -base64 32 > "$keys/pmg-csrf.key"
  chmod 640 "$keys/pmg-csrf.key"
  chown "root:$user" "$keys/pmg-csrf.key"
fi

# Start PostgreSQL
echo "Starting PostgreSQL..."

PG_VERSION="$(
  find /usr/lib/postgresql -mindepth 1 -maxdepth 1 -type d -printf '%f\n' |
    sort -V |
    tail -n1
)"

if [ -z "$PG_VERSION" ]; then
  error "No PostgreSQL version directory found in /usr/lib/postgresql."
  exit 19
fi

PG_CLUSTER="main"
PG_DATA="/var/lib/postgresql/$PG_VERSION/$PG_CLUSTER"

mkdir -p /var/run/postgresql
chown postgres:postgres /var/run/postgresql
chmod 2775 /var/run/postgresql

# If a cluster config exists but the actual database is missing, remove the broken cluster.
if [ ! -s "$PG_DATA/PG_VERSION" ] && [ -d "/etc/postgresql/$PG_VERSION/$PG_CLUSTER" ]; then
  echo "Removing broken PostgreSQL cluster config..."
  pg_dropcluster "$PG_VERSION" "$PG_CLUSTER" --stop || :
fi

# Create the PostgreSQL cluster if it does not exist.
if [ ! -s "$PG_DATA/PG_VERSION" ]; then
  echo "Creating PostgreSQL $PG_VERSION/$PG_CLUSTER cluster..."
  pg_createcluster "$PG_VERSION" "$PG_CLUSTER"
fi

pg_ctlcluster "$PG_VERSION" "$PG_CLUSTER" start

until pg_isready -q -h /var/run/postgresql -p 5432 -U postgres; do
  sleep 0.2
done

# Ensure PostgreSQL role expected by PMG exists
echo "Checking PostgreSQL roles..."

if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='root'" | grep -q 1; then
  echo "Creating PostgreSQL role 'root'..."
  runuser -u postgres -- createuser --superuser root
fi

# Configure hostname/domain before PMG generates Postfix configuration.
configure_hostname

# Initialize PMG configuration and database.
echo "Initializing PMG configuration..."
pmgconfig init

# Detect if DOMAIN changed compared to the previous container start.
detect_domain_change

# Regenerate PMG certificates when missing or when DOMAIN changed.
#
# These certificates are domain-sensitive, but the PMG auth keys and CSRF key
# should not be regenerated because they are persistent identity/state.
if [[ ! -f "$keys/pmg-api.pem" ]] || is_enabled "$DOMAIN_CHANGED"; then
  info "Generating API certificate..."
  rm -f "$keys/pmg-api.pem"
  pmgconfig apicert
fi

if [[ ! -f "$keys/pmg-tls.pem" ]] || is_enabled "$DOMAIN_CHANGED"; then
  info "Generating SMTP TLS certificate..."
  rm -f "$keys/pmg-tls.pem"
  pmgconfig tlscert
fi

echo "Initializing PMG database..."

PMGDB_INIT_OUTPUT="$(pmgdb init 2>&1)" || {
  printf '%s\n' "$PMGDB_INIT_OUTPUT"
  exit 23
}

printf '%s\n' "$PMGDB_INIT_OUTPUT" | grep -vE '^(GRANT|CREATE|ALTER)[[:space:]]*$' || :

# Restore packaged PMG files into the mounted /var/lib/pmg volume if missing.
echo "Checking PMG packaged files..."

PMG_VARLIB_SRC="/usr/share/pmg/var-lib-pmg.dist"
PMG_VARLIB_DST="/var/lib/pmg"

mkdir -p "$PMG_VARLIB_DST"
mkdir -p /etc/pmg/templates

# This backup must exist in the image. If it does not, the Dockerfile did not
# copy /var/lib/pmg before the volume mounted over it at runtime.
if [ ! -f "$PMG_VARLIB_SRC/templates/main.cf.in" ]; then
  error "PMG packaged file backup missing: $PMG_VARLIB_SRC/templates/main.cf.in"
  echo "This means the Docker image was not built with the /var/lib/pmg backup."
  echo "Fix the Dockerfile backup block and rebuild the image."
  echo ""
  echo "Debug output:"
  find /usr/share/pmg -maxdepth 4 -type f 2>/dev/null | sort || true
  find /var/lib/pmg -maxdepth 4 -type f 2>/dev/null | sort || true
  dpkg -S /var/lib/pmg/templates/main.cf.in 2>/dev/null || true
  exit 20
fi

restored=0

while IFS= read -r -d '' src; do
  rel="${src#"$PMG_VARLIB_SRC"/}"
  dst="$PMG_VARLIB_DST/$rel"

  if [ ! -e "$dst" ]; then
    if [ "$restored" -eq 0 ]; then
      echo "Restoring missing PMG packaged files from $PMG_VARLIB_SRC..."
    fi

    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
    restored=$((restored + 1))
  fi
done < <(find "$PMG_VARLIB_SRC" -type f -print0)

if [ "$restored" -gt 0 ]; then
  echo "Restored $restored PMG packaged file(s)."
fi

# Hard check for the known required Postfix template.
if [ ! -f "$PMG_VARLIB_DST/templates/main.cf.in" ]; then
  error "PMG template missing after restore: $PMG_VARLIB_DST/templates/main.cf.in"
  echo ""
  echo "Debug output:"
  find "$PMG_VARLIB_DST" -maxdepth 4 -type f 2>/dev/null | sort || true
  find "$PMG_VARLIB_SRC" -maxdepth 4 -type f 2>/dev/null | sort || true
  dpkg -S "$PMG_VARLIB_DST/templates/main.cf.in" 2>/dev/null || true
  exit 21
fi

chown -R root:www-data "$PMG_VARLIB_DST/templates" 2>/dev/null || :
chmod -R u=rwX,g=rX,o= "$PMG_VARLIB_DST/templates" 2>/dev/null || :

# Ensure PMG runtime state directories exist inside the mounted /var/lib/pmg volume.
mkdir -p \
  /var/lib/pmg/spamassassin \
  /var/lib/pmg/spamassassin/.razor \
  /var/lib/pmg/backup \
  /var/lib/pmg/dump \
  /var/lib/pmg/statistic

chown -R root:www-data /var/lib/pmg 2>/dev/null || :
chown -R www-data:www-data /var/lib/pmg/spamassassin 2>/dev/null || :
chmod 0750 /var/lib/pmg 2>/dev/null || :
chmod 0750 /var/lib/pmg/spamassassin 2>/dev/null || :
chmod 0700 /var/lib/pmg/spamassassin/.razor 2>/dev/null || :

echo "Syncing PMG configuration..."
pmgconfig sync

# Store applied domain only after configuration sync succeeded.
printf '%s\n' "$PMG_FQDN" > "$DOMAIN_STATE_FILE"

# Prepare ClamAV directories.
#
# PMG does not start ClamAV itself when systemd is removed.
# clamd and freshclam need to be supervised separately.
if is_enabled "$CLAMAV" || is_enabled "$FRESHCLAM"; then
  echo "Preparing ClamAV..."

  mkdir -p /run/clamav /var/lib/clamav /var/log/clamav
  chown -R clamav:clamav /run/clamav /var/lib/clamav /var/log/clamav 2>/dev/null || :
  chmod 0755 /run/clamav || :

  # Make sure common log files exist, because Debian ClamAV configs often expect them.
  touch /var/log/clamav/clamav.log /var/log/clamav/freshclam.log 2>/dev/null || :
  chown clamav:clamav /var/log/clamav/clamav.log /var/log/clamav/freshclam.log 2>/dev/null || :
fi

# Initialize ClamAV database before clamd starts.
#
# On first boot the database may be empty. clamd often refuses to start
# when no virus database exists yet. freshclam can fail because of rate limits
# or missing network, so this must not hard-fail the container.
if is_enabled "$CLAMAV" || is_enabled "$FRESHCLAM"; then
  if command -v freshclam >/dev/null 2>&1; then
    if ! find /var/lib/clamav -type f \( -name '*.cvd' -o -name '*.cld' \) 2>/dev/null | grep -q .; then
      echo "Initializing ClamAV virus database..."
      freshclam || warn "freshclam failed during initial database update. Continuing anyway."
    fi
  else
    warn "freshclam binary not found."
  fi
fi

# Start freshclam daemon.
#
# This keeps virus definitions updated while the container is running.
# If freshclam exits later, the container will keep running because mail flow
# can continue with the existing virus database.
FRESHCLAM_PID=""

if is_enabled "$FRESHCLAM"; then
  if command -v freshclam >/dev/null 2>&1; then
    echo "Starting freshclam..."

    freshclam -d --foreground=true &
    FRESHCLAM_PID=$!

    if ! wait_process_alive "$FRESHCLAM_PID" "freshclam" 1; then
      FRESHCLAM_PID=""

      warn "Retrying freshclam in daemon mode..."
      freshclam -d || warn "Could not start freshclam daemon."

      if read_pidfile /run/clamav/freshclam.pid /var/run/clamav/freshclam.pid; then
        FRESHCLAM_PID="$REPLY"
      fi
    fi
  else
    warn "FRESHCLAM=Y but freshclam binary not found."
  fi
fi

# Start clamd.
#
# This is required for PMG virus scanning. pmg-smtp-filter will not start
# clamd for you in a non-systemd container.
CLAMD_PID=""

if is_enabled "$CLAMAV"; then
  if command -v clamd >/dev/null 2>&1; then
    echo "Starting clamd..."

    clamd --foreground=true &
    CLAMD_PID=$!

    if ! wait_process_alive "$CLAMD_PID" "clamd" 1; then
      CLAMD_PID=""

      warn "Retrying clamd with --foreground..."
      clamd --foreground &
      CLAMD_PID=$!

      if ! wait_process_alive "$CLAMD_PID" "clamd" 1; then
        CLAMD_PID=""

        warn "Retrying clamd via init script or daemon mode..."

        if [ -x /etc/init.d/clamav-daemon ]; then
          /etc/init.d/clamav-daemon start || warn "Could not start clamav-daemon."
        else
          clamd || warn "Could not start clamd daemon."
        fi

        if read_pidfile /run/clamav/clamd.pid /var/run/clamav/clamd.pid; then
          CLAMD_PID="$REPLY"
        fi
      fi
    fi
  else
    warn "CLAMAV=Y but clamd binary not found."
  fi
fi

# Wait for clamd socket before starting pmg-smtp-filter.
#
# Starting clamd is not enough. PMG virus scanning needs the local socket
# from /etc/clamav/clamd.conf.
CLAMD_SOCKET=""

if is_enabled "$CLAMAV" && [ -f /etc/clamav/clamd.conf ]; then
  CLAMD_SOCKET="$(awk '$1 == "LocalSocket" { print $2 }' /etc/clamav/clamd.conf 2>/dev/null | tail -n1)"
fi

CLAMD_SOCKET="${CLAMD_SOCKET:-/run/clamav/clamd.ctl}"

if is_enabled "$CLAMAV" && [ -n "${CLAMD_PID:-}" ]; then
  echo "Waiting for clamd socket..."

  for _ in $(seq 1 60); do
    [ -S "$CLAMD_SOCKET" ] && break

    if ! process_alive "$CLAMD_PID"; then
      warn "clamd exited before creating socket."
      CLAMD_PID=""
      break
    fi

    sleep 1
  done

  if [ -n "${CLAMD_PID:-}" ] && [ ! -S "$CLAMD_SOCKET" ]; then
    warn "clamd socket was not created: $CLAMD_SOCKET"
  fi
fi

# Test clamd health.
if is_enabled "$CLAMAV" && [ -n "${CLAMD_PID:-}" ] && command -v clamdscan >/dev/null 2>&1; then
  if ! clamdscan --no-summary /etc/hosts >/dev/null 2>&1; then
    warn "clamdscan test failed. Virus scanning may not work."
  fi
fi

# Start Postfix
echo "Starting Postfix..."
/etc/init.d/postfix start || :
POSTFIX_PID=""

if [ -f /var/spool/postfix/pid/master.pid ]; then
  read -r POSTFIX_PID < /var/spool/postfix/pid/master.pid
fi

# Start fetchmail, if enabled.
#
# This is only needed if you configured PMG to fetch mail from remote POP/IMAP
# accounts. Normal SMTP gateway usage does not need fetchmail.
FETCHMAIL_PID=""

if is_enabled "$FETCHMAIL"; then
  if command -v fetchmail >/dev/null 2>&1; then
    echo "Starting fetchmail..."

    mkdir -p /run/fetchmail
    chown fetchmail:nogroup /run/fetchmail 2>/dev/null || :

    if [ -x /etc/init.d/fetchmail ]; then
      /etc/init.d/fetchmail start || warn "Could not start fetchmail."
    else
      fetchmail -d 300 -f /etc/fetchmailrc || warn "Could not start fetchmail."
    fi

    if read_pidfile /run/fetchmail/fetchmail.pid /var/run/fetchmail/fetchmail.pid; then
      FETCHMAIL_PID="$REPLY"
    fi
  else
    warn "FETCHMAIL=Y but fetchmail binary not found."
  fi
fi

# Start supercronic
echo "Starting supercronic..."

cat >/docker.cron <<'EOF'
# Run PMG hourly maintenance
0 * * * * /usr/bin/pmg-hourly

# Send daily administrator system report
1 0 * * * /usr/bin/pmgreport --timespan yesterday --auto

# Send daily user spam report mails and purge quarantine
5 0 * * * /usr/bin/pmgqm purge; /usr/bin/pmgqm send --timespan yesterday

# Run PMG daily maintenance
30 3 * * * /usr/bin/pmg-daily
EOF

supercronic -quiet -no-reap /docker.cron &
CRON_PID=$!

# Trap helper
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
  [[ "${BASHPID:-}" != "${TRAP_PID:-}" ]] && return 0

  touch /proxmox.end
  echo "Shutting down PMG services..."

  pids=(
    "${PMGDAEMON_PID:-}"
    "${PMGPROXY_PID:-}"
    "${PMGSMTPFILTER_PID:-}"
    "${PMGPOLICY_PID:-}"
    "${PMGMIRROR_PID:-}"
    "${PMGTUNNEL_PID:-}"
    "${FETCHMAIL_PID:-}"
    "${CLAMD_PID:-}"
    "${FRESHCLAM_PID:-}"
    "${CRON_PID:-}"
    "${POSTFIX_PID:-}"
    "${RSYSLOG_PID:-}"
    "${TAIL_PID:-}"
  )

  # Ask PMG daemons to stop using their own commands when possible.
  pmgproxy stop 2>/dev/null || :
  pmgdaemon stop 2>/dev/null || :
  pmg-smtp-filter stop 2>/dev/null || :
  pmgpolicy stop 2>/dev/null || :
  pmgmirror stop 2>/dev/null || :
  pmgtunnel stop 2>/dev/null || :

  # Stop optional non-PMG services cleanly when init scripts are available.
  /etc/init.d/fetchmail stop 2>/dev/null || :
  /etc/init.d/clamav-daemon stop 2>/dev/null || :
  /etc/init.d/clamav-freshclam stop 2>/dev/null || :

  # Send SIGTERM to tracked processes.
  for pid in "${pids[@]}"; do
    [[ -z "${pid:-}" ]] && continue
    kill -0 "$pid" 2>/dev/null || continue
    kill -TERM "$pid" 2>/dev/null || :
  done

  /etc/init.d/postfix stop 2>/dev/null || :
  pg_ctlcluster "$PG_VERSION" "$PG_CLUSTER" stop 2>/dev/null || :
  /etc/init.d/postgresql stop 2>/dev/null || :

  # Wait for processes.
  for pid in "${pids[@]}"; do
    [[ -z "${pid:-}" ]] && continue
    kill -0 "$pid" 2>/dev/null || continue
    wait "$pid" 2>/dev/null || :
  done

  echo ""
  echo "Shutdown completed successfully."
  exit 0
}

# Init trap
rm -f /proxmox.end
_trap cleanup SIGTERM SIGINT

# Start PMG services without systemd.
#
# The normal "start" mode tries to use systemctl in a real PMG install.
# Debug mode keeps the daemons in the foreground, so Docker can track them.
echo "Starting pmgdaemon..."
pmgdaemon start --debug 1 &
PMGDAEMON_PID=$!
wait_process_alive "$PMGDAEMON_PID" "pmgdaemon" 1 || cleanup

echo "Starting pmgproxy..."
pmgproxy start --debug 1 &
PMGPROXY_PID=$!
wait_process_alive "$PMGPROXY_PID" "pmgproxy" 1 || cleanup

echo "Starting pmg-smtp-filter..."
pmg-smtp-filter start

for _ in $(seq 1 30); do
  if ss -ltn | grep -qE '127\.0\.0\.1:1002[34][[:space:]]'; then
    break
  fi
  sleep 1
done

if ! ss -ltn | grep -qE '127\.0\.0\.1:1002[34][[:space:]]'; then
  warn "pmg-smtp-filter does not appear to be listening on ports 10023/10024."
  cleanup
fi

echo "Starting pmgpolicy..."
pmgpolicy start

for _ in $(seq 1 30); do
  if ss -ltn | grep -q '127.0.0.1:10022'; then
    break
  fi
  sleep 1
done

if ! ss -ltn | grep -q '127.0.0.1:10022'; then
  warn "pmgpolicy does not appear to be listening on port 10022."
  cleanup
fi

PMGMIRROR_PID=""

if is_enabled "$PMGMIRROR"; then
  echo "Starting pmgmirror..."
  pmgmirror start --debug 1 &
  PMGMIRROR_PID=$!

  if ! wait_process_alive "$PMGMIRROR_PID" "pmgmirror" 1; then
    warn "pmgmirror exited. Continuing because PMGMIRROR is optional."
    PMGMIRROR_PID=""
  fi
fi

PMGTUNNEL_PID=""

if is_enabled "$PMGTUNNEL"; then
  echo "Starting pmgtunnel..."
  pmgtunnel start --debug 1 &
  PMGTUNNEL_PID=$!

  if ! wait_process_alive "$PMGTUNNEL_PID" "pmgtunnel" 1; then
    warn "pmgtunnel exited. Continuing because PMGTUNNEL is optional."
    PMGTUNNEL_PID=""
  fi
fi

# Final readiness check.
#
# This does not hard-fail the container, but gives clear diagnostics.
echo "Checking Mail Gateway readiness..."

if command -v ss >/dev/null 2>&1; then
  for _ in $(seq 1 60); do
    if ss -ltn | grep -q ':8006 '; then
      break
    fi
    sleep 1
  done

  if ! ss -ltn | grep -q ':8006 '; then
    warn "PMG web interface does not appear to be listening on port 8006."
  fi

  if ! ss -ltn | grep -q ':25 '; then
    warn "Postfix does not appear to be listening on port 25."
  fi
else
  warn "Cannot run readiness port checks because 'ss' is not installed."
fi

echo ""
info "------------------------------------------------------------------------------"
info ""
info ". Welcome to the Proxmox Mail Gateway v$(</etc/version). Connect your web browser to:"
info ""
info ".   https://127.0.0.1:${PORT:-8006}"
info ""
info "------------------------------------------------------------------------------"
info ""
echo ""

# Wait for processes.
# Do not use "pmgdaemon status" here because that may call systemd.
while true; do
  sleep 5

  # Required PMG processes.
  process_alive "$PMGDAEMON_PID" || break
  process_alive "$PMGPROXY_PID" || break
  ss -ltn | grep -qE '127\.0\.0\.1:1002[34][[:space:]]' || break
  ss -ltn | grep -q '127.0.0.1:10022' || break

  # ClamAV is important when enabled. If clamd dies, virus scanning is broken.
  if [ -n "${CLAMD_PID:-}" ]; then
    process_alive "$CLAMD_PID" || break
  fi

  # Optional services should not necessarily kill the whole container.
  if [ -n "${FRESHCLAM_PID:-}" ]; then
    if ! process_alive "$FRESHCLAM_PID"; then
      warn "freshclam exited. Virus definitions will no longer update."
      FRESHCLAM_PID=""
    fi
  fi

  if [ -n "${FETCHMAIL_PID:-}" ]; then
    if ! process_alive "$FETCHMAIL_PID"; then
      warn "fetchmail exited. Continuing because FETCHMAIL is optional."
      FETCHMAIL_PID=""
    fi
  fi

  if [ -n "${PMGMIRROR_PID:-}" ]; then
    if ! process_alive "$PMGMIRROR_PID"; then
      warn "pmgmirror exited. Continuing because PMGMIRROR is optional."
      PMGMIRROR_PID=""
    fi
  fi

  if [ -n "${PMGTUNNEL_PID:-}" ]; then
    if ! process_alive "$PMGTUNNEL_PID"; then
      warn "pmgtunnel exited. Continuing because PMGTUNNEL is optional."
      PMGTUNNEL_PID=""
    fi
  fi
done

info "A required PMG process exited unexpectedly. Shutting down..."
cleanup
