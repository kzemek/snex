# /// script
# requires-python = ">=3.14"
# dependencies = ["jinja2"]
# ///

from __future__ import annotations

import argparse
import inspect
import sys
from annotationlib import Format
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING

from jinja2 import Environment

import snex

if TYPE_CHECKING:
    from types import FunctionType, ModuleType


@dataclass
class GroupHeader:
    title: str
    description: str | None = None


@dataclass
class TypeEntry:
    group: str
    name: str
    doc: str
    parent_type_name: str


@dataclass
class FunctionEntry:
    group: str
    name: str
    shortname: str
    is_async: bool
    doc_lines: list[str]
    signature: inspect.Signature
    args: list[str] = field(default_factory=list)


@dataclass
class ModuleDocs:
    module: ModuleType

    groups: list[GroupHeader] = field(
        default_factory=lambda: [
            GroupHeader("Python Types"),
            GroupHeader("Python Functions"),
        ]
    )
    base_types: set[str] = field(default_factory=set)
    types: list[TypeEntry] = field(default_factory=list)
    functions: list[FunctionEntry] = field(default_factory=list)

    @staticmethod
    def _transform_section(section_name: str, lines: list[str]) -> None:
        if f"{section_name}:" not in lines:
            return

        section_idx = lines.index(f"{section_name}:")

        lines[section_idx] = f"### {section_name}"
        for idx in range(section_idx + 1, len(lines)):
            if lines[idx] and lines[idx][0] != " ":
                break

            if ":" not in lines[idx]:
                continue

            name_type_str, desc = lines[idx].split(":", maxsplit=1)
            name_type = name_type_str.strip().split(" ", maxsplit=1)
            name = f"`{name_type[0]}`"
            type = f" (`{name_type[1].strip("()")}`)" if len(name_type) > 1 else ""
            lines[idx] = f"- {name}{type} - {' '.join(desc.strip().split())}"

    @staticmethod
    def _transform_examples_section(lines: list[str]) -> None:
        if "Examples::" not in lines:
            return

        examples_idx = lines.index("Examples::")
        last_idx = len(lines) - 1
        indent = None
        for idx in range(examples_idx + 1, len(lines)):
            if lines[idx] and lines[idx][0] != " ":
                last_idx = idx - 1
                break

            line_indent = len(lines[idx]) - len(lines[idx].lstrip())
            indent = line_indent if indent is None else min(indent, line_indent)

        lines[examples_idx] = "### Examples"
        lines[examples_idx + 1] = "```python"  # this starts as an empty line
        lines[last_idx] = lines[last_idx] + "\n```"

        for idx in range(examples_idx + 2, last_idx):
            lines[idx] = lines[idx][indent:].rstrip()

    def _collect_function(self, obj: FunctionType, group: str, name: str) -> None:
        if not obj.__doc__:
            return

        signature = inspect.signature(obj, annotation_format=Format.STRING)
        seen_keyword_only = False
        function_args: list[str] = []
        for param in signature.parameters.values():
            if param.kind == inspect.Parameter.KEYWORD_ONLY and not seen_keyword_only:
                function_args.append("*")
                seen_keyword_only = True

            function_args.append(param.name)

        doc = inspect.cleandoc(obj.__doc__).strip()
        lines = doc.splitlines()

        self._transform_section("Args", lines)
        self._transform_examples_section(lines)

        self.functions.append(
            FunctionEntry(
                group=group,
                name=name,
                shortname=obj.__name__,
                is_async=inspect.iscoroutinefunction(obj),
                doc_lines=lines,
                signature=signature,
                args=function_args,
            )
        )

    def _collect_class_standalone(
        self,
        obj: type,
        doc: str,
        group: str,
        name: str,
    ) -> None:
        parent_type = inspect.getmro(obj)[1]

        parent_type_name: str
        if parent_type.__module__.startswith(self.module.__name__):
            parent_type_name = f"{self.module.__name__}.{parent_type.__qualname__}"
        else:
            parent_type_name = (
                parent_type.__qualname__
                if parent_type.__module__ == "builtins"
                else f"{parent_type.__module__}.{parent_type.__qualname__}"
            )
            self.base_types.add(parent_type_name)

        self.types.append(
            TypeEntry(
                group=group,
                name=name,
                doc=doc,
                parent_type_name=parent_type_name,
            )
        )

    def _collect_class_with_children(
        self,
        obj: type,
        doc: str,
        function_members: list[FunctionType],
        class_members: list[type],
    ) -> None:
        child_group = f"{self.module.__name__}.{obj.__qualname__}"

        self.groups.append(GroupHeader(title=child_group, description=doc))

        for function_member in function_members:
            self._collect_function(
                function_member,
                child_group,
                function_member.__qualname__,
            )

        for class_member in class_members:
            self._collect_class(
                class_member,
                child_group,
                class_member.__qualname__,
            )

    def _collect_class(self, obj: type, group: str, name: str) -> None:
        if not obj.__doc__:
            return

        doc = inspect.cleandoc(obj.__doc__)
        lines = doc.splitlines()
        self._transform_section("Attributes", lines)
        doc = "\n".join(lines)

        function_members: list[FunctionType] = []
        class_members: list[type] = []
        for member in obj.__dict__.values():
            member_module = getattr(member, "__module__", None)
            if (
                not member.__doc__
                or member_module is None
                or not member_module.startswith(self.module.__name__)
            ):
                continue

            if inspect.isfunction(member):
                function_members.append(member)
            elif inspect.isclass(member):
                class_members.append(member)

        if function_members or class_members:
            self._collect_class_with_children(obj, doc, function_members, class_members)
        else:
            self._collect_class_standalone(obj, doc, group, name)

    def collect(self) -> "ModuleDocs":
        for exported_name in getattr(self.module, "__all__", []):
            obj = getattr(self.module, exported_name, None)
            if obj is None:
                continue

            full_name = f"{self.module.__name__}.{obj.__qualname__}"
            if inspect.isfunction(obj):
                self._collect_function(obj, "Python Functions", full_name)
            elif inspect.isclass(obj):
                self._collect_class(obj, "Python Types", full_name)

        return self


def format_signature(signature: inspect.Signature, name: str, is_async: bool) -> str:
    async_ = "async " if is_async else ""
    preamble = f"{async_}def {name}"
    max_width = 60 - len(preamble)
    return preamble + signature.format(
        max_width=max_width,
        quote_annotation_strings=False,
    )


def format_decl(name: str, args: list[str] | None, unquote: bool = True) -> str:
    args_str = "nil"
    if args is not None:
        args_str = ", ".join(map(lambda arg: format_decl(arg, None, False), args))
        args_str = f"[{args_str}]"

    name_str = f":{name}" if name.isidentifier() else f':"{name}"'
    decl_str = f"{{ {name_str}, [generated: true], {args_str} }}"
    return f"unquote({decl_str})" if unquote else decl_str


def format_heredoc(text: str | None) -> str:
    return f'"""\n{text}\n"""' if text is not None else "nil"


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate Elixir docs for snex Python interface.",
    )
    parser.add_argument(
        "output",
        type=Path,
        help="Destination path for the generated .ex file.",
    )
    args = parser.parse_args(sys.argv[1:])

    with args.output.open("w", encoding="utf-8") as file:
        module_docs = ModuleDocs(snex).collect()

        env = Environment(
            keep_trailing_newline=True,
            trim_blocks=True,
            lstrip_blocks=True,
        )

        env.filters.update(
            {
                "format_signature": format_signature,
                "decl": format_decl,
                "heredoc": format_heredoc,
            }
        )

        template = env.from_string(TEMPLATE)
        content = template.render(module_docs=module_docs)
        file.write(content)


TEMPLATE = '''
Module.create(Python_Interface_Documentation, quote generated: true do
  @moduledoc """
  Documentation for Python `snex` module.

  The `snex` module is pre-imported inside `Snex.pyeval/4` environments. It can also be
  imported from your Python project if it's ran by Snex - or if you include `deps/snex/py_src`
  in your `PYTHONPATH`.

  > #### Important {: .info}
  >
  > **This is not a functional Elixir module**. The types and functions on this page
  > describe Python types and functions.
  """
  @moduledoc groups: [
    {% for group in module_docs.groups %}
      %{title: "{{ group.title }}", description: {{ group.description | heredoc }}}{{ ", " if not loop.last }}
    {% endfor %}
  ]

  {% for base_type in module_docs.base_types %}
    @typep {{ base_type | decl([]) }} :: any()
  {% endfor %}

  {% for type in module_docs.types %}
    @typedoc group: "{{ type.group }}"
    @typedoc {{ type.doc | heredoc }}
    @type {{ type.name | decl([]) }} :: {{ type.parent_type_name | decl([]) }}
  {% endfor %}

  {% for func in module_docs.functions %}
    @doc group: "{{ func.group }}"
    @doc """
{{ func.doc_lines[0] }}

```python
{{ func.signature | format_signature(func.shortname, func.is_async) }}
```

{{ func.doc_lines[2:] | join("\n") }}
"""
    def {{ func.name | decl(func.args) }}, do: :erlang.nif_error(:not_implemented)
  {% endfor %}

  end,
  __ENV__
)
'''

if __name__ == "__main__":
    main()
