from __future__ import annotations

import functools
import struct
from typing import TYPE_CHECKING, Any

from .models import Atom, Term

if TYPE_CHECKING:
    from collections.abc import Callable

Parts = list[bytes | bytearray | memoryview]

ETF_VERSION = 131

# Constants
SMALL_INTEGER_EXT = 97
INTEGER_EXT = 98
SMALL_TUPLE_EXT = 104
LARGE_TUPLE_EXT = 105
NIL_EXT = 106
LIST_EXT = 108
BINARY_EXT = 109
SMALL_BIG_EXT = 110
LARGE_BIG_EXT = 111
MAP_EXT = 116
ATOM_UTF8_EXT = 118
SMALL_ATOM_UTF8_EXT = 119
NEW_FLOAT_EXT = 70

# Structs
SMALL_INTEGER_STRUCT = struct.Struct("BB")
INTEGER_STRUCT = struct.Struct(">Bi")
SMALL_BIG_STRUCT = struct.Struct("BBB")
LARGE_BIG_STRUCT = struct.Struct(">BIB")
NEW_FLOAT_STRUCT = struct.Struct(">Bd")
ATOM_UTF8_STRUCT = struct.Struct(">BH")
SMALL_TUPLE_STRUCT = struct.Struct("BB")
LENGTH32_STRUCT = struct.Struct(">BI")

# Limits
MAX_U8 = 0xFF
MAX_U16 = 0xFFFF
MAX_U32 = 0xFFFFFFFF
MAX_I32 = 0x7FFFFFFF
MIN_I32 = -0x80000000

# Pre-encoded
BYTES_VERSION = bytes([ETF_VERSION])
BYTES_NIL_EXT = bytes([NIL_EXT])
BYTES_NIL = bytes([SMALL_ATOM_UTF8_EXT, 3]) + b"nil"
BYTES_TRUE = bytes([SMALL_ATOM_UTF8_EXT, 4]) + b"true"
BYTES_FALSE = bytes([SMALL_ATOM_UTF8_EXT, 5]) + b"false"
BYTES_ATOM_INF = bytes([SMALL_ATOM_UTF8_EXT, 3]) + b"inf"
BYTES_ATOM_NEGINF = bytes([SMALL_ATOM_UTF8_EXT, 4]) + b"-inf"
BYTES_ATOM_NAN = bytes([SMALL_ATOM_UTF8_EXT, 3]) + b"nan"
BYTES_FLOAT_INF = NEW_FLOAT_STRUCT.pack(NEW_FLOAT_EXT, float("inf"))
BYTES_FLOAT_NEGINF = NEW_FLOAT_STRUCT.pack(NEW_FLOAT_EXT, float("-inf"))
BYTES_FLOAT_NAN = NEW_FLOAT_STRUCT.pack(NEW_FLOAT_EXT, float("nan"))

# Float handling
_FLOAT_ATOMS = {
    BYTES_FLOAT_INF: BYTES_ATOM_INF,
    BYTES_FLOAT_NEGINF: BYTES_ATOM_NEGINF,
    BYTES_FLOAT_NAN: BYTES_ATOM_NAN,
}

# Small integer fast path
SMALL_INT_CACHE = [bytes((SMALL_INTEGER_EXT, i)) for i in range(256)]


def _default_custom_encoder(data: object) -> object:
    msg = f"Cannot serialize object of {type(data)}"
    raise TypeError(msg)


_custom_encoder: Callable[[object], object] = _default_custom_encoder


def set_custom_encoder(encoder_fun: Callable[[object], object]) -> None:
    """
    Set a custom encoding function for objects that are not supported by default.

    Args:
        encoder_fun: The function to use to encode the objects

    """
    global _custom_encoder  # noqa: PLW0603
    _custom_encoder = encoder_fun


def encode(data: object) -> Parts:
    parts: Parts = [BYTES_VERSION]
    _ENCODER_DISPATCH.get(type(data), _encode_custom)(data, parts)
    return parts


def _encode_int(data: int, parts: Parts) -> None:
    if 0 <= data <= MAX_U8:
        parts.append(SMALL_INT_CACHE[data])
    elif MIN_I32 <= data <= MAX_I32:
        parts.append(INTEGER_STRUCT.pack(INTEGER_EXT, data))
    else:
        sign = 0 if data >= 0 else 1
        if sign:
            data = -data

        length = (data.bit_length() + 7) // 8 or 1
        if length <= MAX_U8:
            parts.append(SMALL_BIG_STRUCT.pack(SMALL_BIG_EXT, length, sign))
        elif length <= MAX_U32:
            parts.append(LARGE_BIG_STRUCT.pack(LARGE_BIG_EXT, length, sign))
        else:
            msg = f"integer out of range: {data}"
            raise ValueError(msg)

        parts.append(data.to_bytes(length, "little"))


def _encode_bool(data: bool, parts: Parts) -> None:  # noqa: FBT001
    parts.append(BYTES_TRUE if data else BYTES_FALSE)


def _encode_none(_: None, parts: Parts) -> None:
    parts.append(BYTES_NIL)


def _encode_float(data: float, parts: Parts) -> None:
    b = NEW_FLOAT_STRUCT.pack(NEW_FLOAT_EXT, data)
    parts.append(_FLOAT_ATOMS.get(b, b))


def _encode_str(data: str, parts: Parts) -> None:
    encoded = data.encode("utf-8")
    parts.append(LENGTH32_STRUCT.pack(BINARY_EXT, len(encoded)))
    parts.append(encoded)


def _encode_atom(data: str, parts: Parts) -> None:
    parts.append(_encode_atom_bytes(data))


def _encode_bytes_like(data: bytes | bytearray | memoryview, parts: Parts) -> None:
    parts.append(LENGTH32_STRUCT.pack(BINARY_EXT, len(data)))
    parts.append(data)


def _encode_term(data: Term, parts: Parts) -> None:
    mv = memoryview(data.value)
    # Report the highest ETF version found in the data.
    # The rest of the encoder uses a very conservative subset of the protocol,
    # but terms are arbitrary data encoded with current `:erlang.term_to_binary/1`.
    if mv[0] > parts[0][0]:
        parts[0] = mv[0:1]
    parts.append(mv[1:])


def _encode_list(data: list[object], parts: Parts) -> None:
    if data:
        parts.append(LENGTH32_STRUCT.pack(LIST_EXT, len(data)))
        for item in data:
            _ENCODER_DISPATCH.get(type(item), _encode_custom)(item, parts)
    parts.append(BYTES_NIL_EXT)


def _encode_tuple(data: tuple[object, ...], parts: Parts) -> None:
    length = len(data)
    if length <= MAX_U8:
        parts.append(SMALL_TUPLE_STRUCT.pack(SMALL_TUPLE_EXT, length))
    elif length <= MAX_U32:
        parts.append(LENGTH32_STRUCT.pack(LARGE_TUPLE_EXT, length))
    else:
        msg = f"tuple too long: {data}"
        raise ValueError(msg)

    for item in data:
        _ENCODER_DISPATCH.get(type(item), _encode_custom)(item, parts)


def _encode_dict(data: dict[object, object], parts: Parts) -> None:
    parts.append(LENGTH32_STRUCT.pack(MAP_EXT, len(data)))
    for key, value in data.items():
        _ENCODER_DISPATCH.get(type(key), _encode_custom)(key, parts)
        _ENCODER_DISPATCH.get(type(value), _encode_custom)(value, parts)


def _encode_set(data: set[object] | frozenset[object], parts: Parts) -> None:
    # This depends on MapSet internal representation.
    # It is technically opaque, though stable for a long time now.
    # If it ever changes, we'll need to update this serializer.
    parts.extend(
        (
            LENGTH32_STRUCT.pack(MAP_EXT, 2),
            _encode_atom_bytes("__struct__"),
            _encode_atom_bytes("Elixir.MapSet"),
            _encode_atom_bytes("map"),
            LENGTH32_STRUCT.pack(MAP_EXT, len(data)),
        ),
    )
    for elem in data:
        _ENCODER_DISPATCH.get(type(elem), _encode_custom)(elem, parts)
        parts.append(BYTES_NIL_EXT)


def _encode_custom(data: object, parts: Parts) -> None:
    if isinstance(data, bool):
        _encode_bool(data, parts)
    elif isinstance(data, int):
        _encode_int(data, parts)
    elif isinstance(data, float):
        _encode_float(data, parts)
    elif isinstance(data, str):
        _encode_str(data, parts)
    elif isinstance(data, (bytes, bytearray, memoryview)):
        _encode_bytes_like(data, parts)
    elif isinstance(data, list):
        _encode_list(data, parts)
    elif isinstance(data, tuple):
        _encode_tuple(data, parts)
    elif isinstance(data, dict):
        _encode_dict(data, parts)
    elif isinstance(data, (set, frozenset)):
        _encode_set(data, parts)
    else:
        data = _custom_encoder(data)
        _ENCODER_DISPATCH.get(type(data), _encode_custom)(data, parts)


_ENCODER_DISPATCH: dict[type, Callable[[Any, Parts], None]] = {
    int: _encode_int,
    bool: _encode_bool,
    type(None): _encode_none,
    float: _encode_float,
    str: _encode_str,
    Atom: _encode_atom,
    bytes: _encode_bytes_like,
    bytearray: _encode_bytes_like,
    memoryview: _encode_bytes_like,
    Term: _encode_term,
    list: _encode_list,
    tuple: _encode_tuple,
    dict: _encode_dict,
    set: _encode_set,
    frozenset: _encode_set,
}


# The lru_cache is faster even though it adds a function call overhead
@functools.lru_cache(maxsize=4096)
def _encode_atom_bytes(data: str) -> bytes:
    if len(data) > MAX_U8:
        msg = f"atom too long: {data}"
        raise ValueError(msg)

    encoded = data.encode("utf-8")
    length = len(encoded)
    if length <= MAX_U8:
        return bytes((SMALL_ATOM_UTF8_EXT, length)) + encoded
    if length <= MAX_U16:
        return ATOM_UTF8_STRUCT.pack(ATOM_UTF8_EXT, length) + encoded

    msg = f"atom too long: {data}"
    raise ValueError(msg)
