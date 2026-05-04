import pytest

from symphony_agent_shim.sandbox import (
    map_approval_policy,
    map_sandbox_tier,
)


def test_workspace_write_maps_to_bypass_with_cwd():
    cfg = map_sandbox_tier("workspace-write", cwd="/tmp/work")
    assert cfg.permission_mode == "bypassPermissions"
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


def test_approval_policy_dict_never_means_auto_accept():
    auto, deny_message = map_approval_policy({"type": "never"})
    assert auto is True
    assert deny_message is None


def test_approval_policy_dict_on_request_means_block():
    auto, deny_message = map_approval_policy({"type": "on-request"})
    assert auto is False
    assert "operator approval" in deny_message
