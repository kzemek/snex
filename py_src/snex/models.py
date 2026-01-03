from __future__ import annotations

import random
from typing import TYPE_CHECKING, Any, Literal, NewType, TypedDict

if TYPE_CHECKING:
    from typing import NotRequired


EnvID = NewType("EnvID", bytes)


def generate_id() -> bytes:
    return random.randbytes(16)  # noqa: S311


class Atom(str):
    __slots__ = ()

    def __repr__(self) -> str:
        return f"snex.Atom({super().__repr__()})"


class Term(bytes):
    __slots__ = ()


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


class GCCommand(TypedDict):
    command: Literal["gc"]
    env: EnvID


class OkResponse(TypedDict):
    status: Literal["ok"]


class OkEnvResponse(TypedDict):
    status: Literal["ok_env"]
    id: EnvID


class OkValueResponse(TypedDict):
    status: Literal["ok_value"]
    value: Any


class SendCommand(TypedDict):
    command: Literal["send"]
    to: Term
    data: Any


class CallCommand(TypedDict):
    command: Literal["call"]
    module: str | Atom | Term
    function: str | Atom | Term
    node: str | Atom | Term | None
    args: list[Any]


class CastCommand(TypedDict):
    command: Literal["cast"]
    module: str | Atom | Term
    function: str | Atom | Term
    node: str | Atom | Term | None
    args: list[Any]


class CallResponse(TypedDict):
    command: Literal["call_response"]
    result: Any


class CallErrorResponse(TypedDict):
    command: Literal["call_error_response"]


class ErrorResponse(TypedDict):
    status: Literal["error"]
    code: Literal[
        "internal_error",
        "python_runtime_error",
        "env_not_found",
        "env_key_not_found",
    ]
    reason: str
    traceback: NotRequired[list[str] | None]


InRequest = InitCommand | MakeEnvCommand | EvalCommand | GCCommand
InResponse = CallResponse | CallErrorResponse
OutRequest = SendCommand | CallCommand | CastCommand
OutResponse = OkResponse | OkEnvResponse | OkValueResponse | ErrorResponse
