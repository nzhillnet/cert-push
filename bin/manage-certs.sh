#!/usr/bin/env bash
# Manages Let's Encrypt certs via acme.sh + Cloudflare DNS-01, then
# distributes each cert to its target host over SSH.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/../hosts.conf.yaml"
CACHE_DIR="${HOME}/certs/cache"
LOG_FILE="${HOME}/certs/manage-certs.log"
CF_ENV="${HOME}/.secrets/cloudflare.env"
ACME="${HOME}/.acme.sh/acme.sh"

usage() {
  echo "Usage: $0 [--host <name>] [--dry-run]"
  echo "  --host <name>   Process only this host (from hosts.conf.yaml)"
  echo "  --dry-run       Print what would be done without issuing/deploying"
  exit 1
}

log() {
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$ts] $*" | tee -a "$LOG_FILE"
}

die() { log "ERROR: $*"; exit 1; }

# Parse args
FILTER_HOST=""
DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)    FILTER_HOST="${2:?--host requires a name}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# Ensure log dir exists before first log() call
mkdir -p "$CACHE_DIR"
mkdir -p "$(dirname "$LOG_FILE")"

# Preflight checks
[[ -f "$ACME" ]]   || die "acme.sh not found at $ACME — run install-acme.sh first"
[[ -f "$CF_ENV" ]] || die "Cloudflare env not found at $CF_ENV — create it (chmod 600)"
[[ -f "$CONFIG" ]] || die "Config not found: $CONFIG"

perms=$(stat -c '%a' "$CF_ENV")
[[ "$perms" == "600" ]] || log "WARN: $CF_ENV has permissions $perms, should be 600"

# shellcheck source=/dev/null
set -a; source "$CF_ENV"; set +a
[[ -n "${CF_Token:-}" ]] || die "CF_Token not set in $CF_ENV"

process_host() {
  local name="$1"
  local fqdn="$2"
  local deploy_target="$3"
  local deploy_user="$4"
  local remote_cert_path="$5"
  local remote_key_path="$6"
  local reload_cmd="$7"
  local transfer_sudo="${8:-false}"   # true = use "sudo tee" instead of "cat >" (e.g. HAOS)
  local keylength="${9:-}"            # e.g. "2048" for RSA; empty = acme.sh default (ECC)

  local cert_dir="${CACHE_DIR}/${name}"
  local cert_file="${cert_dir}/cert.pem"
  local key_file="${cert_dir}/key.pem"
  local fullchain_file="${cert_dir}/fullchain.pem"

  log "--- Processing host: ${name} (${fqdn}) ---"

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY-RUN: would issue cert for ${fqdn}"
    log "DRY-RUN: would deploy to ${deploy_user}@${deploy_target}:${remote_cert_path}"
    log "DRY-RUN: would run reload: ${reload_cmd}"
    return 0
  fi

  mkdir -p "$cert_dir"
  chmod 700 "$cert_dir"

  # Issue (or renew) cert. acme.sh exits 2 when cert is not yet due.
  log "Issuing cert for ${fqdn}..."
  local issue_rc=0
  "$ACME" --issue \
    --dns dns_cf \
    -d "$fqdn" \
    ${keylength:+--keylength "$keylength"} \
    --cert-file      "$cert_file" \
    --key-file       "$key_file" \
    --fullchain-file "$fullchain_file" \
    2>&1 | tee -a "$LOG_FILE" || issue_rc=${PIPESTATUS[0]}

  if [[ $issue_rc -eq 2 ]]; then
    log "Cert for ${fqdn} is up-to-date (not yet due for renewal)"
    # Still ensure the deploy hook is registered; fall through to --install-cert
  elif [[ $issue_rc -ne 0 ]]; then
    log "ERROR: acme.sh --issue failed for ${fqdn} (exit ${issue_rc})"
    return 1
  else
    chmod 600 "$key_file"
  fi

  # Deploy command — written as a script to avoid quoting hell in --reloadcmd.
  # For localhost (the workstation itself), use cp + direct execution instead of scp/ssh.
  local deploy_script="${cert_dir}/deploy.sh"
  if [[ "$deploy_target" == "localhost" || "$deploy_target" == "127.0.0.1" ]]; then
    cat > "$deploy_script" <<DEPLOY
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "${remote_cert_path}" "${remote_key_path}"
cp "${cert_file}" "${fullchain_file}" "${remote_cert_path}"
cp "${key_file}" "${remote_key_path}"
chmod 600 "${remote_key_path}/key.pem"
${reload_cmd}
DEPLOY
  else
    # Choose write verb: "sudo tee FILE > /dev/null" for hosts where deploy_user lacks write
    # access to the cert dir (e.g. an appliance where you're non-root but have passwordless
    # sudo), or "cat > FILE" for root-owned hosts.
    # The key is written under umask 077: a new key.pem is 600. An existing file keeps its mode
    # (cat > / tee don't change it), so hosts whose reload_cmd sets 640 for a service group keep that.
    if [[ "$transfer_sudo" == "true" ]]; then
      local write_cert="sudo tee ${remote_cert_path}cert.pem > /dev/null"
      local write_fullchain="sudo tee ${remote_cert_path}fullchain.pem > /dev/null"
      local write_key="umask 077; sudo tee ${remote_key_path}key.pem > /dev/null"
    else
      local write_cert="cat > ${remote_cert_path}cert.pem"
      local write_fullchain="cat > ${remote_cert_path}fullchain.pem"
      local write_key="umask 077; cat > ${remote_key_path}key.pem"
    fi
    cat > "$deploy_script" <<DEPLOY
#!/usr/bin/env bash
set -euo pipefail
ssh -n -i "${HOME}/.ssh/cert-deploy" "${deploy_user}@${deploy_target}" "mkdir -p ${remote_cert_path} ${remote_key_path}"
ssh -i "${HOME}/.ssh/cert-deploy" "${deploy_user}@${deploy_target}" "${write_cert}"       < "${cert_file}"
ssh -i "${HOME}/.ssh/cert-deploy" "${deploy_user}@${deploy_target}" "${write_fullchain}"  < "${fullchain_file}"
ssh -i "${HOME}/.ssh/cert-deploy" "${deploy_user}@${deploy_target}" "${write_key}"        < "${key_file}"
ssh -n -i "${HOME}/.ssh/cert-deploy" "${deploy_user}@${deploy_target}" "${reload_cmd}"
DEPLOY
  fi
  chmod 700 "$deploy_script"

  log "Registering deploy hook for ${fqdn}..."
  local install_rc=0
  "$ACME" --install-cert \
    -d "$fqdn" \
    --cert-file      "$cert_file" \
    --key-file       "$key_file" \
    --fullchain-file "$fullchain_file" \
    --reloadcmd      "bash ${deploy_script}" \
    2>&1 | tee -a "$LOG_FILE" || install_rc=${PIPESTATUS[0]}

  if [[ $install_rc -ne 0 ]]; then
    log "ERROR: acme.sh --install-cert failed for ${fqdn} (exit ${install_rc})"
    return 1
  fi

  log "Running initial deploy to ${deploy_user}@${deploy_target}..."
  local deploy_rc=0
  bash "$deploy_script" 2>&1 | tee -a "$LOG_FILE" || deploy_rc=${PIPESTATUS[0]}

  if [[ $deploy_rc -ne 0 ]]; then
    log "ERROR: deploy failed for ${name} (exit ${deploy_rc})"
    return 1
  fi

  log "Deploy and reload complete for ${name}"
}

# Enumerate hosts from YAML, emitting one TSV line per host
enumerate_hosts() {
  python3 - "$CONFIG" "$FILTER_HOST" <<'PYEOF'
import sys, yaml, json

config_file = sys.argv[1]
filter_host = sys.argv[2] if len(sys.argv) > 2 else ""

with open(config_file) as f:
    config = yaml.safe_load(f)

domain = config.get("domain", "")
hosts  = config.get("hosts") or []

matched = []
for h in hosts:
    if filter_host and h["name"] != filter_host:
        continue
    matched.append(h)

if filter_host and not matched:
    print(f"Host '{filter_host}' not found in config", file=sys.stderr)
    sys.exit(1)

for h in matched:
    fqdn = f"{h['name']}.{domain}"
    print("\t".join([
        h["name"],
        fqdn,
        str(h["deploy_target"]),
        h["deploy_user"],
        h["remote_cert_path"],
        h["remote_key_path"],
        h["reload_cmd"],
        "true" if h.get("transfer_sudo") else "false",
        str(h.get("keylength", "")),
    ]))
PYEOF
}

# Main
log "=== manage-certs.sh start$([ -n "$FILTER_HOST" ] && echo " (host: $FILTER_HOST)") ==="

overall_rc=0
any_host=false

while IFS=$'\t' read -r name fqdn deploy_target deploy_user \
                         remote_cert_path remote_key_path reload_cmd transfer_sudo keylength; do
  any_host=true
  if process_host "$name" "$fqdn" "$deploy_target" "$deploy_user" \
                  "$remote_cert_path" "$remote_key_path" "$reload_cmd" "$transfer_sudo" "$keylength"; then
    log "SUCCESS: ${name}"
  else
    log "FAILED:  ${name}"
    overall_rc=1
  fi
done < <(enumerate_hosts)

if [[ "$any_host" == false ]]; then
  log "No hosts found in config. Add entries to ${CONFIG}."
fi

log "=== manage-certs.sh done ==="
exit $overall_rc
