# Cyera Dataport Agent

A Google ADK agent that answers questions about Cyera's **Dataport**
Snowflake warehouse by calling Cyera's already-hosted Dataport MCP
gateway. Uses **Gemini 3.8 Flash** by default (configurable -- see
[Configuring the LLM](#5-configuring-the-llm)). Access to the agent
itself is gated by **Google Identity Platform**. Supports the **A2A
protocol** (via ADK's `to_a2a()`) and is registered in Google's **Agent
Registry**. Deployed on **Cloud Run**.

**This directory makes no changes to any other directory in this
project** (`../MCPServer`, `../ADKAgent`, `../ADKAgentSecure`, `../A2A`,
`../A2AProtocolDemo*`). It is completely independent -- its own agent,
its own Cloud Run service, no shared code or imports with anything else
here.

## Contents

1. [Two separate authentication layers](#1-two-separate-authentication-layers)
2. [The MCP connection, verified live](#2-the-mcp-connection-verified-live)
3. [Read-only SQL guard](#3-read-only-sql-guard)
4. [Context-required-before-querying guard](#4-context-required-before-querying-guard)
5. [Configuring the LLM](#5-configuring-the-llm)
6. [Setup and local testing](#6-setup-and-local-testing)
7. [Deploy to Cloud Run](#7-deploy-to-cloud-run)
8. [Agent Registry registration](#8-agent-registry-registration)
9. [Known limitations](#9-known-limitations)
10. [Security notes](#10-security-notes)
11. [Code map](#11-code-map)

## 1. Two separate authentication layers

| | Gates | Mechanism | Where |
|---|---|---|---|
| **Layer 1: who can talk to this agent at all** | Every A2A request except the public Agent Card | Google Identity Platform ID token, verified server-side | `auth_middleware.py`, wired in `main.py` -- verbatim-in-spirit copy of `../ADKAgentSecure`'s |
| **Layer 2: what this agent can do in Cyera's Dataport warehouse** | The MCP tool calls specifically | A single static Bearer JWT (`CYERA_DATAPORT_MCP_TOKEN`) issued by Cyera's MCP gateway -- the attached mcp.json's `hosted-demov2` server | `agent.py`, via `McpToolset` |

Layer 2 here is a **static, long-lived shared credential** (same model as
`../ADKAgentSecure`'s `CYERA_MCP_SHARED_SECRET`), **not** a
per-conversation interactive OIDC sign-in flow -- there is no interactive
sign-in step for Dataport access; whoever holds the token in
`.env`/Secret Manager has whatever access that token grants, for as long
as it remains valid (see Section 9).

## 2. The MCP connection, verified live

The attached `mcp.json` declares:
```json
{"type": "sse", "url": "https://mcp.cyera.io/public/dataport/mcp/sse"}
```
That exact URL was tested live before writing any code and returns a
real 404 from the server itself (confirmed via a raw TLS handshake +
HTTP request, not a proxy artifact) -- regardless of token validity. The
SSE endpoint has moved or been retired since that mcp.json was generated.

The working transport, confirmed live with the real token:
**Streamable HTTP against the base path** (no `/sse` suffix):
```
https://mcp.cyera.io/public/dataport/mcp
```
A bogus token against that URL gets a real `401 invalid_token`; the real
token gets `200`. `agent.py` uses `StreamableHTTPConnectionParams`
against this base URL, not `SseConnectionParams` against the literal
mcp.json URL. `../A2A/mcp_bridge.py` already anticipates exactly this
kind of endpoint drift via its own candidate-negotiation logic
(`_candidates()`); this agent hardcodes the one candidate actually
verified working rather than re-implementing that negotiation, since
ADK's `McpToolset` takes one fixed connection, not a list to probe.
`CYERA_DATAPORT_MCP_URL` can override this if Cyera's gateway moves
again.

**Exactly two tools are exposed** (confirmed live via `tools/list`):
- `get_cyera_dataport_snowflake_context(file_name=None)` -- returns
  Cyera platform/schema documentation. Pass `"index"` first to list
  available context files, then a specific file's exact name (e.g.
  `"dataport_schema.json"`) to load it, or omit `file_name` to load
  everything at once. Always safe; not gated.
- `execute_dataport_query(query: str)` -- runs one SQL statement against
  the Dataport Snowflake warehouse. Its own description says "should get
  dataport snowflake context before using this" -- the agent's
  instruction tells the model to do exactly that.

## 3. Read-only SQL guard

`execute_dataport_query` can run arbitrary SQL, including mutating
statements -- the MCP server itself does not appear to enforce read-only
access. Consistent with this project's established convention
(`../MCPServer`'s `--allow-writes` gate, `../ADKAgentSecure`'s read-only
instruction) and Cyera's own data-handling posture, this agent enforces
read-only access itself, client-side, mirroring
**`../A2A/mcp_bridge.py`'s own `check_sql()`** function almost exactly
(deliberately duplicated, not imported -- see `agent.py`'s module
docstring for why):

- Only a single statement, leading with `SELECT`/`WITH`/`SHOW`/
  `DESCRIBE`/`DESC`/`EXPLAIN`, is allowed.
- A semicolon anywhere in the (trimmed) statement is rejected as a sign
  of multiple statements.
- A regex additionally rejects `INSERT`/`UPDATE`/`DELETE`/`MERGE`/
  `TRUNCATE`/`DROP`/`ALTER`/`CREATE`/`GRANT`/`REVOKE`/`COPY`/`PUT`/
  `REMOVE`/`CALL`/`EXECUTE IMMEDIATE` appearing anywhere in the statement.

This is enforced in `agent.py`'s `before_tool_callback`
(`_before_tool`): when it rejects a query, it returns an error dict
**instead of calling the MCP tool at all** -- the disallowed SQL never
reaches Cyera's Dataport warehouse. There is currently no write-enabled
mode (unlike `../MCPServer`'s `--allow-writes`); add one the same way if
ever needed.

## 4. Context-required-before-querying guard

A real production incident, not a hypothetical: the agent's instruction
has always told the model to call
`get_cyera_dataport_snowflake_context` before writing SQL, but that
alone wasn't reliable -- in one real run, the model skipped it entirely,
guessed table/column names for two `execute_dataport_query` calls, both
came back near-empty, and it told the user "no datastores found" for
a platform that in fact has 157 real datastores in this exact warehouse
(confirmed directly against the warehouse, bypassing this agent, during
the investigation that found this).

Fixed with an actual code-level guard in `agent.py`'s `_before_tool`,
not just stronger instruction wording: `execute_dataport_query` is
rejected outright -- before it ever reaches the real MCP tool -- unless
`get_cyera_dataport_snowflake_context` has already been called at least
once earlier in the same conversation with real content. Calling it
with only `file_name="index"` does **not** satisfy this: the index just
lists available files, it has no table/column names, so it doesn't
actually fix the guessing problem. `_log_after_tool` sets the
corresponding `tool_context.state` flag once a qualifying context call
completes. Unlike the original instruction-only approach, the model
cannot bypass this by simply not following it -- the tool call fails
with a clear, actionable error instead of silently proceeding.

## 5. Configuring the LLM

Two independent things control which model actually answers: **which
model** (`ADK_MODEL`), and **which backend serves it** (model
credentials). Confirmed directly from `agent.py` and the live `.env` in
this directory, not assumed.

### Which model

`ADK_MODEL` defaults to **`gemini-3.8-flash`** (`agent.py` line ~148 --
changed from an earlier `gemini-2.5-pro` default on 2026-09-22). Override
it to any other ADK-resolvable model string:
```
ADK_MODEL=gemini-3.8-flash   # current default
ADK_MODEL=gemini-2.5-pro
ADK_MODEL=gemini-2.5-flash
ADK_MODEL=claude-sonnet-5    # non-Gemini -- see THINKING_BUDGET note below
```
`THINKING_BUDGET` (Gemini reasoning depth in tokens) defaults to `-1`
(automatic -- model chooses, maximum depth); `0` disables reasoning;
any positive integer sets a manual budget. It's silently ignored for
non-Gemini `ADK_MODEL` values (`agent.py` only attaches a
`ThinkingConfig` when `ADK_MODEL.startswith("gemini")`), so setting it
alongside `claude-sonnet-5` has no effect.

### Which backend (required -- choose ONE)

- **Option A -- AI Studio API key** (Gemini models only): set
  `GOOGLE_API_KEY`.
- **Option B -- Vertex AI** (the default path; required for the
  default `gemini-3.8-flash` model): set `GOOGLE_GENAI_USE_VERTEXAI=true`,
  `GOOGLE_CLOUD_PROJECT`, and `GOOGLE_CLOUD_LOCATION` (the Cloud Run
  deploy region, e.g. `us-central1` -- see the `VERTEX_MODEL_LOCATION`
  note immediately below for why this is *not* also where the model gets
  served from).

### `VERTEX_MODEL_LOCATION` -- required for the default model

`gemini-3.8-flash` is only served via Vertex AI's **`global`** endpoint
as of 2026-09-22 (confirmed live), not regional endpoints like
`us-central1`. This is a deliberately **separate** variable from
`GOOGLE_CLOUD_LOCATION` above -- `GOOGLE_CLOUD_LOCATION`/`--region` is
also used elsewhere as the actual Cloud Run deploy region
(`../Deployment_artifacts/deploy.ps1`'s own `Resolve-ModelCredentialConfig`),
and `global` is not a valid Cloud Run region, so conflating the two would
break deployment. Set:
```
VERTEX_MODEL_LOCATION=global
```
If you override `ADK_MODEL` to a model that's served regionally instead,
either omit this variable or set it to match your `GOOGLE_CLOUD_LOCATION`.

**Note:** this directory's own `.env.example` does not currently document
`VERTEX_MODEL_LOCATION` or the `gemini-3.8-flash` default (it still shows
an older `gemini-2.5-pro` default in its comments) even though the real
`.env` sets `VERTEX_MODEL_LOCATION=global` and `agent.py`'s own code
comment describes it as required -- confirmed by reading `.env.example`
directly. Worth updating that file to match next time it's touched; this
README now reflects the actual, current behavior either way.

### Applying a change

Local runs: edit `.env`, then re-run `test_agent_local.py`/`main.py`.
Cloud Run: update the `--set-env-vars` flags in Section 7's deploy
command (or `gcloud run services update --update-env-vars=...` for a
targeted change) and redeploy.

## 6. Setup and local testing

This agent needs its own venv, separate from every other directory here
(`google-adk[mcp]` pins a specific `mcp` SDK version incompatible with
`../MCPServer`'s `fastmcp`/`mcp` pins):

```powershell
cd ADKAgentDataport
python -m venv .venv
.venv\Scripts\pip install -r requirements.txt
copy .env.example .env
# edit .env: CYERA_DATAPORT_MCP_TOKEN, plus model configuration -- see
# Section 5, Configuring the LLM (model credentials, ADK_MODEL,
# VERTEX_MODEL_LOCATION)
.venv\Scripts\python.exe test_agent_local.py
```

`test_agent_local.py` checks (does NOT call the LLM, does NOT run a real
query):
- `check_sql()`'s guard, both allow and reject cases, with no network
  call at all.
- `agent.py` imports and constructs an `LlmAgent` + `McpToolset`.
- The `McpToolset` actually reaches the live Dataport MCP gateway and
  lists its tools (a real network call, using the real token in `.env`).
- `to_a2a()` wraps the agent into a valid Starlette app.
- `IdentityPlatformAuthMiddleware` rejects an unauthenticated in-process
  request (`401`) while leaving the public Agent Card reachable (`200`).

To run the agent locally over HTTP: `.venv\Scripts\python.exe main.py`
(binds `0.0.0.0:8080` by default).

## 7. Deploy to Cloud Run

### Recommended: `deploy.ps1` / `deploy.sh`

This directory ships its own self-contained deploy scripts -- a
single-component equivalent of
`../Deployment_artifacts/deploy.ps1`'s/`deploy.sh`'s own
`Deploy-ADKAgentDataport`/`deploy_adkagentdataport()` function, extracted
so this one agent can be deployed (and registered in Agent Registry, in
the same run) without touching that shared 5-component script at all:

```powershell
.\deploy.ps1 -Project your-project-id
```
```bash
./deploy.sh --project your-project-id
```

Both scripts:
- Deploy via a two-phase `gcloud run deploy --source .` (so the Agent
  Card ends up advertising the real external URL, not `localhost` --
  same reasoning as the manual steps below).
- Resolve `CYERA_DATAPORT_MCP_TOKEN`/`GOOGLE_API_KEY` from `.env` (or
  prompt), storing them in Secret Manager.
- Pick up `VERTEX_MODEL_LOCATION`/`ADK_MODEL`/`THINKING_BUDGET` from
  `.env` automatically if set -- see [Section 5](#5-configuring-the-llm).
- Grant `roles/run.invoker` on the deployed (`--no-allow-unauthenticated`)
  service to the project's compute default service account, plus
  optionally Gemini Enterprise's own service agent
  (`-GeminiEnterpriseProjectNumber`/`--gemini-enterprise-project-number`)
  and any other principal (`-ExtraInvokerMembers`/`--extra-invoker-member`).
- Register the deployed service in Agent Registry (see
  [Section 8](#8-agent-registry-registration) below) -- pass
  `-SkipRegistration`/`--skip-registration` to deploy only.
- Accept **any Cloud Run service name** via
  `-ServiceName`/`--service-name` (default: `cyera-dataport-agent`) --
  deploy multiple independent copies of this agent side by side (e.g.
  per environment) without colliding; `-ServiceId`/`--service-id` and
  `-DisplayName`/`--display-name` (both Agent Registry fields) default
  to the same value for the same reason.
- Support `-DryRun`/`--dry-run` -- always worth running first in a new
  project.

Run `.\deploy.ps1 -?` (PowerShell's own built-in help, reads the
script's comment-based help block) or `./deploy.sh --help` for the full
parameter/flag reference.

### What those scripts do under the hood (manual equivalent)

```powershell
gcloud run deploy cyera-dataport-agent --source . --region us-central1 --no-allow-unauthenticated `
  --set-secrets="CYERA_DATAPORT_MCP_TOKEN=cyera-dataport-mcp-token:latest" `
  --set-env-vars="GOOGLE_GENAI_USE_VERTEXAI=true,GOOGLE_CLOUD_PROJECT=boris-scc-gcp-project,GOOGLE_CLOUD_LOCATION=us-central1,VERTEX_MODEL_LOCATION=global,CLOUD_RUN_IAM_GATED=true"
```

`VERTEX_MODEL_LOCATION=global` is required for the default
`gemini-3.8-flash` model -- see [Section 5](#5-configuring-the-llm). Add
`ADK_MODEL=...`/`THINKING_BUDGET=...` to `--set-env-vars` too if
overriding the model.

This agent is deployed `--no-allow-unauthenticated` -- the real gate is
`IdentityPlatformAuthMiddleware` inside the container (checked on every
request except the public Agent Card), but Cloud Run's own
platform-level IAM invoker check is the actual mechanism that lets
`X-Serverless-Authorization` (Gemini Enterprise's Agent Gateway
credential, or another in-project caller) be verified at all -- see
`auth_middleware.py`'s own module docstring. If you deploy manually
(not via `deploy.ps1`/`deploy.sh`), you must also grant `roles/run.invoker`
yourself (`gcloud run services add-iam-policy-binding`) to whatever
principal needs to call this agent. After the first deploy, note the
service URL and redeploy once more with `A2A_HOST`/`A2A_PORT`/
`A2A_PROTOCOL` set to it (see `main.py`'s module docstring) so the
public Agent Card advertises the real external URL, not `localhost`.

## 8. Agent Registry registration

`deploy.ps1`/`deploy.sh` already do this automatically as their last
step (see [Section 7](#7-deploy-to-cloud-run) above) -- this section
covers running it standalone (e.g. after a manual deploy, or to
re-register following an `agent.py` change without a full redeploy):

```powershell
.venv\Scripts\python.exe register_agent_registry.py --dry-run --service-id YOUR-SERVICE-NAME --card-url https://YOUR-SERVICE-URL/.well-known/agent-card.json   # preview
.venv\Scripts\python.exe register_agent_registry.py             --service-id YOUR-SERVICE-NAME --card-url https://YOUR-SERVICE-URL/.well-known/agent-card.json   # real
```

Registers/updates a `Service` (default ID: `cyera-dataport-agent`) in
`agentregistry.googleapis.com`, from which Agent Registry derives a
read-only `Agent` entry. Re-run any time `agent.py` changes and you've
redeployed -- Agent Registry stores the card content at registration
time, it does not poll the live URL. See the script's own module
docstring for the full data-model explanation and the `updateMask`
finding from this project's other registration scripts (applied here
from the start).

### If Agent Registry registration fails

The most common failure, confirmed live: `fetch_agent_card()` gets
**`HTTP Error 403: Forbidden`** trying to reach
`.well-known/agent-card.json`. This is NOT an application-level
rejection -- `auth_middleware.py` explicitly exempts that path from its
own gate. It's Cloud Run's own **platform-level** IAM invoker check,
which applies to every path on a `--no-allow-unauthenticated` service
(see [Section 7](#7-deploy-to-cloud-run)) regardless of what the app
itself exempts.

`register_agent_registry.py` already handles this itself where it can:
it tries minting a Cloud-Run-scoped identity token directly (works if
you're already authenticated as a service account), then falls back to
**impersonating the project's compute default service account** -- the
same identity `deploy.ps1`/`deploy.sh` already grant `roles/run.invoker`
to. That fallback needs `roles/iam.serviceAccountTokenCreator` on that
service account, which most roles -- **including `roles/owner`**, by
Google's own design -- do not include. If you don't have it, you'll see
the same 403 even with full project ownership.

Two ways to fix it:

1. **Let the deploy script grant it for you**: re-run with
   `-AutoGrantRegistrationImpersonation` (PowerShell) /
   `--auto-grant-registration-impersonation` (bash). Off by default
   (see that flag's own help text for why) -- it checks whether you
   already have the permission first, and only grants it if missing, to
   whichever account `gcloud` is currently logged in as. It then waits
   briefly for the grant to propagate before retrying registration.
2. **Grant it yourself, once per project**:
   ```powershell
   $projectNumber = (gcloud projects describe YOUR_PROJECT_ID --format="value(projectNumber)")
   gcloud iam service-accounts add-iam-policy-binding `
     "$projectNumber-compute@developer.gserviceaccount.com" `
     --project=YOUR_PROJECT_ID `
     --member="user:your-email@example.com" `
     --role="roles/iam.serviceAccountTokenCreator"
   ```
   Takes 10-30 seconds to propagate; re-run `register_agent_registry.py`
   (or `deploy.ps1`/`deploy.sh` without the auto-grant flag) once it has.

This is a one-time, per-project fix -- deploying this agent again later
in the same project won't need it repeated, but deploying into a
**different** project will (Owner doesn't carry the impersonation
permission across projects either).

## 9. Known limitations

- **The Dataport MCP token is a single, static, long-lived shared
  credential** with a real expiry: decoded (not verified) from the
  attached mcp.json, it was issued 2026-04-20 and expires **2026-10-21**.
  Past that date, every tool call will fail with `401 invalid_token`
  (confirmed live to be this exact error shape against a genuinely
  invalid token). There is no refresh flow implemented here -- rotating
  it means getting a new token from Cyera and updating `.env`/Secret
  Manager, then redeploying.
- **No formal A2A `securitySchemes` advertisement** for the Google
  Identity Platform gate -- same as `../ADKAgentSecure`; an uninformed
  caller discovers the requirement via a 401, not upfront from the Agent
  Card.
- **The read-only guard is enforced client-side by this agent, not by
  the MCP server itself.** It covers every path this agent's own
  `before_tool_callback` sees (i.e. every call the LLM makes through this
  agent), but is not a substitute for a server-side control if the same
  token is ever used from anywhere else.
- **The mcp.json-declared "sse" transport does not work** as of this
  writing (see Section 2) -- if Cyera's gateway changes again,
  `CYERA_DATAPORT_MCP_URL` may need updating, or (if SSE is genuinely the
  only transport again) `agent.py` would need to switch from
  `StreamableHTTPConnectionParams` to `SseConnectionParams`.
- **No pagination handling** beyond whatever `execute_dataport_query`
  itself returns -- large result sets are returned to the model as-is
  (subject to whatever the MCP server's own response size limits are).

## 10. Security notes

- This agent holds no Cyera credential other than the single Dataport
  MCP Bearer token -- never baked into the container image, only ever
  supplied via `.env` (local) or Secret Manager (Cloud Run).
- Tool-call logging (`_before_tool`/`_log_after_tool` in `agent.py`) logs
  argument **keys** only, never values -- the `query` argument in
  particular can carry Cyera customer/tenant data and is never written
  to logs.
- Per this project's and Cyera's own data-handling conventions, query
  results may contain live customer/tenant data; the agent's instruction
  tells the model to summarize rather than dump raw result sets
  verbatim, but this is a model-following instruction, not a technical
  control -- treat any output from this agent the same as you would raw
  Dataport query results.

## 11. Code map

| File | Purpose |
|---|---|
| `agent.py` | `LlmAgent` + `McpToolset` (Streamable HTTP) against Cyera's Dataport MCP gateway; read-only SQL guard (`check_sql`); tool/model error callbacks; `ADK_MODEL`/`THINKING_BUDGET` resolution |
| `auth_middleware.py` | `IdentityPlatformAuthMiddleware` -- Google Identity Platform ID token verification (verbatim-in-spirit copy of `../ADKAgentSecure`'s) |
| `main.py` | `to_a2a()` wrapping + middleware + Cloud Run entrypoint |
| `register_agent_registry.py` | Registers/updates this agent's entry in Agent Registry -- re-run after any redeploy that changes `agent.py`'s tools/description. Also mints a Cloud-Run-IAM-scoped identity token (direct, or via impersonating the compute default SA) to fetch the Agent Card -- see [Section 8](#8-agent-registry-registration) |
| `test_agent_local.py` | Offline-ish smoke test: SQL guard unit checks, agent construction, live MCP tool listing, auth-gate rejection |
| `deploy.ps1` / `deploy.sh` | Self-contained, single-component deploy + Agent Registry registration under any service name -- see [Section 7](#7-deploy-to-cloud-run) |
| `Dockerfile` / `requirements.txt` | Cloud Run container build |
| `.env` / `.env.example` | Local configuration (see Sections 5-6) |
