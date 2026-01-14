# /// script
# requires-python = ">=3.14"
# dependencies = []
# ///

from __future__ import annotations

import argparse
import inspect
import sys
from annotationlib import Format
from pathlib import Path
from typing import TYPE_CHECKING

sys.path.append("../py_src")

import snex

if TYPE_CHECKING:
    from types import FunctionType, ModuleType


def format_signature(obj: FunctionType, signature: inspect.Signature) -> str:
    async_ = "async " if inspect.iscoroutinefunction(obj) else ""
    preamble = f"{async_}def {obj.__name__}"
    max_width = 60 - len(preamble)
    return (
        "```python\n"
        + preamble
        + signature.format(max_width=max_width, quote_annotation_strings=False)
        + "\n```"
    )


def format_function(obj: FunctionType) -> str:
    if not obj.__doc__:
        return ""

    signature = inspect.signature(obj, annotation_format=Format.STRING)
    seen_keyword_only = False
    function_args: list[str] = []
    for param in signature.parameters.values():
        if param.kind == inspect.Parameter.KEYWORD_ONLY and not seen_keyword_only:
            function_args.append("{:*, [], nil}")
            seen_keyword_only = True

        function_args.append("{:" + param.name + ", [], nil}")

    function_name = f"{obj.__module__}.{obj.__name__}"
    qualname_parts = obj.__qualname__.split(".")

    out = ""
    if len(qualname_parts) > 1:
        out += f'@doc group: "{obj.__module__}.{".".join(qualname_parts[:-1])}"\n'
        function_name = obj.__qualname__
    else:
        out += '@doc group: "Python Functions"\n'

    out += '@doc """\n'
    doc = inspect.cleandoc(obj.__doc__).strip()
    lines = doc.splitlines()
    out += lines[0] + "\n\n"
    out += format_signature(obj, signature)
    out += "\n"

    if "Args:" in lines:
        args_idx = lines.index("Args:")
        lines[args_idx] = "#### Args"
        for idx in range(args_idx + 1, len(lines)):
            line = lines[idx].strip()
            if ":" not in line:
                continue
            name, desc = line.split(":", maxsplit=1)
            lines[idx] = f"- `{name.strip()}` - {' '.join(desc.strip().split())}"

    out += "\n".join(lines[1:])
    out += '\n"""\n'

    out += f'def unquote({{:"{function_name}", [], ['
    out += ",".join(function_args)
    out += "]}) do\n"
    out += "\n".join(f"_ = unquote({arg})" for arg in function_args)
    out += "\nend\n"
    return out


def format_class(obj: type, groups: list[str], base_types: set[str]) -> str:
    if not obj.__doc__:
        return ""

    doc = inspect.cleandoc(obj.__doc__)

    for member in obj.__dict__.values():
        if getattr(member, "__module__", None) is not None:
            member.__module__ = obj.__module__

    function_members = [
        member
        for member in obj.__dict__.values()
        if inspect.isfunction(member) and member.__doc__
    ]

    out = ""
    if function_members:
        group_title = f"{obj.__module__}.{obj.__name__}"
        groups.append(
            f'%{{title: "{group_title}", description: """\n{doc}\n"""}}',
        )
    else:
        parent_type = inspect.getmro(obj)[1]
        parent_type_name = (
            f'unquote({{:"{parent_type.__module__}.{parent_type.__name__}", [], []}})'
        )
        if parent_type.__module__ == "builtins":
            base_types.add(f"@typep {parent_type.__name__} :: any()")
            parent_type_name = parent_type.__name__

        out += '@typedoc group: "Python Types"\n'
        out += f'@typedoc """\n{doc}\n"""\n'
        out += (
            f'@type unquote({{:"{obj.__module__}.{obj.__name__}", [], []}}) '
            f":: {parent_type_name}\n"
        )

    for member in function_members:
        out += format_function(member)

    return out


def generate_body(module: ModuleType) -> tuple[str, list[str], set[str]]:
    groups: list[str] = ['"Python Types"', '"Python Functions"']
    body_parts: list[str] = []
    base_types: set[str] = set()

    for exported_name in getattr(module, "__all__", []):
        obj = getattr(module, exported_name, None)
        if obj is None:
            continue

        if getattr(obj, "__module__", None) is not None:
            obj.__module__ = module.__name__

        if inspect.isfunction(obj):
            body_parts.append(format_function(obj))
        elif inspect.isclass(obj):
            body_parts.append(format_class(obj, groups, base_types))

    return "".join(body_parts), groups, base_types


def build_module(module: ModuleType) -> str:
    body, groups, base_types = generate_body(module)
    return f'''
Module.create(Python_Interface_Docs, quote do

  @moduledoc """
  Documentation for Python `snex` module.

  The `snex` module is available by default inside `Snex.pyeval/4` environments. It can also be
  imported from your Python project if it's ran by Snex (or if you set `PYTHONPATH` to the Snex's
  `py_src` directory).

  > #### Important {{: .info}}
  >
  > **This is not a functional Elixir module**. The types and functions on this page
  > describe Python types and functions.
  """
  @moduledoc groups: [
  {", ".join(groups)}
  ]

  {"\n".join(base_types)}

  {body}

  end,
  __ENV__
)
'''


def write_output(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as file:
        file.write(content)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate Elixir docs for snex Python interface.",
    )
    parser.add_argument(
        "output",
        type=Path,
        help="Destination path for the generated .ex file.",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> None:
    args = parse_args(argv)

    with args.output.open("w", encoding="utf-8") as file:
        content = build_module(snex)
        file.write(content)


if __name__ == "__main__":
    main(sys.argv[1:])
