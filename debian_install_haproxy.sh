#!/usr/bin/env bash
#
# Interactive HAProxy installer for Debian 11/12/13.

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
KEYRING_DIR="/usr/share/keyrings"
KEYRING_FILE="${KEYRING_DIR}/haproxy-debian-net.gpg"
KEY_URL="https://haproxy.debian.net/bernat.debian.org.gpg"
SOURCE_FILE="/etc/apt/sources.list.d/haproxy.list"
CERT_DIR="/etc/haproxy/certs"
CERT_FILE="${CERT_DIR}/server.pem"
CONFIG_FILE="/etc/haproxy/haproxy.cfg"
DOWNLOAD_USER_AGENT="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125 Safari/537.36"

DEBIAN_VERSION_ID=""
DEBIAN_PRETTY_NAME=""
HAPROXY_SUITE=""
HAPROXY_SERIES=""

RED=""
GREEN=""
YELLOW=""
BLUE=""
BOLD=""
RESET=""

if [ -t 1 ]; then
  RED="$(printf '\033[31m')"
  GREEN="$(printf '\033[32m')"
  YELLOW="$(printf '\033[33m')"
  BLUE="$(printf '\033[34m')"
  BOLD="$(printf '\033[1m')"
  RESET="$(printf '\033[0m')"
fi

log() {
  printf '%s[INFO]%s %s\n' "$BLUE" "$RESET" "$*" >&2
}

ok() {
  printf '%s[ OK ]%s %s\n' "$GREEN" "$RESET" "$*" >&2
}

warn() {
  printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*" >&2
}

die() {
  printf '%s[FAIL]%s %s\n' "$RED" "$RESET" "$*" >&2
  exit 1
}

on_error() {
  local exit_code=$?
  local line_no=${1:-unknown}
  printf '%s[FAIL]%s Command failed near line %s with exit code %s.\n' "$RED" "$RESET" "$line_no" "$exit_code" >&2
  printf '%s[FAIL]%s Review the command output above. No automatic rollback was performed.\n' "$RED" "$RESET" >&2
  exit "$exit_code"
}

trap 'on_error "$LINENO"' ERR

run_cmd() {
  log "Running: $*"
  "$@"
  ok "Finished: $*"
}

prompt_yes_no() {
  local question=$1
  local default_answer=${2:-n}
  local prompt
  local answer

  case "$default_answer" in
    y|Y) prompt="[Y/n]" ;;
    n|N) prompt="[y/N]" ;;
    *) die "Invalid default for prompt_yes_no: ${default_answer}" ;;
  esac

  while true; do
    printf '%s %s ' "$question" "$prompt" > /dev/tty
    IFS= read -r answer < /dev/tty || die "Failed to read input"
    answer=${answer:-$default_answer}
    case "$answer" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
      *) warn "Please answer y or n." ;;
    esac
  done
}

prompt_enter() {
  local message=$1
  local answer

  printf '%s ' "$message" > /dev/tty
  IFS= read -r answer < /dev/tty || die "Failed to read input"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

have_command() {
  command -v "$1" >/dev/null 2>&1
}

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

check_root_or_sudo() {
  require_command id

  if [ "$(id -u)" -eq 0 ]; then
    ok "Running as root."
    return 0
  fi

  require_command sudo
  if sudo -v; then
    ok "sudo access confirmed."
    return 0
  fi

  die "Please run as root or with a user that has sudo permission, for example: sudo bash ${SCRIPT_NAME}"
}

install_missing_packages() {
  local missing_packages=("$@")

  [ "${#missing_packages[@]}" -gt 0 ] || return 0
  warn "Missing required packages: ${missing_packages[*]}"

  if ! have_command apt-get; then
    die "apt-get was not found. Please install these packages manually: ${missing_packages[*]}"
  fi

  if prompt_yes_no "Install missing packages with apt-get now?" "y"; then
    run_cmd as_root apt-get update
    run_cmd as_root apt-get install -y "${missing_packages[@]}"
  else
    die "Cannot continue without required packages: ${missing_packages[*]}"
  fi
}

check_debian_version() {
  [ -r /etc/os-release ] || die "/etc/os-release not found. This installer only supports Debian 11/12/13."

  # shellcheck disable=SC1091
  . /etc/os-release
  [ "${ID:-}" = "debian" ] || die "Unsupported OS: ${PRETTY_NAME:-unknown}. This installer only supports Debian."

  DEBIAN_VERSION_ID="${VERSION_ID:-}"
  DEBIAN_PRETTY_NAME="${PRETTY_NAME:-Debian ${DEBIAN_VERSION_ID}}"

  case "$DEBIAN_VERSION_ID" in
    11)
      HAPROXY_SUITE="bullseye-backports-3.1"
      HAPROXY_SERIES="3.1"
      ;;
    12)
      HAPROXY_SUITE="bookworm-backports-3.2"
      HAPROXY_SERIES="3.2"
      ;;
    13)
      HAPROXY_SUITE="trixie-backports-3.2"
      HAPROXY_SERIES="3.2"
      ;;
    *)
      die "Unsupported Debian version: ${DEBIAN_VERSION_ID:-unknown}. Only Debian 11, 12, and 13 are supported."
      ;;
  esac

  ok "Detected supported system: ${DEBIAN_PRETTY_NAME}"
  ok "Selected HAProxy repository suite: ${HAPROXY_SUITE}"
}

check_dependencies() {
  local missing_packages=()
  local command_name

  for command_name in awk chmod grep head id install mkdir mktemp rm sed sort tee; do
    require_command "$command_name"
  done

  if ! have_command apt-get; then
    die "apt-get was not found. This installer requires Debian APT."
  fi

  if ! have_command curl; then
    missing_packages+=(curl)
  fi

  if ! have_command gpg; then
    missing_packages+=(gnupg)
  fi

  if ! have_command openssl; then
    missing_packages+=(openssl)
  fi

  if [ ! -r /etc/ssl/certs/ca-certificates.crt ]; then
    missing_packages+=(ca-certificates)
  fi

  if ! have_command systemctl; then
    die "systemctl was not found. This installer requires systemd."
  fi

  install_missing_packages "${missing_packages[@]}"

  for command_name in curl gpg openssl systemctl; do
    require_command "$command_name"
  done

  if ! systemctl --version >/dev/null 2>&1; then
    die "systemctl is present but not usable. Please run this on a systemd-based Debian host."
  fi

  ok "Required tools are available."
}

setup_haproxy_repository() {
  local key_tmp
  local gpg_tmp
  local source_tmp
  local source_line

  key_tmp="$(mktemp)"
  gpg_tmp="$(mktemp)"
  source_tmp="$(mktemp)"

  log "Creating keyring directory: ${KEYRING_DIR}"
  run_cmd as_root mkdir -p "$KEYRING_DIR"

  log "Downloading HAProxy Debian repository key."
  run_cmd curl -fsSL --retry 3 --connect-timeout 15 -A "$DOWNLOAD_USER_AGENT" -o "$key_tmp" "$KEY_URL"
  run_cmd gpg --batch --yes --dearmor -o "$gpg_tmp" "$key_tmp"
  run_cmd as_root install -m 0644 "$gpg_tmp" "$KEYRING_FILE"

  source_line="deb [signed-by=${KEYRING_FILE}] https://haproxy.debian.net ${HAPROXY_SUITE} main"
  printf '%s\n' "$source_line" > "$source_tmp"
  run_cmd as_root install -m 0644 "$source_tmp" "$SOURCE_FILE"
  ok "APT source written: ${SOURCE_FILE}"

  rm -f "$key_tmp" "$gpg_tmp" "$source_tmp"
}

update_apt_indexes() {
  run_cmd as_root apt-get update
}

select_haproxy_version() {
  local versions=()
  local default_index=0
  local selected=""
  local i
  local version

  mapfile -t versions < <(apt-cache madison haproxy | awk '{print $3}' | sort -Vr)
  [ "${#versions[@]}" -gt 0 ] || die "No HAProxy package versions were found by apt-cache."

  for i in "${!versions[@]}"; do
    version="${versions[$i]}"
    case "$version" in
      ${HAPROXY_SERIES}.*)
        default_index="$i"
        break
        ;;
    esac
  done

  printf '\nAvailable HAProxy package versions:\n' > /dev/tty
  for i in "${!versions[@]}"; do
    if [ "$i" -eq "$default_index" ]; then
      printf '  %s) %s  [default latest LTS series %s]\n' "$((i + 1))" "${versions[$i]}" "$HAPROXY_SERIES" > /dev/tty
    else
      printf '  %s) %s\n' "$((i + 1))" "${versions[$i]}" > /dev/tty
    fi
  done

  while true; do
    printf 'Select a HAProxy version [default: %s]: ' "$((default_index + 1))" > /dev/tty
    IFS= read -r selected < /dev/tty || die "Failed to read input"
    selected=${selected:-$((default_index + 1))}
    case "$selected" in
      ''|*[!0-9]*) warn "Please enter a number." ;;
      *)
        if [ "$selected" -ge 1 ] && [ "$selected" -le "${#versions[@]}" ]; then
          printf '%s\n' "${versions[$((selected - 1))]}"
          return 0
        fi
        warn "Selection out of range."
        ;;
    esac
  done
}

install_haproxy() {
  local selected_version=$1

  log "Installing HAProxy version: ${selected_version}"
  run_cmd as_root apt-get install -y "haproxy=${selected_version}"
  ok "HAProxy installed."
}

create_self_signed_certificate() {
  log "Creating certificate directory: ${CERT_DIR}"
  run_cmd as_root mkdir -p "$CERT_DIR"

  if [ -f "$CERT_FILE" ]; then
    if prompt_yes_no "Certificate already exists at ${CERT_FILE}. Replace it?" "n"; then
      run_cmd as_root openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 -keyout "$CERT_FILE" -out "$CERT_FILE" -subj "/C=US/ST=NY/L=New York/O=localhost/OU=IT/CN=127.0.0.1"
      run_cmd as_root chmod 600 "$CERT_FILE"
    else
      ok "Keeping existing certificate: ${CERT_FILE}"
    fi
  else
    run_cmd as_root openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 -keyout "$CERT_FILE" -out "$CERT_FILE" -subj "/C=US/ST=NY/L=New York/O=localhost/OU=IT/CN=127.0.0.1"
    run_cmd as_root chmod 600 "$CERT_FILE"
  fi

  as_root grep -q "BEGIN CERTIFICATE" "$CERT_FILE" || die "Certificate file does not contain a certificate: ${CERT_FILE}"
  as_root grep -q "PRIVATE KEY" "$CERT_FILE" || warn "Private key marker was not found in ${CERT_FILE}; verify the certificate manually before TLS use."
  ok "Self-signed certificate is ready: ${CERT_FILE}"
}

enable_haproxy_service() {
  run_cmd as_root systemctl enable haproxy
}

wait_for_manual_config_upload() {
  printf '\nPlease manually upload or edit your HAProxy configuration now:\n' > /dev/tty
  printf '  %s\n' "$CONFIG_FILE" > /dev/tty
  printf 'The installer will validate this file before starting HAProxy.\n\n' > /dev/tty

  while true; do
    prompt_enter "Press Enter after ${CONFIG_FILE} is ready, or press Ctrl+C to stop."
    if [ -f "$CONFIG_FILE" ]; then
      ok "Configuration file found: ${CONFIG_FILE}"
      return 0
    fi
    warn "Configuration file not found: ${CONFIG_FILE}"
  done
}

validate_haproxy_config() {
  require_command haproxy
  run_cmd as_root haproxy -c -f "$CONFIG_FILE"
  ok "HAProxy configuration validation passed."
}

start_and_check_haproxy() {
  run_cmd as_root systemctl start haproxy

  if as_root systemctl is-active --quiet haproxy; then
    ok "HAProxy is running."
  else
    as_root systemctl status haproxy --no-pager || true
    die "HAProxy is not running."
  fi

  run_cmd as_root systemctl status haproxy --no-pager
}

main() {
  local selected_version

  check_root_or_sudo
  check_debian_version
  check_dependencies
  setup_haproxy_repository
  update_apt_indexes
  selected_version="$(select_haproxy_version)"
  install_haproxy "$selected_version"
  create_self_signed_certificate
  enable_haproxy_service
  wait_for_manual_config_upload
  validate_haproxy_config
  start_and_check_haproxy

  ok "HAProxy deployment completed successfully."
}

main "$@"
