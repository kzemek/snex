from __future__ import annotations

import asyncio
import base64
import functools
import pickle
import sys
import traceback

import snex

from . import code, interface, transport
from .models import (
    EnvID,
    ErrorResponse,
    EvalCommand,
    GCCommand,
    InitCommand,
    InRequest,
    InResponse,
    MakeEnvCommand,
    MessageType,
    OkResponse,
    OutResponse,
    generate_id,
)

Envs = dict[EnvID, dict[str, object]]

ID_LEN_BYTES = 16
ROOT_ENV_ID = EnvID(b"root")


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

    env_id = EnvID(generate_id())
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
    req_id: bytes,
    command: InRequest | InResponse,
    envs: Envs,
) -> OutResponse | None:
    result: OutResponse | None = None

    if command["type"] == "init":
        result = await run_init(command, envs)

    elif command["type"] == "make_env":
        result = run_make_env(command, envs)

    elif command["type"] == "eval":
        result = await run_eval(command, envs)

    elif command["type"] == "gc":
        run_gc(command, envs)

    elif command["type"] == "call_response" or command["type"] == "call_error_response":
        interface.on_call_response(req_id, command)

    else:
        result = ErrorResponse(
            type="error",
            code="internal_error",
            reason=f"Unknown command: {command}",
        )

    return result


def on_task_done(
    writer: asyncio.WriteTransport,
    req_id: bytes,
    running_tasks: set[asyncio.Task[OutResponse | None]],
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


async def run_loop() -> None:
    loop = asyncio.get_running_loop()
    running_tasks: set[asyncio.Task[OutResponse | None]] = set()
    envs: Envs = {ROOT_ENV_ID: {"snex": snex, "_SnexReturn": code.SnexReturn}}

    reader, writer = await transport.setup_io(loop)
    interface.init(writer)

    while True:
        try:
            byte_cnt = int.from_bytes(await reader.readexactly(4), "big")
            all_data = memoryview(await reader.readexactly(byte_cnt))
        except asyncio.IncompleteReadError:
            break

        if len(all_data) < ID_LEN_BYTES:
            print(  # noqa: T201
                "Invalid data: not enough bytes for an ID",
                file=sys.stderr,
                end="\r\n",
            )
            continue

        try:
            req_id = bytes(all_data[:16])
            _message_type = MessageType(all_data[16])

            command: InRequest = pickle.loads(all_data[17:])  # noqa: S301

            task = loop.create_task(run(req_id, command, envs))
            running_tasks.add(task)
            task.add_done_callback(
                functools.partial(on_task_done, writer, req_id, running_tasks),
            )
        except asyncio.CancelledError:
            break
        except Exception as e:  # noqa: BLE001
            result = ErrorResponse(
                type="error",
                code="python_runtime_error",
                reason=str(e),
                traceback=traceback.format_exception(e),
            )
            transport.write_data(writer, req_id, result)
