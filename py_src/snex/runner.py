from __future__ import annotations

import asyncio
import base64
import contextlib
import logging
import pickle
import threading
import traceback
from contextlib import asynccontextmanager, contextmanager
from typing import TYPE_CHECKING

import snex

from . import code, interface, transport
from .compat import eager_start
from .logger import LoggingHandler
from .models import (
    EnvID,
    ErrorResponse,
    EvalCommand,
    GCCommand,
    InitCommand,
    InNoReply,
    InRequest,
    MakeEnvCommand,
    MessageType,
    OkResponse,
    OutResponse,
    generate_id,
)

if TYPE_CHECKING:
    from collections.abc import AsyncGenerator, Callable, Generator
    from typing import Final

    Envs = dict[EnvID, dict[str, object]]

ID_LEN_BYTES: Final[int] = 16
ROOT_ENV_ID: Final[EnvID] = EnvID(b"root")

logger: logging.Logger = logging.getLogger(__name__)

subprocess_requests: dict[bytes, transport.StreamWriter] = {}


def env_id_to_str(env_id: EnvID) -> str:
    return base64.b64encode(env_id).decode()


async def run_init(cmd: InitCommand, envs: Envs) -> OkResponse:
    root_env = envs[ROOT_ENV_ID]
    root_env.update(cmd["additional_vars"])

    if cmd["code"]:
        await code.run_exec(cmd["code"], root_env)

    return OkResponse(type="ok", value=None)


def run_make_env(cmd: MakeEnvCommand, envs: Envs) -> OkResponse | ErrorResponse:
    env = envs[ROOT_ENV_ID].copy()

    for from_env_cmd in cmd["from_env"]:
        env_id = from_env_cmd["env_id"]
        try:
            from_env = envs[env_id]
        except KeyError:
            return ErrorResponse(
                type="error",
                code="env_not_found",
                reason=f"Environment {env_id_to_str(env_id)} not found",
            )

        keys = set(from_env_cmd["keys"])
        if from_env_cmd["keys_mode"] == "only":
            for key in keys:
                env[key] = from_env.get(key)
        else:
            for key in from_env:
                if key not in keys:
                    env[key] = from_env[key]

    env.update(cmd["additional_vars"])

    env_id = generate_id()
    envs[env_id] = env

    return OkResponse(type="ok", value=env_id)


async def run_eval(cmd: EvalCommand, envs: Envs) -> OkResponse | ErrorResponse:
    if cmd["env_id"] is None:
        env = envs[ROOT_ENV_ID].copy()
    else:
        env_id = cmd["env_id"]
        try:
            env = envs[env_id]
        except KeyError:
            return ErrorResponse(
                type="error",
                code="env_not_found",
                reason=f"Environment {env_id_to_str(env_id)} not found",
            )

    env.update(cmd["additional_vars"])

    if cmd["code"]:
        value = await code.run_exec(cmd["code"], env)

    return OkResponse(type="ok", value=value)


def run_gc(cmd: GCCommand, envs: Envs) -> None:
    envs.pop(cmd["env_id"], None)


async def run(
    writer: transport.StreamWriter,
    req_id: bytes,
    command: InRequest,
    envs: Envs,
) -> None:
    try:
        result: OutResponse

        if command["type"] == "init":
            result = await run_init(command, envs)

        elif command["type"] == "make_env":
            result = run_make_env(command, envs)

        elif command["type"] == "eval":
            result = await run_eval(command, envs)

        else:
            result = ErrorResponse(
                type="error",
                code="internal_error",
                reason=f"Unknown command: {command}",
            )

        await writer.write_serialized(req_id, result)
    except Exception as e:  # noqa: BLE001
        error_result = ErrorResponse(
            type="error",
            code="python_runtime_error",
            reason=str(e),
            traceback=traceback.format_exception(e),
        )

        try:
            await writer.write_serialized(req_id, error_result)
        except Exception:
            logger.exception("Snex: Error sending error response")


async def run_noreply(command: InNoReply, req_id: bytes, envs: Envs) -> None:
    try:
        if command["type"] == "gc":
            run_gc(command, envs)

        elif (
            command["type"] == "call_response"
            or command["type"] == "call_error_response"
        ):
            interface.on_call_response(req_id, command)

        else:
            logger.error("Snex: Unknown no-reply command: %s", command)
    except Exception:
        logger.exception("Snex: Error processing a no-reply request")


async def _run_loop(
    reader: transport.StreamReader,
    writer: transport.StreamWriter,
) -> None:
    loop = asyncio.get_running_loop()
    running_tasks: set[asyncio.Task[OutResponse | None]] = set()
    envs: Envs = {
        ROOT_ENV_ID: {
            "snex": snex,
            "Elixir": snex.Elixir,
            "_SnexReturn": code.SnexReturn,
        },
    }

    while True:
        try:
            byte_cnt_bytes = await reader.readexactly(4)
            byte_cnt = int.from_bytes(byte_cnt_bytes, "big")
            all_data = memoryview(await reader.readexactly(byte_cnt))
        except asyncio.IncompleteReadError:
            break

        if len(all_data) < ID_LEN_BYTES + 1:
            logger.critical("Snex: not enough bytes for a message type and ID")
            continue

        req_id = bytes(all_data[:ID_LEN_BYTES])
        message_type = all_data[ID_LEN_BYTES]

        if subprocess_writer := subprocess_requests.pop(req_id, None):
            try:
                await subprocess_writer.write_all((byte_cnt_bytes, all_data))
            except Exception:
                logger.exception("Snex: Error writing to subprocess")

            continue

        try:
            # Validate message type
            message_type = MessageType(message_type)
            command = pickle.loads(all_data[ID_LEN_BYTES + 1 :])  # noqa: S301

            if message_type == MessageType.REQUEST:
                coro = run(writer, req_id, command, envs)
            else:
                coro = run_noreply(command, req_id, envs)

            task = loop.create_task(coro, **eager_start)
            running_tasks.add(task)
            task.add_done_callback(running_tasks.discard)
        except Exception as e:
            if message_type == MessageType.REQUEST:
                result = ErrorResponse(
                    type="error",
                    code="python_runtime_error",
                    reason=str(e),
                    traceback=traceback.format_exception(e),
                )
                await writer.write_serialized(req_id, result)
            else:
                logger.exception("Snex: Error in main loop")


@contextmanager
def initialized(writer: transport.StreamWriter) -> Generator[None]:
    with interface.initialized(writer):
        logging_handler = LoggingHandler()
        logger.addHandler(logging_handler)
        try:
            yield
        finally:
            logger.removeHandler(logging_handler)


async def serve_forever(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    *,
    on_ready: Callable[[], None] | None = None,
) -> None:
    """
    Run Snex server loop until canceled.

    Similar to `async with snex.serve(reader, writer)`.
    """
    twriter = transport.StreamWriter(writer)
    with initialized(twriter):
        if on_ready:
            on_ready()

        await _run_loop(reader, twriter)


@asynccontextmanager
async def serve(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
) -> AsyncGenerator[None, None]:
    """
    Run Snex server loop as a context manager.

    The server loop is necessary to use `snex.call`/`snex.cast` from external Python
    processes. Usually, you'll want to run it in a subprocess, and connect the other
    end of the reader/writer pair to the main Snex process.

    Examples::

        import asyncio
        from asyncio import start_unix_server
        from concurrent.futures import ProcessPoolExecutor

        import snex


        async def in_subprocess_loop(sock_path: str) -> int:
            reader, writer = await asyncio.open_unix_connection(sock_path)
            async with snex.serve(reader, writer):
                return await snex.call("Elixir.System", "pid", [])


        def in_subprocess(sock_path: str) -> int:
            return asyncio.run(in_subprocess_loop(sock_path))


        async def main():
            sock_path = "/tmp/snex.sock"
            loop = asyncio.get_running_loop()
            async with await start_unix_server(snex.io_loop_for_connection, sock_path):
                with ProcessPoolExecutor() as pool:
                    return await loop.run_in_executor(pool, in_subprocess, sock_path)

    """
    twriter = transport.StreamWriter(writer)
    with initialized(twriter):
        task = asyncio.create_task(_run_loop(reader, twriter), **eager_start)
        try:
            yield
        finally:
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task


async def _io_loop_for_connection(
    reader: transport.StreamReader,
    writer: transport.StreamWriter,
    main_loop_writer: transport.StreamWriter,
) -> None:
    while True:
        try:
            header_bytes = await reader.readexactly(4)
            byte_cnt = int.from_bytes(header_bytes, "big")
            all_data = memoryview(await reader.readexactly(byte_cnt))
        except asyncio.IncompleteReadError:
            break

        await main_loop_writer.write_all((header_bytes, all_data))

        message_type = MessageType(all_data[ID_LEN_BYTES])
        if message_type != MessageType.REQUEST:
            continue

        req_id = bytes(all_data[:ID_LEN_BYTES])
        subprocess_requests[req_id] = writer


async def io_loop_for_connection(
    sub_reader: asyncio.StreamReader,
    sub_writer: asyncio.StreamWriter,
    *,
    main_loop_writer: transport.StreamWriter,
) -> None:
    if threading.get_ident() != main_loop_writer.thread_id:
        msg = "Subprocess IO loop can only be run in the Snex thread"
        raise RuntimeError(msg)

    reader, writer = sub_reader, transport.StreamWriter(sub_writer)

    try:
        await _io_loop_for_connection(reader, writer, main_loop_writer)
    finally:
        sub_writer.close()
        await sub_writer.wait_closed()
