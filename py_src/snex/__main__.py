from __future__ import annotations

import argparse
import asyncio
import io
import sys
from contextlib import suppress
from typing import TYPE_CHECKING

from . import runner

if TYPE_CHECKING:
    from .transport import FileLike

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, line_buffering=True, newline="\r\n")
sys.stderr = io.TextIOWrapper(sys.stderr.buffer, line_buffering=True, newline="\r\n")

parser = argparse.ArgumentParser()
parser.add_argument("--buffer-limit", type=int, default=8 * 1024 * 1024)
args = parser.parse_args()


async def run_loop(erl_in: FileLike, erl_out: FileLike, buffer_limit: int) -> None:
    reader, writer = await runner.init(erl_in, erl_out, buffer_limit)
    await runner.run_loop(reader, writer)


with (
    open(3, "rb", 0) as erl_in,
    open(4, "wb", 0) as erl_out,
    suppress(asyncio.CancelledError),
):
    asyncio.run(run_loop(erl_in, erl_out, args.buffer_limit))
