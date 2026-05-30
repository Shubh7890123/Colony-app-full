#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_ENV_FILE="$ROOT_DIR/.env.local"
SUPABASE_WORKDIR="$ROOT_DIR/.local/supabase"
COOLIFY_INSTALL_URL="https://cdn.coollabs.io/coolify/install.sh"

green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*"; }
die() { red "ERROR: $*"; exit 1; }

wait_for_apt_locks() {
  local max_wait_seconds="${1:-600}"
  local waited_seconds=0
  local lock_holders

  while true; do
    lock_holders="$(sudo fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock /var/lib/apt/lists/lock 2>/dev/null || true)"
    if [[ -z "$lock_holders" ]]; then
      return 0
    fi

    if (( waited_seconds >= max_wait_seconds )); then
      die "apt/dpkg is still locked after ${max_wait_seconds}s by process(es): $lock_holders. Wait for Ubuntu updates to finish, then rerun ./colony-dev.sh auto"
    fi

    yellow "apt/dpkg is busy, likely Ubuntu auto-update. Waiting... (${waited_seconds}s/${max_wait_seconds}s)"
    sleep 10
    waited_seconds=$((waited_seconds + 10))
  done
}

ensure_wsl() {
  grep -qi microsoft /proc/version || yellow "This script is intended for Ubuntu on WSL2. Continuing anyway."
}

install_base_packages() {
  yellow "Installing base packages if missing..."
  wait_for_apt_locks 600
  sudo apt-get update
  wait_for_apt_locks 600
  sudo apt-get install -y ca-certificates curl gnupg git jq lsb-release openssl python3
}

configure_wsl_systemd() {
  if [[ -f /etc/wsl.conf ]] && grep -q 'systemd=true' /etc/wsl.conf; then
    green "WSL systemd is already enabled."
    return
  fi

  yellow "Enabling systemd in WSL so Docker starts automatically next session..."
  sudo mkdir -p /etc
  if [[ -f /etc/wsl.conf ]]; then
    if grep -q '^\[boot\]' /etc/wsl.conf; then
      sudo sed -i '/^\[boot\]/,/^\[/{s/^systemd=.*/systemd=true/}' /etc/wsl.conf
      grep -q 'systemd=true' /etc/wsl.conf || echo 'systemd=true' | sudo tee -a /etc/wsl.conf >/dev/null
    else
      printf '\n[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf >/dev/null
    fi
  else
    printf '[boot]\nsystemd=true\n' | sudo tee /etc/wsl.conf >/dev/null
  fi
  yellow "If Docker does not auto-start, run from Windows PowerShell: wsl --shutdown"
}

install_docker_if_needed() {
  if command -v docker >/dev/null 2>&1; then
    green "Docker is already installed."
  else
    yellow "Installing Docker Engine from Docker's official Ubuntu apt repository..."
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    wait_for_apt_locks 600
    sudo apt-get update
    wait_for_apt_locks 600
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi

  if ! groups "$USER" | grep -q '\bdocker\b'; then
    sudo usermod -aG docker "$USER"
    yellow "Added $USER to docker group. If Docker commands fail, restart WSL once with: wsl --shutdown"
  fi

  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl enable --now docker || true
  fi

  if ! docker info >/dev/null 2>&1; then
    yellow "Starting Docker daemon manually for this WSL session..."
    sudo dockerd >/tmp/colony-dockerd.log 2>&1 &
    sleep 5
  fi

  docker info >/dev/null 2>&1 || die "Docker is installed but not reachable. Restart WSL and rerun ./setup.sh."
}

install_coolify_if_needed() {
  if docker ps --format '{{.Names}}' | grep -qi '^coolify'; then
    green "Coolify containers are already running."
    return
  fi

  local root_username root_email root_password
  printf 'Coolify admin username [admin]: '
  read -r root_username
  root_username="${root_username:-admin}"
  printf 'Coolify admin email: '
  read -r root_email
  [[ -n "$root_email" ]] || die "Coolify admin email is required."
  printf 'Coolify admin password: '
  read -rs root_password
  printf '\n'
  [[ -n "$root_password" ]] || die "Coolify admin password is required."

  yellow "Installing Coolify with the official installer..."
  wait_for_apt_locks 600
  curl -fsSL "$COOLIFY_INSTALL_URL" | sudo -E env \
    ROOT_USERNAME="$root_username" \
    ROOT_USER_EMAIL="$root_email" \
    ROOT_USER_PASSWORD="$root_password" \
    bash
}

update_local_env() {
  "$ROOT_DIR/find-wsl-ip.sh"
  # shellcheck disable=SC1090
  source "$LOCAL_ENV_FILE"

  if grep -q '^COOLIFY_URL=' "$LOCAL_ENV_FILE"; then
    sed -i "s|^COOLIFY_URL=.*|COOLIFY_URL=\"http://$WSL_IP:8000\"|" "$LOCAL_ENV_FILE"
  else
    printf 'COOLIFY_URL="http://%s:8000"\n' "$WSL_IP" >> "$LOCAL_ENV_FILE"
  fi
}

prepare_supabase_compose() {
  mkdir -p "$SUPABASE_WORKDIR"

  if [[ ! -d "$SUPABASE_WORKDIR/.git" ]]; then
    yellow "Cloning official Supabase repository for Docker Compose templates..."
    git clone --depth 1 https://github.com/supabase/supabase.git "$SUPABASE_WORKDIR"
  else
    yellow "Updating official Supabase repository..."
    git -C "$SUPABASE_WORKDIR" pull --ff-only
  fi

  mkdir -p "$SUPABASE_WORKDIR/docker/volumes/db/init"
  cp "$ROOT_DIR/supabase/init/00_extensions.sql" "$SUPABASE_WORKDIR/docker/volumes/db/init/00_extensions.sql"

  if [[ ! -f "$SUPABASE_WORKDIR/docker/.env" && -f "$SUPABASE_WORKDIR/docker/.env.example" ]]; then
    cp "$SUPABASE_WORKDIR/docker/.env.example" "$SUPABASE_WORKDIR/docker/.env"
    local postgres_password jwt_secret anon_key service_role_key
    postgres_password="$(openssl rand -base64 32 | tr -d '\n')"
    jwt_secret="$(openssl rand -hex 32)"
    anon_key="$(python3 - "$jwt_secret" anon <<'PY'
import base64, hashlib, hmac, json, sys, time
secret, role = sys.argv[1], sys.argv[2]
header = {"alg": "HS256", "typ": "JWT"}
payload = {"role": role, "iss": "supabase", "iat": int(time.time()), "exp": 1893456000}
def b64(data):
    return base64.urlsafe_b64encode(json.dumps(data, separators=(",", ":")).encode()).rstrip(b"=").decode()
signing_input = f"{b64(header)}.{b64(payload)}"
signature = base64.urlsafe_b64encode(hmac.new(secret.encode(), signing_input.encode(), hashlib.sha256).digest()).rstrip(b"=").decode()
print(f"{signing_input}.{signature}")
PY
)"
    service_role_key="$(python3 - "$jwt_secret" service_role <<'PY'
import base64, hashlib, hmac, json, sys, time
secret, role = sys.argv[1], sys.argv[2]
header = {"alg": "HS256", "typ": "JWT"}
payload = {"role": role, "iss": "supabase", "iat": int(time.time()), "exp": 1893456000}
def b64(data):
    return base64.urlsafe_b64encode(json.dumps(data, separators=(",", ":")).encode()).rstrip(b"=").decode()
signing_input = f"{b64(header)}.{b64(payload)}"
signature = base64.urlsafe_b64encode(hmac.new(secret.encode(), signing_input.encode(), hashlib.sha256).digest()).rstrip(b"=").decode()
print(f"{signing_input}.{signature}")
PY
)"
    sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$postgres_password|" "$SUPABASE_WORKDIR/docker/.env"
    sed -i "s|^JWT_SECRET=.*|JWT_SECRET=$jwt_secret|" "$SUPABASE_WORKDIR/docker/.env"
    sed -i "s|^ANON_KEY=.*|ANON_KEY=$anon_key|" "$SUPABASE_WORKDIR/docker/.env"
    sed -i "s|^SERVICE_ROLE_KEY=.*|SERVICE_ROLE_KEY=$service_role_key|" "$SUPABASE_WORKDIR/docker/.env"
    yellow "Created local Supabase .env with generated secrets. Paste these values into Coolify's environment manager."
  fi

  green "Supabase Docker Compose is prepared at $SUPABASE_WORKDIR/docker"
  yellow "Deploy it in Coolify as a Docker Compose resource using that folder, then paste secrets into Coolify's environment manager."
}

wait_for_coolify() {
  # shellcheck disable=SC1090
  source "$LOCAL_ENV_FILE"
  yellow "Waiting for Coolify at $COOLIFY_URL..."
  for _ in {1..30}; do
    if curl -fsS --max-time 5 "$COOLIFY_URL" >/dev/null; then
      green "Coolify is reachable."
      return
    fi
    sleep 5
  done
  yellow "Coolify is not reachable yet. It may still be starting; check with ./verify.sh."
}

run_optional_migrations_and_seed() {
  if [[ -d "$ROOT_DIR/migrations" ]]; then
    yellow "Migrations directory exists, but no app-specific migration runner is defined in Phase 1."
  fi

  if [[ -d "$ROOT_DIR/seed" ]]; then
    yellow "Seed directory exists, but no app-specific seed runner is defined in Phase 1."
  fi
}

print_summary() {
  # shellcheck disable=SC1090
  source "$LOCAL_ENV_FILE"
  local api_url="${API_URL:-http://$WSL_IP:3000}"
  local admin_url="${ADMIN_URL:-http://$WSL_IP:3001}"
  local studio_url="${STUDIO_URL:-http://$WSL_IP:3002}"

  [[ -f "$ROOT_DIR/.env.tunnel" ]] && source "$ROOT_DIR/.env.tunnel"

  printf '\n'
  green "Colony development foundation is prepared."
  printf 'Coolify dashboard: %s\n' "$COOLIFY_URL"
  printf 'Supabase Studio:   %s\n' "${STUDIO_URL:-$studio_url}"
  printf 'API URL:           %s\n' "${API_URL:-$api_url}"
  printf 'Admin panel URL:   %s\n' "${ADMIN_URL:-$admin_url}"
  printf '\nNext tunnel command: ./tunnel.sh\n'
}

main() {
  ensure_wsl
  install_base_packages
  configure_wsl_systemd
  install_docker_if_needed
  install_coolify_if_needed
  update_local_env
  prepare_supabase_compose
  wait_for_coolify
  run_optional_migrations_and_seed
  print_summary
}

main "$@"
