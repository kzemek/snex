from __future__ import annotations

import asyncio
import base64
import concurrent.futures
import functools
import logging
import multiprocessing
import pickle
import threading
import traceback
from contextlib import (
    asynccontextmanager,
    contextmanager,
    suppress,
)
from typing import TYPE_CHECKING

import snex

from . import code, interface, transport
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
    import multiprocessing.connection as mpc
    from collections.abc import AsyncGenerator, Callable, Generator
    from typing import Final

    from .transport import FileLike

    CancelFn = Callable[[], object]
    Envs = dict[EnvID, dict[str, object]]

ID_LEN_BYTES: Final[int] = 16
ROOT_ENV_ID: Final[EnvID] = EnvID(b"root")

logger: logging.Logger = logging.getLogger(__name__)

subprocess_requests: dict[bytes, asyncio.Future[tuple[bytes, memoryview]]] = {}


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


async def run(command: InRequest, envs: Envs) -> OutResponse:
    result: OutResponse | None = None

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

    return result


async def run_noreply(command: InNoReply, req_id: bytes, envs: Envs) -> None:
    if command["type"] == "gc":
        run_gc(command, envs)

    elif command["type"] == "call_response" or command["type"] == "call_error_response":
        interface.on_call_response(req_id, command)

    else:
        msg = f"Unknown no-reply command: {command}"
        raise ValueError(msg)


def on_task_done_reply(
    running_tasks: set[asyncio.Task[OutResponse | None]],
    writer: asyncio.WriteTransport,
    req_id: bytes,
    task: asyncio.Task[OutResponse | None],
) -> None:
    running_tasks.discard(task)

    try:
        exc = task.exception()
        result = task.result() if exc is None else None

        if result is not None:
            try:
                transport.write_data(writer, req_id, result)
            except Exception as e:  # noqa: BLE001
                exc = e

        if exc is not None:
            error_result = ErrorResponse(
                type="error",
                code="python_runtime_error",
                reason=str(exc),
                traceback=traceback.format_exception(exc),
            )

            transport.write_data(writer, req_id, error_result)

    except asyncio.CancelledError:
        pass
    except Exception:
        logger.exception("Snex: Error sending response")


def on_task_done_noreply(
    running_tasks: set[asyncio.Task[OutResponse | None]],
    task: asyncio.Task[None],
) -> None:
    running_tasks.discard(task)

    try:
        if exc := task.exception():
            logger.error(
                "Snex: Error processing a no-reply request ",
                exc_info=(type(exc), exc, exc.__traceback__),
            )

    except asyncio.CancelledError:
        pass


async def run_loop(
    reader: asyncio.StreamReader,
    writer: asyncio.WriteTransport,
) -> None:
    loop = asyncio.get_running_loop()
    running_tasks: set[asyncio.Task[OutResponse | None]] = set()
    envs: Envs = {ROOT_ENV_ID: {"snex": snex, "_SnexReturn": code.SnexReturn}}

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

        if future := subprocess_requests.pop(req_id, None):
            future.set_result((byte_cnt_bytes, all_data))
            continue

        try:
            # Validate message type
            message_type = MessageType(message_type)
            command = pickle.loads(all_data[ID_LEN_BYTES + 1 :])  # noqa: S301

            if message_type == MessageType.REQUEST:
                task = loop.create_task(run(command, envs))
                running_tasks.add(task)
                task.add_done_callback(
                    functools.partial(
                        on_task_done_reply,
                        running_tasks,
                        writer,
                        req_id,
                    ),
                )
            else:
                noreply_task = loop.create_task(run_noreply(command, req_id, envs))
                running_tasks.add(noreply_task)
                noreply_task.add_done_callback(
                    functools.partial(
                        on_task_done_noreply,
                        running_tasks,
                    ),
                )
        except Exception as e:
            if message_type == MessageType.REQUEST:
                result = ErrorResponse(
                    type="error",
                    code="python_runtime_error",
                    reason=str(e),
                    traceback=traceback.format_exception(e),
                )
                transport.write_data(writer, req_id, result)
            else:
                logger.exception("Snex: Error in main loop")


async def init(
    erl_in: FileLike,
    erl_out: FileLike,
) -> tuple[asyncio.StreamReader, asyncio.WriteTransport]:
    reader, writer = await transport.setup_io(erl_in, erl_out)
    interface.init(writer)

    logger.addHandler(LoggingHandler())
    return reader, writer


class RemoteConnection:
    __slots__ = ("_read_pipe", "_write_pipe")

    _read_pipe: mpc.Connection
    _write_pipe: mpc.Connection

    def __init__(self, read_pipe: mpc.Connection, write_pipe: mpc.Connection) -> None:
        self._read_pipe = read_pipe
        self._write_pipe = write_pipe

    @contextmanager
    def remote_snex_thread(self) -> Generator[None, None]:
        future: concurrent.futures.Future[CancelFn] = concurrent.futures.Future()

        snex_thread = threading.Thread(
            target=asyncio.run,
            args=(self._in_loop(future),),
            daemon=True,
        )

        snex_thread.start()

        try:
            cancel = future.result()
        except Exception:
            snex_thread.join()
            raise

        try:
            yield
        finally:
            self._read_pipe.close()
            self._write_pipe.close()
            cancel()
            snex_thread.join()

    async def _in_loop(self, future: concurrent.futures.Future[CancelFn]) -> None:
        loop = asyncio.get_running_loop()
        reader, writer = await init(self._read_pipe, self._write_pipe)
        task = loop.create_task(run_loop(reader, writer))

        future.set_result(functools.partial(loop.call_soon_threadsafe, task.cancel))

        with suppress(asyncio.CancelledError):
            await task


async def _subprocess_io_loop(
    main_writer: asyncio.WriteTransport,
    read_pipe: mpc.Connection,
    write_pipe: mpc.Connection,
) -> None:
    loop = asyncio.get_running_loop()

    subprocess_reader, subprocess_writer = await transport.setup_io(
        read_pipe,
        write_pipe,
    )

    while True:
        try:
            header_bytes = await subprocess_reader.readexactly(4)
            byte_cnt = int.from_bytes(header_bytes, "big")
            all_data = memoryview(await subprocess_reader.readexactly(byte_cnt))
        except asyncio.IncompleteReadError:
            break

        main_writer.writelines([header_bytes, all_data])

        message_type = MessageType(all_data[ID_LEN_BYTES])
        if message_type != MessageType.REQUEST:
            continue

        req_id = bytes(all_data[:ID_LEN_BYTES])
        future: asyncio.Future[tuple[bytes, memoryview]] = loop.create_future()
        subprocess_requests[req_id] = future

        response = await future
        subprocess_writer.writelines(response)


@asynccontextmanager
async def start_subprocess_io_loop(
    main_writer: asyncio.WriteTransport,
) -> AsyncGenerator[RemoteConnection, None]:
    read_pipe, remote_write_pipe = multiprocessing.Pipe(duplex=False)
    remote_read_pipe, write_pipe = multiprocessing.Pipe(duplex=False)
    with read_pipe, write_pipe:
        task = asyncio.create_task(
            _subprocess_io_loop(main_writer, read_pipe, write_pipe),
        )

        try:
            with remote_read_pipe, remote_write_pipe:
                yield RemoteConnection(remote_read_pipe, remote_write_pipe)
        finally:
            task.cancel()
            with suppress(asyncio.CancelledError):
                await task
