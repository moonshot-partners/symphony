"""Tests for the manifest-flow bootstrap CLI."""

from __future__ import annotations

import json
import stat
from pathlib import Path

import pytest

from symphony_agent_shim import bootstrap_github_app as boot


def test_build_manifest_uses_least_privilege_permissions() -> None:
    manifest = boot.build_manifest(
        name="symphony-orchestrator",
        homepage_url="https://github.com/moonshot-partners/symphony",
        callback_port=8765,
    )
    assert manifest["name"] == "symphony-orchestrator"
    assert manifest["url"] == "https://github.com/moonshot-partners/symphony"
    assert manifest["redirect_url"] == "http://127.0.0.1:8765/callback"
    assert manifest["public"] is False
    perms = manifest["default_permissions"]
    assert perms == {
        "contents": "write",
        "pull_requests": "write",
        "metadata": "read",
    }
    # No webhook events: PR creation does not need them.
    assert manifest["default_events"] == []


def test_build_manifest_html_auto_submits_to_personal_account() -> None:
    html = boot.build_manifest_html(
        manifest={"name": "symphony-orchestrator"},
        state="abc123",
        org=None,
    )
    assert 'action="https://github.com/settings/apps/new?state=abc123"' in html
    assert '<input type="hidden" name="manifest"' in html
    assert "auto-submit" in html.lower() or ".submit()" in html


def test_build_manifest_html_targets_org_when_provided() -> None:
    html = boot.build_manifest_html(
        manifest={"name": "symphony-orchestrator"},
        state="abc123",
        org="schoolsoutapp",
    )
    assert (
        'action="https://github.com/organizations/schoolsoutapp/settings/apps/new?state=abc123"'
        in html
    )


def test_exchange_manifest_code_persists_pem_and_env_file(tmp_path: Path) -> None:
    captured: dict = {}

    def fake_post(url: str, headers: dict, body: bytes) -> tuple[str, int]:
        captured["url"] = url
        return (
            json.dumps(
                {
                    "id": 12345,
                    "slug": "symphony-orchestrator",
                    "owner": {"login": "moonshot-partners"},
                    "html_url": "https://github.com/apps/symphony-orchestrator",
                    "pem": (
                        "-----BEGIN RSA PRIVATE KEY-----\nFAKEKEY\n-----END RSA PRIVATE KEY-----\n"
                    ),
                    "webhook_secret": "wh_secret",
                    "client_id": "Iv1.fake",
                    "client_secret": "shh",
                }
            ),
            201,
        )

    result = boot.exchange_manifest_code(
        code="ABC",
        config_dir=tmp_path,
        http_post=fake_post,
    )

    assert captured["url"].endswith("/app-manifests/ABC/conversions")
    assert result.app_id == 12345
    assert result.slug == "symphony-orchestrator"
    assert result.html_url == "https://github.com/apps/symphony-orchestrator"

    pem_path = tmp_path / "github-app.pem"
    assert pem_path.exists()
    mode = stat.S_IMODE(pem_path.stat().st_mode)
    assert mode == 0o600, f"expected 0o600, got {oct(mode)}"
    assert "FAKEKEY" in pem_path.read_text()

    env_path = tmp_path / "github-app.env"
    assert env_path.exists()
    env_text = env_path.read_text()
    assert "SYMPHONY_GITHUB_APP_ID=12345" in env_text
    assert f"SYMPHONY_GITHUB_APP_PRIVATE_KEY_PATH={pem_path}" in env_text
    # INSTALLATION_ID not yet known at this stage — must be commented out.
    assert "# SYMPHONY_GITHUB_APP_INSTALLATION_ID=" in env_text


def test_exchange_manifest_code_rejects_missing_pem(tmp_path: Path) -> None:
    def fake_post(url: str, headers: dict, body: bytes) -> tuple[str, int]:
        return json.dumps({"id": 1, "slug": "x"}), 201  # no pem

    with pytest.raises(boot.BootstrapError, match="missing 'pem'"):
        boot.exchange_manifest_code(code="X", config_dir=tmp_path, http_post=fake_post)


def test_write_installation_id_appends_to_env_file(tmp_path: Path) -> None:
    env_path = tmp_path / "github-app.env"
    env_path.write_text(
        "SYMPHONY_GITHUB_APP_ID=1\n"
        f"SYMPHONY_GITHUB_APP_PRIVATE_KEY_PATH={tmp_path}/github-app.pem\n"
        "# SYMPHONY_GITHUB_APP_INSTALLATION_ID=  # set after install approval\n"
    )

    boot.write_installation_id(env_path=env_path, installation_id=98765)

    text = env_path.read_text()
    assert "SYMPHONY_GITHUB_APP_INSTALLATION_ID=98765" in text
    # Old commented placeholder should be removed (no double entry).
    assert text.count("SYMPHONY_GITHUB_APP_INSTALLATION_ID") == 1


def test_install_approval_template_includes_owner_and_app_url() -> None:
    template = boot.format_install_approval_message(
        owner_username="rrodrigu3z",
        org="schoolsoutapp",
        app_html_url="https://github.com/apps/symphony-orchestrator",
    )
    assert "@rrodrigu3z" in template
    assert "schoolsoutapp" in template
    assert "https://github.com/apps/symphony-orchestrator" in template
    assert "All repositories" in template
