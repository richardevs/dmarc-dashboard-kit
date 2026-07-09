#!/usr/bin/env bash
set -euo pipefail

DB_NAME="dmarc-reports"
WRANGLER_TOML="wrangler.toml"
WORKER_NAME="dmarc-dashboard-kit"
ENV_FILE=".env"

# --- Colors (disabled when not a TTY or when NO_COLOR is set) ---
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_GREEN=$'\033[32m'; C_CYAN=$'\033[36m'; C_YELLOW=$'\033[33m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""
  C_GREEN=""; C_CYAN=""; C_YELLOW=""
fi

# --- Parse arguments ---
MODE="deploy"
CLEANUP_ZONE_ID=""
ASSUME_YES="false"

for arg in "$@"; do
  case "$arg" in
    --cleanup) MODE="cleanup" ;;
    --zone-id=*) CLEANUP_ZONE_ID="${arg#--zone-id=}" ;;
    --yes|-y) ASSUME_YES="true" ;;
    -h|--help)
      cat <<'USAGE'
Usage:
  deploy.sh                     Deploy / update all resources (idempotent).
  deploy.sh --cleanup [opts]    Remove the zone-scoped resources for a receiving
                                domain you no longer use: the dmarc@<domain> email
                                routing rule and the _report._dmarc TXT records.
                                Never touches the worker, D1, stored reports, or
                                Cloudflare Access.

Cleanup options:
  --zone-id=<id>   Zone to clean (defaults to CLOUDFLARE_ZONE_ID in .env). Pass
                   the OLD zone id when migrating to a new receiving domain.
  --yes, -y        Skip the confirmation prompt.
USAGE
      exit 0
      ;;
    *) echo "Unknown argument: $arg (try --help)"; exit 1 ;;
  esac
done

# --- Load config from .env ---
if [ ! -f "$ENV_FILE" ]; then
  echo ""
  echo "No .env file found. Creating one — please fill in the values."
  cp .env.example "$ENV_FILE"
  echo "Created $ENV_FILE — edit it and re-run this script."
  exit 0
fi

# shellcheck source=/dev/null
# Strip inline comments before sourcing so "VAR=value  # comment" works correctly
# set -a auto-exports all variables so python3 subprocesses see them via os.environ
set -a
eval "$(sed 's/[[:space:]]*#.*$//' "$ENV_FILE")"
set +a

# Run wrangler non-interactively. Without this, recent wrangler versions print a
# "Cloudflare agent skills are available..." banner to stdout, which pollutes the
# --json output we parse below and breaks the D1 existence check.
export CI=true

# Validate required vars (needed for both deploy and cleanup)
for var in CLOUDFLARE_API_TOKEN DMARC_EMAIL; do
  if [ -z "${!var:-}" ]; then
    echo "ERROR: $var is not set in $ENV_FILE"
    exit 1
  fi
done

if [ "$MODE" = "deploy" ]; then
  for var in CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_ZONE_ID; do
    if [ -z "${!var:-}" ]; then
      echo "ERROR: $var is not set in $ENV_FILE"
      exit 1
    fi
  done

  if [ -z "${ACCESS_ALLOWED_EMAILS:-}" ] && [ -z "${ACCESS_ALLOWED_EMAIL_DOMAINS:-}" ] && [ -z "${ACCESS_ALLOWED_IPS:-}" ]; then
    echo "ERROR: Set at least one of ACCESS_ALLOWED_EMAILS, ACCESS_ALLOWED_EMAIL_DOMAINS, or ACCESS_ALLOWED_IPS in $ENV_FILE"
    exit 1
  fi

  if [ -z "${ACCESS_ALLOWED_EMAILS:-}" ] && [ -z "${ACCESS_ALLOWED_EMAIL_DOMAINS:-}" ] && [ -n "${ACCESS_ALLOWED_IPS:-}" ]; then
    echo "  WARNING: Only ACCESS_ALLOWED_IPS is set — anyone from these IP ranges can access the dashboard without email identity verification."
  fi
fi

CF_API="https://api.cloudflare.com/client/v4"
AUTH_HEADER="Authorization: Bearer ${CLOUDFLARE_API_TOKEN}"

cf_get()  { curl -s -H "$AUTH_HEADER" "$@"; }
cf_post() { curl -s -H "$AUTH_HEADER" -H "Content-Type: application/json" "$@"; }

# --- Cleanup mode: remove the zone-scoped resources for a retired domain ---
# Only touches the email routing rule and _report._dmarc TXT records on the given
# zone. The worker, D1 database, stored reports, and Access are account-scoped and
# shared, so they are deliberately left untouched.
cleanup_zone() {
  local ZONE_ID="${CLEANUP_ZONE_ID:-${CLOUDFLARE_ZONE_ID:-}}"
  if [ -z "$ZONE_ID" ]; then
    echo "ERROR: no zone to clean up. Pass --zone-id=<id> or set CLOUDFLARE_ZONE_ID in $ENV_FILE."
    exit 1
  fi

  echo "=== DMARC Dashboard Kit Cleanup ==="
  echo ""
  echo "Detecting domain from zone ${ZONE_ID}..."
  local ZONE_RESPONSE DOMAIN
  ZONE_RESPONSE=$(cf_get "${CF_API}/zones/${ZONE_ID}")
  DOMAIN=$(echo "$ZONE_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['name'])" 2>/dev/null || echo "")
  if [ -z "$DOMAIN" ]; then
    echo "  ERROR: Could not detect domain from zone ID. Check the zone id and API token."
    echo "$ZONE_RESPONSE" | python3 -c "import sys,json; [print(f'  {e[\"message\"]}') for e in json.load(sys.stdin).get('errors',[])]" 2>/dev/null || true
    exit 1
  fi
  local ADDRESS="${DMARC_EMAIL}@${DOMAIN}"

  # Gather everything that would be deleted before touching anything.
  local RULES RULE_ROWS
  RULES=$(cf_get "${CF_API}/zones/${ZONE_ID}/email/routing/rules?per_page=50" || echo '{"result":[]}')
  RULE_ROWS=$(echo "$RULES" | ADDRESS="$ADDRESS" python3 -c "
import sys, json, os
addr = os.environ['ADDRESS']
rules = json.load(sys.stdin).get('result', [])
for r in rules:
    if any(m.get('field') == 'to' and m.get('value') == addr for m in r.get('matchers', [])):
        print(r['id'] + '\t' + (r.get('name') or '(unnamed rule)'))
" 2>/dev/null || echo "")

  local DNS DNS_ROWS
  DNS=$(cf_get "${CF_API}/zones/${ZONE_ID}/dns_records?type=TXT&per_page=100" || echo '{"result":[]}')
  DNS_ROWS=$(echo "$DNS" | python3 -c "
import sys, json
recs = json.load(sys.stdin).get('result', [])
for r in recs:
    if '_report._dmarc' in r.get('name', ''):
        print(r['id'] + '\t' + r['name'])
" 2>/dev/null || echo "")

  echo "  Domain: ${DOMAIN}"
  echo ""
  echo "Will delete from zone ${DOMAIN}:"
  echo ""
  echo "  Email routing rules (${ADDRESS} → worker):"
  if [ -z "$RULE_ROWS" ]; then
    echo "    (none found)"
  else
    while IFS=$'\t' read -r _ RULE_NAME; do
      [ -z "$RULE_NAME" ] && continue
      echo "    • ${RULE_NAME}"
    done <<< "$RULE_ROWS"
  fi
  echo ""
  echo "  _report._dmarc TXT records:"
  if [ -z "$DNS_ROWS" ]; then
    echo "    (none found)"
  else
    while IFS=$'\t' read -r _ REC_NAME; do
      [ -z "$REC_NAME" ] && continue
      echo "    • ${REC_NAME}"
    done <<< "$DNS_ROWS"
  fi
  echo ""
  echo "Preserved (not touched): worker, D1 database, stored reports, Cloudflare Access."
  echo ""

  if [ -z "$RULE_ROWS" ] && [ -z "$DNS_ROWS" ]; then
    echo "Nothing to clean up in this zone."
    return
  fi

  if [ "$ASSUME_YES" != "true" ]; then
    printf "Proceed with deletion? [y/N] "
    read -r REPLY </dev/tty 2>/dev/null || REPLY=""
    case "$REPLY" in
      y|Y|yes|YES) ;;
      *) echo "Aborted."; exit 0 ;;
    esac
  fi

  echo ""
  echo "[1/2] Deleting email routing rule(s)..."
  if [ -z "$RULE_ROWS" ]; then
    echo "  (none)"
  else
    while IFS=$'\t' read -r RULE_ID RULE_NAME; do
      [ -z "$RULE_ID" ] && continue
      local DEL
      DEL=$(cf_post -X DELETE "${CF_API}/zones/${ZONE_ID}/email/routing/rules/${RULE_ID}")
      if echo "$DEL" | python3 -c "import sys,json; assert json.load(sys.stdin).get('success')" 2>/dev/null; then
        echo "  Deleted ${RULE_NAME}"
      else
        echo "  WARNING: Failed to delete ${RULE_NAME}:"
        echo "$DEL" | python3 -c "import sys,json; [print(f'    {e[\"message\"]}') for e in json.load(sys.stdin).get('errors',[])]" 2>/dev/null || echo "  $DEL"
      fi
    done <<< "$RULE_ROWS"
  fi

  echo ""
  echo "[2/2] Deleting _report._dmarc TXT record(s)..."
  if [ -z "$DNS_ROWS" ]; then
    echo "  (none)"
  else
    while IFS=$'\t' read -r REC_ID REC_NAME; do
      [ -z "$REC_ID" ] && continue
      local DEL
      DEL=$(cf_post -X DELETE "${CF_API}/zones/${ZONE_ID}/dns_records/${REC_ID}")
      if echo "$DEL" | python3 -c "import sys,json; assert json.load(sys.stdin).get('success')" 2>/dev/null; then
        echo "  Deleted ${REC_NAME}"
      else
        echo "  WARNING: Failed to delete ${REC_NAME}:"
        echo "$DEL" | python3 -c "import sys,json; [print(f'    {e[\"message\"]}') for e in json.load(sys.stdin).get('errors',[])]" 2>/dev/null || echo "  $DEL"
      fi
    done <<< "$DNS_ROWS"
  fi

  echo ""
  echo "=== Cleanup complete for ${DOMAIN} ==="
  echo ""
  echo "Manual follow-ups you may want:"
  echo "  • Disable Email Routing for ${DOMAIN} to remove its MX records:"
  echo "    https://dash.cloudflare.com → ${DOMAIN} → Email → Email Routing"
  echo "  • Confirm no monitored domain still points rua= at ${ADDRESS}:"
  echo "    dig +short TXT _dmarc.<monitored-domain>"
  echo "  • Stored reports stay in D1 and the dashboard — nothing there was removed."
}

if [ "$MODE" = "cleanup" ]; then
  cleanup_zone
  exit 0
fi

echo "=== DMARC Dashboard Kit Deploy ==="

# --- Auto-detect domain from zone ID ---
echo ""
echo "[0/7] Detecting domain from zone..."
ZONE_RESPONSE=$(cf_get "${CF_API}/zones/${CLOUDFLARE_ZONE_ID}")
DMARC_DOMAIN=$(echo "$ZONE_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['name'])" 2>/dev/null || echo "")
if [ -z "$DMARC_DOMAIN" ]; then
  echo "  ERROR: Could not detect domain from zone ID. Check CLOUDFLARE_ZONE_ID and CLOUDFLARE_API_TOKEN."
  echo "$ZONE_RESPONSE" | python3 -c "import sys,json; [print(f'  {e[\"message\"]}') for e in json.load(sys.stdin).get('errors',[])]" 2>/dev/null || true
  exit 1
fi
DMARC_ADDRESS="${DMARC_EMAIL}@${DMARC_DOMAIN}"
echo "  Domain: ${DMARC_DOMAIN}"
echo "  DMARC address: ${DMARC_ADDRESS}"

# --- Step 1: D1 Database ---
echo ""
echo "[1/7] Ensuring D1 database exists..."
export CLOUDFLARE_API_TOKEN
EXISTING_ID=$(npx wrangler d1 list --json 2>/dev/null | \
  python3 -c "import sys,json; dbs=json.load(sys.stdin); print(next((d['uuid'] for d in dbs if d['name']=='$DB_NAME'),''))" 2>/dev/null || true)

if [ -n "$EXISTING_ID" ]; then
  echo "  Database '$DB_NAME' exists: $EXISTING_ID"
  DB_ID="$EXISTING_ID"
else
  echo "  Creating database '$DB_NAME'..."
  CREATE_OUTPUT=$(npx wrangler d1 create "$DB_NAME" 2>&1) || true
  DB_ID=$(echo "$CREATE_OUTPUT" | grep -o 'database_id = "[^"]*"' | cut -d'"' -f2)
  if [ -z "$DB_ID" ]; then
    echo "  ERROR: Could not extract database_id:"
    echo "$CREATE_OUTPUT"
    exit 1
  fi
  echo "  Created: $DB_ID"
fi

# --- Step 2: Generate wrangler.toml ---
echo ""
echo "[2/7] Generating wrangler.toml..."
if [ ! -f "$WRANGLER_TOML" ]; then
  cp wrangler.toml.example "$WRANGLER_TOML"
fi
sed -i.bak "s/database_id = \"\"/database_id = \"$DB_ID\"/" "$WRANGLER_TOML"
rm -f "${WRANGLER_TOML}.bak"
echo "  wrangler.toml ready with database_id=${DB_ID}"

# --- Step 3: Run migrations ---
echo ""
echo "[3/7] Running D1 migrations..."
for f in $(ls migrations/*.sql | sort); do
  npx wrangler d1 execute "$DB_NAME" --file="$f" --remote --yes
done
echo "  Done"

# --- Step 4: Build dashboard ---
echo ""
echo "[4/7] Building dashboard..."
(cd dashboard && pnpm install --frozen-lockfile 2>/dev/null || pnpm install && pnpm run build)
echo "  Built to dashboard/dist/"

# --- Step 5: Deploy worker ---
echo ""
echo "[5/7] Deploying worker..."
DEPLOY_OUTPUT=$(npx wrangler deploy 2>&1)
echo "$DEPLOY_OUTPUT"
WORKER_URL=$(echo "$DEPLOY_OUTPUT" | grep -o 'https://[^ ]*\.workers\.dev' | head -1)
echo "  Deployed: ${WORKER_URL}"

# --- Step 6: Email Routing + DNS ---
echo ""
echo "[6/7] Configuring email routing and DNS..."

# Check if email routing rule exists
EXISTING_RULES=$(cf_get "${CF_API}/zones/${CLOUDFLARE_ZONE_ID}/email/routing/rules" || echo '{"result":[]}')
RULE_EXISTS=$(echo "$EXISTING_RULES" | python3 -c "
import sys,json
rules=json.load(sys.stdin).get('result',[])
print('yes' if any(
  any(m.get('value')==\"${DMARC_ADDRESS}\" for m in r.get('matchers',[]))
  for r in rules
) else 'no')" 2>/dev/null || echo "no")

if [ "$RULE_EXISTS" = "no" ]; then
  echo "  Creating email routing rule: ${DMARC_ADDRESS} → worker..."
  RULE_RESPONSE=$(cf_post -X POST "${CF_API}/zones/${CLOUDFLARE_ZONE_ID}/email/routing/rules" \
    -d "{
      \"matchers\": [{\"type\": \"literal\", \"field\": \"to\", \"value\": \"${DMARC_ADDRESS}\"}],
      \"actions\": [{\"type\": \"worker\", \"value\": [\"${WORKER_NAME}\"]}],
      \"enabled\": true,
      \"name\": \"DMARC reports to worker\"
    }")
  if echo "$RULE_RESPONSE" | python3 -c "import sys,json; assert json.load(sys.stdin).get('success')" 2>/dev/null; then
    echo "  Created email routing rule"
  else
    echo "  WARNING: Failed to create email routing rule:"
    echo "$RULE_RESPONSE" | python3 -c "import sys,json; [print(f'    {e[\"message\"]}') for e in json.load(sys.stdin).get('errors',[])]" 2>/dev/null || echo "  $RULE_RESPONSE"
  fi
else
  echo "  Email routing rule already exists"
fi

# Create _report._dmarc authorization records for external domains.
# When otherdomain.com sets rua=mailto:dmarc@cf-dmarc.uk, report generators
# verify cf-dmarc.uk accepts reports by checking:
#   otherdomain.com._report._dmarc.cf-dmarc.uk TXT "v=DMARC1;"
# If REPORT_AUTHORIZED_DOMAINS is set, create per-domain records.
# Otherwise, create a wildcard *._report._dmarc to accept reports from any domain.
upsert_report_dmarc_record() {
  local RECORD_NAME="$1"
  local LABEL="${2:-${RECORD_NAME}.${DMARC_DOMAIN}}"
  local RECORD_BODY="{
    \"type\": \"TXT\",
    \"name\": \"${RECORD_NAME}\",
    \"content\": \"\\\"v=DMARC1;\\\"\",
    \"ttl\": 3600
  }"
  EXISTING_DNS=$(cf_get "${CF_API}/zones/${CLOUDFLARE_ZONE_ID}/dns_records?type=TXT&name=${RECORD_NAME}.${DMARC_DOMAIN}" || echo '{"result":[]}')
  DNS_ID=$(echo "$EXISTING_DNS" | python3 -c "import sys,json; r=json.load(sys.stdin).get('result',[]); print(r[0]['id'] if r else '')" 2>/dev/null || echo "")

  if [ -z "$DNS_ID" ]; then
    echo "  Creating ${LABEL} TXT record..."
    DNS_RESPONSE=$(cf_post -X POST "${CF_API}/zones/${CLOUDFLARE_ZONE_ID}/dns_records" -d "$RECORD_BODY")
    if echo "$DNS_RESPONSE" | python3 -c "import sys,json; assert json.load(sys.stdin).get('success')" 2>/dev/null; then
      echo "  Created: ${LABEL}"
    else
      echo "  WARNING: Failed to create ${LABEL} record:"
      echo "$DNS_RESPONSE" | python3 -c "import sys,json; [print(f'    {e[\"message\"]}') for e in json.load(sys.stdin).get('errors',[])]" 2>/dev/null || echo "  $DNS_RESPONSE"
    fi
  else
    echo "  Updating ${LABEL} TXT record..."
    DNS_RESPONSE=$(cf_post -X PUT "${CF_API}/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${DNS_ID}" -d "$RECORD_BODY")
    if echo "$DNS_RESPONSE" | python3 -c "import sys,json; assert json.load(sys.stdin).get('success')" 2>/dev/null; then
      echo "  Updated: ${LABEL}"
    else
      echo "  WARNING: Failed to update ${LABEL} record:"
      echo "$DNS_RESPONSE" | python3 -c "import sys,json; [print(f'    {e[\"message\"]}') for e in json.load(sys.stdin).get('errors',[])]" 2>/dev/null || echo "  $DNS_RESPONSE"
    fi
  fi
}

if [ -n "${REPORT_AUTHORIZED_DOMAINS:-}" ]; then
  IFS=',' read -ra AUTH_DOMAINS <<< "$REPORT_AUTHORIZED_DOMAINS"
  for AUTH_DOMAIN in "${AUTH_DOMAINS[@]}"; do
    AUTH_DOMAIN=$(echo "$AUTH_DOMAIN" | xargs)  # trim whitespace
    upsert_report_dmarc_record "${AUTH_DOMAIN}._report._dmarc"
  done
else
  # Wildcard: accept DMARC reports from any domain
  upsert_report_dmarc_record "*._report._dmarc" "*._report._dmarc.${DMARC_DOMAIN} (wildcard)"
fi

# --- Step 7: Cloudflare Access ---
echo ""
echo "[7/7] Configuring Cloudflare Access..."

# Extract domain from the workers.dev URL
WORKER_DOMAIN=$(echo "$WORKER_URL" | sed 's|https://||')

# Check if Access application exists
EXISTING_APPS=$(cf_get "${CF_API}/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps" || echo '{"result":[]}')
APP_EXISTS=$(echo "$EXISTING_APPS" | python3 -c "
import sys,json
apps=json.load(sys.stdin).get('result',[])
match=[a for a in apps if a.get('name')=='DMARC Dashboard']
print(match[0]['id'] if match else '')" 2>/dev/null || echo "")

if [ -z "$APP_EXISTS" ]; then
  echo "  Creating Access application for ${WORKER_DOMAIN}..."
  APP_RESPONSE=$(cf_post -X POST "${CF_API}/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps" \
    -d "{
      \"name\": \"DMARC Dashboard\",
      \"domain\": \"${WORKER_DOMAIN}\",
      \"type\": \"self_hosted\",
      \"session_duration\": \"24h\",
      \"destinations\": [{\"type\": \"public\", \"uri\": \"${WORKER_DOMAIN}\"}],
      \"self_hosted_domains\": [\"${WORKER_DOMAIN}\"]
    }")
  APP_ID=$(echo "$APP_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['id'])" 2>/dev/null || echo "")
  if [ -z "$APP_ID" ]; then
    echo "  WARNING: Failed to create Access app:"
    echo "$APP_RESPONSE" | python3 -c "import sys,json; [print(f'    {e[\"message\"]}') for e in json.load(sys.stdin).get('errors',[])]" 2>/dev/null || echo "  $APP_RESPONSE"
  else
    echo "  Created Access app: $APP_ID"
  fi
else
  APP_ID="$APP_EXISTS"
  echo "  Access application exists: $APP_ID"
  # Update existing app with correct domain
  echo "  Updating Access app domain to ${WORKER_DOMAIN}..."
  UPDATE_RESPONSE=$(cf_post -X PUT "${CF_API}/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps/${APP_ID}" \
    -d "{
      \"name\": \"DMARC Dashboard\",
      \"domain\": \"${WORKER_DOMAIN}\",
      \"type\": \"self_hosted\",
      \"session_duration\": \"24h\",
      \"destinations\": [{\"type\": \"public\", \"uri\": \"${WORKER_DOMAIN}\"}],
      \"self_hosted_domains\": [\"${WORKER_DOMAIN}\"]
    }")
  if echo "$UPDATE_RESPONSE" | python3 -c "import sys,json; assert json.load(sys.stdin).get('success')" 2>/dev/null; then
    echo "  Updated Access app domain"
  else
    echo "  WARNING: Failed to update Access app:"
    echo "$UPDATE_RESPONSE" | python3 -c "import sys,json; [print(f'    {e[\"message\"]}') for e in json.load(sys.stdin).get('errors',[])]" 2>/dev/null || echo "  $UPDATE_RESPONSE"
  fi
fi

# Ensure Access policy exists/updated
if [ -n "$APP_ID" ]; then
  EXISTING_POLICIES=$(cf_get "${CF_API}/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps/${APP_ID}/policies" || echo '{"result":[]}')
  POLICY_ID=$(echo "$EXISTING_POLICIES" | python3 -c "import sys,json; r=json.load(sys.stdin).get('result',[]); print(r[0]['id'] if r else '')" 2>/dev/null || echo "")

  # When both identity rules and IPs are set, always sync the Access Group for the IPs.
  # Rules within a group's include are OR'd, then the group is AND'd via require.
  # This avoids the flat-require AND problem where multiple IPs require matching all at once.
  IP_GROUP_ID=""
  if [ -n "${ACCESS_ALLOWED_IPS:-}" ] && { [ -n "${ACCESS_ALLOWED_EMAILS:-}" ] || [ -n "${ACCESS_ALLOWED_EMAIL_DOMAINS:-}" ]; }; then
    GROUP_INCLUDE=$(python3 -c "
import os, json
ips = os.environ.get('ACCESS_ALLOWED_IPS', '')
rules = [{'ip': {'ip': c.strip()}} for c in ips.split(',') if c.strip()]
print(json.dumps(rules))
")
    EXISTING_GROUPS=$(cf_get "${CF_API}/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/groups" || echo '{"result":[]}')
    IP_GROUP_ID=$(echo "$EXISTING_GROUPS" | python3 -c "
import sys, json
groups = json.load(sys.stdin).get('result', [])
match = [g for g in groups if g.get('name') == 'DMARC Dashboard IPs']
print(match[0]['id'] if match else '')
" 2>/dev/null || echo "")

    if [ -z "$IP_GROUP_ID" ]; then
      GROUP_RESPONSE=$(cf_post -X POST "${CF_API}/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/groups" \
        -d "{\"name\": \"DMARC Dashboard IPs\", \"include\": ${GROUP_INCLUDE}}")
      IP_GROUP_ID=$(echo "$GROUP_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['id'])" 2>/dev/null || echo "")
      if [ -n "$IP_GROUP_ID" ]; then
        echo "  Created Access group for IPs: $IP_GROUP_ID"
      else
        echo "  ERROR: Failed to create Access group for IPs (token needs Access: Groups: Edit):"
        echo "$GROUP_RESPONSE" | python3 -c "import sys,json; [print(f'    {e[\"message\"]}') for e in json.load(sys.stdin).get('errors',[])]" 2>/dev/null || echo "  $GROUP_RESPONSE"
        exit 1
      fi
    else
      UPDATE_GROUP=$(cf_post -X PUT "${CF_API}/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/groups/${IP_GROUP_ID}" \
        -d "{\"name\": \"DMARC Dashboard IPs\", \"include\": ${GROUP_INCLUDE}}")
      if echo "$UPDATE_GROUP" | python3 -c "import sys,json; assert json.load(sys.stdin).get('success')" 2>/dev/null; then
        echo "  Updated Access group for IPs: $IP_GROUP_ID"
      else
        echo "  ERROR: Failed to update Access group for IPs:"
        echo "$UPDATE_GROUP" | python3 -c "import sys,json; [print(f'    {e[\"message\"]}') for e in json.load(sys.stdin).get('errors',[])]" 2>/dev/null || echo "  $UPDATE_GROUP"
        exit 1
      fi
    fi
    export IP_GROUP_ID
  fi

  INCLUDE_RULES=$(python3 -c "
import os, json
rules = []
emails = os.environ.get('ACCESS_ALLOWED_EMAILS', '')
domains = os.environ.get('ACCESS_ALLOWED_EMAIL_DOMAINS', '')
ips = os.environ.get('ACCESS_ALLOWED_IPS', '')
has_identity = bool(emails or domains)
if emails:
    rules += [{'email': {'email': e.strip()}} for e in emails.split(',') if e.strip()]
if domains:
    rules += [{'email_domain': {'domain': d.strip()}} for d in domains.split(',') if d.strip()]
if not has_identity and ips:
    rules += [{'ip': {'ip': c.strip()}} for c in ips.split(',') if c.strip()]
print(json.dumps(rules))
")

  REQUIRE_RULES=$(python3 -c "
import os, json
group_id = os.environ.get('IP_GROUP_ID', '')
if group_id:
    rules = [{'group': {'id': group_id}}]
else:
    rules = []
print(json.dumps(rules))
")

  POLICY_BODY="{
    \"name\": \"DMARC Dashboard Allow\",
    \"decision\": \"allow\",
    \"include\": ${INCLUDE_RULES},
    \"require\": ${REQUIRE_RULES}
  }"

  POLICY_SUMMARY=""
  [ -n "${ACCESS_ALLOWED_EMAILS:-}" ] && POLICY_SUMMARY="${POLICY_SUMMARY} emails=[${ACCESS_ALLOWED_EMAILS}]"
  [ -n "${ACCESS_ALLOWED_EMAIL_DOMAINS:-}" ] && POLICY_SUMMARY="${POLICY_SUMMARY} domains=[${ACCESS_ALLOWED_EMAIL_DOMAINS}]"
  [ -n "${ACCESS_ALLOWED_IPS:-}" ] && POLICY_SUMMARY="${POLICY_SUMMARY} ips=[${ACCESS_ALLOWED_IPS}]"

  if [ -z "$POLICY_ID" ]; then
    echo "  Creating Access policy..."
    POLICY_RESPONSE=$(cf_post -X POST "${CF_API}/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps/${APP_ID}/policies" \
      -d "$POLICY_BODY")
    if echo "$POLICY_RESPONSE" | python3 -c "import sys,json; assert json.load(sys.stdin).get('success')" 2>/dev/null; then
      echo "  Created Access policy:${POLICY_SUMMARY}"
    else
      echo "  WARNING: Failed to create Access policy:"
      echo "$POLICY_RESPONSE" | python3 -c "import sys,json; [print(f'    {e[\"message\"]}') for e in json.load(sys.stdin).get('errors',[])]" 2>/dev/null || echo "  $POLICY_RESPONSE"
    fi
  else
    echo "  Updating Access policy..."
    POLICY_RESPONSE=$(cf_post -X PUT "${CF_API}/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps/${APP_ID}/policies/${POLICY_ID}" \
      -d "$POLICY_BODY")
    if echo "$POLICY_RESPONSE" | python3 -c "import sys,json; assert json.load(sys.stdin).get('success')" 2>/dev/null; then
      echo "  Updated Access policy:${POLICY_SUMMARY}"
    else
      echo "  WARNING: Failed to update Access policy:"
      echo "$POLICY_RESPONSE" | python3 -c "import sys,json; [print(f'    {e[\"message\"]}') for e in json.load(sys.stdin).get('errors',[])]" 2>/dev/null || echo "  $POLICY_RESPONSE"
    fi
  fi
fi

echo ""
echo "${C_GREEN}${C_BOLD}=== Deploy complete! ===${C_RESET}"
echo ""
echo "Your DMARC dashboard is at: ${C_CYAN}${WORKER_URL}${C_RESET}"
echo ""
echo "${C_BOLD}Manual prerequisite (one-time):${C_RESET}"
echo "  Enable Email Routing for ${C_CYAN}${DMARC_DOMAIN}${C_RESET} in Cloudflare dashboard:"
echo "  ${C_DIM}https://dash.cloudflare.com → ${DMARC_DOMAIN} → Email → Email Routing → Enable${C_RESET}"
echo ""
echo "${C_BOLD}To monitor a domain, add a DMARC policy TXT record on that domain:${C_RESET}"
echo "  ${C_DIM}_dmarc.example.com  TXT  \"v=DMARC1; p=none; rua=mailto:${DMARC_ADDRESS}\"${C_RESET}"
echo ""
echo "${C_YELLOW}${C_BOLD}WARNING:${C_RESET}${C_YELLOW} p=none only monitors — it does NOT block spoofed emails.${C_RESET}"
echo "${C_YELLOW}  Move to p=quarantine then p=reject once legitimate senders pass DKIM/SPF.${C_RESET}"
