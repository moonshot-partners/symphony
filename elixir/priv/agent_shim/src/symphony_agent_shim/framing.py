"""Newline-delimited JSON-RPC framing over async byte streams.

Each frame = one JSON object on a single line, terminated by ``\n``. Matches
the format Symphony's Elixir port writes via ``Jason.encode!(msg) <> "\n"``.
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
