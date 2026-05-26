#!/usr/bin/env bash
#
# Interactive txt-dns-bridge installer for Debian 11/12/13.

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
APP_DIR="/root/txt-dns-bridge"
APP_FILE="${APP_DIR}/txt-dns-bridge.py"
SERVICE_NAME="txt-dns-bridge.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
DOWNLOAD_URL="https://raw.githubusercontent.com/wangwangbox/DebianSH/main/txt-dns-bridge.py"
DOWNLOAD_USER_AGENT="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125 Safari/537.36"

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

prompt_text() {
  local question=$1
  local default_value=${2:-}
  local answer

  if [ -n "$default_value" ]; then
    printf '%s [%s]: ' "$question" "$default_value" > /dev/tty
  else
    printf '%s: ' "$question" > /dev/tty
  fi

  IFS= read -r answer < /dev/tty || die "Failed to read input"
  printf '%s\n' "${answer:-$default_value}"
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

check_root() {
  require_command id

  if [ "$(id -u)" -eq 0 ]; then
    ok "Running as root."
    return 0
  fi

  die "Please run as root, for example: sudo bash ${0}"
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

  case "${VERSION_ID:-}" in
    11|12|13)
      ok "Detected supported system: ${PRETTY_NAME:-Debian ${VERSION_ID}}"
      ;;
    *)
      die "Unsupported Debian version: ${VERSION_ID:-unknown}. Only Debian 11, 12, and 13 are supported."
      ;;
  esac
}

check_dependencies() {
  local missing_packages=()
  local command_name

  for command_name in chmod cp date grep id install mkdir mktemp mv rm sed; do
    require_command "$command_name"
  done

  if ! have_command python3; then
    missing_packages+=(python3)
  fi

  if ! have_command curl && ! have_command wget; then
    missing_packages+=(curl)
  fi

  if [ ! -r /etc/ssl/certs/ca-certificates.crt ]; then
    missing_packages+=(ca-certificates)
  fi

  if ! have_command systemctl; then
    die "systemctl was not found. This installer requires systemd."
  fi

  install_missing_packages "${missing_packages[@]}"

  require_command python3
  [ -x /usr/bin/python3 ] || die "/usr/bin/python3 was not found or is not executable. Please install Debian's python3 package."

  if ! have_command curl && ! have_command wget; then
    die "curl or wget is required to download txt-dns-bridge.py."
  fi

  if ! systemctl --version >/dev/null 2>&1; then
    die "systemctl is present but not usable. Please run this on a systemd-based Debian host."
  fi

  ok "Required tools are available."
}

validate_bridge_script() {
  [ -f "$APP_FILE" ] || die "Missing script file: ${APP_FILE}"
  run_cmd /usr/bin/python3 -m py_compile "$APP_FILE"
  ok "Python syntax check passed: ${APP_FILE}"
}

self_encoding_check() {
  local file=$1
  local pattern
  pattern="$(printf '\303|\346|\345|\342\200\246')"
  if LC_ALL=C grep -nE "$pattern" "$file" >/tmp/txt_dns_bridge_mojibake_check.$$ 2>/dev/null; then
    cat /tmp/txt_dns_bridge_mojibake_check.$$ >&2 || true
    rm -f /tmp/txt_dns_bridge_mojibake_check.$$
    die "Mojibake-like bytes found in ${file}; stop before continuing."
  fi
  rm -f /tmp/txt_dns_bridge_mojibake_check.$$ 2>/dev/null || true
}

download_url() {
  local url=$1
  local output=$2

  if have_command curl; then
    log "Downloading with curl: ${url}"
    curl -fL --retry 3 --connect-timeout 15 -A "$DOWNLOAD_USER_AGENT" -o "$output" "$url"
    return $?
  fi

  if have_command wget; then
    log "Downloading with wget: ${url}"
    wget --tries=3 --timeout=15 --user-agent="$DOWNLOAD_USER_AGENT" -O "$output" "$url"
    return $?
  fi

  return 1
}

prepare_app_dir() {
  run_cmd as_root mkdir -p "$APP_DIR"
  run_cmd as_root chmod 700 "$APP_DIR"
}

download_bridge_script() {
  local tmp_file
  tmp_file="$(mktemp)"

  if download_url "$DOWNLOAD_URL" "$tmp_file"; then
    run_cmd as_root install -m 0755 "$tmp_file" "$APP_FILE"
    rm -f "$tmp_file"
    ok "Downloaded txt-dns-bridge.py to ${APP_FILE}"
    return 0
  fi

  rm -f "$tmp_file"
  warn "Automatic download failed."
  printf '\nPlease manually upload the file as:\n  %s\n\n' "$APP_FILE" > /dev/tty

  while [ ! -f "$APP_FILE" ]; do
    prompt_yes_no "Continue after txt-dns-bridge.py has been uploaded?" "y" || die "txt-dns-bridge.py is required to continue."
    [ -f "$APP_FILE" ] || warn "Still not found: ${APP_FILE}"
  done

  run_cmd as_root chmod 755 "$APP_FILE"
  ok "Found manually uploaded script: ${APP_FILE}"
}

prompt_domains() {
  local domains

  while true; do
    domains="$(prompt_text "Enter comma-separated domain suffixes for --domains" "windowsupdate.io")"
    domains="$(printf '%s' "$domains" | sed 's/[[:space:]]//g')"

    if [ -z "$domains" ]; then
      warn "Domains cannot be empty."
      continue
    fi

    if printf '%s\n' "$domains" | grep -Eq '^[A-Za-z0-9_.-]+(,[A-Za-z0-9_.-]+)*$'; then
      printf '%s\n' "$domains"
      return 0
    fi

    warn "Invalid domains. Use comma-separated domain suffixes without spaces, for example: example.com,sub.example.net"
  done
}

write_service_file() {
  local domains=$1
  local enable_logs=$2
  local tmp_service

  tmp_service="$(mktemp)"

  {
    printf '%s\n' "[Unit]"
    printf '%s\n' "Description=txt-dns-bridge"
    printf '%s\n' "After=network.target"
    printf '%s\n'
    printf '%s\n' "[Service]"
    printf '%s\n' "Type=simple"
    printf '%s\n' "User=root"
    printf '%s\n' "WorkingDirectory=/root/txt-dns-bridge"
    printf '%s\n' "ExecStart=/usr/bin/python3 /root/txt-dns-bridge/txt-dns-bridge.py --domains ${domains}"
    printf '%s\n' "Restart=always"
    printf '%s\n' "RestartSec=10"
    if [ "$enable_logs" = "yes" ]; then
      printf '%s\n' "StandardOutput=append:/root/txt-dns-bridge/txt-dns-bridge.output.log"
      printf '%s\n' "StandardError=append:/root/txt-dns-bridge/txt-dns-bridge.error.log"
    fi
    printf '%s\n'
    printf '%s\n' "Environment=PYTHONUNBUFFERED=1"
    printf '%s\n'
    printf '%s\n' "[Install]"
    printf '%s\n' "WantedBy=multi-user.target"
  } > "$tmp_service"

  if [ -f "$SERVICE_FILE" ]; then
    if prompt_yes_no "Existing ${SERVICE_FILE} found. Back it up and overwrite?" "y"; then
      run_cmd as_root cp "$SERVICE_FILE" "${SERVICE_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    else
      rm -f "$tmp_service"
      die "Service file already exists. Aborted by user."
    fi
  fi

  run_cmd as_root mv "$tmp_service" "$SERVICE_FILE"
  run_cmd as_root chmod 644 "$SERVICE_FILE"
  ok "Wrote systemd service: ${SERVICE_FILE}"
}

start_and_check_service() {
  run_cmd as_root systemctl daemon-reload
  run_cmd as_root systemctl enable "$SERVICE_NAME"
  run_cmd as_root systemctl start "$SERVICE_NAME"

  if systemctl is-active --quiet "$SERVICE_NAME"; then
    ok "${SERVICE_NAME} is running."
  else
    warn "${SERVICE_NAME} did not report active status. Showing status for troubleshooting."
  fi

  as_root systemctl status "$SERVICE_NAME" --no-pager
}

main() {
  local domains
  local log_choice

  printf '%s%s%s\n' "$BOLD" "$SCRIPT_NAME" "$RESET"
  printf 'Interactive txt-dns-bridge installer for Debian 11/12/13.\n\n'

  self_encoding_check "$0"
  check_root
  check_debian_version
  check_dependencies
  prepare_app_dir
  download_bridge_script
  validate_bridge_script
  domains="$(prompt_domains)"

  if prompt_yes_no "Enable systemd append logs in /root/txt-dns-bridge/? Default is no." "n"; then
    log_choice="yes"
  else
    log_choice="no"
  fi

  write_service_file "$domains" "$log_choice"
  start_and_check_service
}

main "$@"
