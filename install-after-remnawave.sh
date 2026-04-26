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

require_apt_debian_family() {
  local id
  id="$(os_id)"
  [[ "$id" == "debian" || "$id" == "ubuntu" ]] || die "this script supports Debian/Ubuntu only (ID=${id})"
}

APT_UPDATED=0

apt_ensure_updated() {
  [[ "${APT_UPDATED}" == 1 ]] && return 0
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  APT_UPDATED=1
}

apt_install() {
  apt_ensure_updated
  apt-get install -y --no-install-recommends "$@"
}

ensure_htop() {
  if have_cmd htop; then
    log "htop already installed; skipping"
    return 0
  fi
  log "Installing htop"
  apt_install htop
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

require_docker_for_beszel() {
  have_cmd docker || die "docker not found; install Docker on Debian yourself, then re-run"
  compose_cmd >/dev/null 2>&1 || die "docker compose not found; install compose (plugin or docker-compose), then re-run"
  if ! docker info >/dev/null 2>&1; then
    die "docker daemon not reachable (docker info failed); start docker and retry"
  fi
}

ensure_root_authorized_keys() {
  local key="${1:-}"
  local ssh_dir="/root/.ssh"
  local auth_keys="${ssh_dir}/authorized_keys"

  # Directory: only root may traverse (sshd requirement for key-based login).
  mkdir -p "$ssh_dir"
  chown root:root "$ssh_dir"
  chmod 700 "$ssh_dir"

  # File: create if missing; root-owned, not group/world readable/writable.
  if [[ ! -f "$auth_keys" ]]; then
    : >"$auth_keys"
  fi
  chown root:root "$auth_keys"
  chmod 600 "$auth_keys"

  # Empty file: leave a short hint (lines starting with # are ignored by sshd).
  if [[ ! -s "$auth_keys" ]]; then
    cat >"$auth_keys" <<'KEYSHEAD'
# SSH: один публичный ключ на строку (вставьте ниже, сохраните файл).
# SSH: one public key per line (paste below, save).
#
KEYSHEAD
    chown root:root "$auth_keys"
    chmod 600 "$auth_keys"
    log "Created empty $auth_keys with comments; add keys and save"
  else
    log "SSH $auth_keys present; permissions set to root:root 600, dir 700"
  fi

  if [[ -n "$key" ]]; then
    if ! grep -Fxq "$key" "$auth_keys"; then
      printf '%s\n' "$key" >> "$auth_keys"
      log "Appended key from --authorized-key to $auth_keys"
    else
      log "Key from --authorized-key already in $auth_keys; skipping"
    fi
  fi

  log "SSH access layout: $ssh_dir (drwx------ root) / $auth_keys (-rw------- root)"
}

swap_is_ok() {
  local want_mb="$1"
  local want_kb min_kb total_kb

  want_kb="$(( want_mb * 1024 ))"
  min_kb="$(( want_kb - 4096 ))"

  total_kb="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  [[ "${total_kb:-0}" -ge "$min_kb" ]]
}

ensure_swapfile() {
  local want_mb="$1"
  local swapfile="$2"

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

ensure_beszel_agent() {
  local dir="$1"
  local compose_file="$dir/docker-compose.yml"
  local compose
  local pull_out

  mkdir -p "$dir"
  mkdir -p "$dir/beszel_agent_data"

  if [[ ! -f "$compose_file" ]]; then
    : >"$compose_file"
    log "Created empty $compose_file"
  else
    log "$compose_file already exists; skipping"
  fi

  # Optional: update existing Beszel Agent if it is already installed (container exists).
  # We intentionally avoid failing the whole bootstrap if Docker/Compose are unavailable.
  if have_cmd docker && docker info >/dev/null 2>&1; then
    if compose="$(compose_cmd 2>/dev/null)"; then
      if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq 'beszel-agent'; then
        if [[ -s "$compose_file" ]]; then
          log "Beszel Agent detected; checking for updates"
          pull_out="$($compose -f "$compose_file" pull 2>&1 || true)"
          if printf '%s\n' "$pull_out" | grep -qiE 'downloaded newer image|pull complete|digest:'; then
            log "Beszel Agent image updated; restarting"
          else
            log "Beszel Agent image already up to date; ensuring it's running"
          fi
          $compose -f "$compose_file" up -d >/dev/null 2>&1 || warn "Beszel Agent restart failed; check docker/compose logs"
        else
          warn "Beszel compose file is empty ($compose_file); skipping update"
        fi
      fi
    else
      warn "docker compose not found; skipping Beszel update"
    fi
  else
    warn "docker daemon not reachable; skipping Beszel update"
  fi
}

usage() {
  cat <<'EOF'
Usage:
  bash install-after-remnawave.sh [options]

Debian/Ubuntu only.

Steps (each skipped if already satisfied):
  - htop (apt) if missing
  - SSH: /root/.ssh (700) + authorized_keys (600), template if empty; optional --authorized-key
  - swap file + fstab
  - BBR sysctl (unless --enable-bbr 0)
  - Beszel: create directory and empty docker-compose.yml

Options:
  --authorized-key <key>  Append this pubkey to /root/.ssh/authorized_keys (optional)
  --swap-mb <int>         Swap size in MB (default: 1024)
  --swapfile <path>       Swap file path (default: /swapfile)
  --enable-bbr <0|1>      Enable BBR (default: 1)
  --beszel-dir <path>     Beszel directory for docker-compose.yml (default: /root/beszel-agent)

Examples:
  bash install-after-remnawave.sh --authorized-key 'ssh-ed25519 AAAA... you@host'
EOF
}

main() {
  require_root
  require_apt_debian_family
  ensure_htop

  local swap_mb="1024"
  local swapfile="/swapfile"
  local enable_bbr="1"
  local beszel_dir="/root/beszel-agent"
  local authorized_key="${AUTHORIZED_KEY:-}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --authorized-key) authorized_key="${2:-}"; shift 2 ;;
      --swap-mb) swap_mb="${2:-}"; shift 2 ;;
      --swapfile) swapfile="${2:-}"; shift 2 ;;
      --enable-bbr) enable_bbr="${2:-}"; shift 2 ;;
      --beszel-dir) beszel_dir="${2:-}"; shift 2 ;;
      *) die "unknown arg: $1 (use --help)" ;;
    esac
  done

  [[ "$swap_mb" =~ ^[0-9]+$ ]] || die "--swap-mb must be int"
  [[ "$enable_bbr" == "0" || "$enable_bbr" == "1" ]] || die "--enable-bbr must be 0 or 1"

  ensure_root_authorized_keys "$authorized_key"
  ensure_swapfile "$swap_mb" "$swapfile"
  if [[ "$enable_bbr" == "1" ]]; then
    ensure_bbr
  else
    log "BBR step disabled; skipping"
  fi

  ensure_beszel_agent "$beszel_dir"

  log "Done"
}

main "$@"
