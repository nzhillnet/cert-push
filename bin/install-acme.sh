#!/usr/bin/env bash
# One-time setup: install acme.sh and point it at Let's Encrypt.
# Run this once on the workstation before using manage-certs.sh.
set -euo pipefail

ACME="${HOME}/.acme.sh/acme.sh"

if [[ -f "$ACME" ]]; then
  echo "acme.sh already installed at $ACME"
else
  echo "Installing acme.sh..."
  curl https://get.acme.sh | sh -s email=your-email@example.com
fi

echo "Setting default CA to Let's Encrypt..."
"$ACME" --set-default-ca --server letsencrypt

echo "Installing cron job for automatic renewal..."
"$ACME" --install-cronjob

echo ""
echo "Done. Next steps:"
echo "  1. Create ~/.secrets/cloudflare.env (chmod 600) with:"
echo '     CF_Token="<your scoped API token>"'
echo '     CF_Account_ID="<your account ID>"'
echo "  2. Edit hosts.conf.yaml with your host entries."
echo "  3. Run: ./manage-certs.sh --host <name> --dry-run"
echo "  4. Run: ./manage-certs.sh --host <name>"
