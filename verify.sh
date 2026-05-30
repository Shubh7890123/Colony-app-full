#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_ENV_FILE="$ROOT_DIR/.env.local"
TUNNEL_ENV_FILE="$ROOT_DIR/.env.tunnel"

PASS_COUNT=0
FAIL_COUNT=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

pass() { green "✓ $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { red "✗ $*"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

load_env() {
  [[ -f "$LOCAL_ENV_FILE" ]] && source "$LOCAL_ENV_FILE"
  [[ -f "$TUNNEL_ENV_FILE" ]] && source "$TUNNEL_ENV_FILE"
}

check_http() {
  local label="$1"
  local url="$2"
  if [[ -z "$url" ]]; then
    fail "$label URL is not configured"
  elif curl -fsS --max-time 8 "$url" >/dev/null; then
    pass "$label reachable at $url"
  else
    fail "$label not reachable at $url"
  fi
}

check_container() {
  local label="$1"
  local pattern="$2"
  if docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | grep -Eiq "$pattern"; then
    pass "$label container is running"
  else
    fail "$label container not found"
  fi
}

check_postgres_extensions() {
  local db_container
  db_container="$(docker ps --format '{{.Names}}' | grep -Ei 'supabase.*db|db.*supabase' | head -n 1 || true)"
  if [[ -z "$db_container" ]]; then
    fail "Supabase PostgreSQL container not found"
    return
  fi

  if docker exec "$db_container" pg_isready >/dev/null 2>&1; then
    pass "Supabase PostgreSQL accepts connections"
  else
    fail "Supabase PostgreSQL is not accepting connections"
  fi

  if docker exec "$db_container" psql -U postgres -tAc "select extname from pg_extension where extname in ('postgis','uuid-ossp','pg_trgm')" 2>/dev/null | grep -q postgis; then
    pass "PostGIS extension is installed"
  else
    fail "PostGIS extension is missing"
  fi
}

main() {
  load_env

  check_http "Coolify" "${COOLIFY_URL:-}"
  check_container "Coolify" '^coolify'
  check_postgres_extensions
  check_container "Supabase Realtime" 'realtime'
  check_container "Supabase Storage" 'storage'
  check_container "Redis" 'redis'
  check_http "Supabase Studio" "${STUDIO_URL:-${SUPABASE_STUDIO_URL:-}}"

  if [[ -n "${API_URL:-}" ]]; then
    check_http "Tunnel/API" "$API_URL"
  else
    yellow "No tunnel configured yet. Run ./tunnel.sh or ./tailscale-setup.sh."
  fi

  printf '\nPassed: %s  Failed: %s\n' "$PASS_COUNT" "$FAIL_COUNT"
  [[ "$FAIL_COUNT" -eq 0 ]]
}

main "$@"
