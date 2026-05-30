# Phase 1.0: Colony Development Environment

This phase prepares the local foundation only: WSL Ubuntu, Docker Engine, Coolify, self-hosted Supabase assets, WSL IP discovery, tunnel helpers, Tailscale testing, and health checks.

## Scripts

- `colony-dev.sh` is the smart orchestrator: it auto-detects WSL/Docker/Coolify/Supabase/tunnel/backend state and runs the missing safe setup/start steps.
- `setup.sh` installs base packages, Docker Engine, Coolify, prepares the official Supabase Docker Compose folder, writes `.env.local`, and prints the key URLs.
- `find-wsl-ip.sh` detects the current WSL IP and updates `.env.local`.
- `tunnel.sh` asks whether to use Cloudflare Tunnel or direct public IP, then writes `.env.tunnel`.
- `tailscale-setup.sh` installs/connects Tailscale and writes stable Tailscale URLs to `.env.tunnel`.
- `verify.sh` checks Coolify, Supabase containers, PostgreSQL/PostGIS, Redis, Studio, and the active tunnel URL.

## Fresh Setup

Run from WSL:

```bash
chmod +x colony-dev.sh
./colony-dev.sh auto
```

If Docker group or WSL systemd changes were applied, restart WSL from Windows PowerShell:

```powershell
wsl --shutdown
```

During first install, `setup.sh` asks for the Coolify admin username, email, and password, then passes them to the official installer as root-user environment variables. After install, open the Coolify dashboard printed by `setup.sh`, usually `http://<wsl-ip>:8000`.

## Supabase Through Coolify

`setup.sh` clones the official Supabase repository into `.local/supabase` and prepares `.local/supabase/docker`.

In Coolify:

1. Create a new Docker Compose resource.
2. Use `.local/supabase/docker/docker-compose.yml` as the compose file source.
3. Paste values from `.local/supabase/docker/.env` into Coolify's environment variable manager.
4. Deploy the resource.

Supabase self-hosted includes PostgreSQL, PostGIS-capable database extensions, Studio, PostgREST, Realtime, Storage, Auth, Kong gateway, metadata services, and supporting containers. The init SQL at `supabase/init/00_extensions.sql` enables `postgis`, `uuid-ossp`, and `pg_trgm` on first database creation.

## Tunnel Choices

Cloudflare named tunnel:

```bash
./tunnel.sh
```

Tailscale device testing:

```bash
./tailscale-setup.sh
```

Direct public IP mode is available in `./tunnel.sh`, but it requires router and Windows Firewall port forwarding.

## Verification

```bash
./colony-dev.sh status
./verify.sh
```

Run this after setup, after deploying Supabase in Coolify, or whenever a service breaks.

## Backend Testing From Windows + WSL

Use this as your normal command:

```bash
./colony-dev.sh auto
```

The script refreshes the WSL IP, starts Docker/Coolify if possible, auto-starts a Node backend when it finds a `package.json` with a `dev`, `start:dev`, or `start` script, checks `http://127.0.0.1:3000`, then ensures the configured tunnel URL is written to `.env.tunnel`.
