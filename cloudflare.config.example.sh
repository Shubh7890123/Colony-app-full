#!/usr/bin/env bash

# Copy this file to cloudflare.config.sh and fill in your values once.
# cloudflare.config.sh is intentionally gitignored because it contains an API token.

CF_DOMAIN="yourdomain.com"
CF_TUNNEL_NAME="colony-dev"
CF_ACCOUNT_ID="your_cloudflare_account_id"
CF_API_TOKEN="your_cloudflare_api_token"

CF_API_SUBDOMAIN="api"
CF_ADMIN_SUBDOMAIN="admin"
CF_STUDIO_SUBDOMAIN="studio"

LOCAL_API_PORT="3000"
LOCAL_ADMIN_PORT="3001"
LOCAL_STUDIO_PORT="3002"
