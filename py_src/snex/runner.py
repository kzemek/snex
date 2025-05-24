import ast
import asyncio
import functools
import json
import sys
from typing import Any

from .models import (
    EnvID,
    ErrorCode,
    ErrorResponse,
    EvalCommand,
    MakeEnvCommand,
    OkEnvResponse,
    OkResponse,
    OkValueResponse,
    Response,
)

ID_LEN_BYTES = 16

erl_out_transport: asyncio.WriteTransport
envs: dict[EnvID, dict[str, Any]] = {}


def write_response(req_id: bytes, response: Response) -> None:
    data_json = json.dumps(response.__dict__).encode("utf-8")
    bytes_cnt = len(req_id) + len(data_json)

    erl_out_transport.writelines(
        [int.to_bytes(bytes_cnt, length=4, byteorder="big"), req_id, data_json],
    )


def run_make_env(cmd: MakeEnvCommand) -> Response:
    env: dict[str, Any] = {}

    for from_env_cmd in cmd.from_env:
        try:
            from_env_id = EnvID.deserialize(from_env_cmd.env_id)
            from_env = envs[from_env_id]
        except KeyError:
            return ErrorResponse(
                ErrorCode.ENV_NOT_FOUND,
                "Environment {from_env_cmd.env_id} not found",
            )

        if from_env_cmd.keys_mode == "only":
            for key in from_env_cmd.keys:
                env[key] = from_env.get(key)
        else:
            for key in from_env:
                if key not in from_env_cmd.keys:
                    env[key] = from_env[key]

    env.update(cmd.additional_vars)

    env_id = EnvID.generate()
    envs[env_id] = env

    return OkEnvResponse(env_id.serialize())


async def run_eval(cmd: EvalCommand) -> Response:
    try:
        env_id = EnvID.deserialize(cmd.env_id)
        env = envs[env_id]
    except KeyError:
        return ErrorResponse(
            ErrorCode.ENV_NOT_FOUND,
            f"Environment {cmd.env_id} not found",
        )

    for key, value in cmd.additional_vars.items():
        env[key] = value

    if cmd.code:
        code = compile(cmd.code, "", "exec", flags=ast.PyCF_ALLOW_TOP_LEVEL_AWAIT)
        res = eval(code, env, env)  # noqa: S307
        if asyncio.iscoroutine(res):
            await asyncio.create_task(res)

    if cmd.returning:
        try:
            value = eval(cmd.returning, env, env)  # noqa: S307
            return OkValueResponse(value)
        except KeyError as e:
            return ErrorResponse(
                ErrorCode.ENV_KEY_NOT_FOUND,
                f"Key {e.args[0]} not found in environment {cmd.env_id}",
            )

    return OkResponse()


async def run(json_data: bytes) -> Response:
    data = json.loads(json_data)

    if data["command"] == "make_env":
        return run_make_env(MakeEnvCommand(**data))

    if data["command"] == "eval":
        return await run_eval(EvalCommand(**data))

    return ErrorResponse(
        ErrorCode.INTERNAL_ERROR,
        f"Unknown command: {json_data.decode('utf-8')}",
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
        result = ErrorResponse(ErrorCode.PYTHON_RUNTIME_ERROR, str(e))
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

        req_id = all_data[:16]
        json_data = all_data[16:]

        try:
            if json_data == b"gc":
                clean_env(EnvID(req_id))
                continue

            task = loop.create_task(run(json_data))
            running_tasks.add(task)
            task.add_done_callback(
                functools.partial(on_task_done, req_id, running_tasks),
            )
        except Exception as e:  # noqa: BLE001
            result = ErrorResponse(ErrorCode.PYTHON_RUNTIME_ERROR, str(e))
            write_response(req_id, result)
