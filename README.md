# Snex 🐍

[![CI](https://github.com/kzemek/snex/actions/workflows/ci.yml/badge.svg)](https://github.com/kzemek/snex/actions/workflows/ci.yml)
[![Module Version](https://img.shields.io/hexpm/v/snex.svg)](https://hex.pm/packages/snex)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/snex/)
[![License](https://img.shields.io/hexpm/l/snex.svg)](https://github.com/kzemek/snex/blob/master/LICENSE)

Easy and efficient Python interop for Elixir.

## Highlights

- **Robust & Isolated:**
  Run multiple Python interpreters in separate OS processes, preventing GIL issues from affecting your Elixir application.
- **Declarative Environments:**
  Leverages [`uv`][uv] to manage Python versions and dependencies, embedding them into your application's release for consistent deployments.
- **Ergonomic Interface:**
  A powerful and efficient interface with explicit control over data passing between Elixir and Python processes.
- **Flexible:**
  Supports custom Python environments, `asyncio` code, and integration with external Python projects.
- **Bidirectional communication**
  Python code running under Snex can send, cast, and call Elixir code.
- **Forward Compatibility:**
  Built on stable foundations, so future versions of Python or Elixir are unlikely to require Snex updates to use - they should work day one!

## Quick example

```elixir
defmodule SnexTest.NumpyInterpreter do
  use Snex.Interpreter,
    pyproject_toml: """
    [project]
    name = "my-numpy-project"
    version = "0.0.0"
    requires-python = "==3.10.*"
    dependencies = ["numpy>=2"]
    """
end
```

```elixir
{:ok, inp} = SnexTest.NumpyInterpreter.start_link()
{:ok, env} = Snex.make_env(inp)

{:ok, 6.0} =
  Snex.pyeval(env, """
    import numpy as np
    matrix = np.fromfunction(lambda i, j: (-1) ** (i + j), (s, s), dtype=int)
    """, %{"s" => 6}, returning: "np.linalg.norm(matrix)")
```

## Installation & Requirements

- Elixir `>= 1.18`
- [uv](https://github.com/astral-sh/uv) `>= 0.6.8` -
  a fast Python package & project manager, used by Snex to create and manage Python environments.
  It has to be available at compilation time but isn't needed at runtime.
- Python `>= 3.10` -
  this is the minimum supported version you can run your scripts with.
  You don't need to have it installed - Snex will fetch it with `uv`.

```elixir
# mix.exs
def deps do
  [
    {:snex, "~> 0.2.0"}
  ]
end

# See Releases section in the README on how to configure mix release
```

## Core Concepts & Usage

- [Custom Interpreter](#custom-interpreter)
- [`Snex.pyeval`](#snexpyeval)
- [Environments](#environments)
  - [Initialization script](#initialization-script)
  - [Passing `Snex.Env` between Erlang nodes](#passing-snexenv-between-erlang-nodes)
- [Serialization](#serialization)
  - [Encoding/decoding table](#encodingdecoding-table)
  - [Customizing serialization](#customizing-serialization)
- [Releases](#releases)
- [Cookbook](#cookbook)
  - [Run async code](#run-async-code)
  - [Run blocking code](#run-blocking-code)
  - [Use your in-repo project](#use-your-in-repo-project)
  - [Send messages from Python code](#send-messages-from-python-code)
  - [Cast and call Elixir code from Python](#cast-and-call-elixir-code-from-python)

### Custom Interpreter

You can define your Python project settings using `use Snex.Interpreter` in your module.

Set a required Python version and any dependencies - both the Python binary and the dependencies will be fetched & synced at compile time with [uv][uv], and put into `_build/$MIX_ENV/snex` directory.

```elixir
defmodule SnexTest.NumpyInterpreter do
  use Snex.Interpreter,
    pyproject_toml: """
    [project]
    name = "my-numpy-project"
    version = "0.0.0"
    requires-python = "==3.10.*"
    dependencies = ["numpy>=2"]
    """
end
```

The modules using `Snex.Interpreter` have to be `start_link`ed to use.
Each `Snex.Interpreter` (BEAM) process manages a separate Python (OS) process.

```elixir
{:ok, interpreter} = SnexTest.NumpyInterpreter.start_link()
{:ok, env} = Snex.make_env(interpreter)

{:ok, "hello world!"} = Snex.pyeval(env, "x = 'hello world!'", returning: "x")
```

### `Snex.pyeval`

The main way of interacting with the interpreter process is `Snex.pyeval/4` (and other arities).
This is the function that runs Python code, returns data from the interpreter, and more.

```elixir
{:ok, interpreter} = SnexTest.NumpyInterpreter.start_link()
{:ok, %Snex.Env{} = env} = Snex.make_env(interpreter)

{:ok, 6.0} =
  Snex.pyeval(env, """
    import numpy as np
    matrix = np.fromfunction(lambda i, j: (-1) ** (i + j), (6, 6), dtype=int)
    scalar = np.linalg.norm(matrix)
    """, returning: "scalar")
```

The `:returning` option can take any valid Python expression, or an Elixir list of them:

```elixir
{:ok, interpreter} = Snex.Interpreter.start_link()
{:ok, env} = Snex.make_env(interpreter)

{:ok, [3, 6, 9]} = Snex.pyeval(env, "x = 3", returning: ["x", "x*2", "x**2"])
```

### Environments

`Snex.Env` struct, also called "environment", is an Elixir-side reference to Python-side variable context in which your Python code will run.
New environments can be allocated with `Snex.make_env/3` (and other arities).

Environments are mutable, and will be modified by your Python code.
In Python parlance, they are **global & local symbol table** your Python code is executed with.

> [!IMPORTANT]
>
> **Environments are garbage collected**  
> When a `%Snex.Env{}` value is cleaned up by the BEAM VM, the Python process is signalled to deallocate the environment associated with that value.

Reusing a single environment, you can use variables defined in the previous `Snex.pyeval/4` calls:

```elixir
{:ok, inp} = Snex.Interpreter.start_link()
{:ok, env} = Snex.make_env(inp)

# `pyeval` does not return a value if not given a `returning` opt
:ok = Snex.pyeval(env, "x = 10")

# additional data can be provided for `pyeval` to put in the environment
# before running the code
:ok = Snex.pyeval(env, "y = x * z", %{"z" => 2})

# `pyeval` can also be called with `:returning` opt alone
{:ok, [10, 20, 2]} = Snex.pyeval(env, returning: ["x", "y", "z"])
```

Using `Snex.make_env/2` and `Snex.make_env/3`, you can also create a new environment:

- **copying variables from an old environment**

  ```elixir
  Snex.make_env(interpreter, from: old_env)

  # You can also omit the `interpreter` when using `:from`
  Snex.make_env(from: old_env)
  ```

- **copying variables from multiple environments (later override previous)**

  ```elixir
  Snex.make_env(interpreter, from: [
    oldest_env,
    {older_env, only: ["pool"]},
    {old_env, except: ["pool"]}
  ]))
  ```

- **setting some initial variables (taking precedence over variables from `:from`)**

  ```elixir
  Snex.make_env(interpreter, %{"hello" => 42.0}, from: {old_env, only: ["world"]})
  ```

> [!WARNING]
>
> The environments you copy from have to belong to the same interpreter!

#### Initialization script

`Snex.Interpreter` can be given an `:init_script` option.
The init script runs on interpreter startup, and prepares a "base" environment state that will be cloned to every new environment made with `Snex.make_env/3`.

```elixir
{:ok, inp} = SnexTest.NumpyInterpreter.start_link(
  init_script: """
  import numpy as np
  my_var = 42
  """)
{:ok, env} = Snex.make_env(inp)

# The brand new `env` contains `np` and `my_var`
{:ok, 42} = Snex.pyeval(env, returning: "int(np.array([my_var])[0])")
```

If your init script takes significant time, you can pass `sync_start: false` to `start_link/1`.
This will return early from the interpreter startup, and run the Python interpreter - and the init script - asynchronously.
The downside is that an issue with Python or the initialization code will cause the process to crash asynchronously instead of returning an error directly from `start_link/1`.

#### Passing `Snex.Env` between Erlang nodes

`Snex.Env` garbage collection can only track usage within the node it was created on.
If you send a `%Snex.Env{}` value to another node `b@localhost`, and drop any references to the value on the original node `a@localhost`, the garbage collector may clean up the environment even though it's used on `b`.

In general, it's best to use `Snex.Env` instances created on the same node as their interpreter - this simplifies reasoning about cleanup, especially with node disconnections and shutdowns. Agents are a great way to share `Snex.Env` between nodes without giving up garbage collection:

```elixir
# a@localhost
{:ok, interpreter} = Snex.Interpreter.start_link()

{:ok, env_agent} = Agent.start_link(fn ->
  {:ok, env} = Snex.make_env(interpreter, %{"hello" => "hello from a@localhost!"})
  env
end)

:erpc.call(:"b@localhost", fn ->
  remote_env = Agent.get(env_agent, & &1)
  {:ok, "hello from a@localhost!"} = Snex.pyeval(remote_env, returning: "hello")
end)
```

Alternatively, you can opt into manual management of `Snex.Env` lifetime by calling `Snex.Env.disable_gc/1` on the original node, and later destroying the env by calling `Snex.destroy_env/1` on any node.

### Serialization

Elixir data is serialized using a limited subset of Python's Pickle format (version 5), and deserialized on Python side using `pickle.loads()`.
Python data is serialized with a subset of Erlang's External Term Format, and deserialized on Elixir side using `:erlang.binary_to_term/1`.

#### Encoding/decoding table

The serialization happens as outlined in the table:

| (from) Elixir                | (to) Python     | (to) Elixir  | Comment                                                  |
| ---------------------------- | --------------- | ------------ | -------------------------------------------------------- |
| `nil`                        | `None`          | `nil`        |                                                          |
| `boolean()`                  | `boolean`       | `boolean()`  |                                                          |
| `atom()`                     | `snex.Atom`     | `atom()`     | `snex.Atom` is a subclass of `str`                       |
| `integer()`                  | `int`           | `integer()`  | BigInts up to 2^32 bytes                                 |
| `float()`                    | `float`         | `float()`    | Preserves representation                                 |
| `Snex.Serde.float(:inf)`     | `float('inf')`  | `:inf`       | See `Snex.Serde.float/1`                                 |
| `Snex.Serde.float(:"-inf")`  | `float('-inf')` | `:"-inf"`    |                                                          |
| `Snex.Serde.float(:nan)`     | `float('NaN')`  | `:nan`       |                                                          |
| `Snex.Serde.float(f)`        | `float`         | `f`          | Non-special float decodes to bare float                  |
| `binary()`                   | `str`           | `binary()`   | Elixir binaries are assumed to be strings                |
| `Snex.Serde.binary(b)`       | `bytes`         | `binary()`   |                                                          |
|                              | `bytearray`     | `binary()`   |                                                          |
|                              | `memoryview`    | `binary()`   |                                                          |
| `Snex.Serde.object(m, n, a)` | `object`        |              | See `Snex.Serde.object/3`                                |
| `Snex.Serde.term(t)`         | `snex.Term`     | `t`          | Opaquely round-trips `t`; `snex.Term` subclasses `bytes` |
| `MapSet.t()`                 | `set`           | `MapSet.t()` |                                                          |
|                              | `frozenset`     | `MapSet.t()` |                                                          |
| `struct()`                   | `dict`          | `struct()`   | K/V pairs (including `__struct__`) recursively encoded   |
| `map()`                      | `dict`          | `map()`      | K/V pairs recursively encoded                            |
| `list()`                     | `list`          | `list()`     | Elements recursively encoded                             |
| `tuple()`                    | `tuple`         | `tuple()`    | Elements recursively encoded                             |
| `any()`                      | `snex.Term`     | `any()`      | Round-tripped with `:erlang.term_to_binary/1`            |

> [!WARNING]
>
> In Python, `snex.Atom()` is a simple subclass of `str`, inheriting its `__eq__` and `__hash__` implementations.
>
> This means you can encode `"data" => %{foo: "bar"}` in Elixir, and access it with `data["foo"]` in Python.
> However, it also means that `%{"foo" => "baz", foo: "bar"}` will encode either into `{"foo": "baz"}` or `{"foo": "bar"}`, depending on the map iteration order!

#### Customizing serialization

You can control struct encoding by implementing `Snex.Serde.Encoder` protocol.
`Snex.Serde.Encoder.encode/1` will be called for any struct not explicitly handled in the table above, iif it implements the `Snex.Serde.Encoder` protocol.
The result of the `encode/1` function will then be encoded again according to the table, with the same `Snex.Serde.Encoder` treatment if that result contains a struct.
If `encode/1` returns the same struct type (e.g. `Snex.Serde.Encoder.encode(%X{}) -> %X{}`), the result will be encoded like a generic struct (i.e. as a `dict` with `__struct__` key).

On the Python side, you can call `snex.set_custom_encoder(encoder_fun)` to add encoders for your objects.
`encoder_fun` will only be called for objects that `Snex` doesn't know how to serialize.
The result will then be encoded further according to the table above.

##### Example: roundtrip serialization between an Elixir struct and Python object

```elixir
defimpl Snex.Serde.Encoder, for: Date do
  def encode(%Date{} = d),
    do: Snex.Serde.object("datetime", "date", [d.year, d.month, d.day])
end
```

```elixir
{:ok, inp} = Snex.Interpreter.start_link(init_script: """
  import datetime

  def custom_encoder(obj):
    if isinstance(obj, datetime.date):
      return {
        snex.Atom("__struct__"): snex.Atom("Elixir.Date"),
        snex.Atom("day"): obj.day,
        snex.Atom("month"): obj.month,
        snex.Atom("year"): obj.year,
        snex.Atom("calendar"): snex.Atom("Elixir.Calendar.ISO"),
      }

    raise TypeError(f"Cannot serialize object of {type(obj)}")

  snex.set_custom_encoder(custom_encoder)
  """)

{:ok, env} = Snex.make_env(inp)

{:ok, {{"datetime", "date"}, %Date{year: 2026, month: 12, day: 27}}} =
  Snex.pyeval(env, """
    typ = type(date)
    next_date = date + datetime.timedelta(days=364)
    """,
    %{"date" => Date.new!(2025, 12, 28)},
    returning: "((typ.__module__, typ.__name__), next_date)")
```

### Releases

Snex puts its managed files under `_build/$MIX_ENV/snex`.
This works out of the box with `iex -S mix` and other local ways of running your code, but requires an additional step to copy files around to prepare your releases.

Fortunately, accommodating releases is easy: just add `&Snex.Release.after_assemble/1` to `:steps` of your Mix release config.
The only requirement is that it's placed after `:assemble` (and before `:tar`, if you use it.)

```elixir
# mix.exs
def project do
  [
    releases: [
      demo: [
        steps: [:assemble, &Snex.Release.after_assemble/1]
      ]
    ]
  ]
end
```

### Cookbook

#### Run async code

Code ran by Snex lives in an [`asyncio`](https://docs.python.org/3/library/asyncio.html) loop.
You can include async functions in your snippets and await them on the top level:

```elixir
{:ok, inp} = Snex.Interpreter.start_link()
{:ok, env} = Snex.make_env(inp)

{:ok, ["hello"]} =
  Snex.pyeval(env, """
    import asyncio
    async def do_thing():
        await asyncio.sleep(0.01)
        return "hello"

    result = await do_thing()
    """, returning: ["result"])
```

#### Run blocking code

A good way to run any blocking code is to prepare and use your own thread or process pools:

```elixir
{:ok, inp} = Snex.Interpreter.start_link()
{:ok, pool_env} = Snex.make_env(inp)

:ok =
  Snex.pyeval(pool_env, """
    import asyncio
    from concurrent.futures import ThreadPoolExecutor

    pool = ThreadPoolExecutor(max_workers=cnt)
    loop = asyncio.get_running_loop()
    """, %{"cnt" => 5})

# You can keep the pool environment around and copy it into new ones
{:ok, env} = Snex.make_env(inp, from: {pool_env, only: ["pool", "loop"]})

{:ok, "world!"} =
  Snex.pyeval(env, """
    def blocking_io():
        return "world!"

    res = await loop.run_in_executor(pool, blocking_io)
    """, returning: "res")
```

#### Use your in-repo project

You can reference your existing project path in `use Snex.Interpreter`.

The existing `pyproject.toml` and `uv.lock` will be used to seed the Python environment.

```elixir
defmodule SnexTest.MyProject do
  use Snex.Interpreter,
    project_path: "test/my_python_proj"

  # Overrides `start_link/1` from `use Snex.Interpreter`
  def start_link(opts) do
    # Provide the project's path at runtime - you'll likely want to use
    # :code.priv_dir(:your_otp_app) and construct a path relative to that.
    my_project_path = Path.absname("test/my_python_proj")

    opts
    |> Keyword.put(:environment, %{"PYTHONPATH" => my_project_path})
    |> super()
  end
end
```

```elixir
# $ cat test/my_python_proj/foo.py
# def bar():
#     return "hi from bar"

{:ok, inp} = SnexTest.MyProject.start_link()
{:ok, env} = Snex.make_env(inp)

{:ok, "hi from bar"} = Snex.pyeval(env, "import foo", returning: "foo.bar()")
```

#### Send messages from Python code

Snex allows sending asynchronous BEAM messages from within your running Python code.

Every `env` imports `snex` module that contains a `send()` method, and can be passed a BEAM pid wrapped with `Snex.Serde.term/1`.
The message contents are encoded/decoded as described in [Serialization](#serialization).

This works especially well with async processing, where you can send updates while the event loop processes your long-running tasks.

```elixir
{:ok, inp} = Snex.Interpreter.start_link()
{:ok, env} = Snex.make_env(inp)

Snex.pyeval(env, """
  snex.send(self, b'hello from snex!')
  # insert long computation here
  """,
  %{"self" => self()}
)

"hello from snex!" = receive do val -> val end

# You can use any term supported by `Kernel.send/2` as destination
Process.register(self(), :myname)
Snex.pyeval(env, """
  snex.send((snex.Atom('myname'), node), b'hello from snex (again!)')
  """,
  %{"node" => node()}
)

"hello from snex (again!)" = receive do val -> val end
```

In your external Python code (see [Use your in-repo project](#use-your-in-repo-project)), you can `import snex` (ensure `snex/py_src` is in your Python path) so your code and IDE are aware of Snex types, such as `snex.Atom`, and available functions, such as `send()`.

[uv]: https://github.com/astral-sh/uv

#### Cast and call Elixir code from Python

Similar to `snex.send` above, you can also use `snex.cast(m, f, a)` and `snex.call(m, f, a)` to call Elixir functions from Python.
In fact, `snex.send` is just a convenient interface on top of `snex.cast`!

`snex.cast` and `snex.call` differ only in how they handle results.
`snex.call` must be awaited on, and will return the result of whatever was called, while `snex.cast` is fire-and-forget.
Both functions will run `apply(m, f, a)` in a new process (`m` and `f` will be converted to atoms if given as `str`).
They also accept an optional `node` argument to apply the function on a remote node - as long as it's also running the `:snex` application.

```elixir
{:ok, inp} = Snex.Interpreter.start_link()
{:ok, env} = Snex.make_env(inp)

{:ok, agent} = Agent.start_link(fn -> 42 end)

{:ok, 42} =
  Snex.pyeval(
    env,
    "result = await snex.call('Elixir.Agent', 'get', [agent, identity])",
    %{"agent" => agent, "identity" => & &1},
    returning: "result"
  )
```
