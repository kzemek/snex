import ast
import asyncio
import functools
import sys
import traceback
from typing import Any

from . import models, serde
from .models import (
    EnvID,
    ErrorCode,
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

erl_out_transport: asyncio.WriteTransport
root_env: dict[str, Any] = {}
envs: dict[EnvID, dict[str, Any]] = {}


def write_response(req_id: bytes, response: Response) -> None:
    data_list = serde.encode(response)
    data_len = sum(len(d) for d in data_list)
    bytes_cnt = len(req_id) + data_len

    erl_out_transport.writelines(
        [
            int.to_bytes(bytes_cnt, length=4, byteorder="big"),
            req_id,
            *data_list,
        ],
    )


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
                code=ErrorCode.ENV_NOT_FOUND,
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
            code=ErrorCode.ENV_NOT_FOUND,
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
                code=ErrorCode.ENV_KEY_NOT_FOUND,
                reason=f"Key {e.args[0]} not found in environment {env_id_str}",
            )

    return OkResponse(status="ok")


async def run(serialized_data: bytes) -> Response:
    data = serde.decode(serialized_data)

    if data["command"] == "init":
        return await run_init(data)

    if data["command"] == "make_env":
        return run_make_env(data)

    if data["command"] == "eval":
        return await run_eval(data)

    return ErrorResponse(
        status="error",
        code=ErrorCode.INTERNAL_ERROR,
        reason=f"Unknown command: {data}",
    )


def clean_env(env_id: EnvID) -> None:
    envs.pop(env_id)


def on_task_done(
    req_id: bytes,
    running_tasks: set[asyncio.Task[Any]],
    task: asyncio.Task[Any],
) -> None:
    running_tasks.discard(task)

    try:
        write_response(req_id, task.result())
    except Exception as e:  # noqa: BLE001
        result = ErrorResponse(
            status="error",
            code=ErrorCode.PYTHON_RUNTIME_ERROR,
            reason=str(e),
            traceback=traceback.format_exception(e),
        )
        write_response(req_id, result)


async def run_loop() -> None:
    loop = asyncio.get_running_loop()
    running_tasks: set[asyncio.Task[Any]] = set()

    erl_in = open(3, "rb", 0)  # noqa: ASYNC230, SIM115
    erl_out = open(4, "wb", 0)  # noqa: ASYNC230, SIM115

    global erl_out_transport
    erl_out_transport, _ = await loop.connect_write_pipe(asyncio.Protocol, erl_out)

    reader = asyncio.StreamReader()
    reader_protocol = asyncio.StreamReaderProtocol(reader)
    await loop.connect_read_pipe(lambda: reader_protocol, erl_in)

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

            serialized_data = all_data[16:]

            task = loop.create_task(run(serialized_data))
            running_tasks.add(task)
            task.add_done_callback(
                functools.partial(on_task_done, req_id, running_tasks),
            )
        except Exception as e:  # noqa: BLE001
            result = ErrorResponse(
                status="error",
                code=ErrorCode.PYTHON_RUNTIME_ERROR,
                reason=str(e),
                traceback=traceback.format_exception(e),
            )
            write_response(req_id, result)
