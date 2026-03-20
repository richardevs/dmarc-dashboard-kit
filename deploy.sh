#!/usr/bin/env bash
set -euo pipefail

DB_NAME="dmarc-reports"
WRANGLER_TOML="wrangler.toml"
WORKER_NAME="dmarc-dashboard-kit"
ENV_FILE=".env"

echo "=== DMARC Dashboard Kit Deploy ==="

# --- Load config from .env ---
if [ ! -f "$ENV_FILE" ]; then
  echo ""
  echo "No .env file found. Creating one — please fill in the values."
  cp .env.example "$ENV_FILE"
  echo "Created $ENV_FILE — edit it and re-run this script."
  exit 0
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

# Validate required vars
for var in CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_ZONE_ID DMARC_EMAIL ACCESS_ALLOWED_EMAILS; do
  if [ -z "${!var:-}" ]; then
    echo "ERROR: $var is not set in $ENV_FILE"
    exit 1
  fi
done

CF_API="https://api.cloudflare.com/client/v4"
AUTH_HEADER="Authorization: Bearer ${CLOUDFLARE_API_TOKEN}"

cf_get()  { curl -s -H "$AUTH_HEADER" "$@"; }
cf_post() { curl -s -H "$AUTH_HEADER" -H "Content-Type: application/json" "$@"; }

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
  CREATE_OUTPUT=$(npx wrangler d1 create "$DB_NAME" 2>&1)
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
npx wrangler d1 execute "$DB_NAME" --file=migrations/0001_init.sql --remote --yes
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
if [ -n "${REPORT_AUTHORIZED_DOMAINS:-}" ]; then
  IFS=',' read -ra AUTH_DOMAINS <<< "$REPORT_AUTHORIZED_DOMAINS"
  for AUTH_DOMAIN in "${AUTH_DOMAINS[@]}"; do
    AUTH_DOMAIN=$(echo "$AUTH_DOMAIN" | xargs)  # trim whitespace
    RECORD_NAME="${AUTH_DOMAIN}._report._dmarc"
    EXISTING_DNS=$(cf_get "${CF_API}/zones/${CLOUDFLARE_ZONE_ID}/dns_records?type=TXT&name=${RECORD_NAME}.${DMARC_DOMAIN}" || echo '{"result":[]}')
    DNS_EXISTS=$(echo "$EXISTING_DNS" | python3 -c "import sys,json; print('yes' if json.load(sys.stdin).get('result') else 'no')" 2>/dev/null || echo "no")

    if [ "$DNS_EXISTS" = "no" ]; then
      echo "  Creating ${RECORD_NAME}.${DMARC_DOMAIN} TXT record..."
      DNS_RESPONSE=$(cf_post -X POST "${CF_API}/zones/${CLOUDFLARE_ZONE_ID}/dns_records" \
        -d "{
          \"type\": \"TXT\",
          \"name\": \"${RECORD_NAME}\",
          \"content\": \"v=DMARC1;\",
          \"ttl\": 3600
        }")
      if echo "$DNS_RESPONSE" | python3 -c "import sys,json; assert json.load(sys.stdin).get('success')" 2>/dev/null; then
        echo "  Created: ${RECORD_NAME}.${DMARC_DOMAIN}"
      else
        echo "  WARNING: Failed to create ${RECORD_NAME} record:"
        echo "$DNS_RESPONSE" | python3 -c "import sys,json; [print(f'    {e[\"message\"]}') for e in json.load(sys.stdin).get('errors',[])]" 2>/dev/null || echo "  $DNS_RESPONSE"
      fi
    else
      echo "  ${RECORD_NAME}.${DMARC_DOMAIN} already exists"
    fi
  done
else
  # Wildcard: accept DMARC reports from any domain
  RECORD_NAME="*._report._dmarc"
  EXISTING_DNS=$(cf_get "${CF_API}/zones/${CLOUDFLARE_ZONE_ID}/dns_records?type=TXT&name=${RECORD_NAME}.${DMARC_DOMAIN}" || echo '{"result":[]}')
  DNS_EXISTS=$(echo "$EXISTING_DNS" | python3 -c "import sys,json; print('yes' if json.load(sys.stdin).get('result') else 'no')" 2>/dev/null || echo "no")

  if [ "$DNS_EXISTS" = "no" ]; then
    echo "  Creating wildcard ${RECORD_NAME}.${DMARC_DOMAIN} TXT record..."
    DNS_RESPONSE=$(cf_post -X POST "${CF_API}/zones/${CLOUDFLARE_ZONE_ID}/dns_records" \
      -d "{
        \"type\": \"TXT\",
        \"name\": \"${RECORD_NAME}\",
        \"content\": \"v=DMARC1;\",
        \"ttl\": 3600
      }")
    if echo "$DNS_RESPONSE" | python3 -c "import sys,json; assert json.load(sys.stdin).get('success')" 2>/dev/null; then
      echo "  Created: ${RECORD_NAME}.${DMARC_DOMAIN} (accepts reports from any domain)"
    else
      echo "  WARNING: Failed to create wildcard _report._dmarc record:"
      echo "$DNS_RESPONSE" | python3 -c "import sys,json; [print(f'    {e[\"message\"]}') for e in json.load(sys.stdin).get('errors',[])]" 2>/dev/null || echo "  $DNS_RESPONSE"
    fi
  else
    echo "  ${RECORD_NAME}.${DMARC_DOMAIN} already exists"
  fi
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

# Ensure Access policy exists
if [ -n "$APP_ID" ]; then
  EXISTING_POLICIES=$(cf_get "${CF_API}/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps/${APP_ID}/policies" || echo '{"result":[]}')
  POLICY_EXISTS=$(echo "$EXISTING_POLICIES" | python3 -c "import sys,json; print('yes' if json.load(sys.stdin).get('result') else 'no')" 2>/dev/null || echo "no")

  if [ "$POLICY_EXISTS" = "no" ]; then
    echo "  Creating Access policy..."
    INCLUDE_RULES=$(echo "$ACCESS_ALLOWED_EMAILS" | python3 -c "
import sys,json
emails=[e.strip() for e in sys.stdin.read().split(',') if e.strip()]
print(json.dumps([{'email': {'email': e}} for e in emails]))")

    POLICY_RESPONSE=$(cf_post -X POST "${CF_API}/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps/${APP_ID}/policies" \
      -d "{
        \"name\": \"Allow specific emails\",
        \"decision\": \"allow\",
        \"include\": ${INCLUDE_RULES}
      }")
    if echo "$POLICY_RESPONSE" | python3 -c "import sys,json; assert json.load(sys.stdin).get('success')" 2>/dev/null; then
      echo "  Created Access policy: allow ${ACCESS_ALLOWED_EMAILS}"
    else
      echo "  WARNING: Failed to create Access policy:"
      echo "$POLICY_RESPONSE" | python3 -c "import sys,json; [print(f'    {e[\"message\"]}') for e in json.load(sys.stdin).get('errors',[])]" 2>/dev/null || echo "  $POLICY_RESPONSE"
    fi
  else
    echo "  Access policy already exists"
  fi
fi

echo ""
echo "=== Deploy complete! ==="
echo ""
echo "Your DMARC dashboard is at: ${WORKER_URL}"
echo ""
echo "Manual prerequisite (one-time):"
echo "  Enable Email Routing for ${DMARC_DOMAIN} in Cloudflare dashboard:"
echo "  https://dash.cloudflare.com → ${DMARC_DOMAIN} → Email → Email Routing → Enable"
echo ""
echo "To monitor a domain, add a DMARC policy TXT record on that domain:"
echo "  _dmarc.example.com  TXT  \"v=DMARC1; p=none; rua=mailto:${DMARC_ADDRESS}\""
echo ""
echo "WARNING: p=none only monitors — it does NOT block spoofed emails."
echo "  Move to p=quarantine then p=reject once legitimate senders pass DKIM/SPF."
