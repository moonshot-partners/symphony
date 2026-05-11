"""Anthropic auth resolution.

Precedence:
1. ``CLAUDE_CODE_OAUTH_TOKEN`` — long-lived token from `claude setup-token` (1 year)
2. ``ANTHROPIC_OAUTH_TOKEN`` — short-lived Claude Code session token
3. ``ANTHROPIC_API_KEY`` — standard API key
"""

import os


class AuthError(RuntimeError):
    pass


def resolve_auth_env() -> dict[str, str]:
    if token := os.environ.get("CLAUDE_CODE_OAUTH_TOKEN"):
        return {"CLAUDE_CODE_OAUTH_TOKEN": token}
    if oauth := os.environ.get("ANTHROPIC_OAUTH_TOKEN"):
        return {"ANTHROPIC_OAUTH_TOKEN": oauth}
    if api_key := os.environ.get("ANTHROPIC_API_KEY"):
        return {"ANTHROPIC_API_KEY": api_key}
    raise AuthError(
        "no Anthropic credentials: set CLAUDE_CODE_OAUTH_TOKEN, ANTHROPIC_OAUTH_TOKEN, or ANTHROPIC_API_KEY"
    )
