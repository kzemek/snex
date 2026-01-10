from __future__ import annotations

import random
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


class Term(bytes):
    __slots__ = ()


class Code(TypedDict):
    src: str
    file: str
    line: int


class InitCommand(TypedDict):
    type: Literal["init"]
    code: Code | None
    additional_vars: dict[str, object]


class MakeEnvCommandFromEnv(TypedDict):
    env: EnvID
    keys_mode: Literal["only", "except"]
    keys: list[str]


class MakeEnvCommand(TypedDict):
    type: Literal["make_env"]
    from_env: list[MakeEnvCommandFromEnv]
    additional_vars: dict[str, object]


class EvalCommand(TypedDict):
    type: Literal["eval"]
    code: Code | None
    env: EnvID | None
    additional_vars: dict[str, object]


class GCCommand(TypedDict):
    type: Literal["gc"]
    env: EnvID


class OkResponse(TypedDict):
    status: Literal["ok"]
    value: object


class SendCommand(TypedDict):
    type: Literal["send"]
    to: Term
    data: object


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
OutResponse = OkResponse | ErrorResponse
