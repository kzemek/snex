import asyncio
import threading
from asyncio import AbstractEventLoop
from typing import Any

from . import models, transport
from .models import Atom, Term

_main_loop: AbstractEventLoop | None = None
_writer: asyncio.WriteTransport | None = None
_main_thread_id: int | None = None

_call_futures: dict[bytes, tuple[asyncio.Future[object], AbstractEventLoop, int]] = {}


class ElixirError(Exception):
    def __init__(self, req_id: bytes, reason: str) -> None:
        msg = f"Call (id: {list(req_id)!r}) failed on Elixir side with reason: {reason}"
        super().__init__(msg)


def init(writer: asyncio.WriteTransport) -> None:
    global _main_loop, _writer, _main_thread_id  # noqa: PLW0603
    _main_loop = asyncio.get_running_loop()
    _writer = writer
    _main_thread_id = threading.get_ident()


def _write_request(req_id: bytes, command: models.OutRequest) -> None:
    if not _main_loop or not _writer or _main_thread_id is None:
        msg = "Snex is not running!"
        raise RuntimeError(msg)

    if threading.get_ident() == _main_thread_id:
        transport.write_request(_writer, req_id, command)
    else:
        _main_loop.call_soon_threadsafe(
            transport.write_request,
            _writer,
            req_id,
            command,
        )


def send(to: object, data: object) -> None:
    """
    Send data to a BEAM process.

    Args:
        to: The BEAM process to send the data to; can be any identifier that can be used
            as destination in `Kernel.send/2`
        data: The data to send; will be encoded and sent to the BEAM process

    """
    cast(Atom("Elixir.Kernel"), Atom("send"), [to, data])


def cast(
    module: str | Atom | Term,
    function: str | Atom | Term,
    args: list[object],
    *,
    node: str | Atom | Term | None = None,
) -> None:
    """
    Call a function in BEAM without waiting for a response.

    `module`, `function` and `node` can be given as strings, atoms, or `snex.Term` that
    resolves either to a string, or an atom. They will be converted to atoms on the BEAM
    side.

    The function will be called in a new process on the BEAM side.

    Args:
        module: The module to call the function from
        function: The function to call
        args: The arguments to pass to the function
        node: The node to call the function on; defaults to the current node

    """
    req_id = models.generate_id()
    command = models.CastCommand(
        command="cast",
        module=module,
        function=function,
        args=args,
        node=node,
    )

    _write_request(req_id, command)


async def call(
    module: str | Atom | Term,
    function: str | Atom | Term,
    args: list[object],
    *,
    node: str | Atom | Term | None = None,
) -> Any:  # noqa: ANN401
    """
    Call a function in BEAM, returning the result.

    `module`, `function` and `node` can be given as strings, atoms, or `snex.Term` that
    resolves either to a string, or an atom. They will be converted to atoms on the BEAM
    side.

    The function will be called in a new process on the BEAM side.

    Args:
        module: The module to call the function from
        function: The function to call
        args: The arguments to pass to the function
        node: The node to call the function on; defaults to the current node

    """
    loop = asyncio.get_running_loop()

    req_id = models.generate_id()
    future = loop.create_future()
    command = models.CallCommand(
        command="call",
        module=module,
        function=function,
        args=args,
        node=node,
    )

    _write_request(req_id, command)
    _call_futures[req_id] = (future, loop, threading.get_ident())

    try:
        return await future
    except asyncio.CancelledError:
        _call_futures.pop(req_id, None)
        raise


def on_call_response(
    req_id: bytes,
    data: models.CallResponse | models.CallErrorResponse,
) -> None:
    entry = _call_futures.pop(req_id, None)
    if entry is None:
        # Likely a response for a canceled request
        return

    future, loop, thread_id = entry

    if data["command"] == "call_response":
        if threading.get_ident() == thread_id:
            future.set_result(data["result"])
        else:
            loop.call_soon_threadsafe(future.set_result, data["result"])
    else:
        exc = ElixirError(req_id, data["reason"])
        if threading.get_ident() == thread_id:
            future.set_exception(exc)
        else:
            loop.call_soon_threadsafe(future.set_exception, exc)
