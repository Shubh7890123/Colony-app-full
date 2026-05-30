#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$ROOT_DIR/cloudflare.config.sh"
ENV_FILE="$ROOT_DIR/.env.tunnel"
STATUS_FILE="$ROOT_DIR/.tunnel-status"
PID_FILE="$ROOT_DIR/.cloudflared-tunnel.pid"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
die() { red "ERROR: $*"; exit 1; }

load_config() {
  [[ -f "$CONFIG_FILE" ]] || die "Missing $CONFIG_FILE."
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  # shellcheck disable=SC1090
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
}

check_url() {
  local label="$1"
  local url="$2"

  if curl -fsS --max-time 8 "$url" >/dev/null; then
    green "✓ $label reachable: $url"
    return 0
  fi

  red "✗ $label unreachable: $url"
  return 1
}

main() {
  load_config

  local api_url="${API_URL:-https://$CF_API_SUBDOMAIN.$CF_DOMAIN}"
  local admin_url="${ADMIN_URL:-https://$CF_ADMIN_SUBDOMAIN.$CF_DOMAIN}"
  local studio_url="${STUDIO_URL:-https://$CF_STUDIO_SUBDOMAIN.$CF_DOMAIN}"
  local process_status="stopped"
  local failures=0

  if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" >/dev/null 2>&1; then
    process_status="running"
    green "Tunnel process running with PID $(cat "$PID_FILE")."
  else
    yellow "Tunnel process is not running according to $PID_FILE."
  fi

  check_url "API" "$api_url" || failures=$((failures + 1))
  check_url "Admin" "$admin_url" || failures=$((failures + 1))
  check_url "Studio" "$studio_url" || failures=$((failures + 1))

  cat > "$STATUS_FILE" <<EOF
STATUS="$process_status"
UPDATED_AT="$(date -Is)"
API_URL="$api_url"
ADMIN_URL="$admin_url"
STUDIO_URL="$studio_url"
FAILURES="$failures"
EOF

  [[ "$failures" -eq 0 ]]
}

main "$@"
