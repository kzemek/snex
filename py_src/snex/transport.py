from __future__ import annotations

import asyncio
import threading
from typing import TYPE_CHECKING

from snex import models

from . import etf

if TYPE_CHECKING:
    from collections.abc import Iterable
    from typing import Protocol

    from .models import OutRequest, OutResponse

    class FileLike(Protocol):
        def fileno(self) -> int: ...
        def close(self) -> None: ...


StreamReader = asyncio.StreamReader


def _serialize(
    req_id: bytes,
    data: OutRequest | OutResponse,
) -> list[bytes | bytearray | memoryview[int]]:
    data_parts = etf.encode(data)

    message_type = models.out_message_type(data)
    header = req_id + int.to_bytes(message_type, length=1, byteorder="big")

    data_len = len(header) + sum(map(len, data_parts))
    data_len_header = int.to_bytes(data_len, length=4, byteorder="big")

    data_parts[0] = data_len_header + header + data_parts[0]
    return data_parts


class StreamWriter:
    __slots__ = ("_writer", "loop", "thread_id")

    _writer: asyncio.StreamWriter
    loop: asyncio.AbstractEventLoop
    thread_id: int

    def __init__(self, writer: asyncio.StreamWriter) -> None:
        self._writer = writer
        self.loop = asyncio.get_running_loop()
        self.thread_id = threading.get_ident()

    async def write_serialized(
        self,
        req_id: bytes,
        data: OutRequest | OutResponse,
    ) -> None:
        await self.write_all(_serialize(req_id, data))

    async def write_serialized_threadsafe(
        self,
        req_id: bytes,
        data: OutRequest | OutResponse,
    ) -> None:
        coro = self.write_all(_serialize(req_id, data))
        if threading.get_ident() == self.thread_id:
            await coro
        else:
            future = asyncio.run_coroutine_threadsafe(coro, self.loop)
            await asyncio.wrap_future(future)

    async def write_all(
        self,
        data: Iterable[bytes | bytearray | memoryview[int]],
    ) -> None:
        self._writer.writelines(data)
        await self._writer.drain()
