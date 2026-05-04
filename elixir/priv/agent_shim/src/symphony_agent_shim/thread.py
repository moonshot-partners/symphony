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
from devflow_agent.config import compose_devflow_bundle
from devflow_agent.policy import Policy
from devflow_agent.spec_seed import IssueContext

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

    # --- devflow-agent integration (optional) ---
    devflow_ctx = params.get("devflowContext")
    devflow_session_id: str | None = None
    devflow_system_prompt: str | None = None
    devflow_hooks: dict | None = None
    if devflow_ctx:
        try:
            policy = Policy(devflow_ctx["policy"])
        except (KeyError, ValueError) as exc:
            return protocol.error(
                request_id=request_id,
                code=-32602,
                message=f"invalid devflowContext.policy: {exc}",
            )
        try:
            issue = IssueContext(
                identifier=devflow_ctx["issueIdentifier"],
                title=devflow_ctx["issueTitle"],
                url=devflow_ctx.get("issueUrl", ""),
            )
            devflow_root_path = Path(devflow_ctx["devflowRoot"])
        except KeyError as exc:
            return protocol.error(
                request_id=request_id,
                code=-32602,
                message=f"missing devflowContext field: {exc}",
            )
        bundle = await compose_devflow_bundle(
            issue=issue,
            cwd=Path(cwd),
            devflow_root=devflow_root_path,
            policy=policy,
            base_system_prompt=devflow_ctx.get("basePrompt", ""),
        )
        devflow_session_id = bundle.session_id
        devflow_system_prompt = bundle.system_prompt
        devflow_hooks = bundle.hooks

    options_kwargs: dict[str, Any] = {
        "cwd": Path(cwd),
        "permission_mode": sandbox_cfg.permission_mode,
        "mcp_servers": {"symphony": {"type": "sdk", "name": "symphony", "instance": mcp_server}},
        "env": env,
        "disallowed_tools": sandbox_cfg.disallowed_tools,
    }
    if devflow_hooks is not None:
        options_kwargs["hooks"] = devflow_hooks
    if devflow_system_prompt is not None:
        options_kwargs["system_prompt"] = devflow_system_prompt
    options = ClaudeAgentOptions(**options_kwargs)

    client = ClaudeSDKClient(options=options)
    try:
        await client.connect()
    except Exception as exc:  # noqa: BLE001 — surface SDK init failure as JSON-RPC error
        return protocol.error(
            request_id=request_id, code=-32603, message=f"SDK connect failed: {exc}"
        )

    thread_id = f"shim-{uuid.uuid4().hex[:12]}"
    registry.register(ThreadSession(thread_id=thread_id, client=client, auto_approve=auto_approve))

    response_payload: dict[str, Any] = {"thread": {"id": thread_id}}
    if devflow_session_id:
        response_payload["devflowSessionId"] = devflow_session_id
    return protocol.response(request_id=request_id, result=response_payload)
