#!/usr/bin/env bash
# Idempotent deploy of the amtracker push server to Cloud Run.
#
#   ./deploy.sh --apns-key /path/AuthKey_XXXX.p8 --key-id ABC123DEFG --team-id TEAM123456
#   ./deploy.sh                 # redeploy only (secrets already exist)
#   ./deploy.sh --status        # service URL, scheduler state, trip count
#
# Env: PROJECT (default angular-axe-515221), REGION (default us-west1)
# Flags:
#   --apns-key FILE     .p8 file for APNS_KEY_P8
#   --key-id ID         APNS_KEY_ID
#   --team-id ID        APNS_TEAM_ID
#   --update-secrets    add a new version even if the secret already has one
#   --status            show status and exit
set -euo pipefail

PROJECT="${PROJECT:-angular-axe-515221}"
REGION="${REGION:-us-west1}"
SERVICE="amtracker-push"
JOB="amtracker-tick"
SA_NAME="amtracker-push-run"
SA="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
BUNDLE_ID="${APP_BUNDLE_ID:-com.somefamilies.amtracker}"
SECRETS=(APNS_KEY_P8 APNS_KEY_ID APNS_TEAM_ID APP_SHARED_SECRET TICK_SECRET)

KEY_FILE="" KEY_ID="" TEAM_ID="" UPDATE=0 STATUS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apns-key) KEY_FILE="${2:?}"; shift 2 ;;
    --key-id) KEY_ID="${2:?}"; shift 2 ;;
    --team-id) TEAM_ID="${2:?}"; shift 2 ;;
    --update-secrets) UPDATE=1; shift ;;
    --status) STATUS=1; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")"
G=(gcloud --project "$PROJECT" --quiet)

service_url() { "${G[@]}" run services describe "$SERVICE" --region "$REGION" --format='value(status.url)' 2>/dev/null || true; }
secret_exists() { "${G[@]}" secrets describe "$1" >/dev/null 2>&1; }
secret_has_version() { [[ -n "$("${G[@]}" secrets versions list "$1" --filter='state=ENABLED' --limit=1 --format='value(name)' 2>/dev/null)" ]]; }
secret_value() { "${G[@]}" secrets versions access latest --secret "$1"; }

if [[ $STATUS -eq 1 ]]; then
  URL="$(service_url)"
  echo "project:   $PROJECT"
  echo "region:    $REGION"
  echo "service:   ${URL:-<not deployed>}"
  echo "scheduler: $("${G[@]}" scheduler jobs describe "$JOB" --location "$REGION" --format='value(state,schedule)' 2>/dev/null || echo '<none>')"
  TOKEN="$(gcloud auth print-access-token)"
  COUNT="$(curl -s -X POST \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    "https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents:runAggregationQuery" \
    -d '{"structuredAggregationQuery":{"structuredQuery":{"from":[{"collectionId":"trips"}]},"aggregations":[{"alias":"n","count":{}}]}}' \
    | sed -n 's/.*"integerValue": *"\([0-9]*\)".*/\1/p' | head -n1)"
  echo "trips:     ${COUNT:-0}"
  exit 0
fi

echo "==> Enabling APIs"
"${G[@]}" services enable run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com \
  firestore.googleapis.com cloudscheduler.googleapis.com secretmanager.googleapis.com

echo "==> Firestore database"
if ! "${G[@]}" firestore databases describe --database='(default)' >/dev/null 2>&1; then
  "${G[@]}" firestore databases create --database='(default)' --location="$REGION" --type=firestore-native
else
  echo "exists"
fi

echo "==> Secrets"
ensure_secret() { # name, kind(file|value|random), arg
  local name="$1" kind="$2" arg="${3:-}"
  secret_exists "$name" || "${G[@]}" secrets create "$name" --replication-policy=automatic
  local have=0; secret_has_version "$name" && have=1
  if [[ $have -eq 1 && $UPDATE -eq 0 ]]; then echo "$name: has a version, leaving as is"; return; fi
  case "$kind" in
    file) [[ -n "$arg" ]] || { [[ $have -eq 1 ]] && return; echo "ERROR: $name has no value; pass the matching flag" >&2; exit 1; }
          "${G[@]}" secrets versions add "$name" --data-file="$arg" ;;
    value) [[ -n "$arg" ]] || { [[ $have -eq 1 ]] && return; echo "ERROR: $name has no value; pass the matching flag" >&2; exit 1; }
           printf '%s' "$arg" | "${G[@]}" secrets versions add "$name" --data-file=- ;;
    random) [[ $have -eq 1 ]] && return  # never rotate random secrets implicitly
            openssl rand -hex 32 | tr -d '\n' | "${G[@]}" secrets versions add "$name" --data-file=- ;;
  esac
}
[[ -z "$KEY_FILE" || -f "$KEY_FILE" ]] || { echo "ERROR: $KEY_FILE not found" >&2; exit 1; }
ensure_secret APNS_KEY_P8 file "$KEY_FILE"
ensure_secret APNS_KEY_ID value "$KEY_ID"
ensure_secret APNS_TEAM_ID value "$TEAM_ID"
ensure_secret APP_SHARED_SECRET random
ensure_secret TICK_SECRET random

echo "==> Runtime service account"
"${G[@]}" iam service-accounts describe "$SA" >/dev/null 2>&1 \
  || "${G[@]}" iam service-accounts create "$SA_NAME" --display-name "amtracker push server"
"${G[@]}" projects add-iam-policy-binding "$PROJECT" --member "serviceAccount:$SA" \
  --role roles/datastore.user --condition=None >/dev/null
for s in "${SECRETS[@]}"; do
  "${G[@]}" secrets add-iam-policy-binding "$s" --member "serviceAccount:$SA" \
    --role roles/secretmanager.secretAccessor >/dev/null
done

echo "==> Deploying Cloud Run service"
SET_SECRETS="APNS_KEY_P8=APNS_KEY_P8:latest,APNS_KEY_ID=APNS_KEY_ID:latest,APNS_TEAM_ID=APNS_TEAM_ID:latest,APP_SHARED_SECRET=APP_SHARED_SECRET:latest,TICK_SECRET=TICK_SECRET:latest"
"${G[@]}" run deploy "$SERVICE" --source . --region "$REGION" \
  --service-account "$SA" --allow-unauthenticated \
  --max-instances 2 --min-instances 0 \
  --set-env-vars "APP_BUNDLE_ID=${BUNDLE_ID},GOOGLE_CLOUD_PROJECT=${PROJECT}" \
  --set-secrets "$SET_SECRETS"
URL="$(service_url)"

echo "==> Cloud Scheduler job"
TICK="$(secret_value TICK_SECRET)"
SCHED_ARGS=(--location "$REGION" --schedule "* * * * *" --time-zone "Etc/UTC" --http-method POST
  --uri "${URL}/tick" --update-headers "X-Tick-Secret=${TICK}" --attempt-deadline 60s)
if "${G[@]}" scheduler jobs describe "$JOB" --location "$REGION" >/dev/null 2>&1; then
  "${G[@]}" scheduler jobs update http "$JOB" "${SCHED_ARGS[@]}"
  "${G[@]}" scheduler jobs resume "$JOB" --location "$REGION" >/dev/null 2>&1 || true
else
  "${G[@]}" scheduler jobs create http "$JOB" "${SCHED_ARGS[@]/--update-headers/--headers}"
fi

echo
echo "Service URL:       $URL"
echo "APP_SHARED_SECRET: $(secret_value APP_SHARED_SECRET)"
echo "(put both into the iOS app config)"
