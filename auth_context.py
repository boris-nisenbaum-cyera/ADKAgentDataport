"""Shared contextvar carrying whether the current request was accepted via
auth_middleware.py's CLOUD_RUN_IAM_GATED trust path (Gemini Enterprise's
Agent Gateway, or another agent's own delegation call with no end-user
token to relay) -- rather than a genuine signed-in end user's Identity
Platform token.

Deliberate, verbatim-in-spirit copy of
../CyeraAnalyticsAgent/auth_context.py's identical addition (logger/scope
trimmed down to just this one flag, since this agent -- unlike
CyeraAnalyticsAgent/ADKAgentSecure/ADKAgentGCPToolkit -- is a leaf: it has
no agent_registry_tools.py of its own and never relays a bearer token
onward) -- not an import, per this project's "no dependency on other
directories" convention.

agent.py's response-deadline guard reads this to pick a much shorter
deadline for gateway-trusted callers: those calls are synchronous,
blocking, single-shot requests from a caller (Gemini Enterprise, or
another agent delegating on its behalf) with no visible progress UI and
an unknown but presumably short patience window. A single global deadline
can't serve both that caller and a human's own patience well -- see
agent.py's own module docstring for the live-confirmed rationale (a
genuinely thorough, ~30-query answer took ~8.5 minutes end-to-end and
Gemini Enterprise showed nothing, even though this agent eventually did
produce a real answer).
"""
from __future__ import annotations

import contextvars

_caller_is_gateway_trusted: contextvars.ContextVar[bool] = contextvars.ContextVar(
    "caller_is_gateway_trusted", default=False
)


def set_current_caller_is_gateway_trusted(value: bool) -> contextvars.Token:
    return _caller_is_gateway_trusted.set(value)


def reset_current_caller_is_gateway_trusted(reset_token: contextvars.Token) -> None:
    _caller_is_gateway_trusted.reset(reset_token)


def get_current_caller_is_gateway_trusted() -> bool:
    return _caller_is_gateway_trusted.get()
