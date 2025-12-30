import asyncio
from asyncio import AbstractEventLoop
from collections.abc import Callable
from typing import Any

from . import etf, models, transport


class Snex:
    Atom = models.Atom
    Term = models.Term

    _main_loop: AbstractEventLoop
    _writer: asyncio.WriteTransport

    def __init__(self, writer: asyncio.WriteTransport) -> None:
        self._main_loop = asyncio.get_event_loop()
        self._writer = writer

    def send(self, to: models.Term, data: Any) -> None:  # noqa: ANN401
        self._main_loop.call_soon_threadsafe(
            transport.write_request,
            self._writer,
            models.generate_id(),
            models.SendCommand(command="send", to=to, data=data),
        )

    @staticmethod
    def set_custom_encoder(encoder_fun: Callable[[Any], Any]) -> None:
        etf.set_custom_encoder(encoder_fun)
