from __future__ import annotations

import asyncio
import base64
import functools
import logging
import pickle
import traceback
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
    from typing import Final

    Envs = dict[EnvID, dict[str, object]]

ID_LEN_BYTES: Final[int] = 16
ROOT_ENV_ID: Final[EnvID] = EnvID(b"root")

logger: logging.Logger = logging.getLogger(__name__)


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


async def run_loop() -> None:
    loop = asyncio.get_running_loop()
    running_tasks: set[asyncio.Task[OutResponse | None]] = set()
    envs: Envs = {ROOT_ENV_ID: {"snex": snex, "_SnexReturn": code.SnexReturn}}

    reader, writer = await transport.setup_io(loop)
    interface.init(writer)

    logger.addHandler(LoggingHandler())

    while True:
        try:
            byte_cnt = int.from_bytes(await reader.readexactly(4), "big")
            all_data = memoryview(await reader.readexactly(byte_cnt))
        except asyncio.IncompleteReadError:
            break

        if len(all_data) < ID_LEN_BYTES + 1:
            logger.critical("Snex: not enough bytes for a message type and ID")
            continue

        req_id = bytes(all_data[:ID_LEN_BYTES])
        message_type = all_data[ID_LEN_BYTES]

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
        except asyncio.CancelledError:
            break
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
