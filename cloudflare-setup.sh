#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$ROOT_DIR/cloudflare.config.sh"
ENV_FILE="$ROOT_DIR/.env.tunnel"
CLOUDFLARED_DIR="$HOME/.cloudflared"
TUNNEL_CONFIG_FILE="$CLOUDFLARED_DIR/${CF_TUNNEL_NAME:-colony-dev}.yml"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
die() { red "ERROR: $*"; exit 1; }

load_config() {
  [[ -f "$CONFIG_FILE" ]] || die "Missing $CONFIG_FILE. Copy cloudflare.config.example.sh to cloudflare.config.sh and fill it in."
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

  required_vars=(
    CF_DOMAIN CF_TUNNEL_NAME CF_ACCOUNT_ID CF_API_TOKEN
    CF_API_SUBDOMAIN CF_ADMIN_SUBDOMAIN CF_STUDIO_SUBDOMAIN
    LOCAL_API_PORT LOCAL_ADMIN_PORT LOCAL_STUDIO_PORT
  )

  for var_name in "${required_vars[@]}"; do
    [[ -n "${!var_name:-}" ]] || die "Missing required config value: $var_name"
    [[ "${!var_name}" != your_* ]] || die "Replace placeholder config value: $var_name"
  done

  TUNNEL_CONFIG_FILE="$CLOUDFLARED_DIR/$CF_TUNNEL_NAME.yml"
}

install_cloudflared_if_needed() {
  if command -v cloudflared >/dev/null 2>&1; then
    green "cloudflared is already installed."
    return
  fi

  yellow "Installing cloudflared from the official Cloudflare Linux repository..."
  command -v sudo >/dev/null 2>&1 || die "sudo is required to install cloudflared."
  sudo mkdir -p --mode=0755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" | sudo tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y cloudflared
}

ensure_authenticated() {
  mkdir -p "$CLOUDFLARED_DIR"

  if [[ -f "$CLOUDFLARED_DIR/cert.pem" ]]; then
    green "Cloudflare login credentials found."
    return
  fi

  yellow "Cloudflare login is required. A browser will open; authorize your domain, then return here."
  cloudflared tunnel login
  [[ -f "$CLOUDFLARED_DIR/cert.pem" ]] || die "Cloudflare login did not create $CLOUDFLARED_DIR/cert.pem."
}

get_existing_tunnel_id() {
  cloudflared tunnel list --name "$CF_TUNNEL_NAME" --output json 2>/dev/null \
    | python3 -c 'import json,sys; data=json.load(sys.stdin); print(data[0]["id"] if data else "")' 2>/dev/null || true
}

ensure_tunnel() {
  local existing_id
  existing_id="$(get_existing_tunnel_id)"

  if [[ -n "$existing_id" ]]; then
    TUNNEL_ID="$existing_id"
    green "Named tunnel already exists: $CF_TUNNEL_NAME ($TUNNEL_ID)"
  else
    yellow "Creating named tunnel: $CF_TUNNEL_NAME"
    cloudflared tunnel create "$CF_TUNNEL_NAME"
    TUNNEL_ID="$(get_existing_tunnel_id)"
  fi

  [[ -n "${TUNNEL_ID:-}" ]] || die "Could not determine tunnel ID for $CF_TUNNEL_NAME."
  CREDENTIALS_FILE="$CLOUDFLARED_DIR/$TUNNEL_ID.json"
  [[ -f "$CREDENTIALS_FILE" ]] || die "Missing tunnel credentials file: $CREDENTIALS_FILE"
}

write_tunnel_config() {
  yellow "Writing tunnel ingress config: $TUNNEL_CONFIG_FILE"
  cat > "$TUNNEL_CONFIG_FILE" <<EOF
tunnel: $TUNNEL_ID
credentials-file: $CREDENTIALS_FILE

ingress:
  - hostname: $CF_API_SUBDOMAIN.$CF_DOMAIN
    service: http://localhost:$LOCAL_API_PORT
  - hostname: $CF_ADMIN_SUBDOMAIN.$CF_DOMAIN
    service: http://localhost:$LOCAL_ADMIN_PORT
  - hostname: $CF_STUDIO_SUBDOMAIN.$CF_DOMAIN
    service: http://localhost:$LOCAL_STUDIO_PORT
  - service: http_status:404
EOF
}

api_request() {
  local method="$1"
  local url="$2"
  local data="${3:-}"

  if [[ -n "$data" ]]; then
    curl -fsS -X "$method" "https://api.cloudflare.com/client/v4$url" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json" \
      --data "$data"
  else
    curl -fsS -X "$method" "https://api.cloudflare.com/client/v4$url" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json"
  fi
}

get_zone_id() {
  api_request GET "/zones?name=$CF_DOMAIN&account.id=$CF_ACCOUNT_ID" \
    | python3 -c 'import json,sys; data=json.load(sys.stdin); results=data.get("result", []); print(results[0]["id"] if results else "")'
}

upsert_cname() {
  local subdomain="$1"
  local fqdn="$subdomain.$CF_DOMAIN"
  local target="$TUNNEL_ID.cfargotunnel.com"
  local record_id
  local payload

  payload="$(printf '{"type":"CNAME","name":"%s","content":"%s","ttl":1,"proxied":true}' "$fqdn" "$target")"
  record_id="$(api_request GET "/zones/$ZONE_ID/dns_records?type=CNAME&name=$fqdn" \
    | python3 -c 'import json,sys; data=json.load(sys.stdin); results=data.get("result", []); print(results[0]["id"] if results else "")')"

  if [[ -n "$record_id" ]]; then
    api_request PUT "/zones/$ZONE_ID/dns_records/$record_id" "$payload" >/dev/null
    green "Updated DNS CNAME: $fqdn -> $target"
  else
    api_request POST "/zones/$ZONE_ID/dns_records" "$payload" >/dev/null
    green "Created DNS CNAME: $fqdn -> $target"
  fi
}

configure_dns() {
  yellow "Configuring DNS records through the Cloudflare API..."
  ZONE_ID="$(get_zone_id)"
  [[ -n "$ZONE_ID" ]] || die "Could not find Cloudflare zone for $CF_DOMAIN. Check CF_DOMAIN, CF_ACCOUNT_ID, and CF_API_TOKEN permissions."

  upsert_cname "$CF_API_SUBDOMAIN"
  upsert_cname "$CF_ADMIN_SUBDOMAIN"
  upsert_cname "$CF_STUDIO_SUBDOMAIN"
}

write_env_file() {
  cat > "$ENV_FILE" <<EOF
# Generated by cloudflare-setup.sh
CF_TUNNEL_NAME="$CF_TUNNEL_NAME"
CF_DOMAIN="$CF_DOMAIN"
API_URL="https://$CF_API_SUBDOMAIN.$CF_DOMAIN"
ADMIN_URL="https://$CF_ADMIN_SUBDOMAIN.$CF_DOMAIN"
STUDIO_URL="https://$CF_STUDIO_SUBDOMAIN.$CF_DOMAIN"
EOF
  green "Wrote permanent tunnel URLs to $ENV_FILE"
}

main() {
  load_config
  install_cloudflared_if_needed
  ensure_authenticated
  ensure_tunnel
  write_tunnel_config
  configure_dns
  write_env_file

  green "Cloudflare tunnel setup complete."
  printf 'API:    https://%s.%s\n' "$CF_API_SUBDOMAIN" "$CF_DOMAIN"
  printf 'Admin:  https://%s.%s\n' "$CF_ADMIN_SUBDOMAIN" "$CF_DOMAIN"
  printf 'Studio: https://%s.%s\n' "$CF_STUDIO_SUBDOMAIN" "$CF_DOMAIN"
  yellow "Manual check: Cloudflare Dashboard > your domain > DNS should show the three CNAME records."
}

main "$@"
