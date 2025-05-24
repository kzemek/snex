import base64
import enum
import random
from dataclasses import dataclass
from enum import auto
from typing import Any, Literal

EnvIDStr = str


class EnvID(bytes):
    __slots__ = ()

    @classmethod
    def generate(cls) -> "EnvID":
        return cls(random.randbytes(16))  # noqa: S311

    def serialize(self) -> EnvIDStr:
        return base64.b64encode(self).decode("utf-8")

    @staticmethod
    def deserialize(s: EnvIDStr) -> "EnvID":
        return EnvID(base64.b64decode(s))


@dataclass
class MakeEnvCommand:
    @dataclass
    class FromEnv:
        env_id: EnvIDStr
        keys_mode: Literal["only", "except"]
        keys: list[str]
        command: Literal["from_env"] = "from_env"

    from_env: list[FromEnv]
    additional_vars: dict[str, Any]
    command: Literal["make_env"] = "make_env"

    def __init__(
        self,
        from_env: list[dict[str, Any]],
        additional_vars: dict[str, Any],
        command: Literal["make_env"] = "make_env",
    ) -> None:
        self.from_env = [self.FromEnv(**args) for args in from_env]
        self.additional_vars = additional_vars
        self.command = command


@dataclass
class EvalCommand:
    code: str | None
    env_id: EnvIDStr
    returning: str | None
    additional_vars: dict[str, Any]
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
