"""Codex sandbox / approval policy → Claude Agent SDK options mapping.

Codex tiers (from Symphony's ``WORKFLOW.md``):
- ``workspace-write`` — write inside cwd, no network restrictions
- ``read-only`` — agent may read but not modify
- ``danger-full-access`` — bypass all permission gates

SDK has no named tiers; we approximate via ``permission_mode`` +
``disallowed_tools``. Network isolation is **not enforced** at the SDK level
— if a Symphony tier needs no-network, the operator must rely on host
firewall (the SDK gives no primitive for it).
"""

from dataclasses import dataclass, field


@dataclass
class SandboxConfig:
    permission_mode: str
    cwd: str
    disallowed_tools: list[str] = field(default_factory=list)
    additional_directories: list[str] = field(default_factory=list)


_TIERS = {
    "workspace-write": ("bypassPermissions", []),
    "read-only": ("default", ["Edit", "Write", "Bash"]),
    "danger-full-access": ("bypassPermissions", []),
}


def map_sandbox_tier(tier: str, *, cwd: str) -> SandboxConfig:
    if tier not in _TIERS:
        raise ValueError(f"unknown sandbox tier: {tier!r}")
    mode, disallowed = _TIERS[tier]
    return SandboxConfig(
        permission_mode=mode,
        cwd=cwd,
        disallowed_tools=list(disallowed),
    )


def map_approval_policy(policy: str | dict) -> tuple[bool, str | None]:
    """Return (auto_accept, deny_message_for_blocked_tool).

    ``"never"`` matches Symphony's ``Codex.AppServer.run_turn/4`` auto-approve
    branch (``auto_approve_requests = approval_policy == "never"``). Anything
    else means: shim must NOT auto-approve, must emit the JSON-RPC approval
    request and await Symphony's reply.
    """

    policy_str = policy if isinstance(policy, str) else policy.get("type", "")
    if policy_str == "never":
        return True, None
    return False, "operator approval required for this tool call"
