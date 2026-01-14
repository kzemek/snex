from __future__ import annotations

import asyncio
from typing import TYPE_CHECKING, Protocol

from snex import models

from . import etf

if TYPE_CHECKING:
    from .models import OutRequest, OutResponse

    class FileLike(Protocol):
        def fileno(self) -> int: ...
        def close(self) -> None: ...


def write_data(
    writer: asyncio.WriteTransport,
    req_id: bytes,
    data: OutRequest | OutResponse,
) -> None:
    data_parts = etf.encode(data)

    message_type = models.out_message_type(data)
    data_parts[0] = (
        req_id + int.to_bytes(message_type, length=1, byteorder="big") + data_parts[0]
    )

    data_len = sum(len(d) for d in data_parts)
    data_parts[0] = (
        int.to_bytes(
            data_len,
            length=4,
            byteorder="big",
        )
        + data_parts[0]
    )

    writer.writelines(data_parts)


async def setup_io(
    erl_in: FileLike,
    erl_out: FileLike,
) -> tuple[asyncio.StreamReader, asyncio.WriteTransport]:
    loop = asyncio.get_running_loop()
    writer, _ = await loop.connect_write_pipe(asyncio.Protocol, erl_out)

    reader = asyncio.StreamReader()
    reader_protocol = asyncio.StreamReaderProtocol(reader)
    await loop.connect_read_pipe(lambda: reader_protocol, erl_in)

    return reader, writer
