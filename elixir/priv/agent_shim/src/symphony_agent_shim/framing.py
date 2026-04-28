"""Newline-delimited JSON-RPC framing over async byte streams.

Each frame = one JSON object on a single line, terminated by ``\n``. Matches
the format Symphony's Elixir port writes via ``Jason.encode!(msg) <> "\n"``.

Streams are duck-typed: any object with ``readline()``/``write()``/``flush()``
methods works, sync or async. ``inspect.iscoroutine`` distinguishes the two.
"""

import inspect
import json
from typing import Any


class LineFramer:
    def __init__(self, stream: Any) -> None:
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
        result = self._stream.readline()
        if inspect.iscoroutine(result):
            return await result
        return result


async def write_frame(stream: Any, message: dict[str, Any]) -> None:
    line = (json.dumps(message, separators=(",", ":")) + "\n").encode("utf-8")
    result = stream.write(line)
    if inspect.iscoroutine(result):
        await result
    flush = getattr(stream, "flush", None)
    if flush is not None:
        flush_result = flush()
        if inspect.iscoroutine(flush_result):
            await flush_result
