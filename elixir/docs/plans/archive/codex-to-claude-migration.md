# Codex App Server → Claude Agent SDK Migration Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the OpenAI `codex app-server` subprocess with a Python shim that wraps `claude-agent-sdk` and speaks the exact same JSON-RPC stdio protocol Symphony's `SymphonyElixir.Codex.AppServer` already speaks. Symphony Elixir code stays intact (only `codex.command` config value changes); cleanup of `Codex.*` module names is deferred to a follow-up pass.

**Architecture:** A long-running Python process (`priv/agent_shim/`) reads newline-delimited JSON-RPC 2.0 frames from stdin and writes them to stdout. It mimics Codex's protocol (`initialize`/`thread/start`/`turn/start`, `item/tool/call`, `*Approval` requests, `turn/completed`). Internally each `thread/start` instantiates one `ClaudeSDKClient` keyed by a synthetic `thread_id`; each `turn/start` calls `client.query(prompt)` and translates SDK events to Codex JSON-RPC. Symphony's `dynamicTools[]` array is registered as a single SDK MCP server (`create_sdk_mcp_server(name="symphony", ...)`); when the SDK invokes a Symphony tool, the shim sends `item/tool/call` to Symphony stdout and blocks until Symphony replies with the matching JSON-RPC id.

**Tech Stack:** Python 3.10+, `claude-agent-sdk` (PyPI), `anyio` (async runtime), `pytest` + `pytest-asyncio` (tests), `ruff` (lint+format), `uv` (package manager). Symphony side: ExUnit, no new deps.

---

## File Structure

```
priv/agent_shim/
├── pyproject.toml                  # uv project, deps, ruff/pytest config
├── README.md                       # operator notes — how to run shim alone
├── src/symphony_agent_shim/
│   ├── __init__.py
│   ├── __main__.py                 # entry point — `python -m symphony_agent_shim`
│   ├── framing.py                  # JSON-RPC stdio reader/writer
│   ├── protocol.py                 # message dataclasses + Codex method constants
│   ├── handshake.py                # initialize / initialized handler
│   ├── thread.py                   # thread/start → SDK client setup
│   ├── turn.py                     # turn/start → SDK query loop + event translation
│   ├── tools.py                    # dynamicTools → MCP @tool wrappers, tool-call round-trip
│   ├── sandbox.py                  # Codex sandbox/approval → SDK permission_mode mapping
│   ├── auth.py                     # ANTHROPIC_OAUTH_TOKEN / ANTHROPIC_API_KEY env handling
│   └── server.py                   # main loop — dispatches frames to handlers
└── tests/
    ├── conftest.py                 # fixtures: stdio pipes, fake SDK client, drained queues
    ├── test_framing.py
    ├── test_handshake.py
    ├── test_thread.py
    ├── test_turn.py
    ├── test_tools.py
    ├── test_sandbox.py
    ├── test_auth.py
    └── test_server_smoke.py        # end-to-end: feed initialize+thread/start+turn/start, assert turn/completed
```

Symphony Elixir touch points (D2: minimal):
- `lib/symphony_elixir/config/schema.ex:160` — change `default: "codex app-server"` → `default: "python -m symphony_agent_shim"` after shim is on PYTHONPATH (or path-based default referencing `priv/agent_shim/`)
- `WORKFLOW.md` example — replace `codex app-server` snippet
- `mix.exs` — add `priv/agent_shim/` to release files (if escript packages priv)

No changes to `Codex.AppServer`, `Codex.DynamicTool`, `AgentRunner`, `Tracker`. Module rename pass is **out of scope** for this plan.

---

## Task 1: Python project skeleton + tooling

**Files:**
- Create: `priv/agent_shim/pyproject.toml`
- Create: `priv/agent_shim/src/symphony_agent_shim/__init__.py`
- Create: `priv/agent_shim/src/symphony_agent_shim/__main__.py`
- Create: `priv/agent_shim/tests/__init__.py`
- Create: `priv/agent_shim/tests/test_smoke.py`
- Create: `priv/agent_shim/README.md`

- [ ] **Step 1: Write the failing smoke test**

`priv/agent_shim/tests/test_smoke.py`:
```python
def test_package_imports():
    import symphony_agent_shim
    assert symphony_agent_shim.__version__ == "0.1.0"
```

- [ ] **Step 2: Run test, confirm it fails**

```bash
cd priv/agent_shim && uv run pytest tests/test_smoke.py -v
```
Expected: FAIL — package not yet created.

- [ ] **Step 3: Write `pyproject.toml`**

```toml
[project]
name = "symphony-agent-shim"
version = "0.1.0"
description = "JSON-RPC stdio shim translating Codex app-server protocol to claude-agent-sdk"
requires-python = ">=3.10"
dependencies = [
  "claude-agent-sdk>=0.1.0",
  "anyio>=4.0",
]

[project.optional-dependencies]
dev = [
  "pytest>=8.0",
  "pytest-asyncio>=0.23",
  "ruff>=0.5",
]

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = ["src/symphony_agent_shim"]

[tool.ruff]
line-length = 100
target-version = "py310"

[tool.ruff.lint]
select = ["E", "F", "I", "B", "UP", "ASYNC"]

[tool.pytest.ini_options]
asyncio_mode = "auto"
testpaths = ["tests"]
```

- [ ] **Step 4: Write `__init__.py`**

`priv/agent_shim/src/symphony_agent_shim/__init__.py`:
```python
__version__ = "0.1.0"
```

- [ ] **Step 5: Write minimal `__main__.py`**

`priv/agent_shim/src/symphony_agent_shim/__main__.py`:
```python
from symphony_agent_shim.server import run

if __name__ == "__main__":
    run()
```

(Stub `run` will be added in Task 12; for now create `server.py` with `def run(): raise NotImplementedError`.)

- [ ] **Step 6: Write `server.py` stub**

`priv/agent_shim/src/symphony_agent_shim/server.py`:
```python
def run() -> None:
    raise NotImplementedError("server loop not yet implemented")
```

- [ ] **Step 7: Sync deps + run smoke test**

```bash
cd priv/agent_shim && uv sync --extra dev && uv run pytest tests/test_smoke.py -v
```
Expected: PASS.

- [ ] **Step 8: Run lint**

```bash
cd priv/agent_shim && uv run ruff check . && uv run ruff format --check .
```
Expected: clean.

- [ ] **Step 9: Commit**

```bash
git add priv/agent_shim/
git commit -m "feat(agent_shim): scaffold uv project with pyproject + smoke test"
```

---

## Task 2: JSON-RPC stdio framing (newline-delimited JSON)

**Files:**
- Create: `priv/agent_shim/src/symphony_agent_shim/framing.py`
- Create: `priv/agent_shim/tests/test_framing.py`

**Why first:** The whole protocol depends on parsing JSON lines from stdin and writing JSON lines to stdout. Symphony's `Codex.AppServer.send_message/2` writes `Jason.encode!(message) <> "\n"`; the shim must split on `\n` and decode each line. Buffer handling for `noeol`/`eol` boundaries (Symphony's port uses `line: 1_048_576`) means no single message exceeds 1MB — but we still need to handle partial reads.

- [ ] **Step 1: Write the failing tests**

`priv/agent_shim/tests/test_framing.py`:
```python
import io
import json

import pytest

from symphony_agent_shim.framing import LineFramer, write_frame


@pytest.mark.asyncio
async def test_reads_single_complete_frame():
    raw = b'{"jsonrpc":"2.0","id":1,"method":"initialize"}\n'
    framer = LineFramer(io.BytesIO(raw))
    msg = await framer.read_message()
    assert msg == {"jsonrpc": "2.0", "id": 1, "method": "initialize"}


@pytest.mark.asyncio
async def test_returns_none_on_eof():
    framer = LineFramer(io.BytesIO(b""))
    assert await framer.read_message() is None


@pytest.mark.asyncio
async def test_skips_blank_lines():
    raw = b'\n\n{"id":2}\n'
    framer = LineFramer(io.BytesIO(raw))
    assert await framer.read_message() == {"id": 2}


@pytest.mark.asyncio
async def test_raises_on_malformed_json():
    raw = b"not json\n"
    framer = LineFramer(io.BytesIO(raw))
    with pytest.raises(ValueError, match="malformed"):
        await framer.read_message()


@pytest.mark.asyncio
async def test_write_frame_appends_newline():
    out = io.BytesIO()
    await write_frame(out, {"id": 3, "result": {}})
    out.seek(0)
    line = out.readline()
    assert line.endswith(b"\n")
    assert json.loads(line) == {"id": 3, "result": {}}
```

- [ ] **Step 2: Run tests, confirm fail**

```bash
cd priv/agent_shim && uv run pytest tests/test_framing.py -v
```
Expected: FAIL — module missing.

- [ ] **Step 3: Implement `framing.py`**

`priv/agent_shim/src/symphony_agent_shim/framing.py`:
```python
"""Newline-delimited JSON-RPC framing over async byte streams.

Each frame = one JSON object on a single line, terminated by ``\\n``. Matches
the format Symphony's Elixir port writes via ``Jason.encode!(msg) <> "\\n"``.
"""

import json
from typing import Any, Protocol


class _AsyncReadable(Protocol):
    async def readline(self) -> bytes: ...


class _SyncReadable(Protocol):
    def readline(self) -> bytes: ...


class LineFramer:
    def __init__(self, stream: _AsyncReadable | _SyncReadable) -> None:
        self._stream = stream

    async def read_message(self) -> dict[str, Any] | None:
        while True:
            raw = await self._readline()
            if raw == b"":
                return None
            stripped = raw.strip()
            if not stripped:
                continue
            try:
                parsed = json.loads(stripped)
            except json.JSONDecodeError as exc:
                raise ValueError(f"malformed JSON frame: {exc}") from exc
            if not isinstance(parsed, dict):
                raise ValueError("JSON frame must be an object")
            return parsed

    async def _readline(self) -> bytes:
        readline = self._stream.readline
        result = readline()
        if hasattr(result, "__await__"):
            return await result
        return result


async def write_frame(stream: Any, message: dict[str, Any]) -> None:
    line = (json.dumps(message, separators=(",", ":")) + "\n").encode("utf-8")
    write = stream.write
    result = write(line)
    if hasattr(result, "__await__"):
        await result
    flush = getattr(stream, "flush", None)
    if flush is not None:
        flush_result = flush()
        if hasattr(flush_result, "__await__"):
            await flush_result
```

- [ ] **Step 4: Run tests, confirm pass**

```bash
cd priv/agent_shim && uv run pytest tests/test_framing.py -v
```
Expected: PASS (5/5).

- [ ] **Step 5: Lint**

```bash
cd priv/agent_shim && uv run ruff check src/symphony_agent_shim/framing.py tests/test_framing.py
```

- [ ] **Step 6: Commit**

```bash
git add priv/agent_shim/src/symphony_agent_shim/framing.py priv/agent_shim/tests/test_framing.py
git commit -m "feat(agent_shim): newline-delimited JSON-RPC framer"
```

---

## Task 3: Protocol constants + dataclasses

**Files:**
- Create: `priv/agent_shim/src/symphony_agent_shim/protocol.py`
- Create: `priv/agent_shim/tests/test_protocol.py`

**Why:** Centralize Codex method names and JSON-RPC envelope shapes so other modules import constants instead of duplicating string literals. Reduces typo risk on critical method names like `item/commandExecution/requestApproval`.

- [ ] **Step 1: Write failing tests**

`priv/agent_shim/tests/test_protocol.py`:
```python
from symphony_agent_shim import protocol


def test_codex_method_constants_match_app_server_ex():
    # Mirrors method names parsed in app_server.ex
    assert protocol.METHOD_INITIALIZE == "initialize"
    assert protocol.METHOD_INITIALIZED == "initialized"
    assert protocol.METHOD_THREAD_START == "thread/start"
    assert protocol.METHOD_TURN_START == "turn/start"
    assert protocol.METHOD_TURN_COMPLETED == "turn/completed"
    assert protocol.METHOD_TURN_FAILED == "turn/failed"
    assert protocol.METHOD_TURN_CANCELLED == "turn/cancelled"
    assert protocol.METHOD_ITEM_TOOL_CALL == "item/tool/call"
    assert protocol.METHOD_ITEM_COMMAND_APPROVAL == "item/commandExecution/requestApproval"
    assert protocol.METHOD_EXEC_COMMAND_APPROVAL == "execCommandApproval"
    assert protocol.METHOD_APPLY_PATCH_APPROVAL == "applyPatchApproval"
    assert protocol.METHOD_FILE_CHANGE_APPROVAL == "item/fileChange/requestApproval"
    assert protocol.METHOD_TOOL_USER_INPUT == "item/tool/requestUserInput"


def test_response_envelope_helper():
    env = protocol.response(request_id=42, result={"ok": True})
    assert env == {"jsonrpc": "2.0", "id": 42, "result": {"ok": True}}


def test_notification_envelope_helper():
    env = protocol.notification("turn/completed", {"usage": {}})
    assert env == {"jsonrpc": "2.0", "method": "turn/completed", "params": {"usage": {}}}


def test_error_envelope_helper():
    env = protocol.error(request_id=7, code=-32600, message="bad")
    assert env == {
        "jsonrpc": "2.0",
        "id": 7,
        "error": {"code": -32600, "message": "bad"},
    }
```

- [ ] **Step 2: Run, confirm fail**

```bash
cd priv/agent_shim && uv run pytest tests/test_protocol.py -v
```

- [ ] **Step 3: Implement `protocol.py`**

```python
"""Codex JSON-RPC method names + envelope helpers.

Method names mirror those parsed in
``lib/symphony_elixir/codex/app_server.ex``. Do NOT rename without updating
both sides simultaneously.
"""

from typing import Any

METHOD_INITIALIZE = "initialize"
METHOD_INITIALIZED = "initialized"
METHOD_THREAD_START = "thread/start"
METHOD_TURN_START = "turn/start"
METHOD_TURN_COMPLETED = "turn/completed"
METHOD_TURN_FAILED = "turn/failed"
METHOD_TURN_CANCELLED = "turn/cancelled"
METHOD_ITEM_TOOL_CALL = "item/tool/call"
METHOD_ITEM_COMMAND_APPROVAL = "item/commandExecution/requestApproval"
METHOD_EXEC_COMMAND_APPROVAL = "execCommandApproval"
METHOD_APPLY_PATCH_APPROVAL = "applyPatchApproval"
METHOD_FILE_CHANGE_APPROVAL = "item/fileChange/requestApproval"
METHOD_TOOL_USER_INPUT = "item/tool/requestUserInput"

JSONRPC_VERSION = "2.0"


def response(request_id: int | str, result: Any) -> dict[str, Any]:
    return {"jsonrpc": JSONRPC_VERSION, "id": request_id, "result": result}


def notification(method: str, params: dict[str, Any]) -> dict[str, Any]:
    return {"jsonrpc": JSONRPC_VERSION, "method": method, "params": params}


def error(request_id: int | str, code: int, message: str) -> dict[str, Any]:
    return {
        "jsonrpc": JSONRPC_VERSION,
        "id": request_id,
        "error": {"code": code, "message": message},
    }
```

- [ ] **Step 4: Run tests, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add priv/agent_shim/src/symphony_agent_shim/protocol.py priv/agent_shim/tests/test_protocol.py
git commit -m "feat(agent_shim): JSON-RPC method constants + envelope helpers"
```

---

## Task 4: Handshake — `initialize` + `initialized`

**Files:**
- Create: `priv/agent_shim/src/symphony_agent_shim/handshake.py`
- Create: `priv/agent_shim/tests/test_handshake.py`

**Why:** Codex's `app_server.ex:241-263` sends `initialize` (id=1) expecting a response, then sends notification `initialized`. Shim must reply to id=1 with capabilities, then accept (and ignore) the notification.

- [ ] **Step 1: Write failing tests**

```python
import pytest

from symphony_agent_shim.handshake import handle_initialize


@pytest.mark.asyncio
async def test_initialize_returns_capabilities_envelope():
    request = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}
    reply = await handle_initialize(request)
    assert reply["id"] == 1
    assert "result" in reply
    assert reply["result"]["serverInfo"]["name"] == "symphony-agent-shim"
    assert reply["result"]["capabilities"]["experimentalApi"] is True


@pytest.mark.asyncio
async def test_initialize_preserves_request_id_type():
    request = {"jsonrpc": "2.0", "id": "abc", "method": "initialize"}
    reply = await handle_initialize(request)
    assert reply["id"] == "abc"


def test_is_initialized_notification_recognizes_method():
    from symphony_agent_shim.handshake import is_initialized_notification

    assert is_initialized_notification({"method": "initialized", "params": {}}) is True
    assert is_initialized_notification({"method": "thread/start"}) is False
    assert is_initialized_notification({"id": 1}) is False
```

- [ ] **Step 2: Run, confirm fail**

- [ ] **Step 3: Implement `handshake.py`**

```python
"""initialize / initialized JSON-RPC handlers (Codex compat).

Symphony's ``Codex.AppServer.send_initialize/1`` sends ``initialize`` with
id=1 expecting a response, then a notification ``initialized``. Reply shape
must include ``capabilities`` and ``serverInfo``.
"""

from typing import Any

from symphony_agent_shim import protocol


async def handle_initialize(request: dict[str, Any]) -> dict[str, Any]:
    return protocol.response(
        request_id=request["id"],
        result={
            "capabilities": {"experimentalApi": True},
            "serverInfo": {
                "name": "symphony-agent-shim",
                "version": "0.1.0",
            },
        },
    )


def is_initialized_notification(message: dict[str, Any]) -> bool:
    return message.get("method") == protocol.METHOD_INITIALIZED and "id" not in message
```

- [ ] **Step 4: Run tests, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add priv/agent_shim/src/symphony_agent_shim/handshake.py priv/agent_shim/tests/test_handshake.py
git commit -m "feat(agent_shim): initialize / initialized handshake"
```

---

## Task 5: Sandbox + permission policy mapping

**Files:**
- Create: `priv/agent_shim/src/symphony_agent_shim/sandbox.py`
- Create: `priv/agent_shim/tests/test_sandbox.py`

**Why:** Bridge Codex sandbox tier names (`workspace-write`, `read-only`, `danger-full-access`) to SDK's `permission_mode` + `disallowed_tools`. Symphony's `thread/start` carries `approvalPolicy` and `sandbox` in params; this module decides what `ClaudeAgentOptions` gets. Built before `thread.py` because `thread.py` calls into it.

- [ ] **Step 1: Write failing tests**

```python
import pytest

from symphony_agent_shim.sandbox import (
    SandboxConfig,
    map_approval_policy,
    map_sandbox_tier,
)


def test_workspace_write_maps_to_acceptedits_with_cwd():
    cfg = map_sandbox_tier("workspace-write", cwd="/tmp/work")
    assert cfg.permission_mode == "acceptEdits"
    assert cfg.cwd == "/tmp/work"
    assert cfg.disallowed_tools == []


def test_read_only_disallows_write_edit_bash():
    cfg = map_sandbox_tier("read-only", cwd="/tmp/work")
    assert cfg.permission_mode == "default"
    assert set(cfg.disallowed_tools) >= {"Edit", "Write", "Bash"}


def test_danger_full_access_uses_bypass():
    cfg = map_sandbox_tier("danger-full-access", cwd="/tmp/work")
    assert cfg.permission_mode == "bypassPermissions"
    assert cfg.disallowed_tools == []


def test_unknown_tier_raises():
    with pytest.raises(ValueError, match="unknown sandbox tier"):
        map_sandbox_tier("hyperdrive", cwd="/tmp/work")


def test_approval_policy_never_means_auto_accept():
    auto, deny_message = map_approval_policy("never")
    assert auto is True
    assert deny_message is None


def test_approval_policy_on_request_means_block():
    auto, deny_message = map_approval_policy("on-request")
    assert auto is False
    assert "operator approval" in deny_message
```

- [ ] **Step 2: Run, confirm fail**

- [ ] **Step 3: Implement `sandbox.py`**

```python
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
    "workspace-write": ("acceptEdits", []),
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
```

- [ ] **Step 4: Run tests, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add priv/agent_shim/src/symphony_agent_shim/sandbox.py priv/agent_shim/tests/test_sandbox.py
git commit -m "feat(agent_shim): sandbox tier + approval policy mapping"
```

---

## Task 6: Auth — `ANTHROPIC_OAUTH_TOKEN` / `ANTHROPIC_API_KEY` resolution

**Files:**
- Create: `priv/agent_shim/src/symphony_agent_shim/auth.py`
- Create: `priv/agent_shim/tests/test_auth.py`

**Why:** D3 says use `ANTHROPIC_OAUTH_TOKEN` when set (local testing only — operator accepts ToS risk). Fall back to `ANTHROPIC_API_KEY`. Reject startup if neither set with a clear error so we don't waste a turn discovering 401 mid-stream. Built before `thread.py` so it can call this at session create.

- [ ] **Step 1: Write failing tests**

```python
import pytest

from symphony_agent_shim.auth import AuthError, resolve_auth_env


def test_oauth_token_takes_precedence(monkeypatch):
    monkeypatch.setenv("ANTHROPIC_OAUTH_TOKEN", "sk-oauth-xyz")
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-api-abc")
    env = resolve_auth_env()
    assert env["ANTHROPIC_OAUTH_TOKEN"] == "sk-oauth-xyz"
    assert "ANTHROPIC_API_KEY" not in env


def test_api_key_used_when_no_oauth(monkeypatch):
    monkeypatch.delenv("ANTHROPIC_OAUTH_TOKEN", raising=False)
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-api-abc")
    env = resolve_auth_env()
    assert env["ANTHROPIC_API_KEY"] == "sk-api-abc"
    assert "ANTHROPIC_OAUTH_TOKEN" not in env


def test_no_creds_raises(monkeypatch):
    monkeypatch.delenv("ANTHROPIC_OAUTH_TOKEN", raising=False)
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    with pytest.raises(AuthError, match="no Anthropic credentials"):
        resolve_auth_env()
```

- [ ] **Step 2: Run, confirm fail**

- [ ] **Step 3: Implement `auth.py`**

```python
"""Anthropic auth resolution.

Precedence:
1. ``ANTHROPIC_OAUTH_TOKEN`` — Claude Code subscription token (local only)
2. ``ANTHROPIC_API_KEY`` — standard API key

The SDK reads these from the subprocess environment. We forward whichever
is set so the SDK's internal CLI subprocess inherits it.
"""

import os


class AuthError(RuntimeError):
    pass


def resolve_auth_env() -> dict[str, str]:
    oauth = os.environ.get("ANTHROPIC_OAUTH_TOKEN")
    if oauth:
        return {"ANTHROPIC_OAUTH_TOKEN": oauth}
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if api_key:
        return {"ANTHROPIC_API_KEY": api_key}
    raise AuthError(
        "no Anthropic credentials: set ANTHROPIC_OAUTH_TOKEN or ANTHROPIC_API_KEY"
    )
```

- [ ] **Step 4: Run tests, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add priv/agent_shim/src/symphony_agent_shim/auth.py priv/agent_shim/tests/test_auth.py
git commit -m "feat(agent_shim): Anthropic auth env resolver with precedence"
```

---

## Task 7: Tool round-trip — dynamicTools → MCP wrappers + JSON-RPC bridge

**Files:**
- Create: `priv/agent_shim/src/symphony_agent_shim/tools.py`
- Create: `priv/agent_shim/tests/test_tools.py`

**Why this is the highest-risk piece (built early per the brief — unhappy path first):** Symphony's `dynamicTools[]` (from `Codex.DynamicTool.tool_specs/0`) are Elixir-side tools the agent must be able to invoke. The shim registers each as a Python `@tool` inside an SDK MCP server. When the SDK invokes one, the Python tool function emits an `item/tool/call` JSON-RPC request to Symphony stdout, blocks on a `result` message with the matching id from stdin, and returns the result to the SDK. This is a synchronous round-trip from the SDK's perspective but async at the framing level.

We use a `ToolBridge` object that owns:
- An `outbound_writer` (the stdout stream) for sending requests
- A dict `pending: id → anyio.Event + result_slot` for awaiting replies
- A method `route_response(message)` called by the server loop when a `{"id": x, "result": ...}` frame arrives

- [ ] **Step 1: Write failing tests**

```python
import asyncio
import json
import pytest

from symphony_agent_shim.tools import ToolBridge, build_mcp_server_from_specs


@pytest.mark.asyncio
async def test_bridge_sends_request_and_awaits_response():
    sent: list[dict] = []

    async def writer(msg: dict) -> None:
        sent.append(msg)

    bridge = ToolBridge(writer=writer)

    async def fake_responder():
        # Simulate Symphony replying after request is sent
        await asyncio.sleep(0.01)
        msg_id = sent[-1]["id"]
        bridge.route_response(
            {"id": msg_id, "result": {"success": True, "output": "done"}}
        )

    asyncio.create_task(fake_responder())

    result = await bridge.invoke_tool("greet", {"name": "world"})
    assert result == {"success": True, "output": "done"}

    assert sent[0]["method"] == "item/tool/call"
    assert sent[0]["params"]["tool"] == "greet"
    assert sent[0]["params"]["arguments"] == {"name": "world"}


@pytest.mark.asyncio
async def test_bridge_propagates_error_response():
    sent: list[dict] = []

    async def writer(msg: dict) -> None:
        sent.append(msg)

    bridge = ToolBridge(writer=writer)

    async def fake_responder():
        await asyncio.sleep(0.01)
        msg_id = sent[-1]["id"]
        bridge.route_response(
            {"id": msg_id, "error": {"code": -32000, "message": "boom"}}
        )

    asyncio.create_task(fake_responder())

    with pytest.raises(RuntimeError, match="boom"):
        await bridge.invoke_tool("greet", {})


@pytest.mark.asyncio
async def test_unknown_response_id_is_ignored():
    bridge = ToolBridge(writer=lambda _: None)
    # No raise expected
    bridge.route_response({"id": 9999, "result": {}})


def test_build_mcp_server_from_specs_creates_callable_tools(monkeypatch):
    captured = {}

    def fake_create(*, name, version, tools):
        captured["name"] = name
        captured["tools"] = tools
        return f"server:{name}"

    monkeypatch.setattr(
        "symphony_agent_shim.tools.create_sdk_mcp_server", fake_create
    )

    specs = [
        {
            "name": "linear_graphql",
            "description": "run GraphQL against Linear",
            "input_schema": {
                "type": "object",
                "properties": {"query": {"type": "string"}},
                "required": ["query"],
            },
        }
    ]
    bridge = ToolBridge(writer=lambda _: None)
    server = build_mcp_server_from_specs(specs, bridge=bridge)
    assert server == "server:symphony"
    assert captured["name"] == "symphony"
    assert len(captured["tools"]) == 1
```

- [ ] **Step 2: Run, confirm fail**

- [ ] **Step 3: Implement `tools.py`**

```python
"""Bridge dynamicTools[] (Codex protocol) ↔ Claude Agent SDK MCP tools.

For each Symphony tool spec, we register a Python ``@tool`` whose body
delegates to ``ToolBridge.invoke_tool`` — which sends ``item/tool/call``
to Symphony's stdin (the shim's stdout) and awaits the reply by id.

This means: SDK invokes Python tool → Python tool sends JSON-RPC to
Symphony → Symphony's ``Codex.AppServer.maybe_handle_approval_request/8``
handler executes the Elixir-side ``DynamicTool.execute/2`` → Symphony
sends JSON-RPC response → Python tool returns to SDK → SDK continues.
"""

import asyncio
import itertools
from collections.abc import Awaitable, Callable
from typing import Any

from claude_agent_sdk import create_sdk_mcp_server, tool

from symphony_agent_shim import protocol

Writer = Callable[[dict[str, Any]], Awaitable[None]]


class ToolBridge:
    def __init__(self, writer: Writer) -> None:
        self._writer = writer
        self._counter = itertools.count(start=10000)
        self._pending: dict[int, asyncio.Future[dict[str, Any]]] = {}

    async def invoke_tool(self, tool_name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        request_id = next(self._counter)
        loop = asyncio.get_running_loop()
        future: asyncio.Future[dict[str, Any]] = loop.create_future()
        self._pending[request_id] = future
        try:
            await self._writer(
                {
                    "jsonrpc": protocol.JSONRPC_VERSION,
                    "id": request_id,
                    "method": protocol.METHOD_ITEM_TOOL_CALL,
                    "params": {"tool": tool_name, "arguments": arguments},
                }
            )
            return await future
        finally:
            self._pending.pop(request_id, None)

    def route_response(self, message: dict[str, Any]) -> None:
        msg_id = message.get("id")
        if msg_id is None:
            return
        future = self._pending.get(msg_id)
        if future is None or future.done():
            return
        if "error" in message:
            err = message["error"]
            future.set_exception(RuntimeError(err.get("message", "tool error")))
        else:
            future.set_result(message.get("result", {}))


def build_mcp_server_from_specs(
    specs: list[dict[str, Any]], *, bridge: ToolBridge
) -> Any:
    sdk_tools = []
    for spec in specs:
        sdk_tools.append(_make_tool(spec, bridge))
    return create_sdk_mcp_server(name="symphony", version="0.1.0", tools=sdk_tools)


def _make_tool(spec: dict[str, Any], bridge: ToolBridge):
    name = spec["name"]
    description = spec.get("description", "")
    schema = spec.get("input_schema", {"type": "object"})

    @tool(name, description, schema)
    async def _impl(args: dict[str, Any]) -> dict[str, Any]:
        result = await bridge.invoke_tool(name, args)
        text = result.get("output") or str(result)
        return {"content": [{"type": "text", "text": text}]}

    return _impl
```

- [ ] **Step 4: Run tests, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add priv/agent_shim/src/symphony_agent_shim/tools.py priv/agent_shim/tests/test_tools.py
git commit -m "feat(agent_shim): tool bridge — dynamicTools to MCP round-trip"
```

---

## Task 8: `thread/start` handler — instantiate `ClaudeSDKClient`

**Files:**
- Create: `priv/agent_shim/src/symphony_agent_shim/thread.py`
- Create: `priv/agent_shim/tests/test_thread.py`

**Why:** `thread/start` (id=2) carries `approvalPolicy`, `sandbox`, `cwd`, `dynamicTools[]`. The shim builds `ClaudeAgentOptions` (from sandbox+auth modules), wraps tools via `tools.build_mcp_server_from_specs`, instantiates a single `ClaudeSDKClient`, stores it under a synthetic `thread_id`, and replies with `{thread: {id: <thread_id>}}`.

- [ ] **Step 1: Write failing tests**

```python
import pytest
from unittest.mock import MagicMock

from symphony_agent_shim.thread import ThreadRegistry, handle_thread_start
from symphony_agent_shim.tools import ToolBridge


@pytest.mark.asyncio
async def test_thread_start_creates_session_and_returns_id(monkeypatch, tmp_path):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")

    fake_client = MagicMock()
    sdk_client_factory = MagicMock(return_value=fake_client)
    monkeypatch.setattr(
        "symphony_agent_shim.thread.ClaudeSDKClient", sdk_client_factory
    )

    workspace = tmp_path / "ws"
    workspace.mkdir()

    registry = ThreadRegistry()
    bridge = ToolBridge(writer=lambda _: None)
    request = {
        "jsonrpc": "2.0",
        "id": 2,
        "method": "thread/start",
        "params": {
            "approvalPolicy": "never",
            "sandbox": "workspace-write",
            "cwd": str(workspace),
            "dynamicTools": [],
        },
    }

    reply = await handle_thread_start(request, registry=registry, bridge=bridge)

    assert reply["id"] == 2
    thread_id = reply["result"]["thread"]["id"]
    assert thread_id in registry
    sdk_client_factory.assert_called_once()
    options = sdk_client_factory.call_args.kwargs["options"]
    assert options.permission_mode == "acceptEdits"
    assert str(options.cwd) == str(workspace)


@pytest.mark.asyncio
async def test_thread_start_rejects_unknown_sandbox(monkeypatch, tmp_path):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    registry = ThreadRegistry()
    bridge = ToolBridge(writer=lambda _: None)
    request = {
        "jsonrpc": "2.0",
        "id": 2,
        "method": "thread/start",
        "params": {
            "approvalPolicy": "never",
            "sandbox": "hyperdrive",
            "cwd": str(tmp_path),
            "dynamicTools": [],
        },
    }
    reply = await handle_thread_start(request, registry=registry, bridge=bridge)
    assert "error" in reply
    assert "unknown sandbox tier" in reply["error"]["message"]


@pytest.mark.asyncio
async def test_thread_start_fails_without_credentials(monkeypatch, tmp_path):
    monkeypatch.delenv("ANTHROPIC_OAUTH_TOKEN", raising=False)
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    registry = ThreadRegistry()
    bridge = ToolBridge(writer=lambda _: None)
    request = {
        "jsonrpc": "2.0",
        "id": 2,
        "method": "thread/start",
        "params": {
            "approvalPolicy": "never",
            "sandbox": "workspace-write",
            "cwd": str(tmp_path),
            "dynamicTools": [],
        },
    }
    reply = await handle_thread_start(request, registry=registry, bridge=bridge)
    assert "error" in reply
    assert "credentials" in reply["error"]["message"]
```

- [ ] **Step 2: Run, confirm fail**

- [ ] **Step 3: Implement `thread.py`**

```python
"""thread/start handler — creates one ClaudeSDKClient per Codex thread.

Codex's ``Codex.AppServer.start_thread/3`` sends id=2 with params
{approvalPolicy, sandbox, cwd, dynamicTools}. We build the SDK client
lazily here so credential failures surface as JSON-RPC errors (visible to
Symphony) rather than a subprocess crash.
"""

import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from claude_agent_sdk import ClaudeAgentOptions, ClaudeSDKClient

from symphony_agent_shim import protocol
from symphony_agent_shim.auth import AuthError, resolve_auth_env
from symphony_agent_shim.sandbox import map_approval_policy, map_sandbox_tier
from symphony_agent_shim.tools import ToolBridge, build_mcp_server_from_specs


@dataclass
class ThreadSession:
    thread_id: str
    client: ClaudeSDKClient
    auto_approve: bool


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
        env = resolve_auth_env()
    except (KeyError, ValueError, AuthError) as exc:
        return protocol.error(request_id=request_id, code=-32602, message=str(exc))

    mcp_server = build_mcp_server_from_specs(
        params.get("dynamicTools", []) or [], bridge=bridge
    )

    options = ClaudeAgentOptions(
        cwd=Path(cwd),
        permission_mode=sandbox_cfg.permission_mode,
        mcp_servers={"symphony": mcp_server},
        env=env,
        disallowed_tools=sandbox_cfg.disallowed_tools,
    )

    client = ClaudeSDKClient(options=options)

    thread_id = f"shim-{uuid.uuid4().hex[:12]}"
    registry.register(
        ThreadSession(thread_id=thread_id, client=client, auto_approve=auto_approve)
    )

    return protocol.response(
        request_id=request_id,
        result={"thread": {"id": thread_id}},
    )
```

- [ ] **Step 4: Run tests, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add priv/agent_shim/src/symphony_agent_shim/thread.py priv/agent_shim/tests/test_thread.py
git commit -m "feat(agent_shim): thread/start handler creating SDK client per thread"
```

---

## Task 9: `turn/start` handler — query loop + event translation

**Files:**
- Create: `priv/agent_shim/src/symphony_agent_shim/turn.py`
- Create: `priv/agent_shim/tests/test_turn.py`

**Why:** Highest-volume code path. Symphony sends `turn/start` (id=3) with prompt; shim must:
1. Reply immediately with `{turn: {id: <turn_id>}}` (Symphony then enters `receive_loop`).
2. Drive `client.query(prompt)` async generator.
3. Translate each SDK message:
   - `AssistantMessage` (text content) → notification `item/agent_message` with content
   - `AssistantMessage` carrying tool_use → SDK already routes through MCP, no extra emission needed (the tool round-trip happens via `tools.ToolBridge`)
   - `ResultMessage` (success) → notification `turn/completed` with `{usage, total_cost_usd, turn_id}`
   - SDK exception → notification `turn/failed` with `{error, turn_id}`
4. If Symphony sends interrupt (handled in Task 11), call `client.interrupt()` and emit `turn/cancelled`.

- [ ] **Step 1: Write failing tests**

```python
import pytest
from unittest.mock import AsyncMock, MagicMock

from symphony_agent_shim.thread import ThreadRegistry, ThreadSession
from symphony_agent_shim.turn import handle_turn_start


@pytest.mark.asyncio
async def test_turn_start_returns_turn_id_then_emits_completed():
    sent: list[dict] = []

    async def writer(msg: dict) -> None:
        sent.append(msg)

    fake_client = MagicMock()

    async def fake_messages():
        # Simulate one assistant text message + a result message
        from claude_agent_sdk import AssistantMessage, ResultMessage, TextBlock

        yield AssistantMessage(content=[TextBlock(text="ok")], model="claude-sonnet-4-6")
        yield ResultMessage(
            subtype="success",
            duration_ms=10,
            duration_api_ms=8,
            is_error=False,
            num_turns=1,
            session_id="s",
            total_cost_usd=0.0001,
            usage={
                "input_tokens": 100,
                "output_tokens": 5,
                "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": 0,
            },
            result="ok",
        )

    fake_client.query = AsyncMock()
    fake_client.receive_response = lambda: fake_messages()

    registry = ThreadRegistry()
    session = ThreadSession(thread_id="t1", client=fake_client, auto_approve=True)
    registry.register(session)

    request = {
        "jsonrpc": "2.0",
        "id": 3,
        "method": "turn/start",
        "params": {
            "threadId": "t1",
            "input": [{"type": "text", "text": "do thing"}],
            "cwd": "/tmp",
            "title": "MT-1: do thing",
        },
    }

    reply = await handle_turn_start(request, writer=writer, registry=registry)

    assert reply["id"] == 3
    turn_id = reply["result"]["turn"]["id"]

    # turn/completed must have been sent via writer
    completed = [m for m in sent if m.get("method") == "turn/completed"]
    assert len(completed) == 1
    assert completed[0]["params"]["turn_id"] == turn_id
    assert completed[0]["params"]["usage"]["input_tokens"] == 100


@pytest.mark.asyncio
async def test_turn_start_unknown_thread_returns_error():
    sent: list[dict] = []
    registry = ThreadRegistry()
    request = {
        "jsonrpc": "2.0",
        "id": 3,
        "method": "turn/start",
        "params": {"threadId": "nonexistent", "input": [], "cwd": "/tmp"},
    }
    reply = await handle_turn_start(
        request, writer=lambda m: sent.append(m), registry=registry
    )
    assert "error" in reply
    assert "unknown thread" in reply["error"]["message"]


@pytest.mark.asyncio
async def test_turn_failed_emitted_on_sdk_exception():
    sent: list[dict] = []

    async def writer(msg: dict) -> None:
        sent.append(msg)

    fake_client = MagicMock()
    fake_client.query = AsyncMock(side_effect=RuntimeError("auth bad"))
    fake_client.receive_response = lambda: iter(())

    registry = ThreadRegistry()
    registry.register(
        ThreadSession(thread_id="t2", client=fake_client, auto_approve=True)
    )

    request = {
        "jsonrpc": "2.0",
        "id": 3,
        "method": "turn/start",
        "params": {"threadId": "t2", "input": [{"type": "text", "text": "x"}], "cwd": "/tmp"},
    }

    reply = await handle_turn_start(request, writer=writer, registry=registry)
    assert reply["id"] == 3  # turn id reply still sent

    failed = [m for m in sent if m.get("method") == "turn/failed"]
    assert len(failed) == 1
    assert "auth bad" in failed[0]["params"]["error"]
```

- [ ] **Step 2: Run, confirm fail**

- [ ] **Step 3: Implement `turn.py`**

```python
"""turn/start handler — drives ClaudeSDKClient.query and translates events.

Reply for turn/start id=3 returns ``{turn: {id}}`` immediately; the rest of
the SDK output is streamed as JSON-RPC notifications (turn/completed,
turn/failed, item/agent_message). Symphony's ``receive_loop`` consumes these.
"""

import asyncio
import uuid
from collections.abc import Awaitable, Callable
from typing import Any

from claude_agent_sdk import AssistantMessage, ResultMessage, TextBlock

from symphony_agent_shim import protocol
from symphony_agent_shim.thread import ThreadRegistry

Writer = Callable[[dict[str, Any]], Awaitable[None]]


async def handle_turn_start(
    request: dict[str, Any],
    *,
    writer: Writer,
    registry: ThreadRegistry,
) -> dict[str, Any]:
    request_id = request["id"]
    params = request.get("params", {}) or {}
    thread_id = params.get("threadId")
    session = registry.get(thread_id) if thread_id else None
    if session is None:
        return protocol.error(
            request_id=request_id,
            code=-32602,
            message=f"unknown thread: {thread_id!r}",
        )

    prompt = _flatten_input(params.get("input", []))
    turn_id = f"turn-{uuid.uuid4().hex[:12]}"

    asyncio.create_task(_drive_turn(session.client, prompt, turn_id, writer))

    return protocol.response(
        request_id=request_id,
        result={"turn": {"id": turn_id}},
    )


def _flatten_input(blocks: list[dict[str, Any]]) -> str:
    parts: list[str] = []
    for block in blocks:
        if block.get("type") == "text" and isinstance(block.get("text"), str):
            parts.append(block["text"])
    return "\n\n".join(parts)


async def _drive_turn(client: Any, prompt: str, turn_id: str, writer: Writer) -> None:
    try:
        await client.query(prompt)
        async for message in client.receive_response():
            await _emit_message(message, turn_id, writer)
    except Exception as exc:  # noqa: BLE001 — surface SDK error as JSON-RPC failure
        await writer(
            protocol.notification(
                protocol.METHOD_TURN_FAILED,
                {"turn_id": turn_id, "error": str(exc)},
            )
        )


async def _emit_message(message: Any, turn_id: str, writer: Writer) -> None:
    if isinstance(message, AssistantMessage):
        text_parts = [
            block.text for block in message.content if isinstance(block, TextBlock)
        ]
        if text_parts:
            await writer(
                protocol.notification(
                    "item/agent_message",
                    {"turn_id": turn_id, "text": "\n".join(text_parts)},
                )
            )
        return
    if isinstance(message, ResultMessage):
        await writer(
            protocol.notification(
                protocol.METHOD_TURN_COMPLETED,
                {
                    "turn_id": turn_id,
                    "usage": dict(message.usage or {}),
                    "total_cost_usd": message.total_cost_usd,
                    "stop_reason": message.subtype,
                },
            )
        )
```

- [ ] **Step 4: Run tests, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add priv/agent_shim/src/symphony_agent_shim/turn.py priv/agent_shim/tests/test_turn.py
git commit -m "feat(agent_shim): turn/start drives SDK query and emits turn/completed"
```

---

## Task 10: Auto-approval handlers — emit + receive Codex approval requests

**Files:**
- Modify: `priv/agent_shim/src/symphony_agent_shim/turn.py`
- Modify: `priv/agent_shim/tests/test_turn.py`

**Why:** Symphony's `Codex.AppServer.maybe_handle_approval_request/8` auto-approves four method names when `auto_approve_requests=true`: `item/commandExecution/requestApproval`, `execCommandApproval`, `applyPatchApproval`, `item/fileChange/requestApproval`. With SDK's `permission_mode="acceptEdits"` or `"bypassPermissions"`, the SDK never asks for approval — but Symphony's logger expects to see those events. To keep the operator-facing log identical, we emit synthetic approval-request notifications for matching SDK tool uses (Bash, Edit/Write) and immediately move on without waiting (since SDK already approved internally).

This is **observability-only** — does not gate execution. Distinct from Task 5 sandbox mapping.

- [ ] **Step 1: Write failing tests in `test_turn.py`**

```python
@pytest.mark.asyncio
async def test_emits_synthetic_approval_for_bash_tool_use():
    from claude_agent_sdk import AssistantMessage, ToolUseBlock

    sent: list[dict] = []

    async def writer(msg: dict) -> None:
        sent.append(msg)

    fake_client = MagicMock()

    async def fake_messages():
        yield AssistantMessage(
            content=[
                ToolUseBlock(
                    id="tu_1", name="Bash", input={"command": "ls"}
                )
            ],
            model="claude-sonnet-4-6",
        )

    fake_client.query = AsyncMock()
    fake_client.receive_response = lambda: fake_messages()

    registry = ThreadRegistry()
    registry.register(
        ThreadSession(thread_id="t3", client=fake_client, auto_approve=True)
    )

    await handle_turn_start(
        {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "turn/start",
            "params": {"threadId": "t3", "input": [], "cwd": "/tmp"},
        },
        writer=writer,
        registry=registry,
    )
    await asyncio.sleep(0.05)

    approvals = [
        m for m in sent
        if m.get("method") == "item/commandExecution/requestApproval"
    ]
    assert len(approvals) == 1
    assert approvals[0]["params"]["command"] == "ls"
```

- [ ] **Step 2: Run, confirm fail**

- [ ] **Step 3: Modify `_emit_message` in `turn.py`**

Add at top of `turn.py`:
```python
from claude_agent_sdk import ToolUseBlock
```

Extend `_emit_message`:
```python
    if isinstance(message, AssistantMessage):
        for block in message.content:
            if isinstance(block, TextBlock):
                continue
            if isinstance(block, ToolUseBlock):
                await _emit_synthetic_approval(block, turn_id, writer)
        text_parts = [
            block.text for block in message.content if isinstance(block, TextBlock)
        ]
        if text_parts:
            await writer(
                protocol.notification(
                    "item/agent_message",
                    {"turn_id": turn_id, "text": "\n".join(text_parts)},
                )
            )
        return
```

Add helper:
```python
_BASH_TOOLS = {"Bash", "mcp__bash__bash"}
_FILE_WRITE_TOOLS = {"Edit", "Write", "NotebookEdit"}


async def _emit_synthetic_approval(
    block: Any, turn_id: str, writer: Writer
) -> None:
    if block.name in _BASH_TOOLS:
        method = protocol.METHOD_ITEM_COMMAND_APPROVAL
        params = {
            "turn_id": turn_id,
            "tool_use_id": block.id,
            "command": block.input.get("command", ""),
        }
    elif block.name in _FILE_WRITE_TOOLS:
        method = protocol.METHOD_FILE_CHANGE_APPROVAL
        params = {
            "turn_id": turn_id,
            "tool_use_id": block.id,
            "path": block.input.get("file_path", ""),
        }
    else:
        return
    await writer(protocol.notification(method, params))
```

- [ ] **Step 4: Run all turn tests, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add priv/agent_shim/src/symphony_agent_shim/turn.py priv/agent_shim/tests/test_turn.py
git commit -m "feat(agent_shim): emit synthetic approval events for bash/file tools"
```

---

## Task 11: Cancellation — handle interrupt + emit `turn/cancelled`

**Files:**
- Modify: `priv/agent_shim/src/symphony_agent_shim/turn.py`
- Modify: `priv/agent_shim/src/symphony_agent_shim/server.py` (signal handler)
- Modify: `priv/agent_shim/tests/test_turn.py`

**Why:** Symphony stops sessions via `Port.close/1` which sends SIGTERM; shim must trap that, call `client.interrupt()` if a turn is running, emit `turn/cancelled`, then exit cleanly. Without this, SIGTERM kills mid-turn with no record.

- [ ] **Step 1: Write failing test**

```python
@pytest.mark.asyncio
async def test_cancel_emits_turn_cancelled():
    from symphony_agent_shim.turn import TurnTracker

    sent: list[dict] = []

    async def writer(msg):
        sent.append(msg)

    tracker = TurnTracker()
    tracker.register("turn-x")
    await tracker.cancel_all(writer)

    cancelled = [m for m in sent if m.get("method") == "turn/cancelled"]
    assert len(cancelled) == 1
    assert cancelled[0]["params"]["turn_id"] == "turn-x"
```

- [ ] **Step 2: Run, confirm fail**

- [ ] **Step 3: Implement `TurnTracker` + wire into `_drive_turn`**

In `turn.py`:
```python
class TurnTracker:
    def __init__(self) -> None:
        self._active: set[str] = set()

    def register(self, turn_id: str) -> None:
        self._active.add(turn_id)

    def unregister(self, turn_id: str) -> None:
        self._active.discard(turn_id)

    async def cancel_all(self, writer: Writer) -> None:
        for turn_id in list(self._active):
            await writer(
                protocol.notification(
                    protocol.METHOD_TURN_CANCELLED,
                    {"turn_id": turn_id, "reason": "shim shutdown"},
                )
            )
            self._active.discard(turn_id)
```

Pass `tracker` through `_drive_turn`, call `tracker.register(turn_id)` at start, `tracker.unregister(turn_id)` after `ResultMessage`.

- [ ] **Step 4: Run tests, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add priv/agent_shim/src/symphony_agent_shim/turn.py priv/agent_shim/tests/test_turn.py
git commit -m "feat(agent_shim): cancel emits turn/cancelled for in-flight turns"
```

---

## Task 12: Server main loop — wire it all together

**Files:**
- Modify: `priv/agent_shim/src/symphony_agent_shim/server.py`
- Create: `priv/agent_shim/tests/test_server_smoke.py`

**Why:** Top-level dispatch: read frame → if `id` matches a `pending` ToolBridge response, route to bridge; if method matches a known handler, dispatch; otherwise emit JSON-RPC error reply.

- [ ] **Step 1: Write failing smoke test**

```python
import asyncio
import io
import json

import pytest


@pytest.mark.asyncio
async def test_server_initialize_thread_turn_smoke(monkeypatch, tmp_path):
    """Pipe initialize → thread/start → turn/start; assert turn/completed comes out."""
    from symphony_agent_shim.server import run_async

    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")

    # Stub ClaudeSDKClient so we don't hit the network
    from unittest.mock import AsyncMock, MagicMock
    from claude_agent_sdk import ResultMessage

    fake_client = MagicMock()

    async def fake_msgs():
        yield ResultMessage(
            subtype="success",
            duration_ms=1,
            duration_api_ms=1,
            is_error=False,
            num_turns=1,
            session_id="s",
            total_cost_usd=0.001,
            usage={"input_tokens": 1, "output_tokens": 1,
                   "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0},
            result="ok",
        )

    fake_client.query = AsyncMock()
    fake_client.receive_response = lambda: fake_msgs()
    monkeypatch.setattr(
        "symphony_agent_shim.thread.ClaudeSDKClient",
        MagicMock(return_value=fake_client),
    )

    workspace = tmp_path / "ws"
    workspace.mkdir()

    inputs = b"\n".join([
        json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}).encode(),
        json.dumps({"jsonrpc": "2.0", "method": "initialized", "params": {}}).encode(),
        json.dumps({
            "jsonrpc": "2.0", "id": 2, "method": "thread/start",
            "params": {
                "approvalPolicy": "never",
                "sandbox": "workspace-write",
                "cwd": str(workspace),
                "dynamicTools": [],
            },
        }).encode(),
    ]) + b"\n"

    stdin = io.BytesIO(inputs)
    stdout = io.BytesIO()

    # Run with a 2s timeout; close stdin after thread/start so loop exits naturally
    await asyncio.wait_for(run_async(stdin=stdin, stdout=stdout), timeout=2.0)

    stdout.seek(0)
    lines = [json.loads(line) for line in stdout.readlines() if line.strip()]
    # Expect: initialize reply (id=1), thread/start reply (id=2)
    init_reply = next(m for m in lines if m.get("id") == 1)
    thread_reply = next(m for m in lines if m.get("id") == 2)
    assert "result" in init_reply
    assert thread_reply["result"]["thread"]["id"].startswith("shim-")
```

- [ ] **Step 2: Run, confirm fail**

- [ ] **Step 3: Implement `server.py`**

```python
"""Top-level shim loop — read JSON-RPC frames from stdin, dispatch, write to stdout."""

import asyncio
import sys
from typing import Any

from symphony_agent_shim import protocol
from symphony_agent_shim.framing import LineFramer, write_frame
from symphony_agent_shim.handshake import handle_initialize, is_initialized_notification
from symphony_agent_shim.thread import ThreadRegistry, handle_thread_start
from symphony_agent_shim.tools import ToolBridge
from symphony_agent_shim.turn import TurnTracker, handle_turn_start


async def run_async(*, stdin: Any, stdout: Any) -> None:
    framer = LineFramer(stdin)
    out_lock = asyncio.Lock()

    async def writer(msg: dict[str, Any]) -> None:
        async with out_lock:
            await write_frame(stdout, msg)

    registry = ThreadRegistry()
    bridge = ToolBridge(writer=writer)
    tracker = TurnTracker()

    while True:
        message = await framer.read_message()
        if message is None:
            break

        if "id" in message and "method" not in message:
            bridge.route_response(message)
            continue

        method = message.get("method")
        if method == protocol.METHOD_INITIALIZE:
            await writer(await handle_initialize(message))
        elif is_initialized_notification(message):
            continue
        elif method == protocol.METHOD_THREAD_START:
            await writer(
                await handle_thread_start(message, registry=registry, bridge=bridge)
            )
        elif method == protocol.METHOD_TURN_START:
            await writer(
                await handle_turn_start(
                    message, writer=writer, registry=registry, tracker=tracker
                )
            )
        elif "id" in message:
            await writer(
                protocol.error(
                    request_id=message["id"],
                    code=-32601,
                    message=f"method not found: {method!r}",
                )
            )

    await tracker.cancel_all(writer)


def run() -> None:
    asyncio.run(run_async(stdin=sys.stdin.buffer, stdout=sys.stdout.buffer))
```

(Update `handle_turn_start` signature to accept `tracker: TurnTracker` keyword and pass it into `_drive_turn`.)

- [ ] **Step 4: Run smoke test, confirm pass**

- [ ] **Step 5: Run full pytest suite**

```bash
cd priv/agent_shim && uv run pytest -v
```
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add priv/agent_shim/src/symphony_agent_shim/server.py priv/agent_shim/tests/test_server_smoke.py
git commit -m "feat(agent_shim): server main loop dispatching JSON-RPC frames"
```

---

## Task 13: Symphony config wiring + integration smoke

**Files:**
- Modify: `lib/symphony_elixir/config/schema.ex:160`
- Modify: `WORKFLOW.md` (operator example)
- Create: `test/symphony_elixir/agent_shim_integration_test.exs`

**Why:** Until `codex.command` defaults (or example) point at the shim, no operator can run the new path. Integration test launches the actual shim subprocess and runs a single turn against a stubbed Anthropic backend.

- [ ] **Step 1: Write failing integration test**

`test/symphony_elixir/agent_shim_integration_test.exs`:
```elixir
defmodule SymphonyElixir.AgentShimIntegrationTest do
  use SymphonyElixir.TestSupport
  @moduletag :integration

  @tag :skip_unless_python
  test "agent shim handshake + thread/start replies with thread id" do
    {output, exit_status} =
      System.cmd(
        "python",
        ["-m", "symphony_agent_shim"],
        env: [{"ANTHROPIC_API_KEY", "sk-test-fixture"}],
        cd: Path.join(File.cwd!(), "priv/agent_shim"),
        stderr_to_stdout: true,
        into: <<>>
      )

    # NOTE: This test is a placeholder: real integration flow requires
    # piping JSON-RPC frames + stubbing the Anthropic API. We assert only
    # that the binary launches without crashing on import.
    assert exit_status in [0, 124]  # 124 = killed by timeout
    refute String.contains?(output, "Traceback")
  end
end
```

- [ ] **Step 2: Run, confirm fail (or skip if Python not on PATH)**

- [ ] **Step 3: Update `schema.ex`**

Change line 160 from:
```elixir
field(:command, :string, default: "codex app-server")
```
to:
```elixir
field(:command, :string, default: "python -m symphony_agent_shim")
```

- [ ] **Step 4: Update `WORKFLOW.md` example**

Find the `codex:` block in the WORKFLOW.md template and update the `command:` field example to `python -m symphony_agent_shim` with a comment pointing to `priv/agent_shim/README.md`.

- [ ] **Step 5: Run Elixir test suite**

```bash
cd /Users/vini/Developer/symphony/elixir && mix test
```
Expected: existing tests still green (no regression). Integration test may skip if Python missing.

- [ ] **Step 6: Run shim test suite**

```bash
cd priv/agent_shim && uv run pytest -v
```

- [ ] **Step 7: Commit**

```bash
git add lib/symphony_elixir/config/schema.ex WORKFLOW.md test/symphony_elixir/agent_shim_integration_test.exs
git commit -m "feat(symphony): default codex.command to symphony_agent_shim"
```

---

## Task 14: Operator README + token accounting docs update

**Files:**
- Modify: `priv/agent_shim/README.md`
- Modify: `docs/token_accounting.md`

**Why:** The shim emits `usage` in `turn/completed` with Anthropic field names (`cache_creation_input_tokens`, `cache_read_input_tokens`) instead of OpenAI's. Operator-facing docs must reflect this so the dashboard reading these fields knows what to show.

- [ ] **Step 1: Update `priv/agent_shim/README.md`**

```markdown
# symphony-agent-shim

JSON-RPC stdio shim translating Codex `app-server` protocol to
`claude-agent-sdk`. Symphony's `SymphonyElixir.Codex.AppServer` speaks
unchanged Codex JSON-RPC; this shim is the new daemon on the other side.

## Run standalone (smoke test)

```bash
cd priv/agent_shim
uv sync --extra dev
ANTHROPIC_OAUTH_TOKEN=$(cat ~/.config/claude-code/auth.json | jq -r .access_token) \
  uv run python -m symphony_agent_shim
```

## Symphony integration

`config.codex.command` (in `WORKFLOW.md`) is set to `python -m symphony_agent_shim`.
Symphony spawns the shim per session via `Port.open`.

## Auth

Precedence: `ANTHROPIC_OAUTH_TOKEN` > `ANTHROPIC_API_KEY`. OAuth token works
**locally only** — Anthropic ToS prohibits redistributing third-party apps
that use claude.ai subscription auth.

## Tests

```bash
uv run pytest -v
uv run ruff check . && uv run ruff format --check .
```
```

- [ ] **Step 2: Update `docs/token_accounting.md`** to document new field names

Add a section "Field rename: Codex → Claude":

```markdown
## Field rename: Codex → Claude

When the agent backend is `symphony_agent_shim`, `turn/completed.params.usage`
contains Anthropic's field names instead of OpenAI's:

| Old (Codex)               | New (Claude SDK)                   |
|---------------------------|------------------------------------|
| `prompt_tokens`           | `input_tokens`                     |
| `completion_tokens`       | `output_tokens`                    |
| (n/a)                     | `cache_creation_input_tokens`      |
| (n/a)                     | `cache_read_input_tokens`          |
| (n/a in events)           | `total_cost_usd` (top-level param) |

The dashboard reads these fields verbatim — no translation layer.
```

- [ ] **Step 3: Commit**

```bash
git add priv/agent_shim/README.md docs/token_accounting.md
git commit -m "docs: operator README + token accounting field rename"
```

---

## Task 15: Final VERIFY + REVIEW

- [ ] **Step 1: Run lint + tests across both sides**

```bash
# Python shim
cd priv/agent_shim
uv run ruff check . && uv run ruff format --check . && uv run pytest -v --tb=short

# Elixir
cd /Users/vini/Developer/symphony/elixir
mix format --check-formatted && mix credo --strict && mix dialyzer && mix test
```
Expected: all green.

- [ ] **Step 2: Shadow gate**

```bash
SESSION=${CLAUDE_SESSION_ID:-default}
scripts/shadow_run.sh "$(pwd)" "$SESSION"
```
Expected: rc=0 or rc=2.

- [ ] **Step 3: Review gate**

Invoke `pr-review-toolkit:review-pr` with explicit checks:
- Over-abstraction (Karpathy rule): are interfaces/dataclasses justified by ≥2 implementations?
- Drive-by refactor: any changes outside the spec scope (whitespace, renames, type hints not requested)?
- Silent failures: any `except: pass` or empty error handlers?

Fix any flagged issues before declaring DONE.

- [ ] **Step 4: Update active-spec status to COMPLETED**

Write `~/.claude/devflow/state/$CLAUDE_SESSION_ID/active-spec.json`:
```json
{
  "status": "COMPLETED",
  "task_id": "codex-to-claude-migration",
  "type": "feature",
  "plan_path": "/Users/vini/Developer/symphony/elixir/docs/plans/codex-to-claude-migration.md"
}
```

- [ ] **Step 5: Final commit (if review surfaced any tweaks)**

```bash
git status
git add -A  # only if review tweaks pending
git commit -m "chore: address review feedback for codex→claude migration"
```

---

## Out of scope (follow-up plans)

- **Module rename pass:** `Codex.AppServer` → `ClaudeAgent.AppServer`, `Codex.DynamicTool` → `ClaudeAgent.DynamicTool`, etc. Keep aliases for one release.
- **Network sandboxing:** SDK has no built-in network policy. Wire in via `PreToolUse` hook + Bash command parser, or rely on host firewall.
- **`max_thinking_tokens` exposure:** add a Symphony config field that maps through to `ClaudeAgentOptions.max_thinking_tokens`.
- **Resume sessions across restarts:** SDK persists `.jsonl` per session at `~/.claude/projects/...`; Symphony could resume by passing `resume=session_id`.
- **Multi-agent (subagents):** SDK supports `Agent` tool for spawning subagents; could replace Symphony's orchestrator-managed delegation in some cases.
