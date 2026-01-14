from __future__ import annotations

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


async def run_loop(erl_in: FileLike, erl_out: FileLike) -> None:
    reader, writer = await runner.init(erl_in, erl_out)
    await runner.run_loop(reader, writer)


with (
    open(3, "rb", 0) as erl_in,
    open(4, "wb", 0) as erl_out,
    suppress(asyncio.CancelledError),
):
    asyncio.run(run_loop(erl_in, erl_out))
