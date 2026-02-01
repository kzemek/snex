import sys

if sys.version_info >= (3, 11):
    import enum

    StrEnum = enum.StrEnum
else:
    from enum import Enum

    class StrEnum(str, Enum):
        pass


if sys.version_info >= (3, 12):
    import typing

    override = typing.override
else:
    from collections.abc import Callable
    from typing import Any, TypeVar

    CallableT = TypeVar("CallableT", bound=Callable[..., Any])

    def override(func: CallableT, /) -> CallableT:
        return func
