"""A2A-compliant ASGI app for the identity-gated Cyera Dataport agent, and
its Cloud Run entrypoint.

Same structure as ../ADKAgentSecure/main.py (uses ADK's `to_a2a()` to wrap
`agent.root_agent` as a Starlette app), wrapped in
`IdentityPlatformAuthMiddleware` (auth_middleware.py) so every request
except the public Agent Card must present a valid Google Identity
Platform ID token.

Two independent "port" concepts, do not conflate them (see
../ADKAgent/main.py's module docstring for the full explanation):
  - $PORT: Cloud Run's actual container listen port.
  - A2A_HOST / A2A_PORT / A2A_PROTOCOL: baked into the *public* Agent Card
    so other agents know where to actually reach this service from
    outside.
"""
from __future__ import annotations

import asyncio
import os

import uvicorn
from google.adk.a2a.utils.agent_card_builder import AgentCardBuilder
from google.adk.a2a.utils.agent_to_a2a import to_a2a

from agent import root_agent
from auth_middleware import IdentityPlatformAuthMiddleware

# The GCP/Firebase project ID Identity Platform ID tokens for this project
# are issued for -- used as the expected `aud` claim when verifying tokens.
IDENTITY_PLATFORM_PROJECT_ID = os.environ.get(
    "IDENTITY_PLATFORM_PROJECT_ID", "boris-scc-gcp-project"
)

# Set (unconditionally, alongside --no-allow-unauthenticated) by the
# deploy scripts whenever this service requires Cloud Run authentication
# -- see auth_middleware.py's module docstring for the full rationale.
CLOUD_RUN_IAM_GATED = os.environ.get("CLOUD_RUN_IAM_GATED", "").lower() == "true"

_a2a_host = os.environ.get("A2A_HOST", "localhost")
_a2a_port = os.environ.get("A2A_PORT", "8080")
_a2a_protocol = os.environ.get("A2A_PROTOCOL", "http")


def _build_canonical_rpc_url(protocol: str, host: str, port: str) -> str:
    """Omits the port when it's the scheme's own default (443 for https, 80
    for http) -- see ../CyeraAnalyticsAgent/main.py's identical helper for
    the full, live-confirmed rationale: `to_a2a()`'s auto-built Agent Card
    always appends ":<port>" unconditionally, producing a non-canonical
    URL like "https://host:443" that Cloud Run's own IAM invoker check
    rejects as an audience once this service requires authentication --
    confirmed by minting test tokens with/without the suffix and curling
    this service directly."""
    is_default_port = (protocol == "https" and port == "443") or (
        protocol == "http" and port == "80"
    )
    return f"{protocol}://{host}/" if is_default_port else f"{protocol}://{host}:{port}/"


# Built once, eagerly, via ADK's OWN AgentCardBuilder (the same class
# to_a2a() itself uses internally) -- see ../CyeraAnalyticsAgent/main.py's
# identical construction for why this is safe to do synchronously at
# import time.
_agent_card = asyncio.run(
    AgentCardBuilder(
        agent=root_agent,
        rpc_url=_build_canonical_rpc_url(_a2a_protocol, _a2a_host, _a2a_port),
    ).build()
)

a2a_app = to_a2a(
    root_agent,
    host=_a2a_host,
    port=int(_a2a_port),
    protocol=_a2a_protocol,
    agent_card=_agent_card,
)

a2a_app.add_middleware(
    IdentityPlatformAuthMiddleware,
    project_id=IDENTITY_PLATFORM_PROJECT_ID,
    cloud_run_iam_gated=CLOUD_RUN_IAM_GATED,
)

if __name__ == "__main__":
    listen_port = int(os.environ.get("PORT", "8080"))
    uvicorn.run(a2a_app, host="0.0.0.0", port=listen_port)
