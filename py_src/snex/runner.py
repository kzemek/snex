from __future__ import annotations

import ast
import asyncio
import base64
import functools
import pickle
import sys
import traceback
from typing import Literal

import snex

from . import interface, transport
from .models import (
    Code,
    EnvID,
    ErrorResponse,
    EvalCommand,
    GCCommand,
    InitCommand,
    InRequest,
    InResponse,
    MakeEnvCommand,
    OkResponse,
    OkValueResponse,
    OutResponse,
    generate_id,
)

ID_LEN_BYTES = 16

root_env: dict[str, object] = {}
envs: dict[EnvID, dict[str, object]] = {}


def env_id_to_str(env_id: EnvID) -> str:
    return base64.b64encode(env_id).decode()


async def run_code(
    code: Code,
    env: dict[str, object],
    mode: Literal["exec", "eval"],
) -> object:
    line_offset = code["line"] - 1
    if code["code"] and code["code"][-1] == "\n":
        # heuristic: if the code ends with a newline, then assume we're
        # in a heredoc. In that case, code starts at next line.
        line_offset += 1

    # offset the actual code for accurate line reporting
    code_str = "\n" * line_offset + code["code"]

    flags = 0 if mode == "eval" else ast.PyCF_ALLOW_TOP_LEVEL_AWAIT
    code_obj = compile(code_str, code["file"], mode, flags=flags)
    res = eval(code_obj, env, env)  # noqa: S307

    if asyncio.iscoroutine(res):
        await res

    return res if mode == "eval" else None


async def run_init(cmd: InitCommand) -> OkResponse:
    root_env.update(cmd["additional_vars"])

    if cmd["code"]:
        await run_code(cmd["code"], root_env, "exec")

    return OkResponse(status="ok")


def run_make_env(cmd: MakeEnvCommand) -> OkValueResponse | ErrorResponse:
    env = root_env.copy()

    for from_env_cmd in cmd["from_env"]:
        env_id = from_env_cmd["env"]
        try:
            from_env = envs[env_id]
        except KeyError:
            return ErrorResponse(
                status="error",
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

    return OkValueResponse(status="ok_value", value=env_id)


async def run_eval(cmd: EvalCommand) -> OkResponse | OkValueResponse | ErrorResponse:
    env_id = cmd["env"]
    try:
        env = envs[env_id]
    except KeyError:
        return ErrorResponse(
            status="error",
            code="env_not_found",
            reason=f"Environment {env_id_to_str(env_id)} not found",
        )

    env.update(cmd["additional_vars"])

    if cmd["code"]:
        await run_code(cmd["code"], env, "exec")

    if cmd["returning"]:
        value = await run_code(cmd["returning"], env, "eval")
        return OkValueResponse(status="ok_value", value=value)

    return OkResponse(status="ok")


def run_gc(cmd: GCCommand) -> None:
    envs.pop(cmd["env"], None)


async def run(req_id: bytes, data: InRequest | InResponse) -> OutResponse | None:
    result: OutResponse | None = None

    if data["command"] == "init":
        result = await run_init(data)

    elif data["command"] == "make_env":
        result = run_make_env(data)

    elif data["command"] == "eval":
        result = await run_eval(data)

    elif data["command"] == "gc":
        run_gc(data)

    elif data["command"] == "call_response" or data["command"] == "call_error_response":
        interface.on_call_response(req_id, data)

    else:
        result = ErrorResponse(
            status="error",
            code="internal_error",
            reason=f"Unknown command: {data}",
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
                transport.write_response(writer, req_id, result)
            except Exception as e:  # noqa: BLE001
                exc = e

        if exc is not None:
            error_result = ErrorResponse(
                status="error",
                code="python_runtime_error",
                reason=str(exc),
                traceback=traceback.format_exception(exc),
            )

            transport.write_response(writer, req_id, error_result)

    except asyncio.CancelledError:
        pass


async def run_loop() -> None:
    loop = asyncio.get_running_loop()
    running_tasks: set[asyncio.Task[OutResponse | None]] = set()

    reader, writer = await transport.setup_io(loop)
    interface.init(writer)
    root_env["snex"] = snex

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

            if all_data[16] not in [
                transport.MessageType.REQUEST,
                transport.MessageType.RESPONSE,
            ]:
                msg = f"Invalid message type: {all_data[16]}"
                raise ValueError(msg)  # noqa: TRY301

            command: InRequest = pickle.loads(all_data[17:])  # noqa: S301

            task = loop.create_task(run(req_id, command))
            running_tasks.add(task)
            task.add_done_callback(
                functools.partial(on_task_done, writer, req_id, running_tasks),
            )
        except asyncio.CancelledError:
            break
        except Exception as e:  # noqa: BLE001
            result = ErrorResponse(
                status="error",
                code="python_runtime_error",
                reason=str(e),
                traceback=traceback.format_exception(e),
            )
            transport.write_response(writer, req_id, result)
