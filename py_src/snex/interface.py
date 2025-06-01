import asyncio
from asyncio import AbstractEventLoop
from typing import Any

from .models import SendCommand, generate_id
from .serde import ErlangTerm
from .transport import write_request


class Snex:
    _main_loop: AbstractEventLoop
    _writer: asyncio.WriteTransport

    def __init__(self, writer: asyncio.WriteTransport) -> None:
        self._main_loop = asyncio.get_event_loop()
        self._writer = writer

    def send(self, to: ErlangTerm, data: Any) -> None:  # noqa: ANN401
        self._main_loop.call_soon_threadsafe(
            write_request,
            self._writer,
            generate_id(),
            SendCommand(command="send", to=to, data=data),
        )
