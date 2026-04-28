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
