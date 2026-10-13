#!/usr/bin/env bash
# Deploys ONLY this directory's agent (ADKAgentDataport) to Cloud Run and
# registers it in Agent Registry.
#
# A single-component, self-contained equivalent of
# ../Deployment_artifacts/deploy.sh's own deploy_adkagentdataport()
# function (plus its Agent Registry registration step), extracted into
# this directory so this one agent can be deployed -- under ANY Cloud Run
# service name -- without running or modifying that shared 5-component
# script at all.
#
# Mirrors ../Deployment_artifacts/deploy.sh's own conventions exactly
# (env-file-then-prompt config resolution, Secret Manager for
# credentials, a two-phase deploy to bake the service's own URL into its
# Agent Card) -- the helper functions below are a deliberate COPY, not a
# shared import, consistent with every other self-contained deploy
# script in this project (e.g. ../ADKAgentDataportMarketplace/deploy.sh,
# ../ADKAgentDataportTerraform/deploy.sh). This script makes NO changes
# to any file in this directory -- it only reads `.env` and deploys the
# directory as-is via `gcloud run deploy --source .`.
#
# Unlike ../Deployment_artifacts/deploy.sh's own hardcoded
# "cyera-dataport-agent" service name, --service-name here can be
# anything you want -- deploy multiple independent copies of this same
# agent (e.g. per-environment, per-team, or side-by-side with the one
# ../Deployment_artifacts/deploy.sh already created) without colliding.
# --service-id and --display-name (both Agent Registry fields) default
# to --service-name for the same reason.
#
# Targets bash 3.2 (macOS's stock /bin/bash) deliberately: no associative
# arrays, no `${var,,}` lowercasing -- both are bash-4-only. Same
# constraint as ../Deployment_artifacts/deploy.sh.
#
# Usage:
#   ./deploy.sh --project my-project
#   ./deploy.sh --project my-project --service-name cyera-dataport-agent-qa
#   ./deploy.sh --project my-project --dry-run
#   ./deploy.sh --help
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=0
SKIP_REGISTRATION=0
AUTO_GRANT_REGISTRATION_IMPERSONATION=0
PROJECT=""
REGION="us-central1"
SERVICE_NAME="cyera-dataport-agent"
SERVICE_ID=""
DISPLAY_NAME=""
IDENTITY_PLATFORM_PROJECT_ID=""
GEMINI_ENTERPRISE_PROJECT_NUMBER=""
EXTRA_INVOKER_MEMBERS=()

print_help() {
  cat <<'EOF'
Usage: ./deploy.sh [options]

  --project ID                        GCP project ID. If omitted, read from
                                       this directory's own .env
                                       (GOOGLE_CLOUD_PROJECT), else prompted.
  --region REGION                     Cloud Run region. Default: us-central1.
  --service-name NAME                 Cloud Run service name -- the "assign
                                       any name" knob. Default:
                                       cyera-dataport-agent.
  --service-id ID                     Agent Registry service ID. Default:
                                       same value as --service-name.
  --display-name NAME                 Agent Registry display name. Default:
                                       same value as --service-name.
  --identity-platform-project-id ID   Overrides IDENTITY_PLATFORM_PROJECT_ID.
                                       Default: same as --project.
  --gemini-enterprise-project-number N
                                       Grants roles/run.invoker to Gemini
                                       Enterprise's Discovery Engine service
                                       agent. Optional.
  --extra-invoker-member MEMBER       Extra "serviceAccount:..."/"user:..."
                                       principal to grant roles/run.invoker.
                                       Repeatable.
  --skip-registration                 Deploy only -- skip
                                       register_agent_registry.py.
  --auto-grant-registration-impersonation
                                       Off by default. register_agent_registry.py
                                       needs a Cloud-Run-IAM-scoped identity token
                                       to fetch this agent's own Agent Card (this
                                       service is --no-allow-unauthenticated) -- a
                                       human user account can only get one by
                                       impersonating the project's compute default
                                       service account, which requires
                                       roles/iam.serviceAccountTokenCreator on it
                                       (not included by most roles, even
                                       roles/owner). If passed AND that permission
                                       is missing for the current gcloud user, it
                                       is granted automatically before
                                       registration runs. See README.md's "If
                                       Agent Registry registration fails" section.
  --dry-run                           Print every gcloud/python command this
                                       script would run, execute none of them.
  --help                              Show this message.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --service-name) SERVICE_NAME="$2"; shift 2 ;;
    --service-id) SERVICE_ID="$2"; shift 2 ;;
    --display-name) DISPLAY_NAME="$2"; shift 2 ;;
    --identity-platform-project-id) IDENTITY_PLATFORM_PROJECT_ID="$2"; shift 2 ;;
    --gemini-enterprise-project-number) GEMINI_ENTERPRISE_PROJECT_NUMBER="$2"; shift 2 ;;
    --extra-invoker-member) EXTRA_INVOKER_MEMBERS+=("$2"); shift 2 ;;
    --skip-registration) SKIP_REGISTRATION=1; shift ;;
    --auto-grant-registration-impersonation) AUTO_GRANT_REGISTRATION_IMPERSONATION=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help) print_help; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; print_help; exit 1 ;;
  esac
done

[[ -z "$SERVICE_ID" ]] && SERVICE_ID="$SERVICE_NAME"
[[ -z "$DISPLAY_NAME" ]] && DISPLAY_NAME="$SERVICE_NAME"

if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN="python"
else
  echo "FATAL: neither python3 nor python found on PATH." >&2
  exit 1
fi

# ---------------------------------------------------------------------
# .env parsing / interactive config resolution
# (copied from ../Deployment_artifacts/deploy.sh -- see this script's
# own header comment for why this is a copy, not a shared import)
# ---------------------------------------------------------------------

read_dotenv_value() {
  local file="$1" key="$2" line value
  [[ -f "$file" ]] || return 0
  line="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" | tail -n 1)"
  [[ -z "$line" ]] && return 0
  value="${line#*=}"
  value="$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  if [[ ( "$value" == \"*\" && "$value" == *\" ) ]] || [[ ( "$value" == \'*\' && "$value" == *\' ) ]]; then
    value="${value:1:${#value}-2}"
  fi
  [[ -n "$value" ]] && printf '%s' "$value"
}

# resolve_config_value FILE KEY DEFAULT HINT_FILE SECRET(0/1) SILENT(0/1)
# Prints the resolved value to stdout (the ONLY stdout output -- every
# diagnostic/prompt line goes to stderr, since callers capture this via
# $(...)).
resolve_config_value() {
  local file="$1" key="$2" default="$3" hint_file="$4" secret_flag="$5" silent_flag="$6"
  local value=""
  if [[ -n "$file" ]]; then
    value="$(read_dotenv_value "$file" "$key")"
  fi
  if [[ -n "$value" ]]; then
    printf '%s' "$value"
    return 0
  fi
  if [[ "$silent_flag" == "1" ]]; then
    printf '%s' "$default"
    return 0
  fi
  if [[ -n "$hint_file" ]]; then
    echo "  (Could not find $key in $hint_file)" >&2
  else
    echo "  ($key could not be determined automatically)" >&2
  fi
  local entered attempt max_attempts=5
  if [[ "$secret_flag" == "1" ]]; then
    attempt=0
    printf "  Enter %s: " "$key" >&2
    read -r -s entered
    echo >&2
    while [[ -z "$entered" ]]; do
      attempt=$((attempt + 1))
      if [[ $attempt -ge $max_attempts ]]; then
        echo "  No value received for $key after $max_attempts attempts (no interactive input available?). Aborting." >&2
        exit 1
      fi
      echo "  $key is required." >&2
      printf "  Enter %s: " "$key" >&2
      read -r -s entered
      echo >&2
    done
    printf '%s' "$entered"
    return 0
  fi
  if [[ -n "$default" ]]; then
    printf "  Enter %s [%s]: " "$key" "$default" >&2
    read -r entered
    if [[ -z "$entered" ]]; then
      printf '%s' "$default"
    else
      printf '%s' "$entered"
    fi
    return 0
  fi
  attempt=0
  printf "  Enter %s: " "$key" >&2
  read -r entered
  while [[ -z "$entered" ]]; do
    attempt=$((attempt + 1))
    if [[ $attempt -ge $max_attempts ]]; then
      echo "  No value received for $key after $max_attempts attempts (no interactive input available?). Aborting." >&2
      exit 1
    fi
    echo "  $key is required." >&2
    printf "  Enter %s: " "$key" >&2
    read -r entered
  done
  printf '%s' "$entered"
}

# ---------------------------------------------------------------------
# Secret Manager helpers (idempotent -- see header comment)
# ---------------------------------------------------------------------

secret_exists() {
  local name="$1" project="$2"
  gcloud secrets describe "$name" --project="$project" >/dev/null 2>&1
}

set_deployment_secret() {
  local name="$1" project="$2" value="$3"
  if secret_exists "$name" "$project"; then
    echo "  Secret '$name' already exists -- reusing its current value." >&2
    return 0
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "  [DRY RUN] gcloud secrets create $name --project=$project --data-file=<value>" >&2
    return 0
  fi
  local tmp
  tmp="$(mktemp)"
  printf '%s' "$value" > "$tmp"
  gcloud secrets create "$name" --project="$project" --replication-policy=automatic --data-file="$tmp" >/dev/null
  rm -f "$tmp"
}

grant_secret_access() {
  local name="$1" project="$2" sa="$3"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "  [DRY RUN] gcloud secrets add-iam-policy-binding $name --project=$project --member=serviceAccount:$sa --role=roles/secretmanager.secretAccessor" >&2
    return 0
  fi
  gcloud secrets add-iam-policy-binding "$name" --project="$project" --member="serviceAccount:${sa}" --role="roles/secretmanager.secretAccessor" >/dev/null
}

get_compute_service_account() {
  local project="$1" project_number
  project_number="$(gcloud projects describe "$project" --format='value(projectNumber)')"
  printf '%s' "${project_number}-compute@developer.gserviceaccount.com"
}

# resolve_model_credentials SERVICE PROJECT REGION ENV_FILE
# Sets two globals: MODEL_ENV_VARS and MODEL_SECRETS (the latter may be
# empty). See VERTEX_MODEL_LOCATION's own comment for why it's a
# deliberately different key from GOOGLE_CLOUD_LOCATION.
MODEL_ENV_VARS=""
MODEL_SECRETS=""
resolve_model_credentials() {
  local service="$1" project="$2" region="$3" env_file="$4"
  local api_key
  api_key="$(resolve_config_value "$env_file" "GOOGLE_API_KEY" "" "" "0" "1")"
  if [[ -n "$api_key" ]]; then
    local secret_name="${service}-google-api-key"
    set_deployment_secret "$secret_name" "$project" "$api_key"
    grant_secret_access "$secret_name" "$project" "$(get_compute_service_account "$project")"
    MODEL_ENV_VARS="GOOGLE_CLOUD_PROJECT=${project}"
    MODEL_SECRETS="GOOGLE_API_KEY=${secret_name}:latest"
  else
    # VERTEX_MODEL_LOCATION -- a deliberately DIFFERENT config key from
    # GOOGLE_CLOUD_LOCATION: this agent's own default model
    # (gemini-3.8-flash) is only served via Vertex AI's "global" endpoint,
    # NOT regional endpoints like us-central1 -- yet Cloud Run itself
    # still needs to deploy to a real region, a completely different
    # Google Cloud concept from where the MODEL is served. See this
    # directory's own README.md, "Configuring the LLM" section.
    local model_location
    model_location="$(resolve_config_value "$env_file" "VERTEX_MODEL_LOCATION" "$region" "" "0" "1")"
    MODEL_ENV_VARS="GOOGLE_GENAI_USE_VERTEXAI=true,GOOGLE_CLOUD_PROJECT=${project},GOOGLE_CLOUD_LOCATION=${model_location}"
    MODEL_SECRETS=""
  fi
}

join_non_empty() {
  local result="" part
  for part in "$@"; do
    if [[ -n "$part" ]]; then
      if [[ -n "$result" ]]; then
        result="${result},${part}"
      else
        result="$part"
      fi
    fi
  done
  printf '%s' "$result"
}

# ---------------------------------------------------------------------
# Cloud Run deploy helpers
# ---------------------------------------------------------------------

get_service_url() {
  local service="$1" region="$2" project="$3"
  gcloud run services describe "$service" --region="$region" --project="$project" --format='value(status.url)'
}

DEPLOY_TIMEOUT_SECONDS="${DEPLOY_TIMEOUT_SECONDS:-600}"

# invoke_run_deploy SERVICE SOURCE_DIR REGION PROJECT REQUIRE_AUTH(0/1) [extra gcloud args...]
# Prints the deployed service's URL to stdout on success.
invoke_run_deploy() {
  local service="$1" source_dir="$2" region="$3" project="$4" require_auth="${5:-0}"
  shift 5
  local auth_flag="--allow-unauthenticated"
  [[ "$require_auth" == "1" ]] && auth_flag="--no-allow-unauthenticated"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "  [DRY RUN] gcloud run deploy $service --source $source_dir --region $region --project $project $auth_flag --timeout=$DEPLOY_TIMEOUT_SECONDS $*" >&2
    printf 'https://%s-dry-run-placeholder.a.run.app' "$service"
    return 0
  fi
  echo "  Running: gcloud run deploy $service --source $source_dir --region $region --project $project $auth_flag --timeout=$DEPLOY_TIMEOUT_SECONDS $*" >&2
  if ! gcloud run deploy "$service" --source "$source_dir" --region "$region" --project "$project" "$auth_flag" --timeout="$DEPLOY_TIMEOUT_SECONDS" "$@" >&2; then
    echo "gcloud run deploy failed for service '$service'" >&2
    return 1
  fi
  get_service_url "$service" "$region" "$project"
}

# invoke_two_phase_deploy SERVICE SOURCE_DIR REGION PROJECT ENV_VARS SECRETS REQUIRE_AUTH(0/1)
# Prints the final URL to stdout.
invoke_two_phase_deploy() {
  local service="$1" source_dir="$2" region="$3" project="$4" env_vars="$5" secrets="$6" require_auth="${7:-0}"
  local extra1=()
  [[ -n "$secrets" ]] && extra1+=(--set-secrets "$secrets")
  [[ -n "$env_vars" ]] && extra1+=(--set-env-vars "$env_vars")

  echo "  Phase 1/2: deploying $service (learning its URL)..." >&2
  local url
  url="$(invoke_run_deploy "$service" "$source_dir" "$region" "$project" "$require_auth" "${extra1[@]}")" || return 1

  local host_name env_vars2
  host_name="${url#http://}"; host_name="${host_name#https://}"; host_name="${host_name%/}"
  if [[ -n "$env_vars" ]]; then
    env_vars2="${env_vars},A2A_HOST=${host_name},A2A_PORT=443,A2A_PROTOCOL=https"
  else
    env_vars2="A2A_HOST=${host_name},A2A_PORT=443,A2A_PROTOCOL=https"
  fi

  local extra2=()
  [[ -n "$secrets" ]] && extra2+=(--set-secrets "$secrets")
  extra2+=(--set-env-vars "$env_vars2")

  echo "  Phase 2/2: redeploying $service with A2A_HOST set..." >&2
  invoke_run_deploy "$service" "$source_dir" "$region" "$project" "$require_auth" "${extra2[@]}"
}

# grant_agent_invoker_access SERVICE REGION PROJECT MEMBER [MEMBER...]
grant_agent_invoker_access() {
  local service="$1" region="$2" project="$3"
  shift 3
  local member
  for member in "$@"; do
    [[ -z "$member" ]] && continue
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "  [DRY RUN] gcloud run services add-iam-policy-binding $service --region=$region --project=$project --member=$member --role=roles/run.invoker" >&2
      continue
    fi
    gcloud run services add-iam-policy-binding "$service" --region="$region" --project="$project" --member="$member" --role="roles/run.invoker" >&2
  done
}

# ---------------------------------------------------------------------
# Agent Registry registration
# ---------------------------------------------------------------------

# test_user_has_token_creator SERVICE_ACCOUNT MEMBER -- returns 0 (true)
# if MEMBER already holds roles/iam.serviceAccountTokenCreator directly
# on SERVICE_ACCOUNT's own IAM policy (checked live), 1 otherwise.
test_user_has_token_creator() {
  local sa="$1" member="$2" policy
  policy="$(gcloud iam service-accounts get-iam-policy "$sa" --format=json 2>/dev/null)" || return 1
  [[ -z "$policy" ]] && return 1
  printf '%s' "$policy" | "$PYTHON_BIN" -c '
import json, sys
policy = json.load(sys.stdin)
member = sys.argv[1]
for b in policy.get("bindings", []):
    if b.get("role") == "roles/iam.serviceAccountTokenCreator" and member in b.get("members", []):
        sys.exit(0)
sys.exit(1)
' "$member"
}

# ensure_registration_impersonation_permission PROJECT COMPUTE_SERVICE_ACCOUNT
# Off unless --auto-grant-registration-impersonation was passed -- see
# that flag's own --help text for the full rationale. When on, grants
# the CURRENT gcloud user roles/iam.serviceAccountTokenCreator on
# COMPUTE_SERVICE_ACCOUNT, but only if needed: skipped entirely for an
# already-service-account identity (it has a direct path already), and
# skipped if the permission is already present (checked live).
ensure_registration_impersonation_permission() {
  local project="$1" sa="$2"

  [[ "$AUTO_GRANT_REGISTRATION_IMPERSONATION" != "1" ]] && return 0

  local current_account
  current_account="$(gcloud config get-value account 2>/dev/null)"
  [[ -z "$current_account" ]] && return 0
  if [[ "$current_account" == *.gserviceaccount.com ]]; then
    return 0
  fi

  local member="user:${current_account}"
  if test_user_has_token_creator "$sa" "$member"; then
    echo "  '${current_account}' can already impersonate '${sa}' -- nothing to grant." >&2
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "  [DRY RUN] gcloud iam service-accounts add-iam-policy-binding $sa --project=$project --member=$member --role=roles/iam.serviceAccountTokenCreator" >&2
    return 0
  fi

  echo "  --auto-grant-registration-impersonation was passed -- granting '${current_account}' permission to impersonate '${sa}' so register_agent_registry.py can fetch this agent's Agent Card..." >&2
  if ! gcloud iam service-accounts add-iam-policy-binding "$sa" --project="$project" --member="$member" --role="roles/iam.serviceAccountTokenCreator" >&2; then
    echo "  WARNING: the grant did not succeed -- '${current_account}' likely lacks permission to modify this service account's own IAM policy. Registration below may still fail; see README.md's 'If Agent Registry registration fails' section for the manual command." >&2
    return 0
  fi

  echo "  Granted. Waiting for IAM propagation..." >&2
  local attempt
  for attempt in $(seq 1 10); do
    sleep 6
    if gcloud auth print-identity-token --impersonate-service-account="$sa" --audiences=https://example.com >/dev/null 2>&1; then
      echo "  Confirmed -- impersonation now works." >&2
      return 0
    fi
  done
  echo "  WARNING: granted, but still not propagated after 60s. Re-run this script if registration fails once more." >&2
}

# invoke_registration_script DIR SCRIPT_NAME [extra python args...]
invoke_registration_script() {
  local dir="$1" script_name="$2"
  shift 2
  if [[ ! -f "$dir/$script_name" ]]; then
    echo "  $script_name not found in $dir -- nothing to register." >&2
    return 0
  fi
  if [[ "$SKIP_REGISTRATION" == "1" ]]; then
    echo "  Skipping $script_name (--skip-registration)." >&2
    return 0
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "  [DRY RUN] $PYTHON_BIN $script_name $* --dry-run   (then, if it looks right: $PYTHON_BIN $script_name $*)" >&2
    return 0
  fi
  ( cd "$dir" && "$PYTHON_BIN" "$script_name" "$@" --dry-run && "$PYTHON_BIN" "$script_name" "$@" )
}

# ---------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------

if ! command -v gcloud >/dev/null 2>&1; then
  echo "gcloud CLI not found on PATH. Install the Google Cloud SDK first." >&2
  exit 1
fi

if ! gcloud auth print-access-token >/dev/null 2>&1; then
  echo "Not authenticated with gcloud. Run 'gcloud auth login' first." >&2
  exit 1
fi

ENV_FILE="${SCRIPT_DIR}/.env"

if [[ -z "$PROJECT" ]]; then
  PROJECT="$(resolve_config_value "$ENV_FILE" "GOOGLE_CLOUD_PROJECT" "" "$ENV_FILE" "0" "0")"
fi
if [[ -z "$IDENTITY_PLATFORM_PROJECT_ID" ]]; then
  IDENTITY_PLATFORM_PROJECT_ID="$(resolve_config_value "$ENV_FILE" "IDENTITY_PLATFORM_PROJECT_ID" "$PROJECT" "" "0" "1")"
fi
if [[ -z "$GEMINI_ENTERPRISE_PROJECT_NUMBER" ]]; then
  GEMINI_ENTERPRISE_PROJECT_NUMBER="$(resolve_config_value "$ENV_FILE" "GEMINI_ENTERPRISE_PROJECT_NUMBER" "" "" "0" "1")"
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "*** DRY RUN -- no gcloud/python command below actually changes anything. ***" >&2
  echo >&2
fi
echo "Project: $PROJECT   Region: $REGION   Service name: $SERVICE_NAME" >&2
echo >&2

SA="$(get_compute_service_account "$PROJECT")"

MCP_TOKEN="$(resolve_config_value "$ENV_FILE" "CYERA_DATAPORT_MCP_TOKEN" "" "$ENV_FILE" "1" "0")"
MCP_SECRET_NAME="${SERVICE_NAME}-mcp-token"
set_deployment_secret "$MCP_SECRET_NAME" "$PROJECT" "$MCP_TOKEN"
grant_secret_access "$MCP_SECRET_NAME" "$PROJECT" "$SA"
DATAPORT_SECRETS_ARG="CYERA_DATAPORT_MCP_TOKEN=${MCP_SECRET_NAME}:latest"

resolve_model_credentials "$SERVICE_NAME" "$PROJECT" "$REGION" "$ENV_FILE"
ENV_VARS="$(join_non_empty "$MODEL_ENV_VARS" "IDENTITY_PLATFORM_PROJECT_ID=${IDENTITY_PLATFORM_PROJECT_ID}")"

DATAPORT_URL="$(resolve_config_value "$ENV_FILE" "CYERA_DATAPORT_MCP_URL" "" "" "0" "1")"
[[ -n "$DATAPORT_URL" ]] && ENV_VARS="${ENV_VARS},CYERA_DATAPORT_MCP_URL=${DATAPORT_URL}"

ADK_MODEL_VALUE="$(resolve_config_value "$ENV_FILE" "ADK_MODEL" "" "" "0" "1")"
[[ -n "$ADK_MODEL_VALUE" ]] && ENV_VARS="${ENV_VARS},ADK_MODEL=${ADK_MODEL_VALUE}"

THINKING_BUDGET_VALUE="$(resolve_config_value "$ENV_FILE" "THINKING_BUDGET" "" "" "0" "1")"
[[ -n "$THINKING_BUDGET_VALUE" ]] && ENV_VARS="${ENV_VARS},THINKING_BUDGET=${THINKING_BUDGET_VALUE}"

# Always paired with require_auth=1 below -- tells auth_middleware.py it
# can trust Cloud Run's own platform-level caller verification.
ENV_VARS="${ENV_VARS},CLOUD_RUN_IAM_GATED=true"
SECRETS_COMBINED="$(join_non_empty "$DATAPORT_SECRETS_ARG" "$MODEL_SECRETS")"

URL="$(invoke_two_phase_deploy "$SERVICE_NAME" "$SCRIPT_DIR" "$REGION" "$PROJECT" "$ENV_VARS" "$SECRETS_COMBINED" "1")"
echo "${SERVICE_NAME} deployed: ${URL}" >&2

INVOKER_MEMBERS=("serviceAccount:${SA}")
if [[ -n "$GEMINI_ENTERPRISE_PROJECT_NUMBER" ]]; then
  INVOKER_MEMBERS+=("serviceAccount:service-${GEMINI_ENTERPRISE_PROJECT_NUMBER}@gcp-sa-discoveryengine.iam.gserviceaccount.com")
fi
if [[ "${#EXTRA_INVOKER_MEMBERS[@]}" -gt 0 ]]; then
  INVOKER_MEMBERS+=("${EXTRA_INVOKER_MEMBERS[@]}")
fi
grant_agent_invoker_access "$SERVICE_NAME" "$REGION" "$PROJECT" "${INVOKER_MEMBERS[@]}"

if [[ "$SKIP_REGISTRATION" != "1" ]]; then
  ensure_registration_impersonation_permission "$PROJECT" "$SA"
fi

invoke_registration_script "$SCRIPT_DIR" "register_agent_registry.py" \
  --project "$PROJECT" \
  --card-url "${URL}/.well-known/agent-card.json" \
  --service-id "$SERVICE_ID" \
  --display-name "$DISPLAY_NAME"

echo >&2
echo "Done." >&2
echo "Agent Card: ${URL}/.well-known/agent-card.json" >&2
echo "Agent Registry service ID: ${SERVICE_ID}" >&2
