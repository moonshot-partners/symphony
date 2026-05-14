"""PreToolUse hook: warn (do not block) when implementation lacks a test.

Heuristic: when the agent is writing what looks like an implementation file
(``lib/``, ``src/``, ``app/`` with a code extension) and we cannot find any
sibling test file matching common naming conventions, attach a warning to the
SDK output. The hook always allows the call — the goal is to nudge, not to
gate, since file-pattern heuristics give false positives often enough that
hard-blocking on them would drive the agent crazy.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

_IMPL_DIRS = ("lib", "src", "app")
_CODE_EXTS = frozenset(
    {
        ".py",
        ".ex",
        ".exs",
        ".ts",
        ".tsx",
        ".js",
        ".jsx",
        ".rb",
        ".go",
        ".rs",
        ".java",
        ".kt",
        ".swift",
        ".dart",
    }
)
_WATCHED_TOOLS = frozenset({"Write", "Edit"})


def _allow(reason: str | None = None) -> dict[str, Any]:
    out: dict[str, Any] = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
        }
    }
    if reason:
        out["hookSpecificOutput"]["permissionDecisionReason"] = reason
    return out


def _looks_like_test(path: Path) -> bool:
    name = path.name.lower()
    parts = {p.lower() for p in path.parts}
    return (
        name.startswith("test_")
        or name.endswith("_test.py")
        or "_test." in name
        or ".test." in name
        or ".spec." in name
        or "test" in parts
        or "tests" in parts
        or "spec" in parts
    )


def _looks_like_impl(path: Path) -> bool:
    if path.suffix.lower() not in _CODE_EXTS:
        return False
    parts = {p.lower() for p in path.parts}
    return any(d in parts for d in _IMPL_DIRS) and not _looks_like_test(path)


def _has_sibling_test(impl_path: Path, cwd: Path) -> bool:
    stem = impl_path.stem
    candidates = (
        f"test_{stem}.py",
        f"{stem}_test.py",
        f"{stem}_test.exs",
        f"{stem}.test.ts",
        f"{stem}.test.tsx",
        f"{stem}.test.js",
        f"{stem}.test.jsx",
        f"{stem}.spec.ts",
        f"{stem}.spec.js",
    )
    candidate_set = set(candidates)
    try:
        for found in cwd.rglob("*"):
            if found.name in candidate_set:
                return True
    except OSError:
        pass
    return False


async def tdd_enforcer(
    input_data: dict[str, Any],
    _tool_use_id: str | None,
    _context: dict[str, Any],
) -> dict[str, Any]:
    tool_name = input_data.get("tool_name", "")
    if tool_name not in _WATCHED_TOOLS:
        return _allow()

    tool_input = input_data.get("tool_input", {}) or {}
    file_path_str = tool_input.get("file_path")
    cwd_str = input_data.get("cwd")
    if not file_path_str or not cwd_str:
        return _allow()

    path = Path(file_path_str)
    cwd = Path(cwd_str)

    if not _looks_like_impl(path):
        return _allow()

    if _has_sibling_test(path, cwd):
        return _allow()

    return _allow(
        f"tdd_enforcer warning: writing {path.name} but found no sibling test file "
        f"(stem={path.stem}). Consider RED-first before extending impl."
    )
