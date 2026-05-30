#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$ROOT_DIR/.env.local"

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*"; }
die() { red "ERROR: $*"; exit 1; }

WSL_IP="$(hostname -I | awk '{print $1}')"
[[ -n "$WSL_IP" ]] || die "Could not detect WSL IP address."

touch "$ENV_FILE"
if grep -q '^WSL_IP=' "$ENV_FILE"; then
  sed -i "s|^WSL_IP=.*|WSL_IP=\"$WSL_IP\"|" "$ENV_FILE"
else
  printf 'WSL_IP="%s"\n' "$WSL_IP" >> "$ENV_FILE"
fi

green "WSL IP: $WSL_IP"
printf 'Updated %s\n' "$ENV_FILE"
