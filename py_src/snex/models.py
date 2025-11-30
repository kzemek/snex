from __future__ import annotations

import random
from typing import TYPE_CHECKING, Any, Literal, NewType, TypedDict

if TYPE_CHECKING:
    from typing import NotRequired

    from .serde import ErlangTerm


EnvID = NewType("EnvID", bytes)


def generate_id() -> bytes:
    return random.randbytes(16)  # noqa: S311


class Timestamps(TypedDict):
    request_python_dequeued: int
    request_decoded: NotRequired[int]
    command_executed: NotRequired[int]


class InitCommand(TypedDict):
    command: Literal["init"]
    code: str | None


class MakeEnvCommandFromEnv(TypedDict):
    env: EnvID
    keys_mode: Literal["only", "except"]
    keys: list[str]


class MakeEnvCommand(TypedDict):
    command: Literal["make_env"]
    from_env: list[MakeEnvCommandFromEnv]
    additional_vars: dict[str, Any]


class EvalCommand(TypedDict):
    command: Literal["eval"]
    code: str | None
    env: EnvID
    returning: str | None
    additional_vars: dict[str, Any]


class OkResponse(TypedDict):
    status: Literal["ok"]
    timestamps: NotRequired[Timestamps]


class OkEnvResponse(TypedDict):
    status: Literal["ok_env"]
    timestamps: NotRequired[Timestamps]
    id: EnvID


class OkValueResponse(TypedDict):
    status: Literal["ok_value"]
    timestamps: NotRequired[Timestamps]
    value: Any


class SendCommand(TypedDict):
    command: Literal["send"]
    to: ErlangTerm
    data: Any


class ErrorResponse(TypedDict):
    status: Literal["error"]
    timestamps: NotRequired[Timestamps]
    code: Literal[
        "internal_error",
        "python_runtime_error",
        "env_not_found",
        "env_key_not_found",
    ]
    reason: str
    traceback: NotRequired[list[str] | None]


Command = InitCommand | MakeEnvCommand | EvalCommand
Request = SendCommand
Response = OkResponse | OkEnvResponse | OkValueResponse | ErrorResponse
