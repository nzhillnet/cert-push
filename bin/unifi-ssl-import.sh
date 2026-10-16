#!/usr/bin/env bash
# Example reload_cmd for a UniFi OS Server host (runs as root after the new cert is copied to
# /etc/ssl/<name>/). On UniFi OS, the Let's Encrypt cert is usually served by an nginx TLS front
# (e.g. /etc/nginx/sites-available/unifios, port 443, with the UI's own LAN port reverse-proxied
# or redirected to it) — NOT installed into UniFi OS itself.
#
# Do NOT copy the cert into UniFi's own internal service volume (its "uosserver" config directory):
# the host-side supervisor service verifies that internal cert against 127.0.0.1 for its own
# control-plane link, a public Let's Encrypt cert can never match that, and the UI updater silently
# stops working. Keep the Let's Encrypt cert purely on the nginx front.
set -euo pipefail

CERT=/etc/ssl/your-unifios-host/fullchain.pem
KEY=/etc/ssl/your-unifios-host/key.pem
[[ -s "$CERT" && -s "$KEY" ]] || { echo "ERROR: cert/key missing"; exit 1; }
openssl x509 -in "$CERT" -noout -checkend 0 >/dev/null || { echo "ERROR: $CERT is expired/invalid"; exit 1; }
chmod 600 "$KEY"
nginx -t
systemctl reload nginx
echo "nginx reloaded with $(openssl x509 -in "$CERT" -noout -subject -enddate | tr '\n' ' ')"
