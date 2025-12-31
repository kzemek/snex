import asyncio as _asyncio
from asyncio import AbstractEventLoop as _AbstractEventLoop
from collections.abc import Callable as _Callable
from typing import Any as _Any

from . import etf as _etf
from . import models as _models
from . import transport as _transport
from .models import Atom, Term

_main_loop: _AbstractEventLoop | None = None
_writer: _asyncio.WriteTransport | None = None


def send(to: _Any, data: _Any) -> None:  # noqa: ANN401
    """
    Send data to a BEAM process.

    Args:
        to: The BEAM process to send the data to; can be any identifier that can be used
            as destination in `Kernel.send/2`
        data: The data to send; will be encoded and sent to the BEAM process

    """
    if not _main_loop or not _writer:
        msg = "Snex is not running!"
        raise RuntimeError(msg)

    _main_loop.call_soon_threadsafe(
        _transport.write_request,
        _writer,
        _models.generate_id(),
        _models.SendCommand(command="send", to=to, data=data),
    )


def set_custom_encoder(encoder_fun: _Callable[[_Any], _Any]) -> None:
    """
    Set a custom encoding function for objects that are not supported by default.

    Args:
        encoder_fun: The function to use to encode the objects

    """
    _etf.set_custom_encoder(encoder_fun)


__all__ = ["Atom", "Term", "send", "set_custom_encoder"]
