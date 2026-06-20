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
UDP_RELEASES_API="https://api.github.com/repos/wangwangbox/haproxy-3.4-udp/releases"
UDP_RELEASES_PAGE="https://github.com/wangwangbox/haproxy-3.4-udp/releases"
HAPROXY_BINARY="/usr/sbin/haproxy"

DEBIAN_VERSION_ID=""
DEBIAN_PRETTY_NAME=""
HAPROXY_SUITE=""
HAPROXY_SERIES=""
ENABLE_UDP_SUPPORT=0
UDP_ASSET_NAME=""
UDP_ASSET_LABEL=""
UDP_ASSET_URL=""
UDP_CPU_LEVEL=""
UDP_CPU_VARIANT=""
UDP_INSTALL_STATUS=""

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

  for command_name in apt-mark awk chmod cp date find grep head id install mkdir mktemp rm sed sort tee tr uname; do
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

  if [ "$ENABLE_UDP_SUPPORT" -eq 1 ]; then
    if ! have_command python3; then
      missing_packages+=(python3)
    fi

    if ! have_command tar; then
      missing_packages+=(tar)
    fi

    if ! have_command gzip; then
      missing_packages+=(gzip)
    fi

    if ! have_command unzip; then
      missing_packages+=(unzip)
    fi
  fi

  if ! have_command systemctl; then
    die "systemctl was not found. This installer requires systemd."
  fi

  install_missing_packages "${missing_packages[@]}"

  for command_name in curl gpg openssl systemctl; do
    require_command "$command_name"
  done

  if [ "$ENABLE_UDP_SUPPORT" -eq 1 ]; then
    for command_name in python3 tar gzip unzip; do
      require_command "$command_name"
    done
  fi

  if ! systemctl --version >/dev/null 2>&1; then
    die "systemctl is present but not usable. Please run this on a systemd-based Debian host."
  fi

  ok "Required tools are available."
}

ask_udp_support() {
  if prompt_yes_no "Enable UDP support with a custom HAProxy binary from GitHub releases?" "y"; then
    ENABLE_UDP_SUPPORT=1
    ok "UDP support will be installed from: ${UDP_RELEASES_PAGE}"
  else
    ENABLE_UDP_SUPPORT=0
    ok "UDP support will not be installed."
  fi
}

cpu_flags_have_all() {
  local flags=$1
  shift
  local flag

  for flag in "$@"; do
    printf '%s\n' "$flags" | grep -Eq "(^|[[:space:]])${flag}([[:space:]]|$)" || return 1
  done
}

cpu_flags_have_any() {
  local flags=$1
  shift
  local flag

  for flag in "$@"; do
    if printf '%s\n' "$flags" | grep -Eq "(^|[[:space:]])${flag}([[:space:]]|$)"; then
      return 0
    fi
  done

  return 1
}

detect_udp_cpu_level() {
  local machine
  local ld_path
  local ld_help
  local flags

  machine="$(uname -m)"
  UDP_CPU_LEVEL=""
  UDP_CPU_VARIANT=""

  case "$machine" in
    x86_64|amd64)
      ;;
    *)
      warn "Automatic x86-64 CPU level detection is not available for architecture: ${machine}"
      return 0
      ;;
  esac

  for ld_path in /lib64/ld-linux-x86-64.so.2 /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2; do
    if [ -x "$ld_path" ]; then
      ld_help="$("$ld_path" --help 2>/dev/null || true)"
      if printf '%s\n' "$ld_help" | grep -Eq 'x86-64-v4 .*supported'; then
        UDP_CPU_LEVEL="x86-64-v4"
        UDP_CPU_VARIANT="v4"
        ok "Detected CPU level: ${UDP_CPU_LEVEL}; recommended UDP asset variant: ${UDP_CPU_VARIANT}"
        return 0
      fi
      if printf '%s\n' "$ld_help" | grep -Eq 'x86-64-v3 .*supported'; then
        UDP_CPU_LEVEL="x86-64-v3"
        UDP_CPU_VARIANT="v3"
        ok "Detected CPU level: ${UDP_CPU_LEVEL}; recommended UDP asset variant: ${UDP_CPU_VARIANT}"
        return 0
      fi
      if printf '%s\n' "$ld_help" | grep -Eq 'x86-64-v2 .*supported'; then
        UDP_CPU_LEVEL="x86-64-v2"
        UDP_CPU_VARIANT="v2"
        ok "Detected CPU level: ${UDP_CPU_LEVEL}; recommended UDP asset variant: ${UDP_CPU_VARIANT}"
        return 0
      fi
    fi
  done

  if [ -r /proc/cpuinfo ]; then
    flags="$(grep -m1 '^flags[[:space:]]*:' /proc/cpuinfo || true)"
    if [ -n "$flags" ]; then
      if cpu_flags_have_all "$flags" avx512f avx512bw avx512cd avx512dq avx512vl; then
        UDP_CPU_LEVEL="x86-64-v4"
        UDP_CPU_VARIANT="v4"
      elif cpu_flags_have_all "$flags" avx avx2 bmi1 bmi2 f16c fma movbe xsave && cpu_flags_have_any "$flags" lzcnt abm; then
        UDP_CPU_LEVEL="x86-64-v3"
        UDP_CPU_VARIANT="v3"
      elif cpu_flags_have_all "$flags" cx16 lahf_lm pni popcnt sse4_1 sse4_2 ssse3; then
        UDP_CPU_LEVEL="x86-64-v2"
        UDP_CPU_VARIANT="v2"
      else
        UDP_CPU_LEVEL="x86-64-v1"
        UDP_CPU_VARIANT="v1"
      fi
    fi
  fi

  if [ -n "$UDP_CPU_LEVEL" ]; then
    ok "Detected CPU level: ${UDP_CPU_LEVEL}; recommended UDP asset variant: ${UDP_CPU_VARIANT}"
  else
    warn "Could not detect x86-64 CPU level automatically. The first compatible UDP asset will be selected by default."
  fi
}

print_glibc_version_hint() {
  if have_command ldd; then
    warn "System glibc version: $(ldd --version 2>/dev/null | head -n 1 || printf 'unknown')"
  fi
  warn "This usually means the selected UDP binary was built for a newer Linux distribution."
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

stop_haproxy_if_running() {
  if as_root systemctl is-active --quiet haproxy; then
    warn "HAProxy service is already running. It will be stopped before installation continues."
    run_cmd as_root systemctl stop haproxy
    ok "HAProxy service stopped."
  else
    ok "HAProxy service is not running."
  fi
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

select_udp_release_asset() {
  local release_tmp
  local labels=()
  local urls=()
  local names=()
  local label
  local url
  local name
  local selected=""
  local i
  local default_index=0

  release_tmp="$(mktemp)"
  detect_udp_cpu_level
  log "Fetching UDP-enabled HAProxy releases from GitHub."
  run_cmd curl -fsSL --retry 3 --connect-timeout 15 -A "$DOWNLOAD_USER_AGENT" -o "$release_tmp" "$UDP_RELEASES_API"

  while IFS="$(printf '\t')" read -r label url name; do
    [ -n "$label" ] || continue
    labels+=("$label")
    urls+=("$url")
    names+=("$name")
  done < <(python3 - "$release_tmp" "$DEBIAN_VERSION_ID" "$(uname -m)" "$UDP_CPU_VARIANT" <<'PY'
import json
import re
import sys

json_file, debian_version, machine, cpu_variant = sys.argv[1:5]
with open(json_file, "r", encoding="utf-8") as fh:
    releases = json.load(fh)

arch_aliases = {
    "x86_64": ("amd64", "x86_64", "x64"),
    "amd64": ("amd64", "x86_64", "x64"),
    "aarch64": ("arm64", "aarch64"),
    "arm64": ("arm64", "aarch64"),
}
debian_aliases = {
    "11": ("debian11", "debian-11", "deb11", "bullseye"),
    "12": ("debian12", "debian-12", "deb12", "bookworm"),
    "13": ("debian13", "debian-13", "deb13", "trixie"),
}
known_arch = ("amd64", "x86_64", "x64", "arm64", "aarch64", "armv7", "i386", "386")
known_debian = ("debian11", "debian-11", "deb11", "bullseye", "debian12", "debian-12", "deb12", "bookworm", "debian13", "debian-13", "deb13", "trixie")
checksum_suffixes = (".sha256", ".sha512", ".sha1", ".md5", ".asc", ".sig", ".minisig")

arch_tokens = arch_aliases.get(machine.lower(), (machine.lower(),))
debian_tokens = debian_aliases.get(debian_version, ())
rows = []

for release_index, release in enumerate(releases):
    tag = release.get("tag_name") or release.get("name") or "untagged"
    release_name = release.get("name") or tag
    prerelease = bool(release.get("prerelease"))
    for asset in release.get("assets", []):
        asset_name = asset.get("name") or ""
        download_url = asset.get("browser_download_url") or ""
        if not asset_name or not download_url:
            continue
        if asset_name.lower().endswith(checksum_suffixes):
            continue

        normalized = re.sub(r"[^a-z0-9]+", "-", asset_name.lower())
        asset_score = 0

        if any(token in normalized for token in arch_tokens):
            asset_score += 80
        elif any(token in normalized for token in known_arch):
            asset_score -= 500
        else:
            asset_score += 5

        if debian_tokens and any(token in normalized for token in debian_tokens):
            asset_score += 80
        elif any(token in normalized for token in known_debian):
            asset_score -= 300
        else:
            asset_score += 5

        if "haproxy" in normalized:
            asset_score += 20
        if "static" in normalized:
            asset_score += 30
        if cpu_variant and re.search(rf"(^|-)x86-64-{re.escape(cpu_variant)}($|-)", normalized):
            asset_score += 200
        elif cpu_variant and re.search(r"(^|-)x86-64-v[1-4]($|-)", normalized):
            asset_score -= 80
        if prerelease:
            asset_score -= 30

        if asset_score < -200:
            continue

        suffix = " prerelease" if prerelease else ""
        label = f"{release_name} ({tag}) - {asset_name}{suffix}"
        rows.append((release_index, -asset_score, label, download_url, asset_name))

rows.sort(key=lambda item: (item[0], item[1], item[2]))
for _, _, label, download_url, asset_name in rows:
    safe_label = label.replace("\t", " ").replace("\n", " ")
    safe_name = asset_name.replace("\t", " ").replace("\n", " ")
    print(f"{safe_label}\t{download_url}\t{safe_name}")
PY
)

  rm -f "$release_tmp"

  [ "${#labels[@]}" -gt 0 ] || die "No compatible UDP-enabled HAProxy release assets were found for Debian ${DEBIAN_VERSION_ID} on $(uname -m)."

  if [ -n "$UDP_CPU_VARIANT" ]; then
    for i in "${!names[@]}"; do
      if printf '%s\n' "${names[$i]}" | grep -Eq "(^|[^[:alnum:]])x86-64-${UDP_CPU_VARIANT}([^[:alnum:]]|$)"; then
        default_index="$i"
        break
      fi
    done
  fi

  printf '\nAvailable UDP-enabled HAProxy release assets:\n' > /dev/tty
  for i in "${!labels[@]}"; do
    if [ "$i" -eq "$default_index" ]; then
      if [ -n "$UDP_CPU_VARIANT" ]; then
        printf '  %s) %s  [default recommended for %s]\n' "$((i + 1))" "${labels[$i]}" "$UDP_CPU_LEVEL" > /dev/tty
      else
        printf '  %s) %s  [default]\n' "$((i + 1))" "${labels[$i]}" > /dev/tty
      fi
    else
      printf '  %s) %s\n' "$((i + 1))" "${labels[$i]}" > /dev/tty
    fi
  done

  while true; do
    printf 'Select a UDP-enabled HAProxy asset [default: %s]: ' "$((default_index + 1))" > /dev/tty
    IFS= read -r selected < /dev/tty || die "Failed to read input"
    selected=${selected:-$((default_index + 1))}
    case "$selected" in
      ''|*[!0-9]*) warn "Please enter a number." ;;
      *)
        if [ "$selected" -ge 1 ] && [ "$selected" -le "${#labels[@]}" ]; then
          UDP_ASSET_LABEL="${labels[$((selected - 1))]}"
          UDP_ASSET_NAME="${names[$((selected - 1))]}"
          UDP_ASSET_URL="${urls[$((selected - 1))]}"
          return 0
        fi
        warn "Selection out of range."
        ;;
    esac
  done
}

install_udp_haproxy_binary() {
  local asset_url=$1
  local work_dir
  local extract_dir
  local asset_file
  local asset_lower
  local binary_path
  local backup_file

  UDP_INSTALL_STATUS=""

  work_dir="$(mktemp -d)"
  extract_dir="${work_dir}/extract"
  asset_file="${work_dir}/${UDP_ASSET_NAME:-haproxy-udp-asset}"
  mkdir -p "$extract_dir"

  log "Downloading selected UDP-enabled HAProxy asset: ${UDP_ASSET_LABEL}"
  run_cmd curl -fL --retry 3 --connect-timeout 15 -A "$DOWNLOAD_USER_AGENT" -o "$asset_file" "$asset_url"

  asset_lower="$(printf '%s' "${UDP_ASSET_NAME:-}" | tr 'A-Z' 'a-z')"
  case "$asset_lower" in
    *.tar.gz|*.tgz|*.tar.xz|*.tar.bz2|*.tar)
      run_cmd tar -xf "$asset_file" -C "$extract_dir"
      ;;
    *.zip)
      run_cmd unzip -q "$asset_file" -d "$extract_dir"
      ;;
    *.gz)
      run_cmd gzip -dc "$asset_file" > "${extract_dir}/haproxy"
      run_cmd chmod 0755 "${extract_dir}/haproxy"
      ;;
    *)
      run_cmd cp "$asset_file" "${extract_dir}/haproxy"
      run_cmd chmod 0755 "${extract_dir}/haproxy"
      ;;
  esac

  binary_path="$(find "$extract_dir" -type f \( -name haproxy -o -name 'haproxy-*' -o -name 'haproxy_*' \) | head -n 1 || true)"
  [ -n "$binary_path" ] || die "No HAProxy executable was found inside the selected UDP asset."

  run_cmd chmod 0755 "$binary_path"
  log "Validating selected UDP-enabled HAProxy binary before replacing ${HAPROXY_BINARY}."
  if ! "$binary_path" -v; then
    warn "The selected UDP-enabled HAProxy binary cannot run on this system."
    print_glibc_version_hint
    warn "The Debian package HAProxy binary has not been replaced."
    rm -rf "$work_dir"
    UDP_INSTALL_STATUS="incompatible"
    return 0
  fi
  ok "Selected UDP-enabled HAProxy binary can run on this system."

  if [ -f "$HAPROXY_BINARY" ]; then
    backup_file="${HAPROXY_BINARY}.debian.$(date +%Y%m%d%H%M%S).bak"
    log "Backing up Debian HAProxy binary to: ${backup_file}"
    run_cmd as_root cp "$HAPROXY_BINARY" "$backup_file"
  fi

  run_cmd as_root install -m 0755 "$binary_path" "$HAPROXY_BINARY"
  if ! as_root "$HAPROXY_BINARY" -v; then
    warn "Installed UDP-enabled HAProxy binary failed after replacement."
    if [ -n "${backup_file:-}" ] && [ -f "$backup_file" ]; then
      warn "Restoring backed up Debian HAProxy binary: ${backup_file}"
      run_cmd as_root install -m 0755 "$backup_file" "$HAPROXY_BINARY"
    fi
    rm -rf "$work_dir"
    UDP_INSTALL_STATUS="incompatible"
    return 0
  fi
  rm -rf "$work_dir"
  UDP_INSTALL_STATUS="installed"
  ok "UDP-enabled HAProxy binary installed: ${HAPROXY_BINARY}"
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

set_haproxy_package_hold_state() {
  if [ "$UDP_INSTALL_STATUS" = "installed" ]; then
    log "UDP-enabled HAProxy is installed. Holding the haproxy package to prevent APT from replacing it."
    run_cmd as_root apt-mark hold haproxy
  else
    log "Debian APT HAProxy is in use. Removing any package hold from haproxy."
    run_cmd as_root apt-mark unhold haproxy
  fi
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
  ask_udp_support
  check_dependencies
  setup_haproxy_repository
  update_apt_indexes
  stop_haproxy_if_running
  selected_version="$(select_haproxy_version)"
  install_haproxy "$selected_version"
  if [ "$ENABLE_UDP_SUPPORT" -eq 1 ]; then
    while true; do
      select_udp_release_asset
      install_udp_haproxy_binary "$UDP_ASSET_URL"
      if [ "$UDP_INSTALL_STATUS" = "installed" ]; then
        break
      fi
      if prompt_yes_no "Select another UDP-enabled HAProxy asset and try again?" "n"; then
        continue
      fi
      ENABLE_UDP_SUPPORT=0
      warn "Continuing with the Debian APT HAProxy binary without UDP support."
      break
    done
  fi
  set_haproxy_package_hold_state
  create_self_signed_certificate
  enable_haproxy_service
  wait_for_manual_config_upload
  validate_haproxy_config
  start_and_check_haproxy

  ok "HAProxy deployment completed successfully."
}

main "$@"
