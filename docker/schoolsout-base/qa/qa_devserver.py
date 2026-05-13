"""`next dev` lifecycle helpers for the QA harness.

Extracted from `qa_helpers.py` so that file stays under the project length
limit. The agent doesn't import this module directly — it uses `qa_run()`
in `qa_helpers`, which delegates here for `dev_server` + `_resolve_app_dir`.

What lives here:
  * `_port_open` — fast TCP-level liveness check used as the first gate.
  * `_http_ready` — HTTP 200 poll. TCP open only means the socket is
    accepting — Next.js still compiles routes after that. Without HTTP 200
    we'd yield to assertions while `session.webm` records 30s of spinner.
  * `_resolve_app_dir` — `qa_run("fe-next-app", ...)` works whether the
    agent's cwd is the workspace root or `fe-next-app/`. Public-ish (used
    by `qa_run`); the others are module-private.
  * `_tail` — last N lines of a log file for error messages.
  * `dev_server` — context manager: start `npm run dev`, yield base URL,
    tear down on exit.
"""

from __future__ import annotations

import contextlib
import os
import socket
import subprocess
import time
import urllib.request


def _port_open(port: int) -> bool:
    with contextlib.closing(socket.socket(socket.AF_INET, socket.SOCK_STREAM)) as s:
        return s.connect_ex(("127.0.0.1", port)) == 0


def _http_ready(port: int, *, timeout: int = 60) -> bool:
    """Poll http://localhost:{port}/ until HTTP 200 or timeout expires.

    TCP-open (_port_open) only means the socket is accepting connections —
    Next.js is still compiling routes. HTTP 200 on / means at least one
    page rendered, i.e. the dev server is actually ready for assertions.
    Without this, session.webm starts recording a blank spinner for ~30s.
    """
    url = f"http://localhost:{port}/"
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=5) as r:
                if r.status == 200:
                    return True
        except Exception:
            pass
        time.sleep(2)
    return False


def _resolve_app_dir(app_dir: str) -> str:
    """Find the Next app regardless of where the agent ran `qa_check.py` from.

    The agent edits/tests/builds fe-next-app with the workspace's `fe-next-app/`
    as its cwd; the WORKFLOW sketch passes `qa_run("fe-next-app", ...)`. Accept
    both: a `<app_dir>/package.json` (cwd = workspace root), a `./package.json`
    (cwd = inside the app, the common case), or `../<app_dir>/package.json`.
    Returns an absolute path. Raises if none has a `package.json` — a clear
    error beats silently `mkdir`-ing a phantom dir and failing `npm run dev`.
    """
    for cand in (app_dir, ".", os.path.join("..", os.path.basename(app_dir.rstrip("/")))):
        if os.path.isfile(os.path.join(cand, "package.json")):
            return os.path.abspath(cand)
    raise RuntimeError(
        f"no Next app found: {app_dir!r}, '.' and '../{os.path.basename(app_dir.rstrip('/'))}' "
        f"all lack package.json (cwd={os.getcwd()}). Run qa_check.py from the workspace "
        f"or from inside the app dir."
    )


def _tail(path: str, n: int = 30) -> str:
    with contextlib.suppress(Exception):
        with open(path) as fh:
            return "".join(fh.readlines()[-n:]).rstrip()
    return "(log unavailable)"


@contextlib.contextmanager
def dev_server(app_dir: str, *, port: int, api_base: str,
               build_sha: str | None = None, ready_timeout: int = 240):
    """Start `npm run dev` for `app_dir` on `port`, pointed at the staging API,
    yield the base URL, and tear the process down on exit. If something is
    already listening on `port` (an earlier `next dev`), reuse it."""
    if _port_open(port):
        # TCP open but Next.js may still be compiling routes; wait for HTTP 200
        _http_ready(port)
        yield f"http://localhost:{port}"
        return

    app_dir = _resolve_app_dir(app_dir)
    env = {**os.environ, "PORT": str(port), "NEXT_PUBLIC_API_URL": api_base}
    if build_sha is not None:
        env["NEXT_PUBLIC_BUILD_SHA"] = build_sha
    log_path = os.path.join(app_dir, "qa-evidence", "next-dev.log")
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    log_fh = open(log_path, "w")
    proc = subprocess.Popen(
        ["npm", "run", "dev"], cwd=app_dir, env=env, stdout=log_fh, stderr=subprocess.STDOUT
    )
    try:
        deadline = time.time() + ready_timeout
        while time.time() < deadline:
            if _port_open(port):
                # TCP open != Next.js ready; poll HTTP 200 before yielding
                _http_ready(port)
                break
            if proc.poll() is not None:
                raise RuntimeError(
                    f"`npm run dev` (cwd={app_dir}) exited early (code {proc.returncode}). "
                    f"Last lines of {log_path}:\n{_tail(log_path)}"
                )
            time.sleep(2)
        else:
            raise RuntimeError(
                f"`next dev` not ready on :{port} after {ready_timeout}s (cwd={app_dir}). "
                f"Last lines of {log_path}:\n{_tail(log_path)}"
            )
        yield f"http://localhost:{port}"
    finally:
        proc.terminate()
        with contextlib.suppress(Exception):
            proc.wait(timeout=10)
        if proc.poll() is None:
            proc.kill()
        log_fh.close()
