"""Register or update this agent's A2A Agent Card with Gemini Enterprise
(the specific app/engine's assistant -- NOT Agent Registry;
`register_agent_registry.py` in this same directory handles that,
separately, and is unaffected by this script). This agent stays
registered in Agent Registry either way -- this script only adds a
second, independent registration, it does not touch or replace the
first.

Verbatim-in-spirit copy of ../CyeraAnalyticsAgent/register_gemini_enterprise.py
-- not an import, per this directory's own "completely separate, no
dependency on other directories" convention. Makes NO changes to this
agent itself (`agent.py`, `main.py`, etc.) -- it only fetches the
already-deployed agent's public Agent Card and submits a (schema-
adjusted) copy of it to Gemini Enterprise's own registration API.

--------------------------------------------------------------------------
THE BUG THIS WORKS AROUND
--------------------------------------------------------------------------
ADK's `to_a2a()` (its A2A support is explicitly marked EXPERIMENTAL)
emits an Agent Card that nests the interface URL and protocol version
inside a `supportedInterfaces[]` array (the A2A protocol v1.0 shape):

    {"supportedInterfaces": [{"url": "...", "protocolVersion": "1.0", ...}], ...}

Gemini Enterprise's registration endpoint validates against the
older/canonical A2A schema instead, which expects `url` and
`protocolVersion` as FLAT TOP-LEVEL fields, and rejects the raw card
outright with:

    Unknown property "supportedInterfaces" at path "AgentCard"

`fix_agent_card_schema()` copies `protocolVersion`/`url` from
`supportedInterfaces[0]` up to the top level, and leaves
`supportedInterfaces` itself in place -- Gemini Enterprise's endpoint
accepts the card with both the flat fields and `supportedInterfaces`
present; only Agent Registry's endpoint rejects that combination as
"ambiguous." Since this script targets Gemini Enterprise only, it never
strips `supportedInterfaces`.

--------------------------------------------------------------------------
IDEMPOTENCY -- WHY THIS ISN'T JUST "POST AGAIN"
--------------------------------------------------------------------------
The registration API has no upsert-by-name semantics: POSTing again after
the agent card changes creates a SECOND, DUPLICATE agent entry rather
than updating the first one (Discovery Engine assigns a new numeric
agent ID per POST). This script looks up existing agents by
--display-name first:
  - exactly one match  -> PATCH that agent (update in place)
  - no match            -> POST a new agent
  - more than one match -> refuse and ask you to pass --agent-id
    explicitly (shouldn't happen if you always use this script)

--------------------------------------------------------------------------
EXPLICIT INSTRUCTIONS
--------------------------------------------------------------------------
1. Prerequisites: `gcloud auth login` completed, with access to
   --project (default: cyera-scc-integration); the deployed
   cyera-dataport-agent Cloud Run service reachable at --card-url.

2. ALWAYS preview first:
       .venv\\Scripts\\python.exe register_gemini_enterprise.py --dry-run

3. Run for real once the dry run looks right:
       .venv\\Scripts\\python.exe register_gemini_enterprise.py
   A REAL, LIVE change to a shared Gemini Enterprise app -- anyone using
   that app can immediately see the registered agent.

4. Re-run any time `agent.py` changes in a way that changes its
   tools/skills/description and you've redeployed Cloud Run -- Gemini
   Enterprise stores a STATIC copy of the card at registration time and
   does not poll the URL live.

5. Common flags:
     --dry-run              preview only, no API calls (see step 2)
     --card-url URL          override which URL to fetch the agent card from
     --display-name NAME     override the registration's display name
     --agent-id ID            force-target a specific existing agent
     --project / --project-number / --location / --engine
                              override the GCP project / Discovery Engine
                              location / engine (app) ID

Usage:
    .venv\\Scripts\\python.exe register_gemini_enterprise.py --dry-run
    .venv\\Scripts\\python.exe register_gemini_enterprise.py
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import urllib.error
import urllib.request

DEFAULT_PROJECT = "cyera-scc-integration"
DEFAULT_PROJECT_NUMBER = "67025906140"  # used in the engine/agent resource names
DEFAULT_LOCATION = "global"
DEFAULT_ENGINE = "gemini-enterprise-17890745_1789074551468"
DEFAULT_CARD_URL = (
    "https://cyera-dataport-agent-opwuwltofq-uc.a.run.app/.well-known/agent-card.json"
)
DEFAULT_DISPLAY_NAME = "Cyera Dataport Agent"


def get_access_token() -> str:
    """Reuses your existing `gcloud auth login` session -- no separate
    credentials. shutil.which() (not a bare "gcloud" argv) is required
    on Windows -- gcloud is a .cmd wrapper there; CreateProcess doesn't
    apply PATHEXT resolution the way a shell does."""
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


def fetch_agent_card(url: str) -> dict:
    with urllib.request.urlopen(url, timeout=30) as resp:
        return json.load(resp)


def fix_agent_card_schema(card: dict) -> dict:
    """Add flat top-level `protocolVersion`/`url` derived from
    `supportedInterfaces[0]` -- see module docstring for why. Additive
    only: never overwrites a top-level field already present, and never
    strips `supportedInterfaces`."""
    card = dict(card)  # shallow copy -- don't mutate the caller's object
    interfaces = card.get("supportedInterfaces") or []
    if interfaces:
        iface = interfaces[0]
        card.setdefault("protocolVersion", iface.get("protocolVersion"))
        card.setdefault("url", iface.get("url"))
    return card


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


def list_agents(assistant_url: str, token: str, project: str) -> list[dict]:
    result = api_request("GET", assistant_url, token, project)
    return result.get("agents", [])


def find_by_display_name(agents: list[dict], display_name: str) -> dict | None:
    matches = [a for a in agents if a.get("displayName") == display_name]
    if len(matches) > 1:
        ids = [a["name"].rsplit("/", 1)[-1] for a in matches]
        raise SystemExit(
            f"FATAL: {len(matches)} existing agents already have displayName "
            f"{display_name!r} (IDs: {ids}). Pass --agent-id to disambiguate "
            "which one to update."
        )
    return matches[0] if matches else None


def build_registration_body(card: dict, display_name: str) -> dict:
    return {
        "displayName": display_name,
        "description": card.get("description", ""),
        "a2aAgentDefinition": {"jsonAgentCard": json.dumps(card)},
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Register or update this agent's A2A Agent Card with Gemini Enterprise.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--card-url", default=DEFAULT_CARD_URL, help="where to fetch the live agent card from")
    parser.add_argument("--display-name", default=DEFAULT_DISPLAY_NAME)
    parser.add_argument("--agent-id", default=None, help="force-update this specific agent ID, skipping the by-display-name lookup")
    parser.add_argument("--project", default=DEFAULT_PROJECT, help="GCP project for the x-goog-user-project quota header")
    parser.add_argument("--project-number", default=DEFAULT_PROJECT_NUMBER, help="project number used in the engine resource name")
    parser.add_argument("--location", default=DEFAULT_LOCATION)
    parser.add_argument("--engine", default=DEFAULT_ENGINE, help="Discovery Engine app (engine) ID")
    parser.add_argument("--dry-run", action="store_true", help="fetch + transform + show the planned action, make no API calls")
    args = parser.parse_args()

    base = (
        f"https://discoveryengine.googleapis.com/v1alpha/projects/{args.project_number}"
        f"/locations/{args.location}/collections/default_collection/engines/{args.engine}"
        f"/assistants/default_assistant/agents"
    )

    print(f"Fetching live agent card from {args.card_url} ...")
    raw_card = fetch_agent_card(args.card_url)
    card = fix_agent_card_schema(raw_card)
    added = {k: card[k] for k in ("protocolVersion", "url") if k in card and k not in raw_card}
    if added:
        print(f"Schema fix applied -- added top-level fields: {added}")
    else:
        print("Schema fix was a no-op -- card already had flat protocolVersion/url.")
    print(f"Card has {len(card.get('skills', []))} skills.")

    body = build_registration_body(card, args.display_name)

    if args.dry_run:
        target_id = args.agent_id
        if not target_id:
            print("\n(--dry-run: skipping the live agent lookup that would run "
                  "next -- pass --agent-id to preview a specific UPDATE target, "
                  "or drop --dry-run to let this script look it up for real.)")
            print("ACTION: would look up existing agents by displayName, then "
                  "CREATE (if none found) or UPDATE (if exactly one found).")
        else:
            print(f"ACTION: would UPDATE agent {target_id}")
        print("\nRegistration body that would be sent:")
        preview = dict(body)
        preview["a2aAgentDefinition"] = {"jsonAgentCard": "<omitted, see card above>"}
        print(json.dumps(preview, indent=2))
        return 0

    token = get_access_token()

    if args.agent_id:
        target_url = f"{base}/{args.agent_id}"
        print(f"ACTION: UPDATE (PATCH) {target_url}")
        result = api_request("PATCH", target_url, token, args.project, body)
    else:
        print(f"Looking up existing agents with displayName={args.display_name!r} ...")
        existing = find_by_display_name(list_agents(base, token, args.project), args.display_name)
        if existing:
            agent_id = existing["name"].rsplit("/", 1)[-1]
            target_url = f"{base}/{agent_id}"
            print(f"Found existing agent {agent_id} -- ACTION: UPDATE (PATCH)")
            result = api_request("PATCH", target_url, token, args.project, body)
        else:
            print("No existing agent with that displayName -- ACTION: CREATE (POST)")
            result = api_request("POST", base, token, args.project, body)

    print(f"\nDone. name={result.get('name')}")
    print(f"displayName={result.get('displayName')}  state={result.get('state')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
