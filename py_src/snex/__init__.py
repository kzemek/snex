import asyncio as _asyncio
from asyncio import AbstractEventLoop as _AbstractEventLoop
from typing import Any as _Any

from . import models as _models
from . import transport as _transport
from .etf import set_custom_encoder
from .models import Atom, Term

_main_loop: _AbstractEventLoop | None = None
_writer: _asyncio.WriteTransport | None = None


def send(to: Term, data: _Any) -> None:  # noqa: ANN401
    if not _main_loop or not _writer:
        msg = "Snex is not running!"
        raise RuntimeError(msg)

    _main_loop.call_soon_threadsafe(
        _transport.write_request,
        _writer,
        _models.generate_id(),
        _models.SendCommand(command="send", to=to, data=data),
    )


__all__ = ["Atom", "Term", "send", "set_custom_encoder"]
