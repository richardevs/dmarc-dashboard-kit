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
# Strip inline comments before sourcing so "VAR=value  # comment" works correctly
# set -a auto-exports all variables so python3 subprocesses see them via os.environ
set -a
eval "$(sed 's/[[:space:]]*#.*$//' "$ENV_FILE")"
set +a

# Validate required vars
for var in CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_ZONE_ID DMARC_EMAIL; do
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

    # When both identity rules and IPs are set, create/update an Access Group for the IPs.
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
          echo "  WARNING: Failed to create Access group for IPs:"
          echo "$GROUP_RESPONSE" | python3 -c "import sys,json; [print(f'    {e[\"message\"]}') for e in json.load(sys.stdin).get('errors',[])]" 2>/dev/null || echo "  $GROUP_RESPONSE"
        fi
      else
        UPDATE_GROUP=$(cf_post -X PUT "${CF_API}/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/groups/${IP_GROUP_ID}" \
          -d "{\"name\": \"DMARC Dashboard IPs\", \"include\": ${GROUP_INCLUDE}}")
        if echo "$UPDATE_GROUP" | python3 -c "import sys,json; assert json.load(sys.stdin).get('success')" 2>/dev/null; then
          echo "  Updated Access group for IPs: $IP_GROUP_ID"
        else
          echo "  WARNING: Failed to update Access group for IPs:"
          echo "$UPDATE_GROUP" | python3 -c "import sys,json; [print(f'    {e[\"message\"]}') for e in json.load(sys.stdin).get('errors',[])]" 2>/dev/null || echo "  $UPDATE_GROUP"
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

    POLICY_RESPONSE=$(cf_post -X POST "${CF_API}/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps/${APP_ID}/policies" \
      -d "{
        \"name\": \"DMARC Dashboard Allow\",
        \"decision\": \"allow\",
        \"include\": ${INCLUDE_RULES},
        \"require\": ${REQUIRE_RULES}
      }")
    if echo "$POLICY_RESPONSE" | python3 -c "import sys,json; assert json.load(sys.stdin).get('success')" 2>/dev/null; then
      POLICY_SUMMARY=""
      [ -n "${ACCESS_ALLOWED_EMAILS:-}" ] && POLICY_SUMMARY="${POLICY_SUMMARY} emails=[${ACCESS_ALLOWED_EMAILS}]"
      [ -n "${ACCESS_ALLOWED_EMAIL_DOMAINS:-}" ] && POLICY_SUMMARY="${POLICY_SUMMARY} domains=[${ACCESS_ALLOWED_EMAIL_DOMAINS}]"
      [ -n "${ACCESS_ALLOWED_IPS:-}" ] && POLICY_SUMMARY="${POLICY_SUMMARY} ips=[${ACCESS_ALLOWED_IPS}]"
      echo "  Created Access policy:${POLICY_SUMMARY}"
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
