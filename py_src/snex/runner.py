from __future__ import annotations

import ast
import asyncio
import functools
import sys
import traceback
from typing import Any

from . import interface, models, serde, transport
from .models import (
    Command,
    EnvID,
    ErrorResponse,
    EvalCommand,
    InitCommand,
    MakeEnvCommand,
    OkEnvResponse,
    OkResponse,
    OkValueResponse,
    Response,
)

ID_LEN_BYTES = 16

root_env: dict[str, Any] = {}
envs: dict[EnvID, dict[str, Any]] = {}


async def run_code(code: str, env: dict[str, Any]) -> None:
    code = compile(code, "", "exec", flags=ast.PyCF_ALLOW_TOP_LEVEL_AWAIT)
    res = eval(code, env, env)  # noqa: S307
    if asyncio.iscoroutine(res):
        await res


async def run_init(cmd: InitCommand) -> Response:
    if cmd["code"]:
        await run_code(cmd["code"], root_env)

    return OkResponse(status="ok")


def run_make_env(cmd: MakeEnvCommand) -> Response:
    env = root_env.copy()

    for from_env_cmd in cmd["from_env"]:
        try:
            from_env_id = models.env_id_deserialize(from_env_cmd["env_id"])
            from_env = envs[from_env_id]
        except KeyError:
            return ErrorResponse(
                status="error",
                code="env_not_found",
                reason="Environment {from_env_cmd.env_id} not found",
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

    env_id = models.env_id_generate()
    envs[env_id] = env

    return OkEnvResponse(status="ok_env", id=models.env_id_serialize(env_id))


async def run_eval(cmd: EvalCommand) -> Response:
    env_id_str = cmd["env_id"]
    try:
        env_id = models.env_id_deserialize(env_id_str)
        env = envs[env_id]
    except KeyError:
        return ErrorResponse(
            status="error",
            code="env_not_found",
            reason=f"Environment {env_id_str} not found",
        )

    for key, value in cmd["additional_vars"].items():
        env[key] = value

    if cmd["code"]:
        await run_code(cmd["code"], env)

    if cmd["returning"]:
        try:
            value = eval(cmd["returning"], env, env)  # noqa: S307
            return OkValueResponse(status="ok_value", value=value)
        except KeyError as e:
            return ErrorResponse(
                status="error",
                code="env_key_not_found",
                reason=f"Key {e.args[0]} not found in environment {env_id_str}",
            )

    return OkResponse(status="ok")


async def run(serialized_data: bytes) -> Response:
    data: Command = serde.decode(serialized_data)

    if data["command"] == "init":
        return await run_init(data)

    if data["command"] == "make_env":
        return run_make_env(data)

    if data["command"] == "eval":
        return await run_eval(data)

    return ErrorResponse(
        status="error",
        code="internal_error",
        reason=f"Unknown command: {data}",
    )


def clean_env(env_id: EnvID) -> None:
    envs.pop(env_id)


def on_task_done(
    writer: asyncio.WriteTransport,
    req_id: bytes,
    running_tasks: set[asyncio.Task[Any]],
    task: asyncio.Task[Any],
) -> None:
    running_tasks.discard(task)

    try:
        transport.write_response(writer, req_id, task.result())
    except Exception as e:  # noqa: BLE001
        result = ErrorResponse(
            status="error",
            code="python_runtime_error",
            reason=str(e),
            traceback=traceback.format_exception(e),
        )
        transport.write_response(writer, req_id, result)


async def run_loop() -> None:
    loop = asyncio.get_running_loop()
    running_tasks: set[asyncio.Task[Any]] = set()

    reader, writer = await transport.setup_io(loop)
    root_env["snex"] = interface.Snex(writer)

    while True:
        try:
            byte_cnt = int.from_bytes(await reader.readexactly(4), "big")
            all_data = await reader.readexactly(byte_cnt)
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
            req_id = all_data[:16]
            if all_data[16:18] == b"gc":
                clean_env(EnvID(req_id))
                continue

            if all_data[16] != transport.MessageType.REQUEST:
                msg = f"Invalid message type: request expected, got {all_data[16]}"
                raise ValueError(msg)  # noqa: TRY301

            serialized_data = all_data[17:]

            task = loop.create_task(run(serialized_data))
            running_tasks.add(task)
            task.add_done_callback(
                functools.partial(on_task_done, writer, req_id, running_tasks),
            )
        except Exception as e:  # noqa: BLE001
            result = ErrorResponse(
                status="error",
                code="python_runtime_error",
                reason=str(e),
                traceback=traceback.format_exception(e),
            )
            transport.write_response(writer, req_id, result)
