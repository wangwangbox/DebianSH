#!/usr/bin/env bash
#
# Interactive GOST v3 installer for Debian 11/12/13.

set -Eeuo pipefail

GOST_DIR="/root/gost"
GOST_BIN="/usr/local/bin/gostv3"
SERVICE_FILE="/etc/systemd/system/gostv3.service"
GITHUB_API_LATEST="https://api.github.com/repos/go-gost/gost/releases/latest"
GITHUB_API_RELEASES="https://api.github.com/repos/go-gost/gost/releases"
GITHUB_RELEASES_URL="https://github.com/go-gost/gost/releases"
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

  for command_name in awk basename chmod cp date grep head id mkdir mktemp mv rm sed uname; do
    require_command "$command_name"
  done

  if ! have_command curl && ! have_command wget; then
    missing_packages+=(curl)
  fi

  if [ ! -r /etc/ssl/certs/ca-certificates.crt ]; then
    missing_packages+=(ca-certificates)
  fi

  if ! have_command openssl; then
    missing_packages+=(openssl)
  fi

  if ! have_command tar; then
    missing_packages+=(tar)
  fi

  if ! have_command systemctl; then
    die "systemctl was not found. This installer requires systemd."
  fi

  install_missing_packages "${missing_packages[@]}"

  for command_name in curl openssl tar; do
    if [ "$command_name" = "curl" ] && have_command wget; then
      continue
    fi
    require_command "$command_name"
  done

  if ! systemctl --version >/dev/null 2>&1; then
    die "systemctl is present but not usable. Please run this on a systemd-based Debian host."
  fi

  ok "Required tools are available."
}

detect_asset_arch() {
  local machine
  machine="$(uname -m)"

  case "$machine" in
    x86_64|amd64)
      if prompt_yes_no "Use amd64v3 optimized GOST binary? Default is no, use regular amd64 for maximum compatibility." "n"; then
        printf '%s\n' "amd64v3"
      else
        printf '%s\n' "amd64"
      fi
      ;;
    aarch64|arm64)
      printf '%s\n' "arm64"
      ;;
    armv7l|armv7*)
      printf '%s\n' "armv7"
      ;;
    armv6l|armv6*)
      printf '%s\n' "armv6"
      ;;
    i386|i686)
      printf '%s\n' "386"
      ;;
    *)
      die "Unsupported architecture from uname -m: ${machine}"
      ;;
  esac
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

fetch_release_json() {
  local output=$1
  local allow_prerelease=$2

  if [ "$allow_prerelease" = "yes" ]; then
    download_url "$GITHUB_API_RELEASES" "$output"
  else
    download_url "$GITHUB_API_LATEST" "$output"
  fi
}

parse_release_tag() {
  local json_file=$1
  sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$json_file" | head -n 1
}

is_ignored_prerelease_tag() {
  case "$1" in
    v3.2.7-nightly.20260529|v3.2.7-nightly.20260531|v3.2.6|v3.2.7-nightly.20260605|v3.2.7-nightly.20260606|v3.2.7-nightly.20260619)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

parse_asset_url() {
  local json_file=$1
  local asset_arch=$2
  local asset_url
  local release_tag

  while IFS= read -r asset_url; do
    [ -n "$asset_url" ] || continue
    release_tag="$(parse_release_tag_from_url "$asset_url")"
    if is_ignored_prerelease_tag "$release_tag"; then
      warn "Ignoring pre-release: ${release_tag}"
      continue
    fi
    printf '%s\n' "$asset_url"
    return 0
  done <<EOF
$(sed -n 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*gost_[^"]*_linux_'"${asset_arch}"'\.tar\.gz\)".*/\1/p' "$json_file")
EOF
}

parse_release_tag_from_url() {
  local asset_url=$1

  printf '%s\n' "$asset_url" | sed -n 's#.*/download/\([^/]*\)/.*#\1#p'
}

manual_upload_prompt() {
  local asset_arch=$1
  local uploaded_file

  warn "Automatic download failed."
  printf '\nPlease manually download the matching linux_%s tar.gz from:\n  %s\n' "$asset_arch" "$GITHUB_RELEASES_URL" > /dev/tty
  printf 'Upload or copy it into:\n  %s/\n\n' "$GOST_DIR" > /dev/tty

  while true; do
    uploaded_file="$(prompt_text "Enter uploaded file path" "${GOST_DIR}/gost_xxx_linux_${asset_arch}.tar.gz")"
    if [ -f "$uploaded_file" ]; then
      printf '%s\n' "$uploaded_file"
      return 0
    fi
    warn "File not found: ${uploaded_file}"
    prompt_yes_no "Try another path?" "y" || die "GOST archive is required to continue."
  done
}

prepare_gost_dir() {
  run_cmd as_root mkdir -p "$GOST_DIR"
}

stop_existing_gost_service() {
  if systemctl is-active --quiet gostv3; then
    warn "Existing gostv3 service is running. Stopping it before install."
    run_cmd as_root systemctl stop gostv3
  fi
}

download_gost_archive() {
  local asset_arch=$1
  local allow_prerelease=$2
  local tmp_json
  local release_tag
  local asset_url
  local output_file

  tmp_json="$(mktemp)"

  if fetch_release_json "$tmp_json" "$allow_prerelease"; then
    release_tag="$(parse_release_tag "$tmp_json")"
    asset_url="$(parse_asset_url "$tmp_json" "$asset_arch")"

    [ -n "$release_tag" ] || warn "Could not parse release tag from GitHub API response."
    [ -n "$asset_url" ] || warn "Could not find linux_${asset_arch}.tar.gz asset in selected release data."

    if [ -n "$asset_url" ]; then
      release_tag="$(parse_release_tag_from_url "$asset_url")"
      output_file="${GOST_DIR}/$(basename "$asset_url")"
      log "Selected release: ${release_tag:-unknown}"
      if download_url "$asset_url" "$output_file"; then
        ok "GOST archive downloaded: ${output_file}"
        rm -f "$tmp_json"
        printf '%s\n' "$output_file"
        return 0
      fi
    fi
  fi

  rm -f "$tmp_json"
  manual_upload_prompt "$asset_arch"
}

extract_and_install_gost() {
  local archive_file=$1

  [ -f "$archive_file" ] || die "Archive not found: ${archive_file}"
  run_cmd as_root tar -C "$GOST_DIR" -xzf "$archive_file"
  [ -f "${GOST_DIR}/gost" ] || die "Extracted archive did not contain ${GOST_DIR}/gost"
  run_cmd as_root mv "${GOST_DIR}/gost" "$GOST_BIN"
  run_cmd as_root chmod +x "$GOST_BIN"
  ok "Installed GOST binary to ${GOST_BIN}"
}

generate_certificates() {
  run_cmd as_root openssl req -newkey rsa:2048 -nodes \
    -keyout "${GOST_DIR}/key.pem" \
    -x509 -days 3650 \
    -out "${GOST_DIR}/cert.pem" \
    -subj "/C=CN/ST=GD/L=SZ/O=localhost/CN=localhost"
}

wait_for_uploaded_certificates() {
  printf '\nPlease upload existing certificate files to:\n  %s/cert.pem\n  %s/key.pem\n' "$GOST_DIR" "$GOST_DIR" > /dev/tty

  while true; do
    prompt_yes_no "Continue after cert.pem and key.pem are ready?" "y" || die "cert.pem and key.pem are required to continue."
    if [ -f "${GOST_DIR}/cert.pem" ] && [ -f "${GOST_DIR}/key.pem" ]; then
      ok "Found existing certificate files."
      return 0
    fi

    [ -f "${GOST_DIR}/cert.pem" ] || warn "Still not found: ${GOST_DIR}/cert.pem"
    [ -f "${GOST_DIR}/key.pem" ] || warn "Still not found: ${GOST_DIR}/key.pem"
  done
}

prepare_certificates() {
  if prompt_yes_no "Upload existing cert.pem and key.pem? Choose no to generate new self-signed certificates. Default is yes." "y"; then
    wait_for_uploaded_certificates
  else
    generate_certificates
  fi
}

write_service_file() {
  local enable_logs=$1
  local tmp_service

  tmp_service="$(mktemp)"

  {
    printf '%s\n' "[Unit]"
    printf '%s\n' "Description=GO-GOSTV3 Proxy Service"
    printf '%s\n' "After=network.target"
    printf '%s\n'
    printf '%s\n' "[Service]"
    printf '%s\n' "Type=simple"
    printf '%s\n' "User=root"
    printf '%s\n' 'ExecStart=/usr/local/bin/gostv3 -C /root/gost/gost.json -api "gost:xxoogost@:53333?pathPrefix=/api&accesslog=true"'
    printf '%s\n' "Restart=always"
    printf '%s\n' "RestartSec=5"
    if [ "$enable_logs" = "yes" ]; then
      printf '%s\n' "StandardOutput=append:/root/gost/gost.output.log"
      printf '%s\n' "StandardError=append:/root/gost/gost.error.log"
    fi
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

wait_for_gost_json() {
  local config_file="${GOST_DIR}/gost.json"

  printf '\nPlease upload or edit gost.json at:\n  %s\n' "$config_file" > /dev/tty

  if [ ! -f "$config_file" ]; then
    warn "Default gost.json was not found. Creating an empty file first."
    run_cmd as_root touch "$config_file"
  fi

  while true; do
    prompt_yes_no "Continue after gost.json is ready?" "y" || die "gost.json is required before starting gostv3."
    if [ -f "$config_file" ]; then
      ok "Found ${config_file}"
      return 0
    fi

    warn "Still not found: ${config_file}"
    warn "Creating an empty gost.json again."
    run_cmd as_root touch "$config_file"
  done
}

main() {
  local asset_arch
  local allow_prerelease
  local archive_file
  local log_choice

  printf '%s%s%s\n' "$BOLD" "GOST v3 Debian 11/12/13 installer" "$RESET"

  check_root
  check_debian_version
  check_dependencies
  prepare_gost_dir

  asset_arch="$(detect_asset_arch)"
  if prompt_yes_no "Use pre-release GOST version when it is the newest available? Default is yes." "y"; then
    allow_prerelease="yes"
  else
    allow_prerelease="no"
  fi

  archive_file="$(download_gost_archive "$asset_arch" "$allow_prerelease")"
  stop_existing_gost_service
  extract_and_install_gost "$archive_file"
  prepare_certificates

  if prompt_yes_no "Enable systemd append logs in /root/gost/? Default is no." "n"; then
    log_choice="yes"
  else
    log_choice="no"
  fi

  write_service_file "$log_choice"
  run_cmd as_root systemctl daemon-reload
  run_cmd as_root systemctl enable gostv3
  wait_for_gost_json
  run_cmd as_root systemctl start gostv3

  if systemctl is-active --quiet gostv3; then
    ok "gostv3 is running."
  else
    warn "gostv3 did not report active status. Showing status for troubleshooting."
  fi

  as_root systemctl status gostv3 --no-pager
}

main "$@"
