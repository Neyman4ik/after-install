#!/usr/bin/env bash
set -euo pipefail

log() { printf '%s\n' "[bootstrap] $*"; }
warn() { printf '%s\n' "[bootstrap][warn] $*" >&2; }
die() { printf '%s\n' "[bootstrap][error] $*" >&2; exit 1; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "run as root (or via sudo)"
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

os_id() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    printf '%s' "${ID:-unknown}"
    return 0
  fi
  printf '%s' "unknown"
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends "$@"
}

ensure_packages_common() {
  # Keep it minimal and safe.
  if have_cmd htop; then
    return 0
  fi
  log "Installing common utilities (htop)"
  apt_install htop
}

ensure_docker_debian() {
  if have_cmd docker && have_cmd docker-compose; then
    systemctl enable --now docker >/dev/null 2>&1 || true
    return 0
  fi

  log "Installing Docker + docker-compose (Debian repo packages)"
  apt_install ca-certificates curl docker.io docker-compose
  systemctl enable --now docker
}

ensure_docker_ubuntu() {
  # Ubuntu often provides compose as a plugin; accept either form.
  if have_cmd docker && ( docker compose version >/dev/null 2>&1 || have_cmd docker-compose ); then
    systemctl enable --now docker >/dev/null 2>&1 || true
    return 0
  fi

  log "Installing Docker + Compose (Ubuntu repo packages)"
  apt_install ca-certificates curl docker.io
  if apt-get install -y --no-install-recommends docker-compose-plugin >/dev/null 2>&1; then
    :
  else
    apt_install docker-compose
  fi
  systemctl enable --now docker
}

compose_cmd() {
  if have_cmd docker-compose; then
    printf '%s' "docker-compose"
    return 0
  fi
  if have_cmd docker && docker compose version >/dev/null 2>&1; then
    printf '%s' "docker compose"
    return 0
  fi
  return 1
}

ensure_docker() {
  case "$(os_id)" in
    debian) ensure_docker_debian ;;
    ubuntu) ensure_docker_ubuntu ;;
    *)
      warn "Unknown OS ID: $(os_id). Trying Debian-style Docker install."
      ensure_docker_debian
      ;;
  esac
}

ensure_root_authorized_keys() {
  local key="${1:-}"
  local ssh_dir="/root/.ssh"
  local auth_keys="${ssh_dir}/authorized_keys"

  mkdir -p "$ssh_dir"
  chown root:root "$ssh_dir"
  chmod 700 "$ssh_dir"

  touch "$auth_keys"
  chown root:root "$auth_keys"
  chmod 600 "$auth_keys"

  if [[ -n "$key" ]]; then
    if ! grep -Fxq "$key" "$auth_keys"; then
      printf '%s\n' "$key" >> "$auth_keys"
      log "Added key to $auth_keys"
    else
      log "Key already present in $auth_keys; skipping"
    fi
  else
    log "$auth_keys ensured (no key provided)"
  fi
}

swap_is_ok() {
  # ok if ANY swap is enabled and total >= requested (account for rounding)
  local want_mb="$1"
  local want_kb min_kb total_kb

  want_kb="$(( want_mb * 1024 ))"
  # Some tools show 1GiB swap as 1023MiB due to metadata/rounding.
  # Accept a small tolerance (4MiB).
  min_kb="$(( want_kb - 4096 ))"

  total_kb="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  [[ "${total_kb:-0}" -ge "$min_kb" ]]
}

ensure_swapfile() {
  local want_mb="$1"
  local swapfile="$2"

  # If /etc/fstab already references this swapfile, try enabling it first.
  if grep -qE "^[[:space:]]*${swapfile//\//\\/}[[:space:]]+none[[:space:]]+swap[[:space:]]" /etc/fstab; then
    swapon "$swapfile" >/dev/null 2>&1 || true
  fi

  if swap_is_ok "$want_mb"; then
    log "Swap already present (>= ${want_mb}MB); skipping"
    return 0
  fi

  if [[ -e "$swapfile" ]]; then
    warn "Swapfile exists but swap is insufficient; recreating: $swapfile"
    swapoff "$swapfile" >/dev/null 2>&1 || true
    rm -f "$swapfile"
  fi

  log "Creating swapfile ${want_mb}MB at $swapfile"
  if have_cmd fallocate; then
    fallocate -l "${want_mb}M" "$swapfile" || true
  fi
  if [[ ! -s "$swapfile" ]]; then
    dd if=/dev/zero of="$swapfile" bs=1M count="$want_mb" status=progress
  fi

  chmod 600 "$swapfile"
  mkswap "$swapfile" >/dev/null
  swapon "$swapfile"

  if ! grep -qE "^[[:space:]]*${swapfile//\//\\/}[[:space:]]+none[[:space:]]+swap[[:space:]]" /etc/fstab; then
    echo "$swapfile none swap sw 0 0" >> /etc/fstab
  fi

  log "Swap enabled"
}

current_sysctl() {
  sysctl -n "$1" 2>/dev/null || true
}

ensure_bbr() {
  local algo qdisc
  algo="$(current_sysctl net.ipv4.tcp_congestion_control)"
  qdisc="$(current_sysctl net.core.default_qdisc)"

  if [[ "$algo" == "bbr" && "$qdisc" == "fq" ]]; then
    log "BBR already enabled (bbr + fq); skipping"
    return 0
  fi

  log "Enabling BBR (net.ipv4.tcp_congestion_control=bbr, net.core.default_qdisc=fq)"
  modprobe tcp_bbr >/dev/null 2>&1 || true

  cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

  sysctl --system >/dev/null

  algo="$(current_sysctl net.ipv4.tcp_congestion_control)"
  qdisc="$(current_sysctl net.core.default_qdisc)"
  if [[ "$algo" != "bbr" || "$qdisc" != "fq" ]]; then
    die "BBR enable failed (got: tcp_congestion_control=$algo, default_qdisc=$qdisc)"
  fi
}

write_beszel_compose() {
  local dir="$1"
  local listen="$2"
  local key="$3"
  local token="$4"
  local hub_url="$5"

  mkdir -p "$dir/beszel_agent_data"

  cat > "$dir/docker-compose.yml" <<EOF
services:
  beszel-agent:
    image: henrygd/beszel-agent:latest
    container_name: beszel-agent
    restart: unless-stopped
    network_mode: host
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./beszel_agent_data:/var/lib/beszel-agent
    environment:
      LISTEN: ${listen}
      KEY: '${key}'
      TOKEN: ${token}
      HUB_URL: ${hub_url}
EOF
}

ensure_beszel_agent() {
  local dir="$1"
  local listen="$2"
  local key="$3"
  local token="$4"
  local hub_url="$5"

  mkdir -p "$dir"

  if [[ ! -f "$dir/docker-compose.yml" ]]; then
    [[ -n "$key" ]] || die "missing --key (or BESZEL_KEY)"
    [[ -n "$token" ]] || die "missing --token (or BESZEL_TOKEN)"
    [[ -n "$hub_url" ]] || die "missing --hub-url (or BESZEL_HUB_URL)"
    log "Writing $dir/docker-compose.yml"
    write_beszel_compose "$dir" "$listen" "$key" "$token" "$hub_url"
  else
    log "Found existing $dir/docker-compose.yml; will pull latest and restart"
  fi

  local c
  c="$(compose_cmd)" || die "docker compose not found (install docker compose first)"
  ( cd "$dir" && $c pull && $c up -d )
  docker ps --filter name=beszel-agent --format 'table {{.Names}}\t{{.Status}}' | sed -n '1,2p' || true
}

usage() {
  cat <<'EOF'
Usage:
  bash install-after-remnawave.sh [options]

Options:
  --authorized-key <key>  Add SSH public key to /root/.ssh/authorized_keys
  --swap-mb <int>         Swap size in MB (default: 1024)
  --swapfile <path>       Swap file path (default: /swapfile)
  --enable-bbr <0|1>      Enable BBR (default: 1)
  --beszel-dir <path>     Beszel agent directory (default: /root/beszel-agent)
  --listen <port>         Beszel agent listen port (default: 45876)
  --hub-url <url>         Beszel hub URL (or env BESZEL_HUB_URL)
  --token <token>         Beszel agent token (or env BESZEL_TOKEN)
  --key <ssh-pubkey>      Beszel agent key (or env BESZEL_KEY)

Examples:
  curl -fsSL https://example.com/remnawave-bootstrap.sh | bash -s -- \
    --hub-url http://1.2.3.4:8090/ --token abc --key 'ssh-ed25519 AAAA...'
EOF
}

main() {
  require_root

  local swap_mb="1024"
  local swapfile="/swapfile"
  local enable_bbr="1"
  local beszel_dir="/root/beszel-agent"
  local listen="45876"
  local authorized_key="${AUTHORIZED_KEY:-}"
  local hub_url="${BESZEL_HUB_URL:-}"
  local token="${BESZEL_TOKEN:-}"
  local key="${BESZEL_KEY:-}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --authorized-key) authorized_key="${2:-}"; shift 2 ;;
      --swap-mb) swap_mb="${2:-}"; shift 2 ;;
      --swapfile) swapfile="${2:-}"; shift 2 ;;
      --enable-bbr) enable_bbr="${2:-}"; shift 2 ;;
      --beszel-dir) beszel_dir="${2:-}"; shift 2 ;;
      --listen) listen="${2:-}"; shift 2 ;;
      --hub-url) hub_url="${2:-}"; shift 2 ;;
      --token) token="${2:-}"; shift 2 ;;
      --key) key="${2:-}"; shift 2 ;;
      *) die "unknown arg: $1 (use --help)" ;;
    esac
  done

  [[ "$swap_mb" =~ ^[0-9]+$ ]] || die "--swap-mb must be int"
  [[ "$listen" =~ ^[0-9]+$ ]] || die "--listen must be int"
  [[ "$enable_bbr" == "0" || "$enable_bbr" == "1" ]] || die "--enable-bbr must be 0 or 1"

  ensure_docker
  ensure_packages_common
  ensure_root_authorized_keys "$authorized_key"
  ensure_swapfile "$swap_mb" "$swapfile"
  if [[ "$enable_bbr" == "1" ]]; then
    ensure_bbr
  else
    log "BBR step disabled; skipping"
  fi
  ensure_beszel_agent "$beszel_dir" "$listen" "$key" "$token" "$hub_url"

  log "Done"
}

main "$@"

