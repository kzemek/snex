from __future__ import annotations

import random
from enum import IntEnum
from typing import TYPE_CHECKING, Literal, NewType, TypedDict

if TYPE_CHECKING:
    from typing import NotRequired


EnvID = NewType("EnvID", bytes)


def generate_id() -> bytes:
    return random.randbytes(16)  # noqa: S311


class Atom(str):
    __slots__ = ()

    def __repr__(self) -> str:
        return f"snex.Atom({self!s})"


class DistinctAtom(Atom):
    __slots__ = ()

    def __eq__(self, other: object) -> bool:
        return type(self) is type(other) and super().__eq__(other)

    def __ne__(self, other: object) -> bool:
        return type(self) is not type(other) or super().__ne__(other)

    def __hash__(self) -> int:
        return hash((type(self), str(self)))

    def __repr__(self) -> str:
        return f"snex.DistinctAtom({self!s})"


class Term:
    __slots__ = ("value",)

    value: bytes

    def __init__(self, value: bytes) -> None:
        self.value = value

    def __eq__(self, other: object) -> bool:
        return isinstance(other, Term) and self.value == other.value

    def __hash__(self) -> int:
        return hash((Term, self.value))

    def __repr__(self) -> str:
        return object.__repr__(self)


class Code(TypedDict):
    src: str
    file: str
    line: int


class InitCommand(TypedDict):
    type: Literal["init"]
    code: Code | None
    additional_vars: dict[str, object]


class MakeEnvCommandFromEnv(TypedDict):
    env_id: EnvID
    keys_mode: Literal["only", "except"]
    keys: list[str]


class MakeEnvCommand(TypedDict):
    type: Literal["make_env"]
    from_env: list[MakeEnvCommandFromEnv]
    additional_vars: dict[str, object]


class EvalCommand(TypedDict):
    type: Literal["eval"]
    code: Code | None
    env_id: EnvID | None
    additional_vars: dict[str, object]


class GCCommand(TypedDict):
    type: Literal["gc"]
    env_id: EnvID


class OkResponse(TypedDict):
    type: Literal["ok"]
    value: object


class CallCommand(TypedDict):
    type: Literal["call"]
    module: str | Atom | Term
    function: str | Atom | Term
    node: str | Atom | Term | None
    args: list[object]


class CastCommand(TypedDict):
    type: Literal["cast"]
    module: str | Atom | Term
    function: str | Atom | Term
    node: str | Atom | Term | None
    args: list[object]


class CallResponse(TypedDict):
    type: Literal["call_response"]
    result: object


class CallErrorResponse(TypedDict):
    type: Literal["call_error_response"]
    reason: str


class ErrorResponse(TypedDict):
    type: Literal["error"]
    code: Literal[
        "internal_error",
        "python_runtime_error",
        "env_not_found",
        "env_key_not_found",
    ]
    reason: str
    traceback: NotRequired[list[str] | None]


InRequest = InitCommand | MakeEnvCommand | EvalCommand
InRequestNoreply = GCCommand
InResponse = CallResponse | CallErrorResponse
InNoReply = InRequestNoreply | InResponse
OutRequest = CallCommand | CastCommand
OutResponse = OkResponse | ErrorResponse


class MessageType(IntEnum):
    REQUEST = 0
    REQUEST_NOREPLY = 1
    RESPONSE = 2


def out_message_type(data: OutRequest | OutResponse) -> MessageType:
    message_type: MessageType
    if data["type"] == "call":
        message_type = MessageType.REQUEST
    elif data["type"] == "cast":
        message_type = MessageType.REQUEST_NOREPLY
    else:
        message_type = MessageType.RESPONSE

    return message_type
