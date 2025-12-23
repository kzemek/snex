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
def deps do
  [
    {:snex, "~> 0.2.0"}
  ]
end
```

## Core Concepts & Usage

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

To avoid that, you can immediately call `Snex.make_env(from: node_a_env)` on `b@localhost`, making sure to keep the reference on `a@localhost` at least until the copy is finished:

```elixir
# a@localhost
def pass_env(interpreter) do
  {:ok, local_env} = Snex.make_env(interpreter)
  :ok = GenServer.call({:my_genserver, :"b@localhost"}, {:snex_env, local_env})
  # The remote process is done copying `local_env`, so we can let it be garbage collected
  :ok
end

# b@localhost
@impl GenServer
def handle_call({:snex_env, remote_env}, _from, state) do
  {:ok, env} = Snex.make_env(from: remote_env)
  # We can safely use the new `env` without worrying about it being garbage collected
  {:reply, :ok, Map.put(state, :env, env)}
end
```

Alternatively, you can make sure to keep the original environment around by saving it in a long-lived process state, storing it in a global ETS, putting it in an `Agent`, etc.

### Serialization

By default, data is JSON-serialized using [`JSON`](https://hexdocs.pm/elixir/JSON.html) on the Elixir side and [`json`](https://docs.python.org/3/library/json.html) on the Python side.
Among other things, this means that Python tuples will be serialized as arrays, while Elixir atoms and binaries will be encoded as strings.

```elixir
{:ok, inp} = Snex.Interpreter.start_link()
{:ok, env} = Snex.make_env(inp)

{:ok, ["hello", "world"]} =
  Snex.pyeval(env, "x = ('hello', y)", %{"y" => :world}, returning: "x")
```

Snex will encode your structs to JSON using `Snex.Serde.Encoder`.
If no implementation is defined, `Snex.Serde.Encoder` Snex falls back to `JSON.Encoder` and its defaults.

#### Binary and term serialization

For high‑performance transfer of opaque data, Snex supports out‑of‑band binary channels in addition to JSON:

- `Snex.Serde.binary/1` efficiently passes Elixir binaries or iodata to Python as `bytes` without JSON re‑encoding.
- Python `bytes` returned from `:returning` are received in Elixir as binaries.
- `Snex.Serde.term/1` wraps any Erlang term; it is carried opaquely on the Python side and decoded back to the original Erlang term when returned to Elixir.

```elixir
{:ok, inp} = Snex.Interpreter.start_link()
{:ok, env} = Snex.make_env(inp)

# Pass iodata to Python
{:ok, true} = Snex.pyeval(env,
  %{"val" => Snex.Serde.binary([<<1, 2, 3>>, 4])},
  returning: "val == b'\\x01\\x02\\x03\\x04'")

# Receive Python bytes as an Elixir binary
{:ok, <<1, 2, 3>>} = Snex.pyeval(env, returning: "b'\\x01\\x02\\x03'")

# Round‑trip an arbitrary Erlang term through Python
self = self(); ref = make_ref()
{:ok, {^self, ^ref}} =
  Snex.pyeval(env, %{"val" => Snex.Serde.term({self, ref})}, returning: "val")
```

### Run async code

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

### Run blocking code

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

### Use your in-repo project

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

### Send messages from Python code

Snex allows sending asynchronous BEAM messages from within your running Python code.

Every `env` is initialized with a `snex` object that contains a `send()` method, and can be passed a BEAM pid wrapped with `Snex.Serde.term/1`.
The message contents are encoded/decoded as described in [Serialization](#serialization).

This works especially well with async processing, where you can send updates while the event loop processes your long-running tasks.

```elixir
{:ok, inp} = Snex.Interpreter.start_link()
{:ok, env} = Snex.make_env(inp)

Snex.pyeval(env, """
  snex.send(self, b'hello from snex!')
  # insert long computation here
  """,
  %{"self" => Snex.Serde.term(self())}
)

"hello from snex!" = receive do val -> val end
```

## Releases

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

[uv]: https://github.com/astral-sh/uv
