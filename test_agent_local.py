"""Offline-ish smoke test for the identity-gated Cyera Dataport ADK/A2A
agent.

Same checks as ../ADKAgentSecure/test_agent_local.py (agent.py imports and
constructs an LlmAgent + McpToolset; to_a2a() wraps it into a valid
Starlette app; the McpToolset can actually reach the deployed Cyera
Dataport MCP gateway and list its tools; main.py's
IdentityPlatformAuthMiddleware rejects an unauthenticated local ASGI
call), plus unit-level checks of the read-only SQL guard (check_sql())
and the context-loaded gate (_before_tool/_log_after_tool) -- neither
needs a network call.

Does NOT invoke the LLM (no Gemini call). Does NOT call execute_dataport_query
for real (the tool-listing/reachability check only calls list_tools(),
never call_tool()) -- no risk of this test itself running a live query.

Usage: .venv/Scripts/python.exe test_agent_local.py
"""
from __future__ import annotations

import asyncio
import os
import sys

from dotenv import load_dotenv

load_dotenv()

try:
    import truststore

    truststore.inject_into_ssl()
except ImportError:
    pass


def check_sql_guard() -> bool:
    """Pure unit checks of agent.check_sql() -- no network, no LLM."""
    import agent as agent_module

    ok = True
    read_only_cases = ["select 1", "  WITH x AS (select 1) select * from x", "show tables", "explain select 1"]
    for sql in read_only_cases:
        try:
            agent_module.check_sql(sql)
        except agent_module.SqlNotAllowed as exc:
            print(f"FAILURE: expected '{sql}' to be allowed, got: {exc}", file=sys.stderr)
            ok = False

    reject_cases = [
        "DELETE FROM foo",
        "insert into foo values (1)",
        "select 1; drop table foo",
        "update foo set x=1",
        "",
        "   ",
    ]
    for sql in reject_cases:
        try:
            agent_module.check_sql(sql)
            print(f"FAILURE: expected '{sql}' to be rejected, but it was allowed", file=sys.stderr)
            ok = False
        except agent_module.SqlNotAllowed:
            pass

    print(f"check_sql() guard: {len(read_only_cases)} allowed correctly, {len(reject_cases)} rejected correctly")
    return ok


class _FakeTool:
    def __init__(self, name: str):
        self.name = name


class _FakeToolContext:
    def __init__(self):
        self.state: dict = {}


def test_context_gate() -> bool:
    """Pure unit checks of the context-loaded gate added to
    _before_tool/_log_after_tool -- no network, no LLM. Confirms the
    real bug this fixes (execute_dataport_query succeeding without
    get_cyera_dataport_snowflake_context ever being called first) is now
    actually blocked, not just discouraged by the instruction text."""
    import agent as agent_module

    ok = True
    tc = _FakeToolContext()
    query_tool = _FakeTool(agent_module._QUERY_TOOL_NAME)
    context_tool = _FakeTool(agent_module._CONTEXT_TOOL_NAME)

    # 1. Before any context call: execute_dataport_query must be blocked,
    #    with a clear error telling the model what to do -- and the SQL
    #    guard must never even run (a valid, otherwise-allowed SELECT
    #    still gets rejected here, for the context reason, not a SQL one).
    result = agent_module._before_tool(query_tool, {"query": "select 1"}, tc)
    if result is None or "error" not in result or "context" not in result["error"].lower():
        print(f"FAILURE: expected execute_dataport_query to be blocked before context is loaded, got: {result}", file=sys.stderr)
        ok = False
    else:
        print("OK: execute_dataport_query is blocked before any context has been loaded")

    # 2. Loading ONLY the index must NOT satisfy the gate (it has no
    #    table/column names -- see module docstring).
    agent_module._before_tool(context_tool, {"file_name": "index"}, tc)
    agent_module._log_after_tool(context_tool, {"file_name": "index"}, tc, "some index listing")
    if tc.state.get(agent_module._CONTEXT_LOADED_STATE_KEY):
        print("FAILURE: file_name='index' should not satisfy the context gate", file=sys.stderr)
        ok = False
    result = agent_module._before_tool(query_tool, {"query": "select 1"}, tc)
    if result is None or "error" not in result:
        print("FAILURE: execute_dataport_query should still be blocked after only 'index' was loaded", file=sys.stderr)
        ok = False
    else:
        print("OK: loading only file_name='index' does not unlock the gate")

    # 3. Loading a REAL context file (or file_name=None) DOES satisfy the
    #    gate, and execute_dataport_query is allowed through afterward.
    agent_module._before_tool(context_tool, {"file_name": "dataport_schema.json"}, tc)
    agent_module._log_after_tool(context_tool, {"file_name": "dataport_schema.json"}, tc, "...schema content...")
    if not tc.state.get(agent_module._CONTEXT_LOADED_STATE_KEY):
        print("FAILURE: loading a real context file should satisfy the gate", file=sys.stderr)
        ok = False
    result = agent_module._before_tool(query_tool, {"query": "select 1"}, tc)
    if result is not None:
        print(f"FAILURE: execute_dataport_query should be allowed through after real context was loaded, got: {result}", file=sys.stderr)
        ok = False
    else:
        print("OK: loading a real context file unlocks the gate, and a valid query is then allowed through")

    return ok


def main() -> int:
    if not os.environ.get("CYERA_DATAPORT_MCP_TOKEN"):
        print(
            "FATAL: CYERA_DATAPORT_MCP_TOKEN not set. Copy .env.example to "
            ".env and fill in the Bearer token from the attached mcp.json.",
            file=sys.stderr,
        )
        return 1

    ok = check_sql_guard()
    ok = test_context_gate() and ok

    import agent  # noqa: E402
    from auth_middleware import IdentityPlatformAuthMiddleware  # noqa: E402
    from google.adk.a2a.utils.agent_to_a2a import to_a2a

    print(f"root_agent name:  {agent.root_agent.name}")
    print(f"root_agent model: {agent.root_agent.model}")
    print(f"MCP server URL:   {agent.CYERA_DATAPORT_MCP_URL}")

    a2a_app = to_a2a(agent.root_agent, host="localhost", port=8080, protocol="http")
    a2a_app.add_middleware(
        IdentityPlatformAuthMiddleware,
        project_id=os.environ.get("IDENTITY_PLATFORM_PROJECT_ID", "boris-scc-gcp-project"),
    )
    print(f"to_a2a() + auth middleware wrapping OK: {type(a2a_app).__module__}.{type(a2a_app).__name__}")

    async def check_tools():
        return await agent.cyera_toolset.get_tools()

    tools = asyncio.run(check_tools())
    print(f"McpToolset reached the deployed server: {len(tools)} tools available")
    names = sorted(t.name for t in tools)
    print(f"tools: {names}")
    if len(tools) == 0:
        print("FAILURE: expected > 0 tools", file=sys.stderr)
        return 1
    if "execute_dataport_query" not in names:
        print("FAILURE: expected execute_dataport_query among the tools", file=sys.stderr)
        ok = False

    # Verify the auth gate actually rejects an unauthenticated in-process
    # ASGI call -- using Starlette's own TestClient so this stays a local,
    # offline check (no real network request to a deployed URL).
    from starlette.testclient import TestClient

    with TestClient(a2a_app) as client:
        resp = client.get("/.well-known/agent-card.json")
        print(f"Unauthenticated GET /.well-known/agent-card.json -> {resp.status_code} (expected 200, public)")
        if resp.status_code != 200:
            print("FAILURE: Agent Card should be public", file=sys.stderr)
            ok = False

        resp = client.post("/", json={"jsonrpc": "2.0", "id": "1", "method": "message/send", "params": {}})
        print(f"Unauthenticated POST / -> {resp.status_code} (expected 401, gated)")
        if resp.status_code != 401:
            print("FAILURE: unauthenticated POST should be rejected with 401", file=sys.stderr)
            ok = False

    if not ok:
        return 1

    print("\nAll checks passed (auth ACCEPT path not covered -- needs a real Identity Platform ID token).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
