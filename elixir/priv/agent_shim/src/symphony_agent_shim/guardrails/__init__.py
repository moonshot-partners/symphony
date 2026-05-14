"""Stack-agnostic guardrail hooks for the Symphony agent.

These hooks plug into ``claude-agent-sdk``'s ``ClaudeAgentOptions(hooks=...)``
via ``HookMatcher``. They enforce a minimal safety baseline that applies to
every repository the agent touches, regardless of stack or ticket type.

See ``build_default_hooks`` for the canonical wiring.
"""

from __future__ import annotations

from claude_agent_sdk import HookMatcher

from symphony_agent_shim.guardrails.file_size_check import file_size_check
from symphony_agent_shim.guardrails.pre_edit_overwrite_guard import pre_edit_overwrite_guard
from symphony_agent_shim.guardrails.pre_push_gate import pre_push_gate
from symphony_agent_shim.guardrails.secrets_gate import secrets_gate
from symphony_agent_shim.guardrails.tdd_enforcer import tdd_enforcer


def build_default_hooks() -> dict[str, list[HookMatcher]]:
    """Returns the ``ClaudeAgentOptions.hooks`` dict for every Symphony thread."""
    return {
        "PreToolUse": [
            HookMatcher(matcher="Write|Edit|MultiEdit", hooks=[secrets_gate]),
            HookMatcher(matcher="Write|Edit|MultiEdit", hooks=[pre_edit_overwrite_guard]),
            HookMatcher(matcher="Write|Edit", hooks=[tdd_enforcer]),
            HookMatcher(matcher="Bash", hooks=[pre_push_gate]),
        ],
        "PostToolUse": [
            HookMatcher(matcher="Write|Edit|MultiEdit", hooks=[file_size_check]),
        ],
    }


__all__ = [
    "build_default_hooks",
    "file_size_check",
    "pre_edit_overwrite_guard",
    "pre_push_gate",
    "secrets_gate",
    "tdd_enforcer",
]
