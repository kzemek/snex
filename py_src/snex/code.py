import ast
import asyncio
import functools
from types import CodeType
from typing import TypeVar, cast

from .models import Code

T = TypeVar("T", bound=ast.AST)


def _adjust_lineno(src: str, node: T, line_offset: int) -> T:
    line_offset = max(0, line_offset - 1)
    if src and src[-1] == "\n":
        # heuristic: if the code ends with a newline, then assume we're
        # in an Elixir heredoc. In that case, code starts at next line.
        line_offset += 1

    return ast.increment_lineno(node, line_offset)


@functools.lru_cache(maxsize=1024)
def _compile_exec(src: str, filename: str, line: int) -> CodeType:
    node = ast.parse(src, filename=filename, mode="exec")
    node = _adjust_lineno(src, node, line)

    code = compile(
        node,
        filename=filename,
        mode="exec",
        flags=ast.PyCF_ALLOW_TOP_LEVEL_AWAIT,
    )
    return cast("CodeType", code)


@functools.lru_cache(maxsize=1024)
def _compile_eval(src: str, filename: str, line: int) -> CodeType:
    node = ast.parse(src, filename=filename, mode="eval")
    node = _adjust_lineno(src, node, line)
    return compile(node, filename=filename, mode="eval")


async def run_exec(code: Code, env: dict[str, object]) -> None:
    compiled = _compile_exec(code["src"], code["file"], code["line"])
    res = eval(compiled, env, env)  # noqa: S307

    if asyncio.iscoroutine(res):
        await res


def run_eval(code: Code, env: dict[str, object]) -> object:
    compiled = _compile_eval(code["src"], code["file"], code["line"])
    return eval(compiled, env, env)  # noqa: S307
