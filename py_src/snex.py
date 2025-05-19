import ast
import asyncio
import base64
import enum
import json
import random
import sys
from dataclasses import dataclass
from enum import auto
from typing import Any, Literal

ID_LEN_BYTES = 16

EnvID = bytes
EnvIDStr = str


@dataclass
class MakeEnvCommand:
    @dataclass
    class FromEnv:
        env_id: EnvIDStr
        keys_mode: Literal["only", "except"]
        keys: list[str]
        command: Literal["from_env"] = "from_env"

    from_env: list[FromEnv]
    additional_values: dict[str, Any]
    command: Literal["make_env"] = "make_env"

    def __init__(
        self,
        from_env: list[dict[str, Any]],
        additional_values: dict[str, Any],
        command: Literal["make_env"] = "make_env",
    ) -> None:
        self.from_env = [self.FromEnv(**args) for args in from_env]
        self.additional_values = additional_values
        self.command = command


@dataclass
class EvalCommand:
    code: str | None
    env_id: EnvIDStr
    returning: str | None
    additional_values: dict[str, Any]
    command: Literal["eval"] = "eval"


@dataclass
class OkResponse:
    status: Literal["ok"] = "ok"


@dataclass
class OkEnvResponse:
    id: EnvIDStr
    status: Literal["ok_env"] = "ok_env"


@dataclass
class OkValueResponse:
    value: Any
    status: Literal["ok_value"] = "ok_value"


class ErrorCode(enum.StrEnum):
    INTERNAL_ERROR = auto()
    PYTHON_RUNTIME_ERROR = auto()
    ENV_NOT_FOUND = auto()
    ENV_KEY_NOT_FOUND = auto()


@dataclass
class ErrorResponse:
    code: ErrorCode
    reason: str
    status: Literal["error"] = "error"


Command = MakeEnvCommand | EvalCommand
Response = OkResponse | OkEnvResponse | OkValueResponse | ErrorResponse

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
            from_env_id = base64.b64decode(from_env_cmd.env_id)
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

    env.update(cmd.additional_values)

    env_id: EnvID = random.randbytes(16)  # noqa: S311
    envs[env_id] = env

    return OkEnvResponse(base64.b64encode(env_id).decode("utf-8"))


async def run_eval(cmd: EvalCommand) -> Response:
    try:
        env_id = base64.b64decode(cmd.env_id)
        env = envs[env_id]
    except KeyError:
        return ErrorResponse(
            ErrorCode.ENV_NOT_FOUND,
            f"Environment {cmd.env_id} not found",
        )

    for key, value in cmd.additional_values.items():
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


async def main() -> None:
    loop = asyncio.get_running_loop()

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
                clean_env(req_id)
                continue

            result = await run(json_data)
            write_response(req_id, result)
        except Exception as e:  # noqa: BLE001
            result = ErrorResponse(ErrorCode.PYTHON_RUNTIME_ERROR, str(e))
            write_response(req_id, result)


asyncio.run(main())
