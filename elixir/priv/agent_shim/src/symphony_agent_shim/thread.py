"""thread/start handler — creates one ClaudeSDKClient per Codex thread.

Codex's ``Codex.AppServer.start_thread/3`` sends id=2 with params
{approvalPolicy, sandbox, cwd, dynamicTools}. We build the SDK client
lazily here so credential failures surface as JSON-RPC errors (visible to
Symphony) rather than a subprocess crash.
"""

import asyncio
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from claude_agent_sdk import ClaudeAgentOptions, ClaudeSDKClient

from symphony_agent_shim import protocol
from symphony_agent_shim.auth import AuthError, resolve_auth_env
from symphony_agent_shim.auth_github_app import GitHubAppAuthError, resolve_git_env
from symphony_agent_shim.sandbox import map_approval_policy, map_sandbox_tier
from symphony_agent_shim.tools import ToolBridge, build_mcp_server_from_specs


@dataclass
class ThreadSession:
    thread_id: str
    client: ClaudeSDKClient
    auto_approve: bool
    active_task: asyncio.Task | None = field(default=None)


class ThreadRegistry:
    def __init__(self) -> None:
        self._threads: dict[str, ThreadSession] = {}

    def __contains__(self, thread_id: str) -> bool:
        return thread_id in self._threads

    def register(self, session: ThreadSession) -> None:
        self._threads[session.thread_id] = session

    def get(self, thread_id: str) -> ThreadSession | None:
        return self._threads.get(thread_id)

    def remove(self, thread_id: str) -> None:
        self._threads.pop(thread_id, None)


async def handle_thread_start(
    request: dict[str, Any],
    *,
    registry: ThreadRegistry,
    bridge: ToolBridge,
) -> dict[str, Any]:
    request_id = request["id"]
    params = request.get("params", {}) or {}

    try:
        cwd = params["cwd"]
        sandbox_cfg = map_sandbox_tier(params["sandbox"], cwd=cwd)
        auto_approve, _ = map_approval_policy(params.get("approvalPolicy", "never"))
        env = {**resolve_auth_env(), **resolve_git_env()}
    except (KeyError, ValueError, AuthError, GitHubAppAuthError) as exc:
        return protocol.error(request_id=request_id, code=-32602, message=str(exc))

    mcp_server = build_mcp_server_from_specs(params.get("dynamicTools", []) or [], bridge=bridge)

    options = ClaudeAgentOptions(
        cwd=Path(cwd),
        permission_mode=sandbox_cfg.permission_mode,
        mcp_servers={"symphony": {"type": "sdk", "name": "symphony", "instance": mcp_server}},
        env=env,
        disallowed_tools=sandbox_cfg.disallowed_tools,
    )

    client = ClaudeSDKClient(options=options)
    try:
        await client.connect()
    except Exception as exc:  # noqa: BLE001 — surface SDK init failure as JSON-RPC error
        return protocol.error(
            request_id=request_id, code=-32603, message=f"SDK connect failed: {exc}"
        )

    thread_id = f"shim-{uuid.uuid4().hex[:12]}"
    registry.register(ThreadSession(thread_id=thread_id, client=client, auto_approve=auto_approve))

    return protocol.response(
        request_id=request_id,
        result={"thread": {"id": thread_id}},
    )
