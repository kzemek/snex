from __future__ import annotations

import asyncio
from typing import TYPE_CHECKING

from snex import models

from . import etf

if TYPE_CHECKING:
    from typing import Protocol

    from .models import OutRequest, OutResponse

    class FileLike(Protocol):
        def fileno(self) -> int: ...
        def close(self) -> None: ...


async def write_data(
    writer: asyncio.StreamWriter,
    req_id: bytes,
    data: OutRequest | OutResponse,
) -> None:
    message_type = models.out_message_type(data)
    data_list = etf.encode(data)
    data_len = sum(len(d) for d in data_list)
    bytes_cnt = len(req_id) + 1 + data_len

    writer.writelines(
        [
            int.to_bytes(bytes_cnt, length=4, byteorder="big"),
            req_id,
            int.to_bytes(message_type, length=1, byteorder="big"),
        ],
    )
    writer.writelines(data_list)
    await writer.drain()


async def setup_io(
    pipe_in: FileLike,
    pipe_out: FileLike,
) -> tuple[asyncio.StreamReader, asyncio.StreamWriter]:
    loop = asyncio.get_running_loop()

    reader = asyncio.StreamReader(loop=loop)
    protocol = asyncio.StreamReaderProtocol(reader, loop=loop)
    await loop.connect_read_pipe(lambda: protocol, pipe_in)

    transport, _ = await loop.connect_write_pipe(asyncio.Protocol, pipe_out)
    writer = asyncio.StreamWriter(transport, protocol, reader, loop=loop)

    return reader, writer
