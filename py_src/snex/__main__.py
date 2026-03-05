from __future__ import annotations

import argparse
import asyncio
import io
import sys
from contextlib import suppress

from . import compat, runner

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, line_buffering=True, newline="\r\n")
sys.stderr = io.TextIOWrapper(sys.stderr.buffer, line_buffering=True, newline="\r\n")

parser = argparse.ArgumentParser()
parser.add_argument("--buffer-limit", type=int, default=8 * 1024 * 1024)
parser.add_argument("--eager-polyfill", action="store_true")
args = parser.parse_args()


async def serve_forever(
    erl_in: io.FileIO,
    erl_out: io.FileIO,
    *,
    buffer_limit: int,
    eager_polyfill: bool,
) -> None:
    loop = asyncio.get_running_loop()

    if eager_polyfill:
        compat.loop_eager_polyfill(loop)

    reader = asyncio.StreamReader(limit=buffer_limit, loop=loop)
    protocol = asyncio.StreamReaderProtocol(reader, loop=loop)
    await loop.connect_read_pipe(lambda: protocol, erl_in)
    transport, _ = await loop.connect_write_pipe(asyncio.Protocol, erl_out)
    writer = asyncio.StreamWriter(transport, protocol, reader, loop=loop)

    await runner.serve_forever(reader, writer)


with (
    open(3, "rb", 0) as erl_in,
    open(4, "wb", 0) as erl_out,
    suppress(asyncio.CancelledError),
):
    asyncio.run(
        serve_forever(
            erl_in,
            erl_out,
            buffer_limit=args.buffer_limit,
            eager_polyfill=args.eager_polyfill,
        ),
    )
