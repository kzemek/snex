import ast
import asyncio
import functools
from types import CodeType
from typing import TypeVar, cast

from .models import Code


class SnexReturn(BaseException):
    __slots__ = ("value",)

    def __init__(self, value: object) -> None:
        self.value = value


class ReturnToRaiseTransformer(ast.NodeTransformer):
    def visit_FunctionDef(self, node: ast.FunctionDef) -> ast.FunctionDef:  # noqa: N802
        return node

    def visit_AsyncFunctionDef(  # noqa: N802
        self,
        node: ast.AsyncFunctionDef,
    ) -> ast.AsyncFunctionDef:
        return node

    def visit_ClassDef(self, node: ast.ClassDef) -> ast.ClassDef:  # noqa: N802
        return node

    def visit_Lambda(self, node: ast.Lambda) -> ast.Lambda:  # noqa: N802
        return node

    def visit_Return(self, node: ast.Return) -> ast.Raise:  # noqa: N802
        value = node.value if node.value is not None else ast.Constant(None)
        return ast.fix_missing_locations(
            ast.copy_location(
                ast.Raise(
                    exc=ast.Call(
                        func=ast.Name(id="_SnexReturn", ctx=ast.Load()),
                        args=[value],
                        keywords=[],
                    ),
                    cause=None,
                ),
                node,
            ),
        )


T = TypeVar("T", bound=ast.AST)


def _adjust_lineno(node: T, line_offset: int) -> T:
    line_offset = max(0, line_offset - 1)
    return ast.increment_lineno(node, line_offset)


@functools.lru_cache(maxsize=1024)
def _transform_and_compile_exec(src: str, filename: str, line: int) -> CodeType:
    node = ast.parse(src, filename=filename, mode="exec")
    node = _adjust_lineno(node, line)

    if node.body and isinstance(node.body[-1], ast.Return):
        stmt = node.body[-1]
        value = stmt.value if stmt.value is not None else ast.Constant(None)
        node.body[-1] = ast.fix_missing_locations(
            ast.copy_location(
                ast.Assign(
                    targets=[ast.Name(id="_snex_result", ctx=ast.Store())],
                    value=value,
                ),
                stmt,
            ),
        )

    code = compile(
        ReturnToRaiseTransformer().visit(node),
        filename=filename,
        mode="exec",
        flags=ast.PyCF_ALLOW_TOP_LEVEL_AWAIT,
    )
    return cast("CodeType", code)


async def run_exec(code: Code, env: dict[str, object]) -> object:
    compiled = _transform_and_compile_exec(code["src"], code["file"], code["line"])
    try:
        res = eval(compiled, env, env)  # noqa: S307
        if asyncio.iscoroutine(res):
            await res
    except SnexReturn as r:
        return r.value

    return env.pop("_snex_result", None)
