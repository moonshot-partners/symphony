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


@pytest.mark.asyncio
async def test_raises_on_non_dict_json():
    raw = b'[1, 2, 3]\n'
    framer = LineFramer(io.BytesIO(raw))
    with pytest.raises(ValueError, match="must be an object"):
        await framer.read_message()


@pytest.mark.asyncio
async def test_raises_on_scalar_json():
    raw = b'"a string"\n'
    framer = LineFramer(io.BytesIO(raw))
    with pytest.raises(ValueError, match="must be an object"):
        await framer.read_message()


@pytest.mark.asyncio
async def test_write_frame_async_stream():
    written: list[bytes] = []
    flushed = False

    class AsyncStream:
        async def write(self, data: bytes) -> None:
            written.append(data)

        async def flush(self) -> None:
            nonlocal flushed
            flushed = True

    await write_frame(AsyncStream(), {"id": 4, "result": {"ok": True}})
    assert len(written) == 1
    assert written[0].endswith(b"\n")
    assert json.loads(written[0]) == {"id": 4, "result": {"ok": True}}
    assert flushed is True


@pytest.mark.asyncio
async def test_read_message_async_stream():
    lines = [b'{"id":5}\n', b""]

    class AsyncStream:
        async def readline(self) -> bytes:
            return lines.pop(0)

    framer = LineFramer(AsyncStream())
    assert await framer.read_message() == {"id": 5}
    assert await framer.read_message() is None
