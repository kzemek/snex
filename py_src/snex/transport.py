import asyncio
from enum import IntEnum
from typing import Literal

from . import etf
from .models import Request, Response


class MessageType(IntEnum):
    REQUEST = 0
    RESPONSE = 1


def _write_data(
    writer: asyncio.WriteTransport,
    req_id: bytes,
    data: (
        tuple[Literal[MessageType.REQUEST], Request]
        | tuple[Literal[MessageType.RESPONSE], Response]
    ),
) -> None:
    data_list = etf.encode(data[1])
    data_len = sum(len(d) for d in data_list)
    bytes_cnt = len(req_id) + 1 + data_len

    writer.writelines(
        [
            int.to_bytes(bytes_cnt, length=4, byteorder="big"),
            req_id,
            int.to_bytes(data[0], length=1, byteorder="big"),
        ],
    )
    writer.writelines(data_list)


def write_request(
    writer: asyncio.WriteTransport,
    req_id: bytes,
    request: Request,
) -> None:
    _write_data(writer, req_id, (MessageType.REQUEST, request))


def write_response(
    writer: asyncio.WriteTransport,
    req_id: bytes,
    response: Response,
) -> None:
    _write_data(writer, req_id, (MessageType.RESPONSE, response))


async def setup_io(
    loop: asyncio.AbstractEventLoop,
) -> tuple[asyncio.StreamReader, asyncio.WriteTransport]:
    erl_in = open(3, "rb", 0)  # noqa: ASYNC230, SIM115
    erl_out = open(4, "wb", 0)  # noqa: ASYNC230, SIM115

    writer, _ = await loop.connect_write_pipe(asyncio.Protocol, erl_out)

    reader = asyncio.StreamReader()
    reader_protocol = asyncio.StreamReaderProtocol(reader)
    await loop.connect_read_pipe(lambda: reader_protocol, erl_in)

    return reader, writer
