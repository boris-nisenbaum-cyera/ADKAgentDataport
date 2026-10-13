"""Inbound authentication for this agent's A2A endpoint, via Google
Identity Platform -- OR, when this deployment is Cloud Run IAM-gated (see
CLOUD_RUN_IAM_GATED below), via trusting a caller Cloud Run's own platform
has ALREADY authenticated.

Deliberate, verbatim-in-spirit copy of
../ADKAgentSecure/auth_middleware.py (logger name changed to this agent's
own -- "cyera_dataport_agent") -- not an import, per this project's
convention that each agent directory is independently deployable with no
cross-directory imports (see ../ADKAgentSecure/agent.py's docstring for
the same reasoning applied to agent logic). If ../ADKAgentSecure's
middleware changes in the future, port the same change here by hand.

See ../ADKAgentSecure/auth_middleware.py's own module docstring for the
full rationale (why Identity Platform's own token verification, what this
does and does not cover, what has and hasn't been verified, and the full
live-confirmed CLOUD_RUN_IAM_GATED story) -- all of it applies identically
here.
"""
from __future__ import annotations

import asyncio
import logging

from google.auth import jwt as google_jwt
from google.auth.transport import requests as google_auth_requests
from google.oauth2 import id_token as google_id_token
from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Receive, Scope, Send

from auth_context import (
    reset_current_caller_is_gateway_trusted,
    set_current_caller_is_gateway_trusted,
)

logger = logging.getLogger("cyera_dataport_agent")

# The A2A protocol's own well-known discovery URI -- see
# ../ADKAgentSecure/auth_middleware.py's module docstring for why this
# stays public while everything else is gated.
_PUBLIC_PATHS = frozenset({"/.well-known/agent-card.json"})

# One shared google.auth.transport.requests.Request() instance so Google's
# public certs (fetched to verify token signatures) are cached across
# requests instead of being re-fetched on every single call.
_google_auth_request = google_auth_requests.Request()


class IdentityPlatformAuthMiddleware:
    """Starlette-style ASGI middleware: reject any HTTP request (other than
    the public Agent Card) that doesn't present a valid Google Identity
    Platform ID token as a Bearer credential -- unless cloud_run_iam_gated
    is set, in which case a request with no Identity Platform token but a
    present, well-formed X-Serverless-Authorization is also accepted (see
    ../ADKAgentSecure/auth_middleware.py's module docstring)."""

    def __init__(self, app: ASGIApp, *, project_id: str, cloud_run_iam_gated: bool = False) -> None:
        if not project_id:
            raise ValueError(
                "IdentityPlatformAuthMiddleware requires a non-empty project_id "
                "(the GCP/Firebase project ID, e.g. 'boris-scc-gcp-project' -- "
                "used as the expected token audience)."
            )
        self.app = app
        self._project_id = project_id
        self._cloud_run_iam_gated = cloud_run_iam_gated

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        if scope.get("path") in _PUBLIC_PATHS:
            await self.app(scope, receive, send)
            return

        headers = dict(scope.get("headers") or [])
        raw_auth = headers.get(b"authorization", b"").decode("utf-8", errors="replace")

        if not raw_auth.lower().startswith("bearer "):
            gateway_email = self._try_accept_cloud_run_iam_gated_caller(headers)
            if gateway_email:
                logger.info("auth_accept_gateway email=%s", gateway_email)
                reset_gateway_trusted = set_current_caller_is_gateway_trusted(True)
                try:
                    await self.app(scope, receive, send)
                finally:
                    reset_current_caller_is_gateway_trusted(reset_gateway_trusted)
                return

            logger.warning("auth_reject reason=missing_or_malformed_bearer_header")
            await self._reject(
                scope,
                receive,
                send,
                "Missing 'Authorization: Bearer <Google Identity Platform ID "
                "token>' header.",
            )
            return

        token = raw_auth[len("bearer "):].strip()
        if not token:
            logger.warning("auth_reject reason=empty_bearer_token")
            await self._reject(scope, receive, send, "Empty bearer token.")
            return

        try:
            # verify_firebase_token is a synchronous call that does network
            # I/O (fetching/using cached Google public certs) -- run it off
            # the event loop rather than blocking every other request.
            claims = await asyncio.to_thread(
                google_id_token.verify_firebase_token,
                token,
                _google_auth_request,
                audience=self._project_id,
            )
        except Exception as exc:  # noqa: BLE001 -- ANY verification failure
            # must reject; this is a security gate, never fail open. The
            # detailed reason is logged server-side only -- the client gets
            # a generic message, not internals of why its token was bad.
            logger.warning("auth_reject reason=%s", exc)
            await self._reject(
                scope, receive, send, "Invalid or expired Identity Platform ID token."
            )
            return

        if not claims:
            logger.warning("auth_reject reason=empty_claims")
            await self._reject(
                scope, receive, send, "Invalid or expired Identity Platform ID token."
            )
            return

        # Log only the token's subject (a stable, non-reversible user ID),
        # never the email or other PII the token may carry -- consistent
        # with this whole project's logging conventions.
        logger.info("auth_accept uid=%s", claims.get("user_id") or claims.get("sub") or "<unknown>")
        await self.app(scope, receive, send)

    def _try_accept_cloud_run_iam_gated_caller(self, headers: dict) -> str | None:
        """Returns a caller identity string (for logging only) if
        X-Serverless-Authorization carries a well-formed bearer JWT, else
        None. Off entirely unless cloud_run_iam_gated was configured (see
        ../ADKAgentSecure/auth_middleware.py's module docstring for why no
        signature verification is attempted here -- Cloud Run's own
        platform already did that before this code ever ran)."""
        if not self._cloud_run_iam_gated:
            return None

        raw = headers.get(b"x-serverless-authorization", b"").decode("utf-8", errors="replace")
        if not raw.lower().startswith("bearer "):
            return None
        token = raw[len("bearer "):].strip()
        if not token:
            return None

        try:
            claims = google_jwt.decode(token, verify=False)
        except Exception as exc:  # noqa: BLE001 -- malformed header, reject
            logger.warning("auth_reject reason=gateway_token_malformed detail=%s", exc)
            return None

        return claims.get("email") or "<unknown>"

    @staticmethod
    async def _reject(scope: Scope, receive: Receive, send: Send, detail: str) -> None:
        response = JSONResponse({"error": "unauthorized", "detail": detail}, status_code=401)
        await response(scope, receive, send)
