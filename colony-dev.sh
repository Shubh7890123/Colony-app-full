#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_ENV_FILE="$ROOT_DIR/.env.local"
TUNNEL_ENV_FILE="$ROOT_DIR/.env.tunnel"
STATE_FILE="$ROOT_DIR/.colony-dev-state"
BACKEND_PID_FILE="$ROOT_DIR/.backend-dev.pid"
BACKEND_LOG_FILE="$ROOT_DIR/.backend-dev.log"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
blue() { printf '\033[34m%s\033[0m\n' "$*"; }

fail() {
  red "ERROR: $*"
  exit 1
}

step() {
  printf '\n'
  blue "==> $*"
}

warn() {
  yellow "WARN: $*"
}

ok() {
  green "OK: $*"
}

run() {
  "$@"
}

is_wsl() {
  grep -qi microsoft /proc/version 2>/dev/null
}

load_env() {
  # shellcheck disable=SC1090
  [[ -f "$LOCAL_ENV_FILE" ]] && source "$LOCAL_ENV_FILE"
  # shellcheck disable=SC1090
  [[ -f "$TUNNEL_ENV_FILE" ]] && source "$TUNNEL_ENV_FILE"
  # shellcheck disable=SC1091
  [[ -f "$ROOT_DIR/cloudflare.config.sh" ]] && source "$ROOT_DIR/cloudflare.config.sh"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

port_open() {
  local port="$1"

  if command_exists ss; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$port$"
    return
  fi

  if command_exists netstat; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$port$"
    return
  fi

  return 1
}

http_ok() {
  local url="$1"
  curl -fsS --max-time 5 "$url" >/dev/null 2>&1
}

docker_ready() {
  command_exists docker && docker info >/dev/null 2>&1
}

coolify_running() {
  docker_ready && docker ps --format '{{.Names}}' 2>/dev/null | grep -qi '^coolify'
}

supabase_running() {
  docker_ready && docker ps --format '{{.Names}}' 2>/dev/null | grep -Eiq 'supabase|kong|postgrest|realtime|storage'
}

cloudflare_config_ready() {
  [[ -f "$ROOT_DIR/cloudflare.config.sh" ]] || return 1
  load_env
  [[ -n "${CF_DOMAIN:-}" && -n "${CF_TUNNEL_NAME:-}" && -n "${CF_ACCOUNT_ID:-}" && -n "${CF_API_TOKEN:-}" ]] || return 1
  [[ "$CF_DOMAIN" != your* && "$CF_ACCOUNT_ID" != your* && "$CF_API_TOKEN" != your* ]]
}

cloudflare_tunnel_ready() {
  cloudflare_config_ready || return 1
  command_exists cloudflared || return 1
  [[ -f "$HOME/.cloudflared/$CF_TUNNEL_NAME.yml" ]]
}

cloudflare_tunnel_running() {
  [[ -f "$ROOT_DIR/.cloudflared-tunnel.pid" ]] || return 1
  kill -0 "$(cat "$ROOT_DIR/.cloudflared-tunnel.pid")" >/dev/null 2>&1
}

ensure_executable_scripts() {
  step "Preparing local scripts"
  chmod +x \
    "$ROOT_DIR/setup.sh" \
    "$ROOT_DIR/find-wsl-ip.sh" \
    "$ROOT_DIR/tunnel.sh" \
    "$ROOT_DIR/tunnel-status.sh" \
    "$ROOT_DIR/cloudflare-setup.sh" \
    "$ROOT_DIR/tailscale-setup.sh" \
    "$ROOT_DIR/verify.sh" \
    "$ROOT_DIR/colony-dev.sh" 2>/dev/null || true
  ok "Scripts are executable"
}

ensure_wsl_context() {
  step "Checking WSL context"
  if is_wsl; then
    ok "Running inside WSL"
  else
    warn "This is designed for Ubuntu on WSL2. Continue only if you know this shell can run Linux Docker."
  fi
}

ensure_foundation() {
  step "Checking Docker, Coolify, and Supabase foundation"

  if docker_ready && coolify_running && [[ -d "$ROOT_DIR/.local/supabase/docker" ]]; then
    ok "Foundation already exists"
    return
  fi

  warn "Foundation is incomplete; running ./setup.sh now"
  run "$ROOT_DIR/setup.sh" || fail "./setup.sh failed"
}

refresh_wsl_ip() {
  step "Refreshing WSL IP"
  run "$ROOT_DIR/find-wsl-ip.sh" || fail "Could not update .env.local"
  load_env
}

start_docker_if_needed() {
  step "Checking Docker daemon"

  if docker_ready; then
    ok "Docker daemon is reachable"
    return
  fi

  if command_exists systemctl; then
    sudo systemctl start docker >/dev/null 2>&1 || true
  fi

  if ! docker_ready && command_exists dockerd; then
    warn "Starting Docker daemon manually for this WSL session"
    sudo dockerd >/tmp/colony-dockerd.log 2>&1 &
    sleep 5
  fi

  docker_ready || fail "Docker is not reachable. If just installed, run from Windows PowerShell: wsl --shutdown"
  ok "Docker daemon is ready"
}

start_coolify_if_needed() {
  step "Checking Coolify"

  if coolify_running; then
    ok "Coolify is running"
    return
  fi

  if [[ -d /data/coolify/source ]]; then
    warn "Coolify exists but is stopped; starting containers"
    sudo docker compose \
      --env-file /data/coolify/source/.env \
      -f /data/coolify/source/docker-compose.yml \
      -f /data/coolify/source/docker-compose.prod.yml \
      up -d >/dev/null || warn "Could not start Coolify compose automatically"
  fi

  coolify_running || warn "Coolify is still not running; open ./setup.sh output and check install logs"
}

detect_backend_dir() {
  local candidates=(
    "$ROOT_DIR/backend"
    "$ROOT_DIR/api"
    "$ROOT_DIR/server"
    "$ROOT_DIR/apps/api"
    "$ROOT_DIR/apps/backend"
    "$ROOT_DIR"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    [[ -f "$candidate/package.json" ]] && printf '%s\n' "$candidate" && return 0
  done

  return 1
}

detect_package_manager() {
  local app_dir="$1"

  if [[ -f "$app_dir/pnpm-lock.yaml" ]] && command_exists pnpm; then
    printf 'pnpm\n'
  elif [[ -f "$app_dir/yarn.lock" ]] && command_exists yarn; then
    printf 'yarn\n'
  elif command_exists npm; then
    printf 'npm\n'
  else
    return 1
  fi
}

package_has_script() {
  local app_dir="$1"
  local script_name="$2"

  node -e "const p=require(process.argv[1]); process.exit(p.scripts && p.scripts[process.argv[2]] ? 0 : 1)" \
    "$app_dir/package.json" "$script_name" >/dev/null 2>&1
}

install_node_deps_if_needed() {
  local app_dir="$1"
  local package_manager="$2"

  [[ -d "$app_dir/node_modules" ]] && return 0

  warn "Node dependencies missing in $app_dir; installing with $package_manager"
  case "$package_manager" in
    pnpm) (cd "$app_dir" && pnpm install) ;;
    yarn) (cd "$app_dir" && yarn install) ;;
    npm) (cd "$app_dir" && npm install) ;;
  esac
}

start_backend_if_detected() {
  step "Checking backend dev server"
  load_env

  local api_port="${LOCAL_API_PORT:-3000}"
  if port_open "$api_port"; then
    ok "Something is already listening on API port $api_port"
    return
  fi

  local app_dir package_manager script_name
  app_dir="$(detect_backend_dir || true)"
  if [[ -z "$app_dir" ]]; then
    warn "No Node backend found yet. When backend code exists, this script will auto-start it."
    return
  fi

  command_exists node || {
    warn "Node.js is not installed, so backend auto-start is skipped"
    return
  }

  package_manager="$(detect_package_manager "$app_dir" || true)"
  if [[ -z "$package_manager" ]]; then
    warn "No npm/pnpm/yarn found, so backend auto-start is skipped"
    return
  fi

  if package_has_script "$app_dir" dev; then
    script_name="dev"
  elif package_has_script "$app_dir" start:dev; then
    script_name="start:dev"
  elif package_has_script "$app_dir" start; then
    script_name="start"
  else
    warn "Found $app_dir/package.json, but no dev/start script"
    return
  fi

  install_node_deps_if_needed "$app_dir" "$package_manager"

  warn "Starting backend from $app_dir with $package_manager run $script_name"
  (
    cd "$app_dir"
    case "$package_manager" in
      pnpm) nohup pnpm run "$script_name" > "$BACKEND_LOG_FILE" 2>&1 & ;;
      yarn) nohup yarn "$script_name" > "$BACKEND_LOG_FILE" 2>&1 & ;;
      npm) nohup npm run "$script_name" > "$BACKEND_LOG_FILE" 2>&1 & ;;
    esac
    echo "$!" > "$BACKEND_PID_FILE"
  )

  sleep 5
  if port_open "$api_port"; then
    ok "Backend started on port $api_port"
  else
    warn "Backend did not open port $api_port yet. Check $BACKEND_LOG_FILE"
  fi
}

ensure_tunnel() {
  step "Checking tunnel"
  load_env

  if [[ "${TUNNEL_METHOD:-}" == "tailscale" && -n "${API_URL:-}" ]]; then
    ok "Tailscale tunnel config exists: $API_URL"
    return
  fi

  if [[ "${TUNNEL_METHOD:-}" == "direct-ip" && -n "${API_URL:-}" ]]; then
    ok "Direct IP tunnel config exists: $API_URL"
    return
  fi

  if cloudflare_tunnel_running; then
    ok "Cloudflare tunnel process is already running"
    return
  fi

  if cloudflare_tunnel_ready; then
    warn "Starting existing Cloudflare tunnel"
    run "$ROOT_DIR/tunnel.sh" cloudflare || warn "Cloudflare tunnel start reported a warning"
    return
  fi

  if cloudflare_config_ready; then
    warn "Cloudflare is configured but tunnel is not prepared; running one-time setup"
    run "$ROOT_DIR/cloudflare-setup.sh" || fail "Cloudflare setup failed"
    run "$ROOT_DIR/tunnel.sh" cloudflare || warn "Cloudflare tunnel start reported a warning"
    return
  fi

  warn "No tunnel method is configured. Run ./tunnel.sh or ./tailscale-setup.sh when you need phone/device access."
}

wait_for_local_api() {
  step "Testing local API"
  load_env

  local api_port="${LOCAL_API_PORT:-3000}"
  local local_api="http://127.0.0.1:$api_port"

  if http_ok "$local_api/health" || http_ok "$local_api"; then
    ok "Local API is reachable at $local_api"
  else
    warn "Local API is not reachable at $local_api yet"
  fi
}

write_state() {
  load_env
  cat > "$STATE_FILE" <<EOF
UPDATED_AT="$(date -Is)"
WSL_IP="${WSL_IP:-}"
COOLIFY_URL="${COOLIFY_URL:-}"
TUNNEL_METHOD="${TUNNEL_METHOD:-none}"
API_URL="${API_URL:-}"
BACKEND_PID="$(cat "$BACKEND_PID_FILE" 2>/dev/null || true)"
EOF
}

print_summary() {
  load_env
  local api_port="${LOCAL_API_PORT:-3000}"
  local fallback_api="http://127.0.0.1:$api_port"

  printf '\n'
  green "Colony dev environment check complete."
  printf 'WSL IP:            %s\n' "${WSL_IP:-unknown}"
  printf 'Coolify dashboard: %s\n' "${COOLIFY_URL:-unknown}"
  printf 'Local API:         %s\n' "$fallback_api"
  printf 'Flutter API URL:   %s\n' "${API_URL:-$fallback_api}"
  printf 'Tunnel method:     %s\n' "${TUNNEL_METHOD:-none}"
  printf '\nUseful commands:\n'
  printf '  ./colony-dev.sh auto      # detect + setup + start + verify\n'
  printf '  ./colony-dev.sh status    # quick health check\n'
  printf '  ./colony-dev.sh stop      # stop backend/tunnel started by scripts\n'
  printf '  ./verify.sh               # deeper service checks\n'
}

auto() {
  ensure_wsl_context
  ensure_executable_scripts
  refresh_wsl_ip
  ensure_foundation
  start_docker_if_needed
  start_coolify_if_needed
  start_backend_if_detected
  ensure_tunnel
  wait_for_local_api
  write_state
  print_summary
}

status() {
  load_env
  refresh_wsl_ip
  printf '\n'
  docker_ready && ok "Docker reachable" || warn "Docker not reachable"
  coolify_running && ok "Coolify running" || warn "Coolify not running"
  supabase_running && ok "Supabase-like containers running" || warn "Supabase containers not detected"
  cloudflare_tunnel_running && ok "Cloudflare tunnel running" || warn "Cloudflare tunnel process not running"
  wait_for_local_api
  [[ -x "$ROOT_DIR/verify.sh" ]] && "$ROOT_DIR/verify.sh" || true
  write_state
}

stop() {
  step "Stopping script-managed processes"

  if [[ -f "$BACKEND_PID_FILE" ]] && kill -0 "$(cat "$BACKEND_PID_FILE")" >/dev/null 2>&1; then
    kill "$(cat "$BACKEND_PID_FILE")"
    ok "Stopped backend process"
  else
    warn "No script-managed backend process running"
  fi
  rm -f "$BACKEND_PID_FILE"

  if [[ -x "$ROOT_DIR/tunnel.sh" ]]; then
    "$ROOT_DIR/tunnel.sh" stop || true
  fi

  write_state
}

help_text() {
  cat <<EOF
Usage: ./colony-dev.sh [auto|setup|start|status|verify|tunnel|stop]

Commands:
  auto      Detect system state, install missing foundation, start services, tunnel, and test API.
  setup     Run the full foundational setup script.
  start     Same as auto.
  status    Refresh WSL IP and print service health.
  verify    Run verify.sh.
  tunnel    Start tunnel chooser.
  stop      Stop backend/tunnel processes started by these scripts.
EOF
}

main() {
  cd "$ROOT_DIR" || fail "Could not cd into $ROOT_DIR"

  case "${1:-auto}" in
    auto|start) auto ;;
    setup) ensure_executable_scripts; "$ROOT_DIR/setup.sh" ;;
    status) status ;;
    verify) "$ROOT_DIR/verify.sh" ;;
    tunnel) "$ROOT_DIR/tunnel.sh" ;;
    stop) stop ;;
    -h|--help|help) help_text ;;
    *) help_text; exit 1 ;;
  esac
}

main "$@"
