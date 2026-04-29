"""End-to-end smoke against the real Anthropic API.

Runs initialize -> thread/start -> turn/start with a trivial prompt and prints
all events received until turn/completed. Validates the Codex -> Claude migration
plumbing without any repo cloning or PR creation.

Usage:
    cd priv/agent_shim
    ANTHROPIC_OAUTH_TOKEN=... uv run python scripts/smoke_real.py
    # or
    ANTHROPIC_API_KEY=sk-ant-... uv run python scripts/smoke_real.py

Exit codes:
    0 — turn/completed received
    1 — protocol error or turn/failed
    2 — auth missing
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def build_thread_start_request(request_id: int, cwd: str) -> dict:
    """Build a thread/start JSON-RPC request matching the shim's contract.

    The shim expects camelCase keys (`approvalPolicy`, `dynamicTools`) and
    requires `cwd`. Returning a pure dict here keeps the protocol shape
    testable without spawning the subprocess.
    """
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "thread/start",
        "params": {
            "cwd": cwd,
            "sandbox": "danger-full-access",
            "approvalPolicy": "never",
            "dynamicTools": [],
        },
    }


def build_turn_start_request(request_id: int, thread_id: str, prompt: str) -> dict:
    """Build a turn/start JSON-RPC request matching the shim's contract."""
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "turn/start",
        "params": {
            "threadId": thread_id,
            "input": [{"type": "text", "text": prompt}],
        },
    }


def main() -> int:
    if not (os.environ.get("ANTHROPIC_OAUTH_TOKEN") or os.environ.get("ANTHROPIC_API_KEY")):
        print("error: set ANTHROPIC_OAUTH_TOKEN or ANTHROPIC_API_KEY", file=sys.stderr)
        return 2

    shim_root = Path(__file__).resolve().parent.parent
    proc = subprocess.Popen(
        [sys.executable, "-m", "symphony_agent_shim"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=sys.stderr,
        cwd=shim_root,
        env=os.environ.copy(),
        bufsize=0,
    )
    assert proc.stdin is not None and proc.stdout is not None

    def send(payload: dict) -> None:
        line = json.dumps(payload) + "\n"
        proc.stdin.write(line.encode())
        proc.stdin.flush()
        print(f">>> {payload.get('method', payload.get('id'))}", flush=True)

    def read_one(timeout_s: float = 60.0) -> dict | None:
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            line = proc.stdout.readline()
            if not line:
                return None
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                print(f"!!! malformed: {line!r}", file=sys.stderr)
        return None

    workdir = tempfile.mkdtemp(prefix="symphony-smoke-")

    try:
        send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
        init_resp = read_one()
        print(f"<<< initialize: {json.dumps(init_resp)[:200]}", flush=True)

        send({"jsonrpc": "2.0", "method": "initialized", "params": {}})

        send(build_thread_start_request(request_id=2, cwd=workdir))
        thread_resp = read_one()
        print(f"<<< thread/start: {json.dumps(thread_resp)[:200]}", flush=True)
        if not thread_resp or "error" in thread_resp:
            print("error: thread/start failed", file=sys.stderr)
            return 1
        thread_id = thread_resp.get("result", {}).get("thread", {}).get("id")
        if not thread_id:
            print("error: thread/start missing thread.id in response", file=sys.stderr)
            return 1

        send(
            build_turn_start_request(
                request_id=3,
                thread_id=thread_id,
                prompt="Reply with exactly the word PONG and nothing else.",
            )
        )
        turn_resp = read_one()
        print(f"<<< turn/start: {json.dumps(turn_resp)[:200]}", flush=True)
        if not turn_resp or "error" in turn_resp:
            print("error: turn/start failed", file=sys.stderr)
            return 1

        completed = False
        for _ in range(200):
            evt = read_one(timeout_s=120.0)
            if evt is None:
                print("!!! eof before turn/completed", file=sys.stderr)
                return 1
            method = evt.get("method")
            if method == "turn/completed":
                completed = True
                usage = evt.get("params", {}).get("usage", {})
                print(f"<<< turn/completed usage={json.dumps(usage)}", flush=True)
                break
            if method == "turn/failed":
                print(f"!!! turn/failed: {json.dumps(evt)}", file=sys.stderr)
                return 1
            print(f"<<< {method or evt.get('id')}", flush=True)

        if not completed:
            print("!!! event budget exhausted without turn/completed", file=sys.stderr)
            return 1
        return 0
    finally:
        proc.stdin.close()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


if __name__ == "__main__":
    sys.exit(main())
