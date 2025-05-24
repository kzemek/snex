import functools
import json
from typing import Any


class ErlangTerm(bytes):
    __slots__ = ()


def decode(data: bytes) -> Any:  # noqa: ANN401
    binary_data_len = int.from_bytes(data[:4], "big")
    binary_data = data[4 : 4 + binary_data_len]
    json_data = data[4 + binary_data_len :]

    def decode_object_hook(
        binary_data: bytes,
        obj: dict[str, Any],
    ) -> Any:  # noqa: ANN401
        match obj.get("__snex__"):
            case ["binary", offset, size]:
                return binary_data[offset : offset + size]
            case ["term", offset, size]:
                return ErlangTerm(binary_data[offset : offset + size])
            case _:
                return obj

    return json.loads(
        json_data,
        object_hook=functools.partial(decode_object_hook, binary_data),
    )


def encode(o: Any) -> list[bytes | bytearray]:  # noqa: ANN401
    def encode_default(binary_data: bytearray, o: Any) -> Any:  # noqa: ANN401
        if isinstance(o, ErlangTerm):
            ret = {"__snex__": ["term", len(binary_data), len(o)]}
            binary_data.extend(o)
            return ret

        if isinstance(o, bytes):
            ret = {"__snex__": ["binary", len(binary_data), len(o)]}
            binary_data.extend(o)
            return ret

        msg = f"Object of type {type(o).__name__} is not JSON serializable"
        raise TypeError(msg)

    binary_data = bytearray()
    json_data = json.dumps(o, default=functools.partial(encode_default, binary_data))

    return [
        int.to_bytes(len(binary_data), length=4, byteorder="big"),
        binary_data,
        json_data.encode("utf-8"),
    ]
