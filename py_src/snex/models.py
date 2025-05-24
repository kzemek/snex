import base64
import enum
import random
from enum import auto
from typing import Any, Literal, NewType, NotRequired, TypedDict

EnvIDStr = NewType("EnvIDStr", str)
EnvID = NewType("EnvID", bytes)


def env_id_generate() -> EnvID:
    return EnvID(random.randbytes(16))  # noqa: S311


def env_id_serialize(env_id: EnvID) -> EnvIDStr:
    return EnvIDStr(base64.b64encode(env_id).decode("utf-8"))


def env_id_deserialize(env_id_str: EnvIDStr) -> EnvID:
    return EnvID(base64.b64decode(env_id_str))


class InitCommand(TypedDict):
    command: Literal["init"]
    code: str | None


class MakeEnvCommandFromEnv(TypedDict):
    env_id: EnvIDStr
    keys_mode: Literal["only", "except"]
    keys: list[str]


class MakeEnvCommand(TypedDict):
    command: Literal["make_env"]
    from_env: list[MakeEnvCommandFromEnv]
    additional_vars: dict[str, Any]


class EvalCommand(TypedDict):
    command: Literal["eval"]
    code: str | None
    env_id: EnvIDStr
    returning: str | None
    additional_vars: dict[str, Any]


class OkResponse(TypedDict):
    status: Literal["ok"]


class OkEnvResponse(TypedDict):
    status: Literal["ok_env"]
    id: EnvIDStr


class OkValueResponse(TypedDict):
    status: Literal["ok_value"]
    value: Any


class ErrorCode(enum.StrEnum):
    INTERNAL_ERROR = auto()
    PYTHON_RUNTIME_ERROR = auto()
    ENV_NOT_FOUND = auto()
    ENV_KEY_NOT_FOUND = auto()


class ErrorResponse(TypedDict):
    status: Literal["error"]
    code: ErrorCode
    reason: str
    traceback: NotRequired[list[str] | None]


Command = MakeEnvCommand | EvalCommand
Response = OkResponse | OkEnvResponse | OkValueResponse | ErrorResponse
