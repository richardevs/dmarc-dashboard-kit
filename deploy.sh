#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

WORKER_NAME="dmarc-dashboard-kit"
DB_NAME="dmarc-reports"
# Fixed comment on every DNS record this script creates, so cleanup can never
# select a record it did not create. DNS comments work on every plan.
MANAGED_TAG="managed-by:dmarc-dashboard-kit"
RULE_NAME="DMARC reports to worker"
ACCESS_APP_NAME="DMARC Dashboard"
ACCESS_POLICY_NAME="DMARC Dashboard Allow"
ACCESS_GROUP_NAME="DMARC Dashboard IPs"
CF_BIN="node_modules/.bin/cf"
# OAuth scopes requested by --login: only what this script and the deploy use.
LOGIN_SCOPES=(
  account:read user:read offline
  zone:read dns_records:edit
  workers_scripts:write workers_routes:write d1:write
  email_routing:write email-routing-rule.write
  access-app.write access-policy.write access-group.write
)

# --- Colors (disabled when not a TTY or when NO_COLOR is set) ---
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_GREEN=$'\033[32m'; C_CYAN=$'\033[36m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""
  C_GREEN=""; C_CYAN=""; C_YELLOW=""; C_RED=""
fi

die()  { echo "${C_RED}ERROR:${C_RESET} $*" >&2; exit 1; }
warn() { echo "  ${C_YELLOW}WARNING:${C_RESET} $*"; }
# Status lines shared by --list and --verify.
V_FAIL=0; V_WARN=0
v_ok()   { echo "  ${C_GREEN}✓${C_RESET} $*"; }
v_warn() { echo "  ${C_YELLOW}⚠${C_RESET} $*"; V_WARN=$((V_WARN + 1)); }
v_fail() { echo "  ${C_RED}✗${C_RESET} $*"; V_FAIL=$((V_FAIL + 1)); }

header() { echo "${C_BOLD}${C_CYAN}$*${C_RESET}"; }
# kv <label> <value> [color] — empty, "-" and "(…)" values are dimmed.
kv() {
  local V="$2" COLOR="${3:-}"
  case "$V" in ""|-|"("*) V="${C_DIM}${V:--}${C_RESET}" ;; *) [ -n "$COLOR" ] && V="${COLOR}${V}${C_RESET}" ;; esac
  printf "  ${C_DIM}%-22s${C_RESET} %s\n" "$1" "$V"
}
csv_or_dash() { echo "$1" | jq -r 'join(", ") | if . == "" then "-" else . end'; }

# confirm "Question?" — exactly Y is yes, exactly N is no; anything else (even a stray
# Enter) asks again, so a slip never discards a long setup. No terminal means no.
confirm() {
  local REPLY=""
  while :; do
    printf "%s [Y/N] " "$1"
    { read -r REPLY </dev/tty; } 2>/dev/null || { echo ""; return 1; }
    case "$REPLY" in
      Y) return 0 ;;
      N) return 1 ;;
      *) echo "  ${C_YELLOW}Answer Y or N.${C_RESET}" ;;
    esac
  done
}

usage() {
  cat <<USAGE
${C_BOLD}Usage:${C_RESET} bash deploy.sh [--profile <name>] [action]

${C_BOLD}Actions${C_RESET} (one at a time; none = deploy):
  (none)                   Show the plan for the profile and deploy it after confirmation.
  --setup                  Create or edit profiles/<profile>.json step by step
                           (runs automatically when the profile does not exist).
  --list                   Show the profile's settings, managed resources, and login scopes.
  --verify                 Check the live Cloudflare setup against the profile,
                           including leftovers from older versions.
  --cleanup                List the resources this script created on the profile's
                           account and delete the ones you tick.
  --migrate-from=<source>  Copy stored reports from another profile's D1 database into
                           this profile's. Safe to re-run.
  --login                  Log in to Cloudflare with only the permissions this script
                           needs (runs automatically when needed).
  --import-env             Convert a legacy .env into profiles/<profile>.json.
  -h, --help               Show this help.

--profile <name> selects profiles/<name>.json (default: "default").

${C_BOLD}Examples:${C_RESET}
  bash deploy.sh                              deploy profiles/default.json
  bash deploy.sh --profile company --verify    check profiles/company.json against Cloudflare
  bash deploy.sh --profile company --migrate-from=default
USAGE
}

# invalid "message" — explain, show the help, and fail.
invalid() {
  echo "${C_RED}Invalid parameter:${C_RESET} $*" >&2
  echo "" >&2
  usage >&2
  SHOW_HINT="false"
  exit 2
}

# Every run except --help ends with a pointer to the help.
SHOW_HINT="true"
trap '[ "$SHOW_HINT" = true ] && printf "\n%s\n" "${C_DIM}More usage: bash deploy.sh --help${C_RESET}"' EXIT

# --- Parse arguments ---
MODE="deploy"
PROFILE="default"
PROFILE_SET="false"
MIGRATE_FROM=""

set_mode() {
  [ "$MODE" = deploy ] || invalid "$1 cannot be combined with --${MODE/migrate/migrate-from}"
  MODE="$2"
}

set_profile() {
  [ "$PROFILE_SET" = true ] && invalid "--profile given twice"
  [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]] || invalid "--profile ${1:-<missing>} (profile names may contain letters, digits, - and _)"
  PROFILE="$1"; PROFILE_SET="true"
}

while [ $# -gt 0 ]; do
  arg="$1"; shift
  case "$arg" in
    --profile) set_profile "${1:-}"; [ $# -gt 0 ] && shift ;;
    --profile=*) set_profile "${arg#--profile=}" ;;
    --cleanup) set_mode "$arg" cleanup ;;
    --import-env) set_mode "$arg" import-env ;;
    --login) set_mode "$arg" login ;;
    --setup) set_mode "$arg" setup ;;
    --list) set_mode "$arg" list ;;
    --verify) set_mode "$arg" verify ;;
    --migrate-from=?*) set_mode "--migrate-from" migrate; MIGRATE_FROM="${arg#--migrate-from=}" ;;
    -h|--help) SHOW_HINT="false"; usage; exit 0 ;;
    -*) invalid "$arg" ;;
    cleanup|import-env|login|setup|list|verify|help|migrate-from*)
      invalid "$arg (did you mean --${arg}?)" ;;
    *) invalid "$arg (did you mean --profile ${arg}?)" ;;
  esac
done

PROFILE_FILE="profiles/${PROFILE}.json"
PROFILE_ARG=" --profile $PROFILE"

command -v jq >/dev/null || die "jq is required (brew install jq / apt install jq)."
[ -x "$CF_BIN" ] || die "cf CLI not found. Run 'pnpm install' first."

# The profile's cfLogin selects a named cf login; empty uses cf's default login.
CF_PROFILE=""
cf() {
  local ARGS=("$@") OUT ERR RC TRY READ_ONLY="false" A
  [ -n "$CF_PROFILE" ] && ARGS+=(--profile "$CF_PROFILE")
  # Commands that show progress or ask questions keep their terminal output.
  case "$1 ${2:-} ${3:-}" in
    "deploy "*|"d1 migrations apply"|"auth login"*|"auth create"*) "$CF_BIN" "${ARGS[@]}"; return ;;
  esac
  # Reads are retried on Cloudflare server errors (5xx). Writes are not: a 5xx does
  # not prove a write failed, and repeating a create could duplicate a record.
  for A in "$@"; do case "$A" in list|list-account|get|whoami) READ_ONLY="true" ;; esac; done
  # Everything runs quietly: cf draws a banner and spinner on a terminal, which would
  # bury this script's output. Errors are still shown.
  OUT=$(mktemp); ERR=$(mktemp)
  for TRY in 1 2 3; do
    "$CF_BIN" "${ARGS[@]}" --quiet >"$OUT" 2>"$ERR" && { cat "$OUT"; rm -f "$OUT" "$ERR"; return 0; }
    RC=$?
    [ "$READ_ONLY" = true ] && [ "$TRY" -lt 3 ] && grep -qE '(^|[^0-9])5[0-9]{2}([^0-9]|$)' "$ERR" || break
    sleep $((TRY * 2))
  done
  sed $'s/\x1b\\[[0-9;?]*[A-Za-z]//g' "$ERR" | grep -vE '^\s*.?\s*$|Loading' >&2 || true
  rm -f "$OUT" "$ERR"
  return $RC
}

# Profiles are written only by this script (--setup, .env import, generated host).
# _checksum lets every other run notice a profile changed by hand.
PROFILE_NOTE="Managed by bash deploy.sh --setup. Do not edit by hand; run --setup to change it."
profile_hash() { jq -S 'del(._note, ._checksum)' "$1" | { shasum -a 256 2>/dev/null || sha256sum; } | cut -c1-16; }
save_profile() {  # save_profile <file> <json>
  local TMP; TMP=$(mktemp)
  echo "$2" | jq --arg n "$PROFILE_NOTE" '{_note: $n} + del(._note, ._checksum)' > "$TMP"
  mkdir -p "$(dirname "$1")"
  jq --arg c "$(profile_hash "$TMP")" '. + {_checksum: $c}' "$TMP" > "$1"
  rm -f "$TMP"
}

# csv_to_json "a, b,,c d" → ["a","b","c","d"] (commas and/or spaces separate items)
csv_to_json() {
  jq -cn --arg s "$1" '[$s | splits("[,\\s]+")] | map(select(length > 0))'
}

# --- Import mode: convert a legacy .env into a profile ---
import_env() {
  [ -f .env ] || die "No .env file to import."
  [ -f "$PROFILE_FILE" ] && die "$PROFILE_FILE already exists. Pick another profile name: bash deploy.sh --profile <name> --import-env"

  # Parse KEY=VALUE lines without evaluating them: strip inline comments,
  # surrounding whitespace and quotes. Values may contain spaces.
  local VARS
  VARS=$(awk '
    /^[[:space:]]*(#|$)/ { next }
    {
      line = $0; sub(/^[[:space:]]*(export[[:space:]]+)?/, "", line)
      eq = index(line, "="); if (!eq) next
      k = substr(line, 1, eq - 1); v = substr(line, eq + 1)
      sub(/[[:space:]]+#.*$/, "", v); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      if (v ~ /^".*"$/ || v ~ /^\x27.*\x27$/) v = substr(v, 2, length(v) - 2)
      print k "\t" v
    }' .env)
  get() { printf '%s\n' "$VARS" | awk -F'\t' -v k="$1" '$1==k {print $2}'; }

  # Profiles name the zone by domain. cf still reads the token from .env here,
  # so the lookup works for token-only setups too.
  local ZONE ZONE_NAME
  ZONE=$(get CLOUDFLARE_ZONE_ID)
  ZONE_NAME=$(cf zones get --zone "$ZONE" 2>/dev/null | jq -r '.name // empty' || true)

  local JSON
  JSON=$(jq -n \
    --arg accountId "$(get CLOUDFLARE_ACCOUNT_ID)" \
    --arg zone "${ZONE_NAME:-$ZONE}" \
    --arg localPart "$(get DMARC_EMAIL)" \
    --argjson authorizedDomains "$(csv_to_json "$(get REPORT_AUTHORIZED_DOMAINS)")" \
    --argjson emails "$(csv_to_json "$(get ACCESS_ALLOWED_EMAILS)")" \
    --argjson emailDomains "$(csv_to_json "$(get ACCESS_ALLOWED_EMAIL_DOMAINS)")" \
    --argjson ips "$(csv_to_json "$(get ACCESS_ALLOWED_IPS)")" \
    '{
      cfLogin: "",
      accountId: $accountId,
      zone: $zone,
      dmarc: { localPart: (if $localPart == "" then "dmarc" else $localPart end), subdomain: "", authorizedDomains: $authorizedDomains },
      dashboard: { host: "" },
      access: { emails: $emails, emailDomains: $emailDomains, ips: $ips }
    }')
  save_profile "$PROFILE_FILE" "$JSON"

  echo "Created ${C_CYAN}${PROFILE_FILE}${C_RESET}. The API token was not imported — deploy.sh logs in with cf instead."
  echo ""

  # cf reads ./.env on its own, so a leftover .env would keep overriding the cf login.
  if confirm "Move .env to .env.legacy so cf stops reading its token?"; then
    mv .env .env.legacy
    echo "Moved .env to .env.legacy (delete it once the deploy works)."
  else
    warn ".env left in place. deploy.sh will refuse to run until it is moved or deleted."
  fi
  # Versions before profiles generated wrangler.toml; it is no longer read.
  if [ -f wrangler.toml ]; then
    echo ""
    echo "wrangler.toml is no longer used. Compare it with cloudflare.config.ts and wrangler.config.ts"
    echo "(e.g. for settings you added yourself), then remove it."
  fi
  echo ""
  echo "Review the profile, then run: ${C_BOLD}bash deploy.sh${C_RESET}$([ "$PROFILE" != "default" ] && echo " $PROFILE")"
}

if [ "$MODE" = "import-env" ]; then
  import_env
  exit 0
fi

# cf reads ./.env on its own, so a leftover .env would override the cf login.
if [ -f .env ]; then
  if [ -f "$PROFILE_FILE" ]; then
    die "Found a legacy .env next to ${PROFILE_FILE}. cf reads .env automatically, so its token would
override your cf login. Move it aside (mv .env .env.legacy) or delete it."
  fi
  echo "Found a legacy .env — converting it to ${PROFILE_FILE}."
  echo ""
  import_env
  exit 0
fi

login() {
  echo "Logging in to Cloudflare${CF_PROFILE:+ (cf profile: ${CF_PROFILE})}..."
  echo "${C_DIM}  On the consent screen, select only the account(s) this kit should manage.${C_RESET}"
  if [ -n "$CF_PROFILE" ]; then
    "$CF_BIN" auth create "$CF_PROFILE" --scopes "${LOGIN_SCOPES[@]}"
  else
    "$CF_BIN" auth login --force --scopes "${LOGIN_SCOPES[@]}"
  fi
}
logged_in() { cf auth whoami 2>/dev/null | jq -e '.authenticated and .tokenValid != false' >/dev/null; }

# --- Setup mode: build a profile interactively ---
session_label() {
  case "$1" in 15m) echo "15 minutes" ;; 30m) echo "30 minutes" ;; 6h) echo "6 hours" ;; 12h) echo "12 hours" ;;
    24h) echo "24 hours" ;; 168h) echo "1 week" ;; 730h) echo "1 month" ;; *) echo "$1" ;; esac
}

# offer "Run X now?" — for optional follow-ups: Y says yes, anything else just ends.
offer() {
  local REPLY=""
  printf "%s [Y/N] " "$1"
  { read -r REPLY </dev/tty; } 2>/dev/null || { echo ""; return 1; }
  [ "$REPLY" = "Y" ]
}

# next_run <args…> — continue with another action as a fresh run, as if typed.
next_run() {
  SHOW_HINT="false"
  echo ""
  exec bash "$0" "$@"
}

# chosen <text> — confirms what a setup step ended up with.
chosen() { echo "  ${C_GREEN}✓${C_RESET} $*"; }

# ask <var> <prompt> [default] [what Enter means when the default is empty] — "-" clears the default.
# The brackets show what Enter submits: a value, or "Enter = …" when that is nothing.
ask() {
  local REPLY_ SHOWN="${3:-}"
  [ -z "$SHOWN" ] && [ -n "${4:-}" ] && SHOWN="Enter = $4"
  printf "%s%s: " "$2" "${SHOWN:+ ${C_DIM}[${SHOWN}]${C_RESET}}"
  { read -r REPLY_ </dev/tty; } 2>/dev/null || die "--setup needs an interactive terminal."
  REPLY_="${REPLY_:-${3:-}}"
  [ "$REPLY_" = "-" ] && REPLY_=""
  printf -v "$1" '%s' "$REPLY_"
}
# pick <var> <prompt> <default value> <rows: value<TAB>label> — numbered choice.
pick() {
  local VAR="$1" PROMPT="$2" DEF="$3" ROWS="$4" I=0 DEF_N=1 N VALUE LABEL
  while IFS=$'\t' read -r VALUE LABEL; do
    I=$((I + 1))
    [ "$VALUE" = "$DEF" ] && DEF_N=$I
    printf "  %2d) %s\n" "$I" "$LABEL"
  done <<< "$ROWS"
  while :; do
    ask N "$PROMPT" "$DEF_N"
    if [[ "$N" =~ ^[0-9]+$ ]] && [ "$N" -ge 1 ] && [ "$N" -le "$I" ]; then
      printf -v "$VAR" '%s' "$(echo "$ROWS" | sed -n "${N}p" | cut -f1)"
      return
    fi
  done
}

# Without --profile, let the user choose which profile to create or edit.
choose_profile() {
  local F N ROWS="" CHOICE
  [ "$PROFILE_SET" = true ] && return
  header "0. Profile"
  for F in profiles/*.json; do
    N=$(basename "$F" .json)
    [ "$N" = example ] || [ ! -f "$F" ] && continue
    ROWS+="$(printf '%s\t%-12s %s' "$N" "$N" "${C_DIM}$(jq -r '"\(.zone // "?") → \(.dashboard.host // "" | if . == "" then "host not generated yet" else . end)"' "$F" 2>/dev/null)${C_RESET}")"$'\n'
  done
  ROWS+="$(printf '__new__\t%s' "New profile…")"
  pick CHOICE "Profile" "$([ -f profiles/default.json ] && echo default || echo __new__)" "$ROWS"
  if [ "$CHOICE" = "__new__" ]; then
    while :; do
      ask CHOICE "Name for the new profile (letters, digits, - and _)" "$([ -f profiles/default.json ] || echo default)"
      [[ "$CHOICE" =~ ^[A-Za-z0-9_-]+$ ]] && [ ! -f "profiles/${CHOICE}.json" ] && break
      echo "  ${C_YELLOW}Use letters, digits, - and _, and a name that does not exist yet.${C_RESET}"
    done
  fi
  PROFILE="$CHOICE"
  PROFILE_FILE="profiles/${PROFILE}.json"
  PROFILE_ARG=" --profile $PROFILE"
  echo ""
}

setup_profile() {
  local OLD="" CFP ACC ZONE_ SUB LOCAL AUTH HOST LABEL EMAILS DOMAINS IPS WHO ROWS MX RECV DEF_SUB
  old()  { [ -n "$OLD" ] && jq -r "$1 // empty" "$OLD" || true; }
  oldl() { [ -n "$OLD" ] && jq -r "($1 // []) | join(\", \")" "$OLD" || true; }

  header "=== Profile setup ==="
  echo "${C_DIM}Enter accepts what is in [brackets]; type - to clear a value.${C_RESET}"
  echo ""
  choose_profile
  if [ -f "$PROFILE_FILE" ]; then chosen "Editing ${C_CYAN}${PROFILE_FILE}${C_RESET}"; else chosen "Creating ${C_CYAN}${PROFILE_FILE}${C_RESET}"; fi
  echo ""
  # Existing values become the defaults, so re-running only changes what you type.
  [ -f "$PROFILE_FILE" ] && jq empty "$PROFILE_FILE" 2>/dev/null && OLD="$PROFILE_FILE"

  header "1. Cloudflare login"
  echo "Each profile can use its own cf login, which keeps e.g. personal and company accounts apart."
  local LOGINS NAME EMAIL
  LOGINS=$("$CF_BIN" auth list 2>/dev/null | jq -r '.[]?.name' || true)
  ROWS=""
  for NAME in $(printf '%s\n' default $LOGINS | awk '!seen[$0]++'); do
    if [ "$NAME" = default ]; then
      EMAIL=$("$CF_BIN" auth whoami 2>/dev/null | jq -r 'if .authenticated then .email // "logged in" else "not logged in" end' || echo "not logged in")
      ROWS+="$(printf '__default__\t%-14s %s' "default" "${C_DIM}${EMAIL} (cf's default login)${C_RESET}")"$'\n'
    else
      EMAIL=$("$CF_BIN" auth whoami --profile "$NAME" 2>/dev/null | jq -r 'if .authenticated then .email // "logged in" else "not logged in" end' || echo "not logged in")
      ROWS+="$(printf '%s\t%-14s %s' "$NAME" "$NAME" "${C_DIM}${EMAIL}${C_RESET}")"$'\n'
    fi
  done
  ROWS+="$(printf '__new__\t%s' "New login…")"
  # pick cannot carry an empty value, so cf's default login travels as __default__.
  local OLD_LOGIN; OLD_LOGIN=$(old .cfLogin)
  pick CFP "Login" "${OLD_LOGIN:-__default__}" "$ROWS"
  [ "$CFP" = "__default__" ] && CFP=""
  if [ "$CFP" = "__new__" ]; then
    while :; do
      ask CFP "Name for the new login (letters, digits, - and _)" "$([ "$PROFILE" != default ] && echo "$PROFILE")"
      [[ "$CFP" =~ ^[A-Za-z0-9_-]+$ ]] && [ "$CFP" != default ] && break
    done
    CF_PROFILE="$CFP"
    login
  else
    CF_PROFILE="$CFP"
    logged_in || login
  fi
  WHO=$(cf auth whoami)
  chosen "Login ${C_CYAN}${CFP:-default}${C_RESET} ($(echo "$WHO" | jq -r '.email // "logged in"'))"

  echo ""
  header "2. Account"
  ROWS=$(echo "$WHO" | jq -r '.accounts[]? | [.id, .name] | @tsv')
  [ -n "$ROWS" ] || die "This login has no accounts. Run: bash deploy.sh${PROFILE_ARG} --login"
  if [ "$(echo "$ROWS" | wc -l | tr -d ' ')" = 1 ]; then
    ACC=$(echo "$ROWS" | cut -f1)
  else
    pick ACC "Account" "$(old .accountId)" "$ROWS"
  fi
  chosen "Account ${C_CYAN}$(echo "$ROWS" | awk -F'\t' -v id="$ACC" '$1 == id {print $2}')${C_RESET}"
  export CLOUDFLARE_ACCOUNT_ID="$ACC"

  echo ""
  header "3. Zone"
  echo "The zone that receives reports and hosts the dashboard."
  ROWS=$(cf zones list --account-id "$ACC" --per-page 50 | jq -r '.[] | [.name, .name] | @tsv')
  [ -n "$ROWS" ] || die "No zones on this account. Add a domain to Cloudflare first."
  pick ZONE_ "Zone" "$(old .zone)" "$ROWS"
  chosen "Zone ${C_CYAN}${ZONE_}${C_RESET}"

  echo ""
  header "4. Receiving address"
  MX=$(cf dns records list --zone "$ZONE_" --type MX --name "$ZONE_" | jq -r '[.[].content] | join(", ")')
  local ROOT_FOREIGN="false" WHERE DEF_WHERE MAILBOX_HINT
  if [ -z "$MX" ]; then
    echo "${ZONE_} has no MX records, so it can receive on the root (enable Email Routing on it once in the dashboard)."
  elif ! echo "$MX" | tr ',' '\n' | grep -qv "mx.cloudflare.net"; then
    echo "${ZONE_} already uses Cloudflare Email Routing."
  else
    ROOT_FOREIGN="true"
    echo "${C_YELLOW}${ZONE_} already receives mail elsewhere (${MX}).${C_RESET}"
    echo "Receive on a subdomain so the existing mailbox is not affected."
  fi
  # Default to the profile's current choice; for a new profile, to a subdomain when the root is taken.
  if [ -n "$OLD" ]; then
    DEF_WHERE=$([ -n "$(old .dmarc.subdomain)" ] && echo sub || echo root)
  else
    DEF_WHERE=$([ "$ROOT_FOREIGN" = true ] && echo sub || echo root)
  fi
  MAILBOX_HINT=$(old .dmarc.localPart); MAILBOX_HINT=${MAILBOX_HINT:-rua}
  pick WHERE "Receive reports on" "$DEF_WHERE" "$(printf 'root\t%-18s %s\nsub\t%-18s %s' \
    "The zone itself" "${C_DIM}${MAILBOX_HINT}@${ZONE_}${C_RESET}" \
    "A subdomain" "${C_DIM}e.g. ${MAILBOX_HINT}@dmarc.${ZONE_}${C_RESET}")"
  SUB=""
  if [ "$WHERE" = sub ]; then
    while :; do
      DEF_SUB=$(old .dmarc.subdomain)
      ask SUB "Subdomain name (e.g. dmarc → ${MAILBOX_HINT}@dmarc.${ZONE_})" "${DEF_SUB:-dmarc}"
      [[ "$SUB" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] && break
      echo "  ${C_YELLOW}Use a single DNS label: letters, digits and inner hyphens.${C_RESET}"
    done
    # A generic name may already be in use; existing mail on it would be taken over.
    local SUB_RECS
    SUB_RECS=$(cf dns records list --zone "$ZONE_" --name "${SUB}.${ZONE_}" | jq -r '[.[] | select((.content | endswith("mx.cloudflare.net")) | not) | .type] | unique | join(", ")')
    [ -n "$SUB_RECS" ] && echo "${C_YELLOW}${SUB}.${ZONE_} already has DNS records (${SUB_RECS}); make sure it is not used for something else.${C_RESET}"
  elif [ "$ROOT_FOREIGN" = true ]; then
    echo "${C_YELLOW}Deploy will stop until Email Routing is enabled on ${ZONE_}, which replaces its MX records (${MX}).${C_RESET}"
  fi
  RECV="${SUB:+${SUB}.}${ZONE_}"
  # The mailbox name says which report type it receives, so ruf@ can sit next to rua@ later.
  LOCAL=$(old .dmarc.localPart)
  ask LOCAL "Mailbox name (<name>@${RECV})" "${LOCAL:-rua}"
  chosen "Reports go to ${C_CYAN}${LOCAL}@${RECV}${C_RESET}"

  echo ""
  header "5. Other domains reporting here"
  echo "Domains outside ${ZONE_} whose rua= points at ${LOCAL}@${RECV} must be authorized."
  echo "Separate them with commas or spaces; with none listed, reports for any domain are kept."
  ask AUTH "Authorized domains (e.g. example.org, example.net)" "$(oldl .dmarc.authorizedDomains)" "any domain"
  local NAUTH; NAUTH=$(csv_to_json "$AUTH" | jq 'length')
  if [ "$NAUTH" = 0 ]; then chosen "Reports kept for ${C_CYAN}any domain${C_RESET}"
  else chosen "Reports kept for ${C_CYAN}${ZONE_}${C_RESET} and ${C_CYAN}${NAUTH}${C_RESET} other domain(s), each with its _report._dmarc record"; fi

  echo ""
  header "6. Dashboard hostname"
  echo "Must be one level below ${ZONE_} so its Universal SSL certificate covers it."
  while :; do
    ask HOST "Hostname (a name like dash, or the full host)" "$(old .dashboard.host)" "generate dmarc-<random>"
    HOST=$(echo "$HOST" | tr 'A-Z' 'a-z')
    # A bare label is placed under the zone.
    [ -n "$HOST" ] && [[ "$HOST" != *.* ]] && HOST="${HOST}.${ZONE_}"
    [ -z "$HOST" ] && break
    LABEL="${HOST%."$ZONE_"}"
    [ "$LABEL" != "$HOST" ] && [[ "$LABEL" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] && break
    echo "  ${C_YELLOW}Use a single name directly under ${ZONE_}, e.g. dash or dash.${ZONE_}.${C_RESET}"
  done
  if [ -n "$HOST" ]; then chosen "Dashboard at ${C_CYAN}https://${HOST}${C_RESET}"; else chosen "Dashboard host generated on first deploy (dmarc-<random>.${ZONE_})"; fi

  echo ""
  header "7. Who may open the dashboard (Cloudflare Access)"
  echo "Emails and email domains are OR'd; IP ranges, when set, are required in addition."
  EMAILS=$(oldl .access.emails)
  ask EMAILS "Emails (e.g. you@company.com)" "${EMAILS:-$(echo "$WHO" | jq -r '.email // empty')}"
  ask DOMAINS "Email domains (e.g. company.com)" "$(oldl .access.emailDomains)" "no email domains"
  ask IPS "IP ranges (e.g. 203.0.113.0/24)" "$(oldl .access.ips)" "no IP ranges"
  [ -n "$EMAILS$DOMAINS$IPS" ] || die "Set at least one email, email domain, or IP range."
  chosen "Allowed: $(jq -rn --argjson e "$(csv_to_json "$EMAILS")" --argjson d "$(csv_to_json "$DOMAINS")" --argjson i "$(csv_to_json "$IPS")" \
    '[($e|select(length>0)|"emails \(join(", "))"), ($d|select(length>0)|"email domains \(join(", "))"), ($i|select(length>0)|"IP ranges \(join(", ")) (required in addition)")] | join("; ")')"

  # The durations Cloudflare's dashboard offers for an Access application.
  local SESSION OLD_SESSION
  OLD_SESSION=$(old .access.sessionDuration)
  echo ""
  echo "How long a login to the dashboard lasts before Access asks again."
  pick SESSION "Session duration" "${OLD_SESSION:-24h}" "$(printf '%s\t%s\n' 15m "15 minutes" 30m "30 minutes" 6h "6 hours" 12h "12 hours" 24h "24 hours" 168h "1 week" 730h "1 month")"
  chosen "Session lasts ${C_CYAN}$(session_label "$SESSION")${C_RESET}"

  local JSON
  JSON=$(jq -n --arg cfp "$CFP" --arg acc "$ACC" --arg zone "$ZONE_" --arg lp "$LOCAL" --arg sub "$SUB" --arg host "$HOST" --arg session "$SESSION" \
    --argjson auth "$(csv_to_json "$AUTH")" --argjson emails "$(csv_to_json "$EMAILS")" \
    --argjson domains "$(csv_to_json "$DOMAINS")" --argjson ips "$(csv_to_json "$IPS")" '{
      cfLogin: $cfp, accountId: $acc, zone: $zone,
      dmarc: {localPart: $lp, subdomain: $sub, authorizedDomains: $auth},
      dashboard: {host: $host},
      access: {emails: $emails, emailDomains: $domains, ips: $ips, sessionDuration: $session}
    }')
  echo ""
  echo "$JSON"
  echo ""
  confirm "Write ${PROFILE_FILE}?" || { echo "Aborted."; exit 0; }
  save_profile "$PROFILE_FILE" "$JSON"
  echo "Saved. Deploy with: ${C_BOLD}bash deploy.sh${PROFILE_ARG}${C_RESET}"
  echo ""
  offer "${C_BOLD}Deploy profile ${PROFILE} now?${C_RESET}" && next_run --profile "$PROFILE"
}

# --- Load profile ---
if [ "$MODE" = "setup" ] || [ ! -f "$PROFILE_FILE" ]; then
  setup_profile
  exit 0
fi

jq empty "$PROFILE_FILE" 2>/dev/null || die "$PROFILE_FILE is not valid JSON. Run: bash deploy.sh${PROFILE_ARG} --setup"
if [ "$(jq -r '._checksum // empty' "$PROFILE_FILE")" != "$(profile_hash "$PROFILE_FILE")" ]; then
  CHANGED_MSG="${PROFILE_FILE} was changed outside --setup (or saved by an older version). Review and save it with: bash deploy.sh${PROFILE_ARG} --setup"
  case "$MODE" in
    list|verify|login) warn "$CHANGED_MSG"; echo "" ;;
    *) die "$CHANGED_MSG" ;;
  esac
fi
p()  { jq -r "$1 // empty" "$PROFILE_FILE"; }
pj() { jq -c "$1 // []" "$PROFILE_FILE"; }

CF_PROFILE=$(p .cfLogin)
ACCOUNT_ID=$(p .accountId)
ZONE=$(p .zone)
LOCAL_PART=$(p .dmarc.localPart); LOCAL_PART=${LOCAL_PART:-dmarc}
SUBDOMAIN=$(p .dmarc.subdomain)
DASHBOARD_HOST=$(p .dashboard.host)
AUTH_DOMAINS=$(pj .dmarc.authorizedDomains)
ACCESS_EMAILS=$(pj .access.emails)
ACCESS_EMAIL_DOMAINS=$(pj .access.emailDomains)
ACCESS_IPS=$(pj .access.ips)
SESSION_DURATION=$(p .access.sessionDuration); SESSION_DURATION=${SESSION_DURATION:-24h}

[ -n "$ACCOUNT_ID" ] && export CLOUDFLARE_ACCOUNT_ID="$ACCOUNT_ID"

if [ "$MODE" = "login" ]; then
  login
  exit 0
fi

RECEIVE_DOMAIN_P="${SUBDOMAIN:+${SUBDOMAIN}.}${ZONE}"
DMARC_ADDRESS_P="${LOCAL_PART}@${RECEIVE_DOMAIN_P}"

# Access include rules for the profile: identities when set, otherwise the IP ranges.
expected_include() {
  jq -cn --argjson e "$ACCESS_EMAILS" --argjson d "$ACCESS_EMAIL_DOMAINS" --argjson ips "$ACCESS_IPS" '
    if ($e + $d | length) > 0
    then ($e | map({email: {email: .}})) + ($d | map({email_domain: {domain: .}}))
    else $ips | map({ip: {ip: .}}) end'
}
# dmarc_status <address> — check the published DMARC record of the zone and every
# authorized domain (public DNS over HTTPS, so no extra permissions or dig needed).
dmarc_status() {
  local ADDRESS="$1" D TXT P RUA
  for D in $(echo "$AUTH_DOMAINS" | jq -r --arg z "$ZONE" '[$z] + (. - [$z] | unique) | .[]'); do
    # Join split TXT strings ("a" "b") back into one record.
    TXT=$(curl -fsS -m 10 -H 'accept: application/dns-json' "https://cloudflare-dns.com/dns-query?name=_dmarc.${D}&type=TXT" 2>/dev/null \
      | jq -r '[.Answer[]? | select(.type == 16) | .data | gsub("\" \""; "") | ltrimstr("\"") | rtrimstr("\"")]
               | map(select(test("^v=DMARC1"; "i"))) | first // empty' 2>/dev/null || true)
    if [ -z "$TXT" ]; then
      if [ "$D" = "$ZONE" ]; then echo "  ${C_DIM}· ${D}: no DMARC record (not monitored here)${C_RESET}"
      else v_warn "${D}: no DMARC record (_dmarc.${D})"; fi
      continue
    fi
    P=$(echo "$TXT" | grep -oiE '(^|;)[[:space:]]*p=[a-z]+' | head -1 | sed -E 's/.*p=//I' | tr 'A-Z' 'a-z')
    RUA=$(echo "$TXT" | grep -oiE 'rua=[^;]*' | head -1)
    if ! echo "$RUA" | tr 'A-Z' 'a-z' | grep -qF "mailto:$(echo "$ADDRESS" | tr 'A-Z' 'a-z')"; then
      # The zone may just host this kit (not a monitored domain); listed domains are meant to report here.
      if [ "$D" = "$ZONE" ]; then echo "  ${C_DIM}· ${D}: not monitored here (its rua= points elsewhere)${C_RESET}"
      else v_warn "${D}: p=${P:-?}, but rua= does not include ${ADDRESS}, so its reports do not arrive here"; fi
    elif [ "$P" = none ] || [ -z "$P" ]; then
      v_warn "${D}: p=${P:-missing} only monitors; move to quarantine, then reject, once senders pass DKIM/SPF"
    else
      v_ok "${D}: p=${P}, reports here"
    fi
  done
}

report_record_names() {
  echo "$AUTH_DOMAINS" | jq -r --arg d "$1" 'if length == 0 then ["*"] else . end | .[] | "\(.)._report._dmarc.\($d)"'
}

# --- List mode: show the profile's settings and what the script manages ---
list_profile() {
  local F N INFO
  header "Profiles"
  for F in profiles/*.json; do
    N=$(basename "$F" .json)
    [ "$N" = example ] && continue
    INFO=$(jq -r '[(.zone // "?"), (.dashboard.host // "" | if . == "" then "host not generated yet" else . end)] | join("  →  ")' "$F")
    if [ "$N" = "$PROFILE" ]; then
      printf "  ${C_GREEN}●${C_RESET} ${C_BOLD}%-12s${C_RESET} %s\n" "$N" "$INFO"
    else
      printf "  ${C_DIM}○${C_RESET} %-12s ${C_DIM}%s${C_RESET}\n" "$N" "$INFO"
    fi
  done

  echo ""
  show_plan
  show_login
}

# The profile's settings and the resources the script manages for it.
show_plan() {
  header "Profile ${PROFILE} ${C_RESET}${C_DIM}(${PROFILE_FILE})"
  kv "cf login" "${CF_PROFILE:-(default login)}"
  kv "Account" "${ACCOUNT_ID:-(single account of the login)}"
  kv "Zone" "$ZONE" "$C_BOLD"
  kv "Receiving address" "$DMARC_ADDRESS_P" "$C_CYAN"
  if [ "$AUTH_DOMAINS" = "[]" ]; then
    kv "Report authorization" "*._report._dmarc.${RECEIVE_DOMAIN_P} (any domain)"
    kv "Reports kept for" "(any domain)"
  else
    kv "Report authorization" "<domain>._report._dmarc.${RECEIVE_DOMAIN_P} for each domain below"
    kv "Reports kept for" "${ZONE} and these $(echo "$AUTH_DOMAINS" | jq length) domains (and subdomains):"
    # shellcheck disable=SC2046
    print_columns $(echo "$AUTH_DOMAINS" | jq -r '.[]')
  fi
  if [ -n "$DASHBOARD_HOST" ]; then kv "Dashboard" "https://${DASHBOARD_HOST}" "$C_CYAN"; else kv "Dashboard" "(generated on first deploy)"; fi
  kv "Access emails" "$(csv_or_dash "$ACCESS_EMAILS")"
  kv "Access email domains" "$(csv_or_dash "$ACCESS_EMAIL_DOMAINS")"
  kv "Access IP ranges" "$(csv_or_dash "$ACCESS_IPS")"
  kv "Access session" "$(session_label "$SESSION_DURATION")"

  echo ""
  header "Resources managed by this script"
  kv "Worker" "${WORKER_NAME} (route ${DASHBOARD_HOST:-<host>}/*; workers.dev and preview URLs off)"
  kv "D1 database" "$DB_NAME"
  kv "Email Routing" "enabled on ${RECEIVE_DOMAIN_P} if not yet (only when it has no MX records)"
  kv "Email routing rule" "\"${RULE_NAME}\": ${DMARC_ADDRESS_P} → ${WORKER_NAME}"
  kv "DNS records" "_report._dmarc TXT + dashboard A 192.0.2.0 (proxied), comment ${MANAGED_TAG}"
  kv "Access" "app \"${ACCESS_APP_NAME}\", reusable policy \"${ACCESS_POLICY_NAME}\"$([ "$ACCESS_IPS" != "[]" ] && [ "$HAS_IDENTITY_P" = true ] && echo ", group \"${ACCESS_GROUP_NAME}\"")"
}

# Granted alongside "offline"; part of the requested login, not an extra.
IMPLIED_SCOPES=(offline_access)

# print_columns <items…> — three per row, aligned.
print_columns() {
  local I=0 ITEM
  for ITEM in "$@"; do
    [ $((I % 3)) -eq 0 ] && printf "      "
    printf "%-28s" "$ITEM"
    I=$((I + 1))
    [ $((I % 3)) -eq 0 ] && printf "\n"
  done
  [ $((I % 3)) -ne 0 ] && printf "\n"
  return 0
}

# scope_report <whoami json> — the required scopes, and any extra ones the login also has.
scope_report() {
  local WANT MISSING EXTRA N=${#LOGIN_SCOPES[@]} NM NE
  if ! echo "$1" | jq -e '.scopes | type == "array"' >/dev/null; then
    v_warn "Scopes unknown for $(echo "$1" | jq -r '.authSource // "this login"')"
    return
  fi
  WANT=$(printf '%s\n' "${LOGIN_SCOPES[@]}" "${IMPLIED_SCOPES[@]}" | jq -Rn '[inputs]')
  MISSING=$(echo "$1" | jq -r --argjson w "$(printf '%s\n' "${LOGIN_SCOPES[@]}" | jq -Rn '[inputs]')" '$w - .scopes | .[]')
  EXTRA=$(echo "$1" | jq -r --argjson w "$WANT" '.scopes - $w | .[]')
  if [ -z "$MISSING" ]; then
    v_ok "All ${N} required scopes granted:"
    print_columns "${LOGIN_SCOPES[@]}"
  else
    NM=$(echo "$MISSING" | wc -l | tr -d ' ')
    v_fail "Missing ${NM} of ${N} required scopes (run: bash deploy.sh${PROFILE_ARG} --login):"
    # shellcheck disable=SC2046
    print_columns $(echo "$MISSING")
  fi
  if [ -n "$EXTRA" ]; then
    NE=$(echo "$EXTRA" | wc -l | tr -d ' ')
    v_warn "${NE} non-required scope(s) also granted — narrow the login with: bash deploy.sh${PROFILE_ARG} --login"
    # A plain `cf auth login` grants hundreds; only name a handful.
    # shellcheck disable=SC2046
    [ "$NE" -le 9 ] && print_columns $(echo "$EXTRA")
  fi
}

show_login() {
  local WHO
  echo ""
  header "Cloudflare login"
  if WHO=$(cf auth whoami 2>/dev/null) && echo "$WHO" | jq -e '.authenticated and .tokenValid != false' >/dev/null; then
    kv "Logged in as" "$(echo "$WHO" | jq -r '.email // "?"')" "$C_BOLD"
    kv "Credentials" "$(echo "$WHO" | jq -r '.authSource // "?"')"
    scope_report "$WHO"
  else
    v_fail "Not logged in — run: bash deploy.sh${PROFILE_ARG} --login"
  fi
}

HAS_IDENTITY_P="false"
[ "$ACCESS_EMAILS$ACCESS_EMAIL_DOMAINS" != "[][]" ] && HAS_IDENTITY_P="true"

if [ "$MODE" = "list" ]; then
  list_profile
  exit 0
fi

logged_in || login

# --- Verify mode: compare the live setup with the profile ---

verify() {
  local WHO MISSING Z RULES REC NAME APP POLICIES CERT HTTP D1 PENDING
  header "=== Verify profile ${PROFILE} against Cloudflare ==="

  echo ""; header "Login"
  WHO=$(cf auth whoami)
  v_ok "Logged in as $(echo "$WHO" | jq -r '.email // .authSource')"
  scope_report "$WHO"

  echo ""; header "Zone and Email Routing"
  Z=$(cf zones get --zone "$ZONE" 2>/dev/null | jq -r '.name // empty') || true
  [ -n "$Z" ] || { v_fail "Zone ${ZONE} not found on this account"; return; }
  v_ok "Zone ${Z}"
  if cf dns records list --zone "$Z" --type MX --name "$RECEIVE_DOMAIN_P" | jq -e 'any(.[]; .content | endswith("mx.cloudflare.net"))' >/dev/null; then
    v_ok "Email Routing enabled on ${RECEIVE_DOMAIN_P}"
  else v_fail "Email Routing is not enabled on ${RECEIVE_DOMAIN_P}"; fi

  RULES=$(cf email-routing rules list-account --zone "$Z" | jq -c --arg w "$WORKER_NAME" \
    '[.[] | select(any(.actions[]?; .type == "worker" and ((.value // []) | index($w))))]')
  if echo "$RULES" | jq -e --arg to "$DMARC_ADDRESS_P" 'any(.[]; .enabled and any(.matchers[]?; .value == $to))' >/dev/null; then
    v_ok "Routing rule ${DMARC_ADDRESS_P} → ${WORKER_NAME}"
  else v_fail "No enabled routing rule ${DMARC_ADDRESS_P} → ${WORKER_NAME}"; fi
  echo "$RULES" | jq -r --arg to "$DMARC_ADDRESS_P" '.[] | select(any(.matchers[]?; .value == $to) | not) | (.matchers[]? | select(.field == "to") | .value)' |
    while read -r NAME; do [ -n "$NAME" ] && v_warn "Extra routing rule ${NAME} → ${WORKER_NAME} (old address? remove with --cleanup)"; done

  echo ""; header "DNS"
  REC=$(cf dns records list --zone "$Z" --type TXT --name-endswith "._report._dmarc.${RECEIVE_DOMAIN_P}")
  while read -r NAME; do
    if echo "$REC" | jq -e --arg n "$NAME" --arg c "$MANAGED_TAG" 'any(.[]; .name == $n and .content == "\"v=DMARC1;\"" and .comment == $c)' >/dev/null; then
      v_ok "TXT ${NAME}"
    elif echo "$REC" | jq -e --arg n "$NAME" 'any(.[]; .name == $n)' >/dev/null; then
      v_warn "TXT ${NAME} exists but is untagged or differs (fixed on next deploy)"
    else v_fail "TXT ${NAME} missing"; fi
  done <<< "$(report_record_names "$RECEIVE_DOMAIN_P")"
  echo "$REC" | jq -r --arg c "$MANAGED_TAG" --argjson want "$(report_record_names "$RECEIVE_DOMAIN_P" | jq -Rn '[inputs]')" \
    '.[] | select(.comment == $c and (.name as $n | $want | index($n) | not)) | .name' |
    while read -r NAME; do [ -n "$NAME" ] && v_warn "Stale TXT ${NAME} (removed on next deploy)"; done

  if [ -z "$DASHBOARD_HOST" ]; then
    v_fail "dashboard.host is empty — not deployed yet"
  else
    REC=$(cf dns records list --zone "$Z" --name "$DASHBOARD_HOST" | jq -c 'first(.[]) // empty')
    if [ -z "$REC" ]; then v_fail "No DNS record for ${DASHBOARD_HOST}"
    elif echo "$REC" | jq -e --arg c "$MANAGED_TAG" '.type == "A" and .content == "192.0.2.0" and .proxied and .comment == $c' >/dev/null; then
      v_ok "A ${DASHBOARD_HOST} → 192.0.2.0 (proxied)"
    elif echo "$REC" | jq -e '.meta.origin_worker_id' >/dev/null; then
      v_warn "${DASHBOARD_HOST} is a Workers custom domain (has its own certificate in CT logs)"
    else v_warn "${DASHBOARD_HOST} record differs: $(echo "$REC" | jq -r '"\(.type) \(.content) proxied=\(.proxied)"') (fixed on next deploy if tagged)"; fi
  fi

  echo ""; header "Worker"
  if W=$(cf workers get "$WORKER_NAME" 2>/dev/null); then
    v_ok "Worker ${WORKER_NAME}"
    if echo "$W" | jq -e '.subdomain.enabled == false and .subdomain.previews_enabled == false' >/dev/null; then
      v_ok "workers.dev and preview URLs disabled"
    else v_warn "workers.dev or preview URLs enabled (bypasses the dashboard host)"; fi
  else v_fail "Worker ${WORKER_NAME} not deployed"; fi
  D1=$(cf d1 list | jq -r --arg n "$DB_NAME" 'first(.[] | select(.name == $n) | .uuid) // empty')
  if [ -n "$D1" ]; then
    PENDING=$(cf d1 migrations list "$D1" --dir migrations | jq -r '[.[].Name] | join(", ")')
    if [ -z "$PENDING" ]; then v_ok "D1 ${DB_NAME}, migrations applied"; else v_warn "D1 ${DB_NAME}: pending migrations ${PENDING}"; fi
  else v_fail "D1 database ${DB_NAME} missing"; fi

  echo ""; header "Access and TLS"
  APP=$(cf zero-trust access applications list | jq -c --arg n "$ACCESS_APP_NAME" 'first(.[] | select(.name == $n)) // empty')
  if [ -z "$APP" ]; then v_fail "Access app \"${ACCESS_APP_NAME}\" missing"
  else
    if echo "$APP" | jq -e --arg h "$DASHBOARD_HOST" '.domain == $h' >/dev/null; then v_ok "Access app covers ${DASHBOARD_HOST}"
    else v_fail "Access app is on $(echo "$APP" | jq -r .domain), not ${DASHBOARD_HOST}"; fi
    if echo "$APP" | jq -e --arg sd "$SESSION_DURATION" '.session_duration == $sd' >/dev/null; then
      v_ok "Session duration $(session_label "$SESSION_DURATION")"
    else v_warn "Session duration is $(echo "$APP" | jq -r '.session_duration // "unset"'), profile says ${SESSION_DURATION} (updated on next deploy)"; fi
    POLICIES=$(cf zero-trust access applications get "$(echo "$APP" | jq -r .id)" | jq -c '.policies // []')
    if echo "$POLICIES" | jq -e --arg n "$ACCESS_POLICY_NAME" 'any(.[]; .name == $n and .reusable)' >/dev/null; then
      v_ok "Reusable policy \"${ACCESS_POLICY_NAME}\" attached"
      if echo "$POLICIES" | jq -e --arg n "$ACCESS_POLICY_NAME" --argjson inc "$(expected_include)" \
          'first(.[] | select(.name == $n)) | (.include | sort) == ($inc | sort)' >/dev/null; then
        v_ok "Policy rules match the profile"
      else v_warn "Policy rules differ from the profile (updated on next deploy)"; fi
    elif echo "$POLICIES" | jq -e 'any(.[]; .reusable | not)' >/dev/null; then
      v_warn "App uses an app-scoped (legacy) policy (converted on next deploy)"
    else v_fail "No allow policy attached — the dashboard denies everyone"; fi
  fi
  if [ -n "$DASHBOARD_HOST" ]; then
    HTTP=$(curl -s -o /dev/null -m 15 -w '%{http_code} %{redirect_url}' "https://${DASHBOARD_HOST}/api/domains" || true)
    case "$HTTP" in
      30[0-9]*cloudflareaccess.com*) v_ok "https://${DASHBOARD_HOST} requires Access login" ;;
      200*) v_fail "https://${DASHBOARD_HOST} answers WITHOUT Access — the dashboard is public" ;;
      *) v_fail "https://${DASHBOARD_HOST} unexpected response: ${HTTP:-no response}" ;;
    esac
    if command -v openssl >/dev/null; then
      CERT=$(echo | openssl s_client -connect "${DASHBOARD_HOST}:443" -servername "$DASHBOARD_HOST" 2>/dev/null | openssl x509 -noout -ext subjectAltName 2>/dev/null || true)
      case "$CERT" in
        *"DNS:*.${Z}"*) v_ok "Served by the zone's wildcard certificate" ;;
        *"DNS:${DASHBOARD_HOST}"*) v_warn "Served by a per-host certificate (hostname is in CT logs)" ;;
        *) v_warn "Could not read the TLS certificate" ;;
      esac
    fi
  fi

  if [ "$AUTH_DOMAINS" != "[]" ]; then
    echo ""; header "Monitored domains"
    dmarc_status "$DMARC_ADDRESS_P"
  fi

  echo ""; header "Leftovers from older versions"
  local FOUND="false" ZID ZNAME
  [ -f .env.legacy ] && { v_warn ".env.legacy holds an old API token — delete it and revoke the token"; FOUND=true; }
  [ -f wrangler.toml ] && { v_warn "wrangler.toml is no longer used — compare it with cloudflare.config.ts and wrangler.config.ts (e.g. for settings you added yourself), then remove it"; FOUND=true; }
  if [ -n "$APP" ] && echo "$APP" | jq -e 'any(.destinations[]?; .uri | endswith(".workers.dev"))' >/dev/null; then
    v_warn "Access app still lists a workers.dev host"; FOUND=true
  fi
  while IFS=$'\t' read -r ZID ZNAME; do
    [ -z "$ZID" ] || [ "$ZNAME" = "$Z" ] && continue
    if cf email-routing rules list-account --zone "$ZID" 2>/dev/null | jq -e --arg w "$WORKER_NAME" \
        'any(.[]; any(.actions[]?; .type == "worker" and ((.value // []) | index($w))))' >/dev/null; then
      v_warn "${ZNAME} still routes mail to ${WORKER_NAME} (remove with --cleanup)"; FOUND=true
    fi
    if cf dns records list --zone "$ZID" --comment "$MANAGED_TAG" 2>/dev/null | jq -e 'length > 0' >/dev/null; then
      v_warn "${ZNAME} has DNS records created by this script (remove with --cleanup)"; FOUND=true
    fi
  done <<< "$(cf zones list | jq -r '.[] | [.id, .name] | @tsv')"
  if cf dns records list --zone "$Z" --type TXT --name-contains "_report._dmarc" --comment-absent true 2>/dev/null \
      | jq -e 'any(.[]; .content == "\"v=DMARC1;\"")' >/dev/null; then
    v_warn "Untagged _report._dmarc records from an older version on ${Z}"; FOUND=true
  fi
  [ "$FOUND" = true ] || v_ok "None found"

  echo ""
  if [ "$V_FAIL" -gt 0 ]; then echo "${C_RED}${C_BOLD}${V_FAIL} problem(s), ${V_WARN} warning(s).${C_RESET}"; exit 1
  elif [ "$V_WARN" -gt 0 ]; then echo "${C_YELLOW}${C_BOLD}No problems, ${V_WARN} warning(s).${C_RESET}"
  else echo "${C_GREEN}${C_BOLD}Everything matches the profile.${C_RESET}"; fi
}

if [ "$MODE" = "verify" ]; then
  verify
  exit 0
fi

# --- Cleanup mode: pick and delete resources this script created ---
# Lists everything any version of this script created on the profile's account —
# including routing rules and _report._dmarc records left on zones it no longer
# uses — and deletes only what is ticked.
ITEM_KIND=(); ITEM_ID=(); ITEM_ZONE=(); ITEM_LABEL=(); ITEM_ON=()
add_item() { ITEM_KIND+=("$1"); ITEM_ID+=("$2"); ITEM_ZONE+=("$3"); ITEM_LABEL+=("$4"); ITEM_ON+=(0); }

gather_resources() {
  if cf workers get "$WORKER_NAME" >/dev/null 2>&1; then
    add_item worker "$WORKER_NAME" "" "Worker ${WORKER_NAME}"
  fi

  local APP_ID POLICY_ID GROUP_ID
  APP_ID=$(cf zero-trust access applications list | jq -r --arg n "$ACCESS_APP_NAME" 'first(.[] | select(.name == $n) | .id) // empty')
  [ -n "$APP_ID" ] && add_item access-app "$APP_ID" "" "Access app \"${ACCESS_APP_NAME}\" (and its app-scoped policies)"
  POLICY_ID=$(cf zero-trust access policies list | jq -r --arg n "$ACCESS_POLICY_NAME" 'first(.[] | select(.name == $n) | .id) // empty')
  [ -n "$POLICY_ID" ] && add_item access-policy "$POLICY_ID" "" "Access policy \"${ACCESS_POLICY_NAME}\""
  GROUP_ID=$(cf zero-trust access rule-groups list | jq -r --arg n "$ACCESS_GROUP_NAME" 'first(.[] | select(.name == $n) | .id) // empty')
  [ -n "$GROUP_ID" ] && add_item access-group "$GROUP_ID" "" "Access group \"${ACCESS_GROUP_NAME}\""

  local DB_ID
  DB_ID=$(cf d1 list | jq -r --arg n "$DB_NAME" 'first(.[] | select(.name == $n) | .uuid) // empty')
  [ -n "$DB_ID" ] && add_item d1 "$DB_ID" "" "D1 database ${DB_NAME} — stored reports"

  local ZONES
  ZONES=$(cf zones list | jq -r '.[] | [.id, .name] | @tsv')
  while IFS=$'\t' read -r ZID ZNAME; do
    [ -z "$ZID" ] && continue
    cf email-routing rules list-account --zone "$ZID" 2>/dev/null | jq -r --arg w "$WORKER_NAME" '
      .[] | select(any(.actions[]?; .type == "worker" and ((.value // []) | index($w))))
      | [.id, ((.matchers[]? | select(.field == "to") | .value) // .name // "(unnamed rule)")] | @tsv' |
    while IFS=$'\t' read -r ID TO; do echo "rule	$ID	$ZID	Email routing rule ${TO} → ${WORKER_NAME}"; done
    # Records tagged by this script, plus untagged "v=DMARC1;" records from
    # versions that predate tagging.
    cf dns records list --zone "$ZID" --comment "$MANAGED_TAG" 2>/dev/null | jq -r '.[] | [.id, .type, .name] | @tsv' |
    while IFS=$'\t' read -r ID TYPE NAME; do echo "dns	$ID	$ZID	DNS ${TYPE} ${NAME}"; done
    cf dns records list --zone "$ZID" --type TXT --name-contains "_report._dmarc" --comment-absent true 2>/dev/null \
      | jq -r '.[] | select(.content == "\"v=DMARC1;\"") | [.id, .name] | @tsv' |
    while IFS=$'\t' read -r ID NAME; do echo "dns	$ID	$ZID	DNS TXT ${NAME} (untagged, from an older version)"; done
  done <<< "$ZONES" > "$TMP_ITEMS"
  while IFS=$'\t' read -r KIND ID ZID LABEL; do add_item "$KIND" "$ID" "$ZID" "$LABEL"; done < "$TMP_ITEMS"

  # Disabling Email Routing needs Zone Settings Write, which the login does not
  # request, so a receiving subdomain is left as a manual step.
  MANUAL_ROUTING=""
  if [ -n "$SUBDOMAIN" ] && cf dns records list --zone "$ZONE" --type MX --name "${SUBDOMAIN}.${ZONE}" 2>/dev/null \
      | jq -e 'any(.[]; .content | endswith("mx.cloudflare.net"))' >/dev/null; then
    MANUAL_ROUTING="${SUBDOMAIN}.${ZONE}"
  fi
}

# Toggle items by number until Enter on an empty line.
pick_items() {
  local N=${#ITEM_KIND[@]} INPUT TOKEN I FROM TO
  while :; do
    echo ""
    for ((I = 0; I < N; I++)); do
      printf "  %2d [%s] %s\n" $((I + 1)) "$([ "${ITEM_ON[$I]}" = 1 ] && echo x || echo ' ')" "${ITEM_LABEL[$I]}"
    done
    echo ""
    printf "Toggle by number (e.g. \"1 3\" or \"2-4\"), a = all, n = none, Enter = done: "
    { read -r INPUT </dev/tty; } 2>/dev/null || INPUT=""
    [ -z "$INPUT" ] && return
    for TOKEN in ${INPUT//,/ }; do
      case "$TOKEN" in
        a) for ((I = 0; I < N; I++)); do ITEM_ON[$I]=1; done ;;
        n) for ((I = 0; I < N; I++)); do ITEM_ON[$I]=0; done ;;
        *-*) FROM=${TOKEN%-*}; TO=${TOKEN#*-}
             if [[ "$FROM$TO" =~ ^[0-9]+$ ]]; then
               for ((I = FROM; I <= TO && I <= N; I++)); do [ "$I" -ge 1 ] && ITEM_ON[$((I - 1))]=$((1 - ITEM_ON[I - 1])); done
             fi ;;
        *) if [[ "$TOKEN" =~ ^[0-9]+$ ]] && [ "$TOKEN" -ge 1 ] && [ "$TOKEN" -le "$N" ]; then
             ITEM_ON[$((TOKEN - 1))]=$((1 - ITEM_ON[TOKEN - 1]))
           fi ;;
      esac
    done
  done
}

selected() {  # selected <kind> — succeeds if any item of that kind is ticked
  local I
  for ((I = 0; I < ${#ITEM_KIND[@]}; I++)); do
    [ "${ITEM_KIND[$I]}" = "$1" ] && [ "${ITEM_ON[$I]}" = 1 ] && return 0
  done
  return 1
}
present() {  # present <kind> — succeeds if an item of that kind exists
  local K
  for K in "${ITEM_KIND[@]}"; do [ "$K" = "$1" ] && return 0; done
  return 1
}

delete_item() {
  local I=$1 ID="${ITEM_ID[$1]}" Z="${ITEM_ZONE[$1]}"
  case "${ITEM_KIND[$I]}" in
    # --force skips cf's own prompt; this script already asked for Y.
    rule)          cf email-routing rules delete "$ID" --zone "$Z" --force ;;
    dns)           cf dns records delete "$ID" --zone "$Z" --force ;;
    worker)        cf workers delete "$ID" --force ;;
    access-app)    cf zero-trust access applications delete "$ID" --force ;;
    access-policy) cf zero-trust access policies delete "$ID" --force ;;
    access-group)  cf zero-trust access rule-groups delete "$ID" --force ;;
    d1)            cf d1 delete "$ID" --force ;;
  esac >/dev/null
}

cleanup() {
  echo "=== DMARC Dashboard Kit Cleanup (profile: ${PROFILE}) ==="
  echo ""
  echo "Looking for resources created by this script..."
  TMP_ITEMS=$(mktemp)
  gather_resources
  rm -f "$TMP_ITEMS"

  if [ ${#ITEM_KIND[@]} -eq 0 ]; then
    echo "Nothing found — no resources created by this script remain."
    [ -n "$MANUAL_ROUTING" ] && echo "Email Routing on ${MANUAL_ROUTING} is still on: remove it in the dashboard (${ZONE} → Email → Email Routing → Settings → Subdomains)."
    return
  fi

  pick_items
  selected worker || selected access-app || selected access-policy || selected access-group || selected d1 \
    || selected rule || selected dns || { echo "Nothing selected."; return; }

  # Without Access the worker would serve the dashboard and API publicly.
  if { selected access-app || selected access-policy; } && present worker && ! selected worker; then
    die "Deleting Access while keeping the worker would make the dashboard public. Tick the worker too, or keep Access."
  fi

  if selected d1; then
    echo ""
    echo "${C_YELLOW}${C_BOLD}The selected D1 database(s) hold the stored DMARC reports.${C_RESET}"
    confirm "Have the reports been copied elsewhere with --migrate-from, or are they no longer needed?" \
      || { echo "Aborted. Copy them first: bash deploy.sh --profile <target> --migrate-from=${PROFILE}"; exit 0; }
  fi

  echo ""
  echo "Will delete:"
  local I
  for ((I = 0; I < ${#ITEM_KIND[@]}; I++)); do
    [ "${ITEM_ON[$I]}" = 1 ] && echo "  • ${ITEM_LABEL[$I]}"
  done
  echo ""
  confirm "Delete these resources?" || { echo "Aborted."; exit 0; }
  echo ""

  # Ingestion first, then the worker before Access so the dashboard is never
  # reachable without it, then data last.
  local KIND
  for KIND in rule worker dns access-app access-policy access-group d1; do
    for ((I = 0; I < ${#ITEM_KIND[@]}; I++)); do
      [ "${ITEM_KIND[$I]}" = "$KIND" ] && [ "${ITEM_ON[$I]}" = 1 ] || continue
      if delete_item "$I"; then echo "  Deleted ${ITEM_LABEL[$I]}"; else warn "Failed to delete ${ITEM_LABEL[$I]}"; fi
    done
  done

  echo ""
  echo "=== Cleanup complete ==="
  if [ -n "$MANUAL_ROUTING" ]; then
    echo ""
    echo "To stop receiving on ${MANUAL_ROUTING}, remove it in the dashboard:"
    echo "  ${ZONE} → Email → Email Routing → Settings → Subdomains"
  fi
  if selected rule || selected dns; then
    echo ""
    echo "Confirm no monitored domain still points rua= at a removed address:"
    echo "  dig +short TXT _dmarc.<monitored-domain>"
  fi
}

if [ "$MODE" = "cleanup" ]; then
  cleanup
  exit 0
fi

# --- Migrate mode: copy stored reports from another profile's database ---
# Each side runs with its own profile's cf login and account, so the source can
# live on a different Cloudflare account. INSERT OR IGNORE on the unique keys
# (reports.report_id, record_rows(report_id, source_ip, header_from)) skips
# reports both databases already have. The source is only read.
cf_as() {
  local FILE="$1"; shift
  (
    CF_PROFILE=$(jq -r '.cfLogin // empty' "$FILE")
    ACC=$(jq -r '.accountId // empty' "$FILE")
    if [ -n "$ACC" ]; then export CLOUDFLARE_ACCOUNT_ID="$ACC"; else unset CLOUDFLARE_ACCOUNT_ID; fi
    cf "$@"
  )
}

migrate_from() {
  local SRC_FILE="profiles/${MIGRATE_FROM}.json"
  [ -f "$SRC_FILE" ] || die "Source profile ${SRC_FILE} not found."
  [ "$SRC_FILE" = "$PROFILE_FILE" ] && die "Source and target are the same profile."
  cf_as "$SRC_FILE" auth whoami 2>/dev/null | jq -e '.authenticated and .tokenValid != false' >/dev/null \
    || die "Not logged in for profile ${MIGRATE_FROM}. Run: bash deploy.sh --profile ${MIGRATE_FROM} --login"

  echo "=== Migrate reports: ${MIGRATE_FROM} → ${PROFILE} ==="
  echo ""
  local SRC_DB DST_DB
  SRC_DB=$(cf_as "$SRC_FILE" d1 list | jq -r --arg n "$DB_NAME" 'first(.[] | select(.name == $n) | .uuid) // empty')
  DST_DB=$(cf_as "$PROFILE_FILE" d1 list | jq -r --arg n "$DB_NAME" 'first(.[] | select(.name == $n) | .uuid) // empty')
  [ -n "$SRC_DB" ] || die "No '${DB_NAME}' database found for profile ${MIGRATE_FROM}."
  [ -n "$DST_DB" ] || die "No '${DB_NAME}' database found for profile ${PROFILE}. Deploy it first: bash deploy.sh${PROFILE_ARG}"
  [ "$SRC_DB" = "$DST_DB" ] && die "Both profiles use the same database (${SRC_DB}) — nothing to migrate."

  local COUNTS
  COUNTS=$(cf_as "$SRC_FILE" d1 query "$SRC_DB" --sql "SELECT (SELECT COUNT(*) FROM reports) AS reports, (SELECT COUNT(*) FROM record_rows) AS record_rows" | jq -c '.[0].results[0]')
  echo "  Source ${MIGRATE_FROM}: $(echo "$COUNTS" | jq -r '"\(.reports) reports, \(.record_rows) record rows"') (${SRC_DB})"
  echo "  Target ${PROFILE}: ${DST_DB}"
  echo ""
  confirm "Copy them into ${PROFILE}? Reports already there are skipped." || { echo "Aborted."; exit 0; }
  echo ""

  # Reports first: record_rows references reports(report_id).
  copy_table reports \
    "report_id, org_name, date_range_begin, date_range_end, error, domain, adkim, aspf, policy_p, policy_sp, policy_pct, received_at"
  copy_table record_rows \
    "report_id, source_ip, count, disposition, dkim_result, spf_result, reason_type, envelope_to, header_from, date_range_begin"

  echo ""
  echo "=== Migration complete ==="
  echo "Re-running is safe: rows already copied are skipped."
}

# copy_table <table> <columns>: pages through the source by id and inserts each
# page as one JSON parameter (D1 caps bound parameters at 100 per query).
copy_table() {
  local TABLE="$1" COLS="$2" PAGE=200 LAST_ID=0 READ=0 ADDED=0 ROWS N SELECT_JSON
  SELECT_JSON=$(echo "$COLS" | tr -d ' ' | tr ',' '\n' | awk '{printf "%sjson_extract(value, '"'"'$.%s'"'"')", (NR>1?", ":""), $1}')
  while :; do
    ROWS=$(cf_as "profiles/${MIGRATE_FROM}.json" d1 query "$SRC_DB" \
      --sql "SELECT id, ${COLS} FROM ${TABLE} WHERE id > ? ORDER BY id LIMIT ${PAGE}" --params "$LAST_ID" | jq -c '.[0].results')
    N=$(echo "$ROWS" | jq 'length')
    [ "$N" -eq 0 ] && break
    LAST_ID=$(echo "$ROWS" | jq '.[-1].id')
    ADDED=$(( ADDED + $(cf_as "$PROFILE_FILE" d1 query "$DST_DB" \
      --sql "INSERT OR IGNORE INTO ${TABLE} (${COLS}) SELECT ${SELECT_JSON} FROM json_each(?)" \
      --params "$(echo "$ROWS" | jq -c 'map(del(.id))')" | jq '.[0].meta.changes // 0') ))
    READ=$(( READ + N ))
    printf "\r  %-12s %d read, %d added" "$TABLE" "$READ" "$ADDED"
  done
  printf "\r  %-12s %d read, %d added (%d already present)\n" "$TABLE" "$READ" "$ADDED" "$(( READ - ADDED ))"
}

if [ "$MODE" = "migrate" ]; then
  migrate_from
  exit 0
fi

# --- Validate profile for deploy ---
[ -n "$ZONE" ] || die "The profile has no zone. Run: bash deploy.sh${PROFILE_ARG} --setup"
if [ "$ACCESS_EMAILS$ACCESS_EMAIL_DOMAINS$ACCESS_IPS" = "[][][]" ]; then
  die "The profile allows nobody into the dashboard. Add Access emails, email domains, or IP ranges with: bash deploy.sh${PROFILE_ARG} --setup"
fi
HAS_IDENTITY="false"
[ "$ACCESS_EMAILS$ACCESS_EMAIL_DOMAINS" != "[][]" ] && HAS_IDENTITY="true"
if [ "$HAS_IDENTITY" = "false" ]; then
  warn "Only access.ips is set — anyone from these IP ranges can open the dashboard without email identity verification."
fi

header "=== DMARC Dashboard Kit Deploy ==="
echo ""
show_plan
echo ""
confirm "${C_BOLD}Deploy profile ${PROFILE}?${C_RESET}" || { echo "Aborted."; exit 0; }

# --- Step 0: Zone and addresses ---
echo ""
echo "[0/7] Checking zone and Email Routing..."
ZONE_NAME=$(cf zones get --zone "$ZONE" | jq -r '.name // empty') \
  || die "Could not read zone ${ZONE}. Check the zone name and your cf login (pnpm exec cf auth whoami)."
ZONE="$ZONE_NAME"
RECEIVE_DOMAIN="${SUBDOMAIN:+${SUBDOMAIN}.}${ZONE}"
DMARC_ADDRESS="${LOCAL_PART}@${RECEIVE_DOMAIN}"

if [ -z "$DASHBOARD_HOST" ]; then
  # A random suffix keeps the dashboard host from being guessable from the
  # receiving address. Generated once and saved, so it stays stable across deploys.
  SUFFIX=$(node -e 'const c="abcdefghijklmnopqrstuvwxyz0123456789";let s="";for(const b of require("crypto").randomBytes(5))s+=c[b%36];console.log(s)')
  DASHBOARD_HOST="dmarc-${SUFFIX}.${ZONE}"
  save_profile "$PROFILE_FILE" "$(jq --arg h "$DASHBOARD_HOST" '.dashboard.host = $h' "$PROFILE_FILE")"
  echo "  Generated dashboard host ${DASHBOARD_HOST} (saved to ${PROFILE_FILE})"
fi
# The zone's Universal SSL certificate covers one level of subdomain only; a
# deeper host would need its own certificate, which lands in public CT logs.
case "${DASHBOARD_HOST%."$ZONE"}" in
  "$DASHBOARD_HOST"|*.*|"") die "dashboard.host (${DASHBOARD_HOST}) must be exactly one level below ${ZONE} (e.g. dmarc-x7k2q.${ZONE})." ;;
esac

echo "  Zone: ${ZONE}"
echo "  DMARC address: ${DMARC_ADDRESS}"
echo "  Dashboard: https://${DASHBOARD_HOST}"

# Enabling Email Routing on the zone apex replaces its MX records, which would
# break any existing mailbox — so that stays a deliberate manual step. A
# receiving subdomain only gets records under the subdomain, so it is enabled here.
# A domain has Email Routing when its MX records point at Cloudflare.
if cf dns records list --zone "$ZONE" --type MX --name "$RECEIVE_DOMAIN" | jq -e 'any(.[]; .content | endswith("mx.cloudflare.net"))' >/dev/null; then
  echo "  Email Routing enabled on ${RECEIVE_DOMAIN}"
elif [ -z "$SUBDOMAIN" ]; then
  # Enabling Email Routing on the root replaces its MX records, so only do it when
  # there are none (a domain without mail of its own); never over another provider.
  ROOT_MX=$(cf dns records list --zone "$ZONE" --type MX --name "$ZONE" | jq -r '[.[].content] | join(", ")')
  if [ -n "$ROOT_MX" ]; then
    die "${ZONE} receives mail through ${ROOT_MX}. Enabling Email Routing on it would replace
those MX records and break that mail. Receive on a subdomain instead (choose it with:
bash deploy.sh${PROFILE_ARG} --setup)."
  fi
  echo "  Enabling Email Routing on ${ZONE} (it has no MX records yet)..."
  cf email-routing enable --zone "$ZONE" >/dev/null \
    || die "Could not enable Email Routing on ${ZONE}. Enable it in the dashboard: ${ZONE} → Email → Email Routing."
else
  # Enabling a subdomain also touches the zone root: Cloudflare adds a DKIM key
  # (cf2024-1._domainkey) and, only when the root has no SPF record, an SPF record
  # that authorizes Cloudflare alone. The root's MX and an existing SPF stay as they are.
  ROOT_MX=$(cf dns records list --zone "$ZONE" --type MX --name "$ZONE" | jq -r '[.[].content | select(endswith("mx.cloudflare.net") | not)] | join(", ")')
  ROOT_SPF=$(cf dns records list --zone "$ZONE" --type TXT --name "$ZONE" | jq -r '[.[].content | select(test("v=spf1"))] | length')
  if [ "$ROOT_SPF" = 0 ] && [ -n "$ROOT_MX" ]; then
    die "${ZONE} receives mail through ${ROOT_MX} but has no SPF record. Enabling Email Routing on
${RECEIVE_DOMAIN} would add a root SPF record that authorizes only Cloudflare, so ${ZONE}'s own
outgoing mail would start failing SPF. Publish an SPF record for ${ZONE} first, then deploy again."
  fi
  [ "$ROOT_SPF" = 0 ] && echo "  Note: ${ZONE} has no SPF record; Cloudflare will add one authorizing only its own servers."
  SUB_MX=$(cf dns records list --zone "$ZONE" --type MX --name "$RECEIVE_DOMAIN" | jq -r '[.[].content] | join(", ")')
  [ -z "$SUB_MX" ] || die "${RECEIVE_DOMAIN} already receives mail through ${SUB_MX}. Enabling Email Routing on it would
take that over. Pick another subdomain with: bash deploy.sh${PROFILE_ARG} --setup"
  echo "  Enabling Email Routing on ${RECEIVE_DOMAIN}..."
  cf email-routing enable --zone "$ZONE" --body "$(jq -cn --arg n "$RECEIVE_DOMAIN" '{name: $n}')" >/dev/null \
    || die "Could not enable Email Routing on ${RECEIVE_DOMAIN}. Add it in the dashboard:
${ZONE} → Email → Email Routing → Settings → Subdomains."
fi

# --- Step 1: Cloudflare Access ---
# Runs before the deploy so the dashboard host is never reachable without Access.
echo ""
echo "[1/7] Configuring Cloudflare Access..."
# Every Access call fails until Zero Trust is set up on the account (a one-time,
# account-level choice of team name and plan), so check once and explain.
cf zero-trust access applications list >/dev/null || die "Cloudflare Access is not available on this account.
If Zero Trust is not set up yet, do it once in the dashboard: Zero Trust → Get started
(choose a team name and the Free plan), then deploy again."

# Rules within a group's include are OR'd, then the group is AND'd via require.
# This avoids the flat-require AND problem where several IPs would all have to match.
REQUIRE_RULES="[]"
if [ "$ACCESS_IPS" != "[]" ] && [ "$HAS_IDENTITY" = "true" ]; then
  GROUP_BODY=$(jq -cn --arg n "$ACCESS_GROUP_NAME" --argjson ips "$ACCESS_IPS" '{name: $n, include: ($ips | map({ip: {ip: .}}))}')
  GROUP_ID=$(cf zero-trust access rule-groups list | jq -r --arg n "$ACCESS_GROUP_NAME" 'first(.[] | select(.name == $n) | .id) // empty')
  if [ -z "$GROUP_ID" ]; then
    GROUP_ID=$(cf zero-trust access rule-groups create --body "$GROUP_BODY" | jq -r '.id')
    echo "  Created Access group for IPs: ${GROUP_ID}"
  else
    cf zero-trust access rule-groups update "$GROUP_ID" --body "$GROUP_BODY" >/dev/null
    echo "  Updated Access group for IPs: ${GROUP_ID}"
  fi
  REQUIRE_RULES=$(jq -cn --arg id "$GROUP_ID" '[{group: {id: $id}}]')
fi

INCLUDE_RULES=$(expected_include)
POLICY_BODY=$(jq -cn --arg n "$ACCESS_POLICY_NAME" --argjson inc "$INCLUDE_RULES" --argjson req "$REQUIRE_RULES" \
  '{name: $n, decision: "allow", include: $inc, require: $req}')

APP_ID=$(cf zero-trust access applications list | jq -r --arg n "$ACCESS_APP_NAME" 'first(.[] | select(.name == $n) | .id) // empty')

# The policy is account-level and reusable, attached to the app by id. App-scoped
# ("legacy") policies from earlier versions of this script are converted in place.
POLICY_ID=$(cf zero-trust access policies list | jq -r --arg n "$ACCESS_POLICY_NAME" 'first(.[] | select(.name == $n) | .id) // empty')
if [ -z "$POLICY_ID" ] && [ -n "$APP_ID" ]; then
  LEGACY_ID=$(cf zero-trust access applications get "$APP_ID" | jq -r --arg n "$ACCESS_POLICY_NAME" \
    'first(.policies[]? | select(.name == $n and (.reusable | not)) | .id) // empty')
  if [ -n "$LEGACY_ID" ]; then
    cf zero-trust access applications policies make-reusable "$LEGACY_ID" --app-id "$APP_ID" >/dev/null
    POLICY_ID="$LEGACY_ID"
    echo "  Converted legacy app policy to a reusable policy: ${POLICY_ID}"
  fi
fi
if [ -z "$POLICY_ID" ]; then
  POLICY_ID=$(cf zero-trust access policies create --body "$POLICY_BODY" | jq -r '.id')
  echo "  Created reusable Access policy: ${POLICY_ID}"
else
  cf zero-trust access policies update "$POLICY_ID" --body "$POLICY_BODY" >/dev/null
  echo "  Updated reusable Access policy: ${POLICY_ID}"
fi

# When dashboard.host changed, retire the previous host before Access moves off it:
# a leftover route (wrangler keeps old routes when it cannot replace them all) must
# never serve the dashboard without Access. Our own record is removed so the old
# host stops resolving; a record we did not create keeps Access on the old host.
KEEP_HOSTS="[]"
PREV_HOST=$([ -n "$APP_ID" ] && cf zero-trust access applications get "$APP_ID" | jq -r '.domain // empty' || true)
if [ -n "$PREV_HOST" ] && [ "$PREV_HOST" != "$DASHBOARD_HOST" ] && [[ "$PREV_HOST" != *.workers.dev ]]; then
  PREV_REC=$(cf dns records list --zone "$ZONE" --name "$PREV_HOST" | jq -c 'first(.[]) // empty')
  if [ -z "$PREV_REC" ]; then
    :
  elif echo "$PREV_REC" | jq -e --arg c "$MANAGED_TAG" '.comment == $c' >/dev/null; then
    cf dns records delete "$(echo "$PREV_REC" | jq -r .id)" --zone "$ZONE" --force >/dev/null
    echo "  Removed DNS record for the previous dashboard host ${PREV_HOST}"
  else
    KEEP_HOSTS=$(jq -cn --arg h "$PREV_HOST" '[$h]')
    warn "${PREV_HOST} still resolves (record not created by this script), so Access keeps protecting it. Remove that record, then deploy again."
  fi
fi

APP_BODY=$(jq -cn --arg n "$ACCESS_APP_NAME" --arg h "$DASHBOARD_HOST" --arg p "$POLICY_ID" --argjson keep "$KEEP_HOSTS" --arg sd "$SESSION_DURATION" '{
  name: $n, type: "self_hosted", domain: $h, session_duration: $sd,
  destinations: ([$h] + $keep | map({type: "public", uri: .})),
  policies: [{id: $p, precedence: 1}]
}')
if [ -z "$APP_ID" ]; then
  APP_ID=$(cf zero-trust access applications create --body "$APP_BODY" | jq -r '.id')
  echo "  Created Access app for ${DASHBOARD_HOST}: ${APP_ID}"
else
  cf zero-trust access applications update "$APP_ID" --body "$APP_BODY" >/dev/null
  echo "  Updated Access app for ${DASHBOARD_HOST}: ${APP_ID}"
fi
echo "  Allowed: $(jq -rn --argjson e "$ACCESS_EMAILS" --argjson d "$ACCESS_EMAIL_DOMAINS" --argjson i "$ACCESS_IPS" \
  '[($e|select(length>0)|"emails=\(join(","))"), ($d|select(length>0)|"domains=\(join(","))"), ($i|select(length>0)|"ips=\(join(","))")] | join(" ")')"

# The worker runs on a route, which needs a proxied DNS record for the host.
# 192.0.2.0 (RFC 5737) is Cloudflare's documented placeholder for originless setups.
HOST_BODY=$(jq -cn --arg n "$DASHBOARD_HOST" --arg c "$MANAGED_TAG" \
  '{type: "A", name: $n, content: "192.0.2.0", proxied: true, ttl: 1, comment: $c}')
HOST_REC=$(cf dns records list --zone "$ZONE" --name "$DASHBOARD_HOST" | jq -c 'first(.[]) // empty')
if [ -z "$HOST_REC" ]; then
  cf dns records create --zone "$ZONE" --body "$HOST_BODY" >/dev/null
  echo "  Created proxied DNS record for ${DASHBOARD_HOST}"
elif ! echo "$HOST_REC" | jq -e --arg c "$MANAGED_TAG" '.comment == $c' >/dev/null; then
  die "${DASHBOARD_HOST} already has a DNS record not created by this script.
Pick a different dashboard hostname with: bash deploy.sh${PROFILE_ARG} --setup"
elif ! echo "$HOST_REC" | jq -e '.type == "A" and .content == "192.0.2.0" and .proxied' >/dev/null; then
  cf dns records update "$(echo "$HOST_REC" | jq -r .id)" --zone "$ZONE" --body "$HOST_BODY" >/dev/null
  echo "  Updated DNS record for ${DASHBOARD_HOST}"
fi

# --- Step 2: D1 Database ---
echo ""
echo "[2/7] Ensuring D1 database exists..."
DB_ID=$(cf d1 list | jq -r --arg n "$DB_NAME" 'first(.[] | select(.name == $n) | .uuid) // empty')
if [ -n "$DB_ID" ]; then
  echo "  Database '${DB_NAME}' exists: ${DB_ID}"
else
  DB_ID=$(cf d1 create --name "$DB_NAME" | jq -r '.uuid // empty')
  [ -n "$DB_ID" ] || die "Could not create D1 database '${DB_NAME}'."
  echo "  Created: ${DB_ID}"
fi
# Read by cloudflare.config.ts. Looked up fresh every run, so switching accounts
# or profiles can never deploy against a stale database id.
export DMARC_D1_ID="$DB_ID"
# Domains whose reports the worker keeps: none listed = any domain; otherwise the
# zone (and its subdomains) plus dmarc.authorizedDomains.
export DMARC_REPORT_DOMAINS
DMARC_REPORT_DOMAINS=$(echo "$AUTH_DOMAINS" | jq -c --arg z "$ZONE" 'if length == 0 then [] else [$z] + . end')

# --- Step 3: Run migrations ---
echo ""
echo "[3/7] Applying D1 migrations..."
cf d1 migrations apply "$DB_ID" --dir migrations

# --- Step 4: Build dashboard ---
echo ""
echo "[4/7] Building dashboard..."
pnpm install --frozen-lockfile
pnpm --filter dashboard run build
echo "  Built to dashboard/dist/"

# IP geolocation databases (DB-IP Lite, CC BY 4.0), served to the worker as static
# assets (see src/geo.ts). Published monthly; cached per month in .cache/dbip/.
fetch_geo_db() {  # fetch_geo_db <country|asn>
  local KIND="$1" MONTH FILE
  for MONTH in "$(date +%Y-%m)" "$(date -v-1m +%Y-%m 2>/dev/null || date -d '1 month ago' +%Y-%m)"; do
    FILE=".cache/dbip/dbip-${KIND}-lite-${MONTH}.mmdb"
    if [ ! -s "$FILE" ]; then
      mkdir -p .cache/dbip
      curl -fsSL "https://download.db-ip.com/free/dbip-${KIND}-lite-${MONTH}.mmdb.gz" 2>/dev/null | gunzip > "$FILE.tmp" 2>/dev/null \
        && [ -s "$FILE.tmp" ] && mv "$FILE.tmp" "$FILE" || rm -f "$FILE.tmp"
    fi
    if [ -s "$FILE" ]; then
      mkdir -p dashboard/dist/_geo
      cp "$FILE" "dashboard/dist/_geo/dbip-${KIND}-lite.mmdb"
      echo "  IP data: DB-IP ${KIND} ${MONTH}"
      return 0
    fi
  done
  warn "Could not download the DB-IP ${KIND} database; sender IPs will show no ${KIND} data."
}
fetch_geo_db country
fetch_geo_db asn

# --- Step 5: Deploy worker ---
echo ""
echo "[5/7] Deploying worker..."
cf deploy --mode "$PROFILE" --message "deploy.sh (${PROFILE})"

# --- Step 6: Email Routing rule ---
echo ""
echo "[6/7] Configuring email routing rule..."
RULE_BODY=$(jq -cn --arg name "$RULE_NAME" --arg to "$DMARC_ADDRESS" --arg w "$WORKER_NAME" '{
  name: $name, enabled: true,
  matchers: [{type: "literal", field: "to", value: $to}],
  actions: [{type: "worker", value: [$w]}]
}')
# One rule per zone points at the worker. Reuse it (even if its address changed)
# instead of leaving the old one behind.
RULES=$(cf email-routing rules list-account --zone "$ZONE")
RULE_ID=$(echo "$RULES" | jq -r --arg w "$WORKER_NAME" --arg to "$DMARC_ADDRESS" '
  [.[] | select(any(.actions[]?; .type == "worker" and ((.value // []) | index($w))))]
  | (map(select(any(.matchers[]?; .value == $to))) + .) | first | .id // empty')
if [ -z "$RULE_ID" ]; then
  cf email-routing rules create --zone "$ZONE" --body "$RULE_BODY" >/dev/null
  echo "  Created rule: ${DMARC_ADDRESS} → ${WORKER_NAME}"
else
  cf email-routing rules update "$RULE_ID" --zone "$ZONE" --body "$RULE_BODY" >/dev/null
  echo "  Rule up to date: ${DMARC_ADDRESS} → ${WORKER_NAME}"
fi

# --- Step 7: _report._dmarc DNS records ---
# When otherdomain.com sets rua=mailto:dmarc@<receiving domain>, report generators
# verify the receiving domain accepts its reports by looking up
#   otherdomain.com._report._dmarc.<receiving domain>  TXT "v=DMARC1;"
# With no dmarc.authorizedDomains, a wildcard accepts reports for any domain.
echo ""
echo "[7/7] Configuring _report._dmarc DNS records..."
WANTED=$(echo "$AUTH_DOMAINS" | jq -r --arg d "$RECEIVE_DOMAIN" '
  if length == 0 then ["*"] else . end | .[] | "\(.)._report._dmarc.\($d)"')
EXISTING=$(cf dns records list --zone "$ZONE" --type TXT --name-endswith "._report._dmarc.${RECEIVE_DOMAIN}")

while IFS= read -r NAME; do
  BODY=$(jq -cn --arg n "$NAME" --arg c "$MANAGED_TAG" '{type: "TXT", name: $n, content: "\"v=DMARC1;\"", ttl: 3600, comment: $c}')
  REC=$(echo "$EXISTING" | jq -c --arg n "$NAME" 'first(.[] | select(.name == $n)) // empty')
  if [ -z "$REC" ]; then
    cf dns records create --zone "$ZONE" --body "$BODY" >/dev/null
    echo "  Created ${NAME}"
  elif echo "$REC" | jq -e --arg c "$MANAGED_TAG" '.content == "\"v=DMARC1;\"" and .comment == $c' >/dev/null; then
    echo "  Up to date: ${NAME}"
  else
    cf dns records update "$(echo "$REC" | jq -r .id)" --zone "$ZONE" --body "$BODY" >/dev/null
    echo "  Updated ${NAME}"
  fi
done <<< "$WANTED"

# Records this script created earlier that are no longer wanted (e.g. the
# wildcard after authorizedDomains was set). Only tagged records are removed.
STALE=$(echo "$EXISTING" | jq -r --arg c "$MANAGED_TAG" --argjson wanted "$(echo "$WANTED" | jq -Rn '[inputs]')" '
  .[] | select(.comment == $c and (.name as $n | $wanted | index($n) | not)) | [.id, .name] | @tsv')
if [ -n "$STALE" ]; then
  while IFS=$'\t' read -r ID NAME; do
    cf dns records delete "$ID" --zone "$ZONE" --force >/dev/null
    echo "  Removed ${NAME} (no longer in authorizedDomains)"
  done <<< "$STALE"
fi

echo ""
echo "${C_GREEN}${C_BOLD}=== Deploy complete! ===${C_RESET}"
echo ""
echo "Your DMARC dashboard is at: ${C_CYAN}https://${DASHBOARD_HOST}${C_RESET}"
echo ""
echo "${C_BOLD}To monitor a domain, add a DMARC policy TXT record on that domain:${C_RESET}"
echo "  ${C_DIM}_dmarc.example.com  TXT  \"v=DMARC1; p=none; rua=mailto:${DMARC_ADDRESS}\"${C_RESET}"
echo ""
if [ "$AUTH_DOMAINS" = "[]" ]; then
  echo "${C_YELLOW}${C_BOLD}WARNING:${C_RESET}${C_YELLOW} p=none only monitors — it does NOT block spoofed emails.${C_RESET}"
  echo "${C_YELLOW}  Move to p=quarantine then p=reject once legitimate senders pass DKIM/SPF.${C_RESET}"
  echo "${C_DIM}  List your domains in --setup (authorized domains) to have their DMARC records checked here.${C_RESET}"
else
  header "Monitored domains"
  dmarc_status "$DMARC_ADDRESS"
fi
echo ""
offer "${C_BOLD}Run --verify now?${C_RESET}" && next_run --profile "$PROFILE" --verify
