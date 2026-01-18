from __future__ import annotations

import random
import sys
from enum import IntEnum
from typing import TYPE_CHECKING, Literal, NewType, TypedDict

if sys.version_info >= (3, 11):
    from enum import StrEnum
else:
    from enum import Enum

    class StrEnum(str, Enum):
        pass


if TYPE_CHECKING:
    from typing import NotRequired


EnvID = NewType("EnvID", bytes)


def generate_id() -> bytes:
    return random.randbytes(16)  # noqa: S311


class Atom(str):
    """
    Atom represents an Elixir atom.

    Will be converted to atom when decoded in Elixir.
    """

    __slots__ = ()

    def __repr__(self) -> str:
        return f"snex.Atom({self!s})"


class DistinctAtom(Atom):
    """
    DistinctAtom represents an Elixir atom that is not equal to a bare `str`.

    Will be converted to atom when decoded in Elixir.

    Unlike `snex.Atom`, `snex.DistinctAtom` does not compare equal to a bare `str`
    (or, by extension, `snex.Atom`). In other words, `"foo" != snex.DistinctAtom("foo")`
    while `"foo" == snex.Atom("foo")`.  This allows to mix atom and string keys
    in a dictionary.
    """

    __slots__ = ()

    def __eq__(self, other: object) -> bool:
        return isinstance(other, DistinctAtom) and super().__eq__(other)

    def __ne__(self, other: object) -> bool:
        return not isinstance(other, DistinctAtom) or super().__ne__(other)

    def __hash__(self) -> int:
        return hash((DistinctAtom, str(self)))

    def __repr__(self) -> str:
        return f"snex.DistinctAtom({self!s})"


class Term:
    """
    Term represents an Elixir term, opaque on Python side.

    Created on Elixir side by encoding otherwise unserializable terms, or wrapping
    a term with `Snex.Serde.term/1`. It's not supposed to be created or modified
    on Python side. It's decoded back to the original term on Elixir side.
    """

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


class EncodingOpt:
    """Options for encoding Elixir terms into Python objects."""

    class BinaryAs(StrEnum):
        """
        The representation of Elixir binaries on the Python side.

        - `STR` (`"str"`) encodes binary as `str`
        - `BYTES` (`"bytes"`) encodes binary as `bytes`
        - `BYTEARRAY` (`"bytearray"`) encodes binary as `bytearray`
        """

        STR = Atom("str")
        BYTES = Atom("bytes")
        BYTEARRAY = Atom("bytearray")

    class SetAs(StrEnum):
        """
        The representation of Elixir `MapSet`s on the Python side.

        - `SET` (`"set"`) encodes `MapSet` as `set`
        - `FROZENSET` (`"frozenset"`) encodes `MapSet` as `frozenset`
        """

        SET = Atom("set")
        FROZENSET = Atom("frozenset")

    class AtomAs(StrEnum):
        """
        The representation of Elixir atoms on the Python side.

        - `ATOM` (`"atom"`) encodes atom as `snex.Atom`
        - `DISTINCT_ATOM` (`"distinct_atom"`) encodes atom as `snex.DistinctAtom`
        """

        ATOM = Atom("atom")
        DISTINCT_ATOM = Atom("distinct_atom")


class EncodingOpts(TypedDict):
    """
    Configuration for encoding Elixir terms into Python objects.

    Attributes:
        binary_as (NotRequired[EncodingOpt.BinaryAs]): How Elixir binaries are encoded
        set_as (NotRequired[EncodingOpt.SetAs]): How Elixir `MapSet`s are encoded
        atom_as (NotRequired[EncodingOpt.AtomAs]): How Elixir atoms are encoded

    """

    binary_as: NotRequired[EncodingOpt.BinaryAs]
    set_as: NotRequired[EncodingOpt.SetAs]
    atom_as: NotRequired[EncodingOpt.AtomAs]


class CallCommand(TypedDict):
    type: Literal["call"]
    module: str | Atom | Term
    function: str | Atom | Term
    args: list[object]
    node: NotRequired[str | Atom | Term]
    result_encoding_opts: NotRequired[EncodingOpts]


class CastCommand(TypedDict):
    type: Literal["cast"]
    module: str | Atom | Term
    function: str | Atom | Term
    args: list[object]
    node: NotRequired[str | Atom | Term]


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
