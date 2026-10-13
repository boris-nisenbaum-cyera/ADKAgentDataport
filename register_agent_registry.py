"""Register or update the Cyera Dataport Agent (`cyera-dataport-agent`,
this directory) as a `Service` in Google's Agent Registry
(agentregistry.googleapis.com).

Self-contained script, not importing from `../ADKAgent`, `../ADKAgentSecure`,
or `../ADKAgentAWS` (each of which has its own near-identical script) --
consistent with this directory's "completely separate, no dependency on
other directories" convention.

--------------------------------------------------------------------------
HOW THIS WORKS -- THE agentregistry.googleapis.com DATA MODEL
--------------------------------------------------------------------------
Confirmed via this exact API's own discovery document during
`../ADKAgent/register_agent_registry.py`'s development, not re-derived
here: there is no direct "create an Agent" method. You create a `Service`
resource; when its `agentSpec` is set (as opposed to `mcpServerSpec` or
`endpointSpec`), the registry derives a corresponding read-only `Agent`
entry from it. `AgentSpec.type = A2A_AGENT_CARD` means `AgentSpec.content`
is a full A2A Agent Card JSON object.

Agent Registry wants the RAW, unmodified Agent Card `to_a2a()` produces
(the v1.0 `supportedInterfaces[]` shape) -- no schema translation needed,
confirmed by `../ADKAgent/register_agent_registry.py`'s own trial against
the live API; this agent's card is built the same way (same `to_a2a()`).

The Agent Card's `.well-known/agent-card.json` endpoint is exempt from
this agent's OWN app-level Google Identity Platform gate (see
`auth_middleware.py`) -- but that is NOT the same as needing no
credential at all. When this agent is deployed `--no-allow-unauthenticated`
(both `../Deployment_artifacts/deploy.ps1` and this directory's own
`deploy.ps1`/`deploy.sh` do this -- see `CLOUD_RUN_IAM_GATED`),
Cloud Run's own PLATFORM-level IAM invoker check applies to EVERY path on
the service, including this one, regardless of what the app itself
exempts. Confirmed live: a bare, unauthenticated `urlopen()` call against
such a deployment's Agent Card URL returns a 403 straight from Google's
front end, before the request ever reaches this agent's own code.
`fetch_agent_card()` below therefore always attempts to attach a
Cloud-Run-IAM-scoped OIDC identity token (NOT the plain OAuth2 access
token `get_access_token()` mints for the Agent Registry API itself --
Cloud Run's invoker check specifically requires an identity token whose
`aud` is the service's own base URL) as a best-effort Bearer credential;
a genuinely public (`--allow-unauthenticated`) deployment simply ignores
the extra header.

`services.create`/`services.patch` return a long-running `Operation`
rather than the Service directly -- this script polls it briefly and
reports the outcome.

PATCH always sends an explicit `updateMask` covering every field in the
body (`displayName,description,agentSpec`). This was a real, confirmed
finding from `../ADKAgentAWS/register_agent_registry.py`'s development:
the API's own discovery doc says an omitted mask means "all fields
present in the request will be overwritten," but a real PATCH run
without one returned `done: true` immediately while the stored Service
(re-fetched directly, not just read back from the Operation) kept its
old `agentSpec.content`/`description` for several minutes. Re-sending the
identical body with an explicit mask resolved it on the next poll. Cause
not fully isolated (likely read-after-write lag on this still-maturing
API, possibly mask-dependent apply behavior) -- sending the mask always
is the cheap way to not depend on which it is. Applied here from the
start rather than re-discovering it.

--------------------------------------------------------------------------
IDEMPOTENCY
--------------------------------------------------------------------------
Agent Registry's `services.create` lets the caller choose the
`serviceId`, so this script always uses the same one (`--service-id`, a
stable slug) and checks for existence first:
  - Service already exists at that ID  -> PATCH (update in place)
  - Service doesn't exist yet          -> POST (create)

--------------------------------------------------------------------------
EXPLICIT INSTRUCTIONS
--------------------------------------------------------------------------
1. Prerequisites: `gcloud auth login` completed, with access to
   --project (default: boris-scc-gcp-project). No separate credentials.

2. ALWAYS preview first:
       .venv\\Scripts\\python.exe register_agent_registry.py --dry-run
   Fetches the live agent card and prints the Service body plus whether
   it would CREATE or PATCH -- no API calls that modify anything.

3. Run for real once the dry run looks right:
       .venv\\Scripts\\python.exe register_agent_registry.py
   A REAL, LIVE change visible to anyone in this GCP project/org with
   Agent Registry read access.

4. Re-run any time `agent.py` changes and you've redeployed Cloud Run --
   Agent Registry stores the card content at registration time; it does
   not poll the URL live.

5. Common flags:
     --dry-run             preview only, no API calls (see step 2)
     --card-url URL        override which URL to fetch the agent card from
     --display-name NAME   override the registration's display name
     --service-id ID       override the stable Service ID (default:
                            cyera-dataport-agent) -- changing this after
                            the fact creates a SECOND registry entry
                            rather than updating the first
     --project / --location
                            override the GCP project / Agent Registry
                            location

Usage:
    .venv\\Scripts\\python.exe register_agent_registry.py --dry-run
    .venv\\Scripts\\python.exe register_agent_registry.py
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_PROJECT = "boris-scc-gcp-project"
DEFAULT_LOCATION = "global"
DEFAULT_CARD_URL = (
    "https://cyera-dataport-agent-125700827764.us-central1.run.app/.well-known/agent-card.json"
)
DEFAULT_DISPLAY_NAME = "Cyera Dataport Agent"
DEFAULT_SERVICE_ID = "cyera-dataport-agent"

OPERATION_POLL_SECONDS = 2
OPERATION_POLL_ATTEMPTS = 10  # ~20s total


def get_access_token() -> str:
    """Reuses your existing `gcloud auth login` session -- no separate
    credentials needed. shutil.which() (not a bare "gcloud" argv) is
    required on Windows -- gcloud is a .cmd wrapper there; CreateProcess
    doesn't apply PATHEXT resolution the way a shell does."""
    gcloud_path = shutil.which("gcloud")
    if not gcloud_path:
        raise SystemExit("FATAL: `gcloud` not found on PATH -- install the Cloud SDK first.")
    result = subprocess.run(
        [gcloud_path, "auth", "print-access-token"],
        capture_output=True, text=True, check=False,
    )
    if result.returncode != 0:
        raise SystemExit(
            "FATAL: `gcloud auth print-access-token` failed -- run `gcloud "
            f"auth login` first.\n{result.stderr}"
        )
    return result.stdout.strip()


def _get_compute_service_account(project: str) -> str | None:
    """Looks up `project`'s own compute default service account
    (`<project-number>-compute@developer.gserviceaccount.com`) -- the
    identity `deploy.ps1`/`deploy.sh` (both this directory's own and
    `../Deployment_artifacts`'s) already grant `roles/run.invoker` to on
    every Cloud-Run-IAM-gated service they deploy. Returns None on any
    failure."""
    gcloud_path = shutil.which("gcloud")
    if not gcloud_path:
        return None
    result = subprocess.run(
        [gcloud_path, "projects", "describe", project, "--format=value(projectNumber)"],
        capture_output=True, text=True, check=False,
    )
    if result.returncode != 0:
        return None
    project_number = result.stdout.strip()
    return f"{project_number}-compute@developer.gserviceaccount.com" if project_number else None


def _mint_cloud_run_identity_token(audience: str, project: str) -> str | None:
    """Best-effort: mints a Google-signed OIDC identity token scoped to
    `audience` (the Cloud Run service's own base URL, no path) --
    satisfies Cloud Run's own platform-level IAM invoker check on a
    `--no-allow-unauthenticated` service. This is a DIFFERENT token type
    from `get_access_token()`'s plain OAuth2 access token above -- Cloud
    Run's invoker check does not accept that type.

    Two-tier, both confirmed live:
      1. Try minting directly for whatever identity `gcloud` is
         currently logged in as -- works if that identity is ALREADY a
         service account (e.g. a CI pipeline's own credentials).
      2. A plain human `gcloud auth login` USER account cannot do that
         at all -- confirmed live: `gcloud auth print-identity-token
         --audiences=...` fails outright for a user account ("Invalid
         account Type for `--audiences`. Requires valid service
         account."). The working fallback for that case, also confirmed
         live: impersonate `project`'s own compute default service
         account via `--impersonate-service-account=<sa>
         --audiences=<url>` -- this is exactly the identity this
         project's own deploy scripts already grant `roles/run.invoker`
         to, so it's reliable, not a guess. Requires the calling user to
         hold `roles/iam.serviceAccountTokenCreator` (or equivalent) on
         that service account.

    Returns None (never raises) on total failure (e.g. `gcloud` not on
    PATH, or neither path works) so a genuinely public
    (`--allow-unauthenticated`) deployment's Agent Card can still be
    fetched unauthenticated even if this fails."""
    gcloud_path = shutil.which("gcloud")
    if not gcloud_path:
        return None

    result = subprocess.run(
        [gcloud_path, "auth", "print-identity-token", f"--audiences={audience}"],
        capture_output=True, text=True, check=False,
    )
    if result.returncode == 0 and result.stdout.strip():
        return result.stdout.strip()

    sa = _get_compute_service_account(project)
    if not sa:
        return None
    result = subprocess.run(
        [gcloud_path, "auth", "print-identity-token",
         f"--impersonate-service-account={sa}", f"--audiences={audience}"],
        capture_output=True, text=True, check=False,
    )
    if result.returncode != 0:
        return None
    token = result.stdout.strip()
    return token or None


def fetch_agent_card(url: str, project: str) -> dict:
    """See this module's own docstring ("HOW THIS WORKS") for why a
    Cloud-Run-IAM-scoped identity token is attached here even though the
    Agent Card path is exempt from this agent's OWN app-level auth
    gate."""
    parsed = urllib.parse.urlsplit(url)
    audience = f"{parsed.scheme}://{parsed.netloc}"
    token = _mint_cloud_run_identity_token(audience, project)
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def api_request(method: str, url: str, token: str, project: str, body: dict | None = None) -> dict:
    headers = {
        "Authorization": f"Bearer {token}",
        "x-goog-user-project": project,
        "Content-Type": "application/json",
    }
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise SystemExit(f"FATAL: {method} {url} -> HTTP {exc.code}\n{detail}")


def api_request_allow_404(method: str, url: str, token: str, project: str) -> dict | None:
    headers = {"Authorization": f"Bearer {token}", "x-goog-user-project": project}
    req = urllib.request.Request(url, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None
        detail = exc.read().decode("utf-8", errors="replace")
        raise SystemExit(f"FATAL: {method} {url} -> HTTP {exc.code}\n{detail}")


def build_service_body(card: dict, display_name: str) -> dict:
    return {
        "displayName": display_name,
        "description": card.get("description", ""),
        # interfaces must stay empty here -- required when agentSpec.type
        # is A2A_AGENT_CARD, per the AgentSpec.type enum description in
        # the discovery doc ("The interfaces field must be empty").
        "agentSpec": {
            "type": "A2A_AGENT_CARD",
            "content": card,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Register or update the Cyera Dataport Agent as a Service (agentSpec) in Agent Registry.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--card-url", default=DEFAULT_CARD_URL)
    parser.add_argument("--display-name", default=DEFAULT_DISPLAY_NAME)
    parser.add_argument("--service-id", default=DEFAULT_SERVICE_ID)
    parser.add_argument("--project", default=DEFAULT_PROJECT)
    parser.add_argument("--location", default=DEFAULT_LOCATION)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    parent = f"projects/{args.project}/locations/{args.location}"
    services_base = f"https://agentregistry.googleapis.com/v1/{parent}/services"
    service_name = f"{parent}/services/{args.service_id}"
    service_url = f"https://agentregistry.googleapis.com/v1/{service_name}"

    print(f"Fetching live agent card from {args.card_url} ...")
    card = fetch_agent_card(args.card_url, args.project)
    print(f"Card has {len(card.get('skills', []))} skills (submitted as-is, no schema fix needed here).")

    body = build_service_body(card, args.display_name)

    if args.dry_run:
        print(f"\nWould check for an existing Service at: {service_name}")
        print("ACTION: would CREATE if absent, or UPDATE (PATCH) if already present.")
        preview = dict(body)
        preview["agentSpec"] = {"type": "A2A_AGENT_CARD", "content": "<omitted, see card above>"}
        print("\nService body that would be sent:")
        print(json.dumps(preview, indent=2))
        return 0

    token = get_access_token()

    print(f"Checking for an existing Service at {service_name} ...")
    existing = api_request_allow_404("GET", service_url, token, args.project)

    if existing:
        print("Found existing Service -- ACTION: UPDATE (PATCH)")
        # See module docstring's "PATCH always sends an explicit
        # updateMask" section for why this is not optional here.
        patch_url = f"{service_url}?updateMask=displayName,description,agentSpec"
        op = api_request("PATCH", patch_url, token, args.project, body)
    else:
        print("No existing Service with that ID -- ACTION: CREATE")
        create_url = f"{services_base}?serviceId={args.service_id}"
        op = api_request("POST", create_url, token, args.project, body)

    op_name = op.get("name")
    print(f"Operation started: {op_name}")
    done = op.get("done", False)
    result = op
    for _ in range(OPERATION_POLL_ATTEMPTS):
        if done:
            break
        time.sleep(OPERATION_POLL_SECONDS)
        op_url = f"https://agentregistry.googleapis.com/v1/{op_name}"
        result = api_request("GET", op_url, token, args.project)
        done = result.get("done", False)

    if not done:
        print(f"\nOperation still in progress after {OPERATION_POLL_ATTEMPTS * OPERATION_POLL_SECONDS}s. "
              f"Check it later with:\n  GET https://agentregistry.googleapis.com/v1/{op_name}")
        return 0

    if "error" in result:
        print(f"\nFAILED: {result['error']}", file=sys.stderr)
        return 1

    response = result.get("response", {})
    print(f"\nDone. registryResource={response.get('registryResource')}")
    print(f"name={response.get('name')}")
    print(f"displayName={response.get('displayName')}")
    print("\nVerify it's now discoverable via Agent Registry:")
    print(f"  GET https://agentregistry.googleapis.com/v1/{parent}/agents")
    return 0


if __name__ == "__main__":
    sys.exit(main())
