#!/usr/bin/env bash
#
# Interactive AnyLink Docker installer for Debian 11/12/13.

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
TEMPLATE_URL="https://raw.githubusercontent.com/wangwangbox/DebianSH/main/AnylinkConfigUpdateTemplate.sh"
UPDATE_SCRIPT="/root/AnylinkConfigUpdate.sh"
CONF_DIR="/root/conf"
CRON_LINE="*/2 * * * * /root/AnylinkConfigUpdate.sh >> /root/conf/AnylinkConfigUpdate.log 2>&1"
DOCKER_IMAGE="bjdgyc/anylink"
CONTAINER_NAME="anylink"
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

check_root() {
  require_command id

  if [ "$(id -u)" -eq 0 ]; then
    ok "Running as root."
    return 0
  fi

  die "Please run as root, for example: sudo bash ${SCRIPT_NAME}"
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

  for command_name in awk chmod cmp cp date grep id md5sum mkdir mktemp mv rm sed sleep tail tee wc; do
    require_command "$command_name"
  done

  if ! have_command apt-get; then
    die "apt-get was not found. This installer requires Debian APT."
  fi

  if ! have_command curl; then
    missing_packages+=(curl)
  fi

  if ! have_command wget; then
    missing_packages+=(wget)
  fi

  if [ ! -r /etc/ssl/certs/ca-certificates.crt ]; then
    missing_packages+=(ca-certificates)
  fi

  if ! have_command unzip; then
    missing_packages+=(unzip)
  fi

  if ! have_command crontab; then
    missing_packages+=(cron)
  fi

  install_missing_packages "${missing_packages[@]}"

  for command_name in curl wget unzip crontab; do
    require_command "$command_name"
  done

  ok "Required tools are available."
}

download_url() {
  local url=$1
  local output=$2

  run_cmd curl -fsSL --retry 3 --connect-timeout 15 -A "$DOWNLOAD_USER_AGENT" -o "$output" "$url"
}

ensure_docker() {
  local installer

  if have_command docker; then
    ok "Docker command is already installed."
  else
    warn "Docker is not installed."
    if prompt_yes_no "Install Docker using get.docker.com now?" "y"; then
      installer="$(mktemp)"
      download_url "https://get.docker.com" "$installer"
      run_cmd as_root sh "$installer"
      rm -f "$installer"
    else
      die "Docker is required to continue."
    fi
  fi

  require_command docker

  if have_command systemctl; then
    as_root systemctl enable docker >/dev/null 2>&1 || warn "Could not enable docker with systemctl."
    as_root systemctl start docker >/dev/null 2>&1 || warn "Could not start docker with systemctl."
  fi

  if ! as_root docker info >/dev/null 2>&1; then
    die "Docker is installed, but the Docker daemon is not responding."
  fi

  ok "Docker is installed and running."
}

download_update_script() {
  local tmp_file

  tmp_file="$(mktemp)"
  download_url "$TEMPLATE_URL" "$tmp_file"
  [ -s "$tmp_file" ] || die "Downloaded update script is empty."
  run_cmd as_root mv "$tmp_file" "$UPDATE_SCRIPT"
  ok "Downloaded update script to ${UPDATE_SCRIPT}."
}

prompt_domain() {
  local domain

  while true; do
    domain="$(prompt_text "Enter the domain for AnyLink config downloads, without https:// or path")"
    case "$domain" in
      ""|*"://"*|*/*|*[[:space:]]*)
        warn "Please enter only a domain or host:port, for example vpn.example.com."
        ;;
      *)
        printf '%s\n' "$domain"
        return 0
        ;;
    esac
  done
}

replace_update_domain() {
  local domain=$1
  local escaped_domain

  [ -f "$UPDATE_SCRIPT" ] || die "Update script not found: ${UPDATE_SCRIPT}"
  escaped_domain="$(printf '%s' "$domain" | sed 's/[\/&]/\\&/g')"
  run_cmd as_root sed -i "s/windowsupdate\\.io/${escaped_domain}/g" "$UPDATE_SCRIPT"

  if as_root grep -q "windowsupdate.io" "$UPDATE_SCRIPT"; then
    die "Domain replacement did not complete in ${UPDATE_SCRIPT}."
  fi

  ok "Updated download domain in ${UPDATE_SCRIPT}."
}

validate_remote_config() {
  local domain=$1
  local profile_url="https://${domain}/conf/profile.xml"
  local cert_url="https://${domain}/conf/vpn_cert.zip"
  local profile_tmp
  local cert_tmp

  profile_tmp="$(mktemp)"
  cert_tmp="$(mktemp)"

  download_url "$profile_url" "$profile_tmp"
  [ -s "$profile_tmp" ] || die "profile.xml downloaded successfully but is empty."
  grep -q "<AnyConnectProfile" "$profile_tmp" || die "profile.xml does not contain <AnyConnectProfile."
  grep -q "</AnyConnectProfile>" "$profile_tmp" || die "profile.xml does not contain </AnyConnectProfile>."
  ok "profile.xml is reachable and passed XML content checks."

  download_url "$cert_url" "$cert_tmp"
  [ -s "$cert_tmp" ] || die "vpn_cert.zip downloaded successfully but is empty."
  run_cmd unzip -t "$cert_tmp"
  ok "vpn_cert.zip is reachable and passed zip integrity checks."

  rm -f "$profile_tmp" "$cert_tmp"
}

make_update_script_executable() {
  run_cmd as_root chmod +x "$UPDATE_SCRIPT"
  [ -x "$UPDATE_SCRIPT" ] || die "Failed to make ${UPDATE_SCRIPT} executable."
  ok "Update script is executable."
}

wait_for_conf_dir() {
  printf '\nPlease upload your conf directory to:\n  %s\n' "$CONF_DIR" > /dev/tty
  printf 'The Docker container will mount this directory as /app/conf.\n\n' > /dev/tty

  while true; do
    prompt_enter "Press Enter after ${CONF_DIR} is ready, or press Ctrl+C to stop."
    if [ -d "$CONF_DIR" ]; then
      ok "Configuration directory found: ${CONF_DIR}"
      return 0
    fi
    warn "Configuration directory not found: ${CONF_DIR}"
  done
}

ensure_cron_service() {
  if have_command systemctl; then
    as_root systemctl enable cron >/dev/null 2>&1 || warn "Could not enable cron with systemctl."
    as_root systemctl start cron >/dev/null 2>&1 || warn "Could not start cron with systemctl."

    if as_root systemctl is-active --quiet cron; then
      ok "Cron service is active."
      return 0
    fi
  fi

  if have_command pgrep && pgrep cron >/dev/null 2>&1; then
    ok "Cron process is running."
    return 0
  fi

  die "Cron service does not appear to be running."
}

install_cron_job() {
  local current_cron
  local new_cron

  current_cron="$(mktemp)"
  new_cron="$(mktemp)"

  as_root crontab -l > "$current_cron" 2>/dev/null || true
  if grep -Fqx "$CRON_LINE" "$current_cron"; then
    ok "Cron job already exists."
  else
    cp "$current_cron" "$new_cron"
    printf '%s\n' "$CRON_LINE" >> "$new_cron"
    run_cmd as_root crontab "$new_cron"
    ok "Cron job added: ${CRON_LINE}"
  fi

  rm -f "$current_cron" "$new_cron"
  as_root crontab -l | grep -Fqx "$CRON_LINE" || die "Cron job verification failed."
  run_cmd as_root touch "${CONF_DIR}/AnylinkConfigUpdate.log"
  ensure_cron_service
}

check_cron_execution() {
  local before_size
  local after_size
  local i=1

  if ! prompt_yes_no "Wait up to 150 seconds to confirm cron writes to the log?" "y"; then
    warn "Skipped timed cron execution check. Cron entry and service were verified."
    return 0
  fi

  before_size="$(wc -c < "${CONF_DIR}/AnylinkConfigUpdate.log" 2>/dev/null || printf '0')"
  log "Waiting for cron to run. This can take up to 150 seconds."

  while [ "$i" -le 15 ]; do
    sleep 10
    after_size="$(wc -c < "${CONF_DIR}/AnylinkConfigUpdate.log" 2>/dev/null || printf '0')"
    if [ "$after_size" -gt "$before_size" ]; then
      ok "Cron wrote to ${CONF_DIR}/AnylinkConfigUpdate.log."
      return 0
    fi
    i=$((i + 1))
  done

  warn "Cron did not write new log data within 150 seconds."
  warn "Showing current cron status and recent log lines for review."
  as_root crontab -l | grep -F "$UPDATE_SCRIPT" || true
  tail -n 20 "${CONF_DIR}/AnylinkConfigUpdate.log" || true
}

prompt_port() {
  local question=$1
  local default_port=$2
  local port

  while true; do
    port="$(prompt_text "$question" "$default_port")"
    case "$port" in
      ''|*[!0-9]*)
        warn "Please enter a numeric TCP/UDP port."
        ;;
      *)
        if [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
          printf '%s\n' "$port"
          return 0
        fi
        warn "Port must be between 1 and 65535."
        ;;
    esac
  done
}

remove_existing_container_if_needed() {
  if ! as_root docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
    return 0
  fi

  warn "A Docker container named ${CONTAINER_NAME} already exists."
  if prompt_yes_no "Stop and remove the existing container before creating a new one?" "y"; then
    as_root docker rm -f "$CONTAINER_NAME" >/dev/null
    ok "Removed existing container: ${CONTAINER_NAME}"
  else
    die "Cannot create a new container while ${CONTAINER_NAME} already exists."
  fi
}

run_anylink_container() {
  local https_port=$1
  local admin_port=$2

  remove_existing_container_if_needed
  run_cmd as_root docker pull "$DOCKER_IMAGE"
  run_cmd as_root docker run -itd \
    -v "${CONF_DIR}:/app/conf" \
    -p "${https_port}:443/tcp" \
    -p "${https_port}:443/udp" \
    -p "${admin_port}:8800/tcp" \
    --name "$CONTAINER_NAME" \
    --privileged \
    --restart=always \
    "$DOCKER_IMAGE"
}

check_anylink_container() {
  local running

  sleep 3
  running="$(as_root docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || printf 'false')"
  if [ "$running" = "true" ]; then
    ok "AnyLink Docker container is running."
    as_root docker ps --filter "name=^/${CONTAINER_NAME}$"
    return 0
  fi

  warn "AnyLink Docker container is not running. Showing recent logs."
  as_root docker logs --tail 80 "$CONTAINER_NAME" || true
  die "AnyLink Docker container failed to start."
}

main() {
  local domain
  local https_port
  local admin_port

  printf '%s%s%s\n' "$BOLD" "AnyLink Debian 11/12/13 Docker installer" "$RESET"

  check_root
  check_debian_version
  check_dependencies
  ensure_docker
  download_update_script
  domain="$(prompt_domain)"
  replace_update_domain "$domain"
  validate_remote_config "$domain"
  make_update_script_executable
  wait_for_conf_dir
  install_cron_job
  check_cron_execution
  https_port="$(prompt_port "Enter host port to map to container 443" "4443")"
  admin_port="$(prompt_port "Enter host port to map to container 8800" "48800")"

  if [ "$https_port" = "$admin_port" ]; then
    die "The 443 mapping port and 8800 mapping port cannot be the same."
  fi

  run_anylink_container "$https_port" "$admin_port"
  check_anylink_container

  ok "AnyLink deployment completed successfully."
  ok "HTTPS/UDP 443 is mapped to host port ${https_port}; admin TCP 8800 is mapped to host port ${admin_port}."
}

main "$@"
