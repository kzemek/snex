# Snex 🐍

[![CI](https://github.com/kzemek/snex/actions/workflows/ci.yml/badge.svg)](https://github.com/kzemek/snex/actions/workflows/ci.yml)
[![Module Version](https://img.shields.io/hexpm/v/snex.svg)](https://hex.pm/packages/snex)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/snex/)
[![License](https://img.shields.io/hexpm/l/snex.svg)](https://github.com/kzemek/snex/blob/master/LICENSE)

Easy and efficient Python interop for Elixir.

## Highlights

- 🛡️ **Robust & Isolated:**
  Run multiple Python interpreters in separate OS processes, preventing GIL issues from affecting your Elixir application.
- 📦 **Declarative Environments:**
  Leverages [`uv`][uv] to manage Python versions and dependencies, embedding them into your application's release for consistent deployments.
- ✨ **Ergonomic Interface:**
  A powerful and efficient interface with explicit control over data passing between Elixir and Python processes.
- 🤸 **Flexible:**
  Supports custom Python environments, `asyncio` code, and integration with external Python projects.
- ⏩ **Forward Compatibility:**
  Built on stable foundations, so future versions of Python or Elixir are unlikely to require Snex updates to use — they should work day one!

## Quick example

```elixir
defmodule SnexTest.NumpyInterpreter do
  use Snex.Interpreter,
    otp_app: :my_app_name,
    pyproject_toml: """
    [project]
    name = "my-numpy-project"
    version = "0.0.0"
    requires-python = "==3.10.*"
    dependencies = ["numpy>=2"]
    """
end

iex> {:ok, inp} = SnexTest.NumpyInterpreter.start_link()
iex> {:ok, env} = Snex.make_env(inp)
...>
iex> Snex.pyeval(env, """
...>   import numpy as np
...>   matrix = np.fromfunction(lambda i, j: (-1) ** (i + j), (s, s), dtype=int)
...>   """, %{"s" => 6}, returning: "np.linalg.norm(matrix)")
{:ok, 6.0}
```

## Installation & Requirements

- Elixir `>= 1.18`
- [uv](https://github.com/astral-sh/uv) `>= 0.6.8` -
  a fast Python package & project manager, used by Snex to create and manage Python environments.
  It has to be available at compilation time but isn't needed at runtime.
- Python `>= 3.10` -
  this is the minimum supported version you can run your scripts with.
  You don't need to have it installed — Snex will fetch it with `uv`.

```elixir
def deps do
  [
    {:snex, "~> 0.1.0"}
  ]
end
```

## Core Concepts & Usage

### Custom Interpreter

You can define your Python project settings using `use Snex.Interpreter` in your module.

Set a required Python version and any dependencies —both the Python binary & the dependencies will
be fetched & synced at compile time with [uv][uv], and put into your application's priv directory.

```elixir
defmodule SnexTest.NumpyInterpreter do
  use Snex.Interpreter,
    otp_app: :my_app_name,
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

### `Snex.pyeval`

The main way of interacting with the interpreter process is `Snex.pyeval/4` (and other arities).
This is the function that runs Python code, returns data from the interpreter, and more.

```elixir
iex> {:ok, interpreter} = SnexTest.NumpyInterpreter.start_link()
iex> {:ok, %Snex.Env{} = env} = Snex.make_env(interpreter)
...>
iex> Snex.pyeval(env, """
...>   import numpy as np
...>   matrix = np.fromfunction(lambda i, j: (-1) ** (i + j), (6, 6), dtype=int)
...>   scalar = np.linalg.norm(matrix)
...>   """, returning: "scalar")
{:ok, 6.0}
```

The `:returning` option can take any valid Python expression, or an Elixir list of them:

```elixir
iex> {:ok, interpreter} = SnexTest.NumpyInterpreter.start_link()
iex> {:ok, env} = Snex.make_env(interpreter)
...>
iex> Snex.pyeval(env, "x = 3", returning: ["x", "x*2", "x**2"])
{:ok, [3, 6, 9]}
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
iex> {:ok, inp} = SnexTest.NumpyInterpreter.start_link()
iex> {:ok, env} = Snex.make_env(inp)
...>
...> # `pyeval` does not return a value if not given a `returning` opt
iex> :ok = Snex.pyeval(env, "x = 10")
...>
...> # additional data can be provided for `pyeval` to put in the environment
...> # before running the code
iex> :ok = Snex.pyeval(env, "y = x * z", %{"z" => 2})
...>
...> # `pyeval` can also be called with `:returning` opt alone
iex> Snex.pyeval(env, returning: ["x", "y", "z"])
{:ok, [10, 20, 2]}
```

Using `Snex.make_env/2` and `Snex.make_env/3`, you can also create a new environment:

- **copying variables from an old environment**
  ```elixir
  Snex.make_env(interpreter, from: old_env)
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
iex> {:ok, inp} = SnexTest.NumpyInterpreter.start_link(
...>   init_script: """
...>   import numpy as np
...>   my_var = 42
...>   """)
iex> {:ok, env} = Snex.make_env(inp)
...>
...> # The brand new `env` contains `np` and `my_var`
iex> Snex.pyeval(env, returning: "int(np.array([my_var])[0])")
{:ok, 42}
```

### Serialization

By default, data is JSON-serialized using [`JSON`](https://hexdocs.pm/elixir/JSON.html) on the Elixir side and [`json`](https://docs.python.org/3/library/json.html) on the Python side.
Among other things, this means that Python tuples will be serialized as arrays, while Elixir atoms and binaries will be encoded as strings.

```elixir
iex> {:ok, inp} = SnexTest.NumpyInterpreter.start_link()
iex> {:ok, env} = Snex.make_env(inp)
...>
iex> Snex.pyeval(env, "x = ('hello', y)", %{"y" => :world}, returning: "x")
{:ok, ["hello", "world"]}
```

Snex will encode your structs to JSON using `Snex.Serde.Encoder`.
If no implementation is defined, `Snex.Serde.Encoder` Snex falls back to `JSON.Encoder` and its defaults.

#### Binary and term serialization

For high‑performance transfer of opaque data, Snex supports out‑of‑band binary channels in addition to JSON:

- `Snex.Serde.binary/1` efficiently passes Elixir binaries or iodata to Python as `bytes` without JSON re‑encoding.
- Python `bytes` returned from `:returning` are received in Elixir as binaries.
- `Snex.Serde.term/1` wraps any Erlang term; it is carried opaquely on the Python side and decoded back to the original Erlang term when returned to Elixir.

```elixir
iex> {:ok, inp} = SnexTest.NumpyInterpreter.start_link()
iex> {:ok, env} = Snex.make_env(inp)
...>
...> # Pass iodata to Python
iex> Snex.pyeval(env,
...>   %{"val" => Snex.Serde.binary([<<1, 2, 3>>, 4])},
...>   returning: "val == b'\\x01\\x02\\x03\\x04'")
{:ok, true}
...>
...> # Receive Python bytes as an Elixir binary
iex> Snex.pyeval(env, returning: "b'\\x01\\x02\\x03'")
{:ok, <<1, 2, 3>>}
...>
...> # Round‑trip an arbitrary Erlang term through Python
iex> self = self(); ref = make_ref()
iex> {:ok, {^self, ^ref}} = Snex.pyeval(env, nil, %{"val" => Snex.Serde.term({self, ref})}, returning: "val")
```

### Run async code

Code ran by Snex lives in an [`asyncio`](https://docs.python.org/3/library/asyncio.html) loop.
You can include async functions in your snippets and await them on the top level:

```elixir
iex> {:ok, inp} = SnexTest.NumpyInterpreter.start_link()
iex> {:ok, env} = Snex.make_env(inp)
...>
iex> Snex.pyeval(env, """
...>   import asyncio
...>   async def do_thing():
...>       await asyncio.sleep(0.01)
...>       return "hello"
...>
...>   result = await do_thing()
...>   """, returning: ["result"])
{:ok, ["hello"]}
```

### Run blocking code

A good way to run any blocking code is to prepare and use your own thread or process pools:

```elixir
iex> {:ok, inp} = SnexTest.NumpyInterpreter.start_link()
iex> {:ok, pool_env} = Snex.make_env(inp)
...>
iex> :ok = Snex.pyeval(pool_env, """
...>   import asyncio
...>   from concurrent.futures import ThreadPoolExecutor
...>
...>   pool = ThreadPoolExecutor(max_workers=cnt)
...>   loop = asyncio.get_running_loop()
...>   """, %{"cnt" => 5})
...>
...> # You can keep the pool environment around and copy it into new ones
iex> {:ok, env} = Snex.make_env(inp, from: {pool_env, only: ["pool", "loop"]})
...>
iex> {:ok, "world!"} = Snex.pyeval(env, """
...>   def blocking_io():
...>       return "world!"
...>
...>   res = await loop.run_in_executor(pool, blocking_io)
...>   """, returning: "res")
{:ok, "world!"}
```

### Use your in-repo project

You can reference your existing project path in `use Snex.Interpreter`.

The existing `pyproject.toml` and `uv.lock` will be used to seed the Python environment.

```elixir
defmodule SnexTest.MyProject do
  use Snex.Interpreter,
    otp_app: :my_app_name,
    project_path: "test/my_python_proj"

  # Overrides `start_link/1` from `use Snex.Interpreter`
  def start_link(opts) do
    # Provide the project's path at runtime - you'll likely want to use
    # :code.priv_dir(:your_otp_app) and construct a path relative to that.
    my_project_path = "test/my_python_proj"

    opts
    |> Keyword.put(:environment, %{"PYTHONPATH" => my_project_path})
    |> super()
  end
end

# $ cat test/my_python_proj/foo.py
# def bar():
#     return "hi from bar"

iex> {:ok, inp} = SnexTest.MyProject.start_link()
iex> {:ok, env} = Snex.make_env(inp)
...>
iex> Snex.pyeval(env, "import foo", returning: "foo.bar()")
{:ok, "hi from bar"}
```

[uv]: https://github.com/astral-sh/uv
