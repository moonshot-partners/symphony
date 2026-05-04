"""One-shot CLI that walks the operator through the GitHub App manifest flow.

The flow:

1. Build a manifest describing the desired App (name, permissions, redirect).
2. Open a browser tab with an HTML form that auto-submits the manifest to
   ``https://github.com/settings/apps/new`` (operator clicks once).
3. After GitHub creates the App, it redirects to our local callback with a
   short-lived ``code`` we exchange via ``POST /app-manifests/{code}/conversions``.
4. Persist the returned PEM (chmod 600) and an env file at
   ``~/.symphony/github-app.env``.
5. Print the install URL + a Slack message template the operator can DM to an
   org owner. Once approval lands, the operator re-runs the CLI with
   ``--finalize <installation_id>`` (or ``--discover-install <org>``) to write
   the final ``SYMPHONY_GITHUB_APP_INSTALLATION_ID`` to the env file.

This module is entirely synchronous and import-light so the bootstrap CLI can
run without the rest of the shim.
"""

from __future__ import annotations

import argparse
import json
import secrets
import socket
import sys
import time
import urllib.error
import urllib.request
import webbrowser
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from textwrap import dedent
from urllib.parse import parse_qs, urlparse

GITHUB_API = "https://api.github.com"
DEFAULT_CALLBACK_PORT = 8765
DEFAULT_CONFIG_DIR = Path.home() / ".symphony"
# Cap the callback wait so an abandoned browser doesn't hang the CLI forever.
CALLBACK_TIMEOUT_SECONDS = 300


class BootstrapError(RuntimeError):
    pass


@dataclass(frozen=True)
class ExchangeResult:
    app_id: int
    slug: str
    html_url: str
    pem_path: Path
    env_path: Path


# --- Manifest construction ---


def build_manifest(
    *,
    name: str,
    homepage_url: str,
    callback_port: int,
) -> dict:
    """Return the JSON manifest GitHub will turn into a real App."""

    return {
        "name": name,
        "url": homepage_url,
        "redirect_url": f"http://127.0.0.1:{callback_port}/callback",
        "callback_urls": [f"http://127.0.0.1:{callback_port}/callback"],
        "public": False,
        "default_permissions": {
            "contents": "write",
            "pull_requests": "write",
            "metadata": "read",
        },
        "default_events": [],
    }


def build_manifest_html(*, manifest: dict, state: str, org: str | None) -> str:
    if org:
        action = f"https://github.com/organizations/{org}/settings/apps/new?state={state}"
    else:
        action = f"https://github.com/settings/apps/new?state={state}"
    manifest_json = json.dumps(manifest)
    escaped = (
        manifest_json.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )
    return dedent(
        f"""\
        <!DOCTYPE html>
        <html>
        <head><title>Create symphony-orchestrator</title></head>
        <body>
        <p>Auto-submitting manifest to GitHub…</p>
        <form id="manifest-form" action="{action}" method="post">
          <input type="hidden" name="manifest" value="{escaped}">
        </form>
        <script>document.getElementById('manifest-form').submit();</script>
        </body>
        </html>
        """
    )


# --- Manifest code → App credentials ---


def exchange_manifest_code(
    *,
    code: str,
    config_dir: Path,
    http_post=None,
) -> ExchangeResult:
    url = f"{GITHUB_API}/app-manifests/{code}/conversions"
    headers = {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "symphony-orchestrator-bootstrap",
    }
    poster = http_post if http_post is not None else _default_post
    body, _status = poster(url, headers, b"")
    try:
        data = json.loads(body)
    except json.JSONDecodeError as exc:
        raise BootstrapError(f"GitHub returned non-JSON: {body[:200]!r}") from exc

    pem = data.get("pem")
    if not isinstance(pem, str) or "PRIVATE KEY" not in pem:
        raise BootstrapError(f"GitHub response missing 'pem': {list(data)}")
    app_id = data.get("id")
    if not isinstance(app_id, int):
        raise BootstrapError(f"GitHub response missing integer 'id': {data}")
    slug = data.get("slug") or "symphony-orchestrator"
    html_url = data.get("html_url") or f"https://github.com/apps/{slug}"

    config_dir.mkdir(parents=True, exist_ok=True)
    pem_path = config_dir / "github-app.pem"
    pem_path.write_text(pem)
    pem_path.chmod(0o600)

    env_path = config_dir / "github-app.env"
    env_lines = [
        f"SYMPHONY_GITHUB_APP_ID={app_id}",
        f"SYMPHONY_GITHUB_APP_PRIVATE_KEY_PATH={pem_path}",
        "# SYMPHONY_GITHUB_APP_INSTALLATION_ID=  # set after install approval",
    ]
    env_path.write_text("\n".join(env_lines) + "\n")

    return ExchangeResult(
        app_id=app_id,
        slug=slug,
        html_url=html_url,
        pem_path=pem_path,
        env_path=env_path,
    )


def write_installation_id(*, env_path: Path, installation_id: int) -> None:
    """Patch the env file with the discovered installation_id (no duplicates)."""

    text = env_path.read_text()
    out_lines = []
    written = False
    for line in text.splitlines():
        stripped = line.lstrip("#").strip()
        if stripped.startswith("SYMPHONY_GITHUB_APP_INSTALLATION_ID="):
            if not written:
                out_lines.append(f"SYMPHONY_GITHUB_APP_INSTALLATION_ID={installation_id}")
                written = True
            continue
        out_lines.append(line)
    if not written:
        out_lines.append(f"SYMPHONY_GITHUB_APP_INSTALLATION_ID={installation_id}")
    env_path.write_text("\n".join(out_lines).rstrip("\n") + "\n")


def format_install_approval_message(*, owner_username: str, org: str, app_html_url: str) -> str:
    return dedent(
        f"""\
        Hey @{owner_username} — quick ask: I just created the
        `symphony-orchestrator` GitHub App on my personal account so the
        Symphony agent can author PRs as a bot instead of me. It needs
        org-level install on `{org}` (All repositories) with
        `contents:write`, `pull_requests:write`, `metadata:read`.

        App: {app_html_url}

        Could you approve the install request when you get a sec? Thanks!
        """
    )


# --- HTTP plumbing ---


def _default_post(url: str, headers: dict[str, str], body: bytes) -> tuple[str, int]:
    request = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return response.read().decode("utf-8"), response.status
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise BootstrapError(f"GitHub HTTP {exc.code}: {detail[:300]}") from exc
    except urllib.error.URLError as exc:
        raise BootstrapError(f"network error: {exc}") from exc


# --- Local callback server ---


def _wait_for_callback(
    port: int,
    expected_state: str,
    *,
    timeout_seconds: int = CALLBACK_TIMEOUT_SECONDS,
) -> str:
    """Spin up a one-shot HTTP server and return the captured ``code``."""

    received: dict[str, str] = {}

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802 — http.server convention
            parsed = urlparse(self.path)
            params = parse_qs(parsed.query)
            code = params.get("code", [""])[0]
            state = params.get("state", [""])[0]
            if not code:
                self._respond(400, "missing 'code' in query")
                return
            if state != expected_state:
                self._respond(400, "state mismatch — possible CSRF, aborting")
                return
            received["code"] = code
            self._respond(200, "Symphony bootstrap captured the code. You can close this tab.")

        def log_message(self, format: str, *args) -> None:  # noqa: A002, N802
            return  # silence default access log

        def _respond(self, status: int, message: str) -> None:
            self.send_response(status)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(message.encode("utf-8"))

    address = ("127.0.0.1", port)
    httpd = HTTPServer(address, Handler)
    httpd.timeout = 1.0
    deadline = time.monotonic() + timeout_seconds
    while "code" not in received:
        if time.monotonic() >= deadline:
            raise BootstrapError(
                f"timed out waiting for GitHub callback after {timeout_seconds}s; "
                "did the browser tab redirect back to localhost?"
            )
        httpd.handle_request()
    return received["code"]


def _port_is_free(port: int) -> bool:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.bind(("127.0.0.1", port))
    except OSError:
        return False
    finally:
        sock.close()
    return True


# --- CLI entrypoint ---


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="symphony-setup-github-app",
        description="Create the symphony-orchestrator GitHub App via the manifest flow.",
    )
    parser.add_argument(
        "--name",
        default="symphony-orchestrator",
        help="App name (must be globally unique on GitHub).",
    )
    parser.add_argument(
        "--homepage",
        default="https://github.com/symphony-orchestrator",
        help="Public homepage URL for the App listing.",
    )
    parser.add_argument(
        "--org",
        default=None,
        help=(
            "If set, create the App on this org instead of the personal "
            "account. Requires org owner permission."
        ),
    )
    parser.add_argument(
        "--port",
        type=int,
        default=DEFAULT_CALLBACK_PORT,
        help="Localhost port for the callback (default: 8765).",
    )
    parser.add_argument(
        "--config-dir",
        type=Path,
        default=DEFAULT_CONFIG_DIR,
        help="Directory for the .pem and env file (default: ~/.symphony).",
    )
    parser.add_argument(
        "--finalize",
        type=int,
        default=None,
        metavar="INSTALLATION_ID",
        help=("Skip the manifest flow; just write INSTALLATION_ID into an existing env file."),
    )
    args = parser.parse_args(argv)

    if args.finalize is not None:
        env_path = args.config_dir / "github-app.env"
        if not env_path.exists():
            print(f"error: {env_path} not found — run without --finalize first", file=sys.stderr)
            return 2
        write_installation_id(env_path=env_path, installation_id=args.finalize)
        print(f"installation_id={args.finalize} written to {env_path}")
        return 0

    if not _port_is_free(args.port):
        print(f"error: port {args.port} is busy; pass --port", file=sys.stderr)
        return 2

    state = secrets.token_urlsafe(24)
    manifest = build_manifest(name=args.name, homepage_url=args.homepage, callback_port=args.port)
    html = build_manifest_html(manifest=manifest, state=state, org=args.org)

    html_path = args.config_dir / "manifest-bootstrap.html"
    args.config_dir.mkdir(parents=True, exist_ok=True)
    html_path.write_text(html)
    file_url = f"file://{html_path}"

    print(f"opening {file_url} — confirm App creation in your browser…")
    webbrowser.open(file_url)

    code = _wait_for_callback(args.port, state)
    result = exchange_manifest_code(code=code, config_dir=args.config_dir)

    print()
    print("=" * 72)
    print(f"App created: {result.html_url}")
    print(f"  app_id     : {result.app_id}")
    print(f"  pem        : {result.pem_path}  (chmod 600)")
    print(f"  env file   : {result.env_path}")
    print("=" * 72)
    print()
    print("Next steps:")
    print(f"  1. Install the App on your org: {result.html_url}/installations/new")
    print("     Choose 'All repositories' for the schoolsoutapp org.")
    print()
    print("  2. If you are not an org owner, GitHub will fire an approval")
    print("     request to the owners. DM one of them with this template:")
    print()
    print(
        format_install_approval_message(
            owner_username="<owner-handle>",
            org="<your-org>",
            app_html_url=result.html_url,
        )
    )
    print()
    print("  3. After approval, finalize the env file with:")
    print("     symphony-setup-github-app --finalize <installation_id>")
    print()
    print("  4. Source the env file before launching Symphony:")
    print(f"     source {result.env_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
