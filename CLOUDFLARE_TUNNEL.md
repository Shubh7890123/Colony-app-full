# Phase 0: Cloudflare Permanent Tunnel

## Files

- `cloudflare.config.example.sh` — copy to `cloudflare.config.sh` and fill in once.
- `cloudflare.config.sh` — local Cloudflare settings and API token; gitignored.
- `cloudflare-setup.sh` — one-time tunnel creation, DNS setup, and `.env.tunnel` generation.
- `tunnel.sh` — day-to-day tunnel start, stop, and restart command.
- `tunnel-status.sh` — checks the tunnel process and performs real HTTP checks for all URLs.
- `.env.tunnel` — generated permanent URLs for other scripts and Flutter build configuration.

## One-Time Setup

```bash
cp cloudflare.config.example.sh cloudflare.config.sh
nano cloudflare.config.sh
./cloudflare-setup.sh
```

The setup script installs `cloudflared` in WSL if needed, opens Cloudflare login if not authenticated, creates or reuses the named tunnel, writes the tunnel ingress config, creates the three CNAME DNS records through the Cloudflare API, and writes `.env.tunnel`.

## Daily Use

```bash
./tunnel.sh start
./tunnel-status.sh
./tunnel.sh stop
```

After setup, manually verify Cloudflare Dashboard > your domain > DNS contains CNAME records for `api`, `admin`, and `studio` pointing to the tunnel target.
