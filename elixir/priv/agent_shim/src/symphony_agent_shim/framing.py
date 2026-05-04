"""Newline-delimited JSON-RPC framing over async byte streams.

Each frame = one JSON object on a single line, terminated by ``\n``. Matches
the format Symphony's Elixir port writes via ``Jason.encode!(msg) <> "\n"``.

Streams are duck-typed: any object with ``readline()``/``write()``/``flush()``
methods works, sync or async. Async readlines are awaited directly; sync
readlines run via ``asyncio.to_thread`` so a blocking stdin read does not
freeze the event loop and starve concurrently scheduled tasks (e.g. turn
drivers).
"""

import asyncio
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
        readline = self._stream.readline
        if inspect.iscoroutinefunction(readline):
            return await readline()
        return await asyncio.to_thread(readline)


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
