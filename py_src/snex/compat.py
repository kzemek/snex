from __future__ import annotations

import asyncio
import sys
import time
from collections import deque
from functools import wraps
from types import MethodType
from typing import Any, Final

MAX_EAGER_RUNS = 100
MAX_EAGER_RUN_TIMEOUT_NS: Final[int] = 10_000
LOOP_EAGER_POLYFILL_ATTR: Final[str] = "_loop_eager_polyfill"

if sys.version_info >= (3, 11):
    import enum

    StrEnum = enum.StrEnum
else:
    from enum import Enum

    class StrEnum(str, Enum):
        pass


if sys.version_info >= (3, 12):
    import typing

    override = typing.override
else:
    from collections.abc import Callable
    from typing import Any, TypeVar

    CallableT = TypeVar("CallableT", bound=Callable[..., Any])

    def override(func: CallableT, /) -> CallableT:
        return func


eager_start: dict[str, Any] = {}
if sys.version_info >= (3, 14):
    eager_start = {"eager_start": True}


def loop_eager_polyfill(loop: asyncio.AbstractEventLoop) -> None:
    if (
        not isinstance(loop, asyncio.BaseEventLoop)
        or not hasattr(loop, "_run_once")
        or not hasattr(loop, "_ready")
        or not isinstance(loop._ready, deque)  # noqa: SLF001
        or not hasattr(asyncio.Handle, "_run")
        or hasattr(loop, LOOP_EAGER_POLYFILL_ATTR)
    ):
        return

    orig_run_once = loop._run_once  # noqa: SLF001

    @wraps(orig_run_once)
    def run_once(self: asyncio.BaseEventLoop) -> None:
        orig_run_once()
        if not hasattr(self, "_ready"):
            return

        deadline = time.monotonic_ns() + MAX_EAGER_RUN_TIMEOUT_NS
        ready: deque[asyncio.Handle] = self._ready

        handle: asyncio.Handle | None = None
        for _ in range(MAX_EAGER_RUNS):
            if not ready or time.monotonic_ns() > deadline:
                break

            handle = ready.popleft()
            if handle.cancelled():
                continue

            handle._run()  # noqa: SLF001

        handle = None  # Needed to break cycles when an exception occurs.

    loop._run_once = MethodType(run_once, loop)  # noqa: SLF001
    setattr(loop, LOOP_EAGER_POLYFILL_ATTR, True)

    # With eager loop polyfill, we don't need to start tasks eagerly. That gives
    # us fairer semantics, as concurrent tasks are filled through BFS instead of DFS
    eager_start.clear()
