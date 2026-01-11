import asyncio

from snex import models

from . import etf
from .models import OutRequest, OutResponse


def write_data(
    writer: asyncio.WriteTransport,
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
