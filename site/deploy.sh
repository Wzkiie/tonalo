#!/bin/sh
# Lädt die Website auf tonalo.app hoch. Token (und Account-ID) liegen nur in ~/.config/tonalo/cloudflare.env,
# nie im Repo. Mit --dry-run wird nur gebaut und geprüft, nichts hochgeladen.
set -e
cd "$(dirname "$0")"
ENV="$HOME/.config/tonalo/cloudflare.env"
if [ "$1" != "--dry-run" ]; then
  [ -r "$ENV" ] || { echo "Fehlt: $ENV (CLOUDFLARE_API_TOKEN=..., CLOUDFLARE_ACCOUNT_ID=...)"; exit 1; }
  set -a; . "$ENV"; set +a
fi
export WRANGLER_SEND_METRICS=false # keine Telemetrie an Cloudflare
exec npx --yes wrangler@4.151.1 deploy "$@"
