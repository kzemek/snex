## 0.4.0 (Unreleased)

### Breaking

- **`Snex.pyeval/4` no longer returns bare `:ok`**

  `Snex.pyeval/4` now always returns either `{:ok, value}` or `{:error, reason}`.
  It always felt wrong to have a result shape that depended on passed options.
  Most importantly, this change fits well with the deprecation of `:returning`.

### Features

- **`Snex.pyeval/4` can execute code with Python `return` statements**

  `Snex.pyeval/4` is now able to parse and execute `return` statements in Python code.
  This obsoletes the `:returning` option, which now emits a deprecation warning.

- **`Snex.pyeval/4` can be called with interpreter instead of `%Snex.Env{}`**

  Simplifies setup for one-off commands.
  `pyeval` without a `Snex.Env` is less performant due to additional interprocess communication, but cutting a `make_env` Python call makes up for it when running just a few commands.

- **Add a way to configure port's `:parallelism, :busy_limits_port, :busy_limits_msgq`**

  These can be configured with `:port_opts` opt in `Snex.Interpreter.start_link/1`.
  If not configured, `:busy_limits_port` is set to `{4MB, 8MB}`, up from Erlang's default of `{4kB, 8kB}`.

### Changes

- **Set line location with `ast` manipulation & cache code compilation**

  Both changes bring a sizeable reduction of `Snex.pyeval/4` execution overhead.
  1024 compiled code snippets are cached through `functools.lru`.

- **Pre-resolve interpreter name to pid when creating `Snex.Env`**

  Saves work down the line, especially in a multi-node scenario.
  Smooths over an edge case of garbage collecting on a dead registered interpreter.

- **Separate handling for call/cast earlier in the Elixir stack**

  Up to 70% speedup of `snex.cast`, taking better advantage of the fact that we don't care about the result.

- **Set Python's stdout/stderr to output `\r\n` newlines**

  stdout/stderr is handled through Erlang, and line offsets get mangled without carriage return.

- **Improve logs in exceptional circumstances**

- **Document that `Snex.pyeval/4` can run over timeout if suspended on port send**

- **Document thread-safety of `snex.{send,cast,call}` functions**

- **Lots of smaller refactors for code clarity and improved performance**

## 0.3.2

### Fixes

- **Copy Python linked directories over when preparing release**

  `uv 0.10.0` has changed how Python interpreters are installed - they now create and point venvs at a minor release directory, and the minor release directory is symlinked to a patch release directory.

  `Snex.Release.after_assemble` only copies Python interpreters that are actually used (pointed at) by the project, so it after upgrading `uv` it only copied the symlink.

  This fix recursively resolves and copies over symlinks while copying the Python directories.

## 0.3.0

### Breaking

- **Improved serialization**

  Serialization protocol between Python & Elixir has been changed.
  Instead of JSON encoding both ways, Elixir now encodes terms into a restricted Pickle (v5) format, while Python encodes objects into a restricted External Term Format.
  The encoded data is then decoded with `pickle.loads()` on Python side, and `:erlang.binary_to_term/1` in Elixir.

  Writing only encoders in both languages allows the implementation to be small and portable between versions, and reusing native decoding routines makes it highly performant - especially in Python.

  Consequently:
  - `Snex.Serde.Encoder` now requires an `encode/1` implementation, instead of `encode/2`
  - tuples are now encoded as tuples instead of lists
  - all Elixir terms can be encoded and round-tripped (fallback to `:erlang.term_to_binary/1`)
  - all Python basic objects can be encoded
  - floats preserve representation between languages
  - encoding customization is available on both sides

  Please consult the `Serialization` section of README.md for details.

### Features

- **New ways of calling Elixir code from Python**

  Code running under Snex can use `snex.call(m, f, a)` and `snex.cast(m, f, a)` to communicate with the BEAM.
  `snex.call` can be awaited on, and will return the result of the call, while `snex.cast` is fire-and-forget (returns `None`).
  Both functions will run the `apply(m, f, a)` in a new process (`m`, `f` can be given as `str`, and will be converted to atoms).
  They also accept an optional `node` argument that will spawn a process on a chosen Elixir node, as long as it's also running the `:snex` application.

  Existing `snex.send(to, data)` function is now implemented on top of `snex.cast`.

- **Sigils for code location**

  New `%Snex.Code{}` struct holds location metadata for Python code, for accurate stacktraces on Python side.

  `import Snex.Sigils` to use `~p"code"`, `~P"code"` sigils, which create `%Snex.Code{}` automatically.

  ```elixir
  iex> Snex.pyeval(env, ~p"raise RuntimeError('test')")

  {:error,
    %Snex.Error{
    code: :python_runtime_error,
    reason: "test",
    traceback: [...,
      "  File \"/Users/me/snex/CHANGELOG.md\", line 41, in <module>\n    raise RuntimeError(\"test\")\n",
      "RuntimeError: test\n"]
    }}
  ```

- **New `Snex.Interpreter` (and custom interpreters) options**
  - `:label` - labels the interpreter process through `:proc_lib.set_label/1`.
    Most usefully, the label is automatically set to `__MODULE__` when calling `use Snex.Interpreter`.
    This way, `Snex.Interpreter` processes become easily traceable to the custom interpreter that spawned them.

  - `:init_script` - now also takes `{script, args}` tuple, to pass variables to the init script and the root environment it prepares.

  - `:init_script_timeout` - if `:init_script` doesn't finish under the timeout, the interpreter process stops with `%Snex.Error{code: :init_script_timeout}`.
    60 seconds default.

  - `:wrap_exec` - customizes how the Python process is spawned by wrapping the executable path and arguments.
    This can be used e.g. to run Python inside a Docker container, see `docker_example_test.exs`.

- **New functions**
  - `Snex.destroy_env/1` - explicitly cleans up the referenced Python environment.

  - `Snex.Env.disable_gc/1` - opts out of automatic lifetime management for a `%Snex.Env{}`.
    It can only be called on the node that created the environment.
    Once called, the Python-side environment will only be destroyed on explicit `Snex.destroy_env/1` or on interpreter shutdown.

  - `Snex.Env.interpreter/1` - gets the interpreter process associated with a `%Snex.Env{}`.

  - `Snex.Interpreter.os_pid/1` - gets the OS PID of the Python interpreter process.
    Also available in custom interpreter modules.

  - `Snex.Interpreter.stop/1,2,3` - stops the interpreter process.
    Pending callers will return `{:error, %Snex.Error{code: :call_failed, reason: reason}}`

- **Infer interpreter if `Snex.make_env` is created `:from` existing environments**

  We can now call `Snex.make_env(from: env)` without explicitly passing in an interpreter, roughly equivalent to `Snex.make_env(Snex.Env.interpreter(env), from: env)`.

### Fixes

- **Fix `Snex.Env` usage in multi-node scenario**

  NIFs can only operate on local pids/ports, so `Snex.make_env({:my_interpreter, :"othernode@localhost"})` would fail trying to create a local resource with a remote interpreter.
  This is addressed by starting a garbage collector process on each Elixir node with Snex.
  The new process acts as a local proxy that cleans up remote environments.

- **Fix `Snex.Env` cleanup races**

  `Snex.Env` could get cleaned up before a `Snex.pyeval` using it has finished.
  This could happen because GC signals were processed immediately, while `Snex.pyeval` tasks are put onto a task queue.
  The race is addressed by treating GC signals as another kind of task, getting rid of the special treatment, and making sure they get processed after a `Snex.pyeval` that happened before.

- **Fail fast on port exit**

  Handle port exits if they happen before we try to run `:init_script`, instead of timing out waiting on `:init_script` result.

### Changes

- **Move serde work to Snex callers**

  Serialization and deserialization on Elixir side is now done outside of `Snex.Interpreter` process.
  The outside callers send data directly to the port (possibly with `:erpc` if remote).
  `Snex.Interpreter` is now almost exclusively responsible for routing responses from Python.

- **Document `Snex.Env` garbage collection behavior in multi-node scenarios**

- **Un-opaque the type of `Snex.Env{}`**

  `%Snex.Env{}` is directly referenced in the docs all over, so it makes sense to publicly type it with `Snex.Env.t()`.
  This replaces the previous opaque `Snex.env()` type.

- **Move Snex interface code to a public module `snex`**

  You can now import `snex` module from your external Python code to get awareness of Snex Python-side types and interface.

## 0.2.0

### Features

- **`Snex.Serde`: Rework serialization between Elixir and Python**
  - iodata can be wrapped with `Snex.Serde.binary(b)` to efficiently pass it to Python out-of-band, without further encoding.
    On the Python side, it's received as `bytes`.
  - Python `bytes` are passed to Elixir through the same mechanism.
  - Arbitrary Erlang terms can be wrapped with `Snex.Serde.term(t)`.
    They will be encoded with `term_to_binary` and will be decoded in Python as opaque, tagged binaries.
    Passing the value back to Elixir will decode it with `binary_to_term`.
    Like raw binaries wrapped with `Snex.Serde.binary/1`, terms are efficiently passed out-of-band.
  - Users can `defimpl Snex.Serde.Encoder` to define custom encoding of structs.
    If no implementation is defined, encoding falls back to `JSON` encoding (`JSON.Encoder` and its defaults).
    Implementations must encode structs into JSON.

- **Add `:init_script` option for `Snex.Interpreter` and its derivatives**

  A init script is a Python code snippet that will run when the interpreter is started and before it runs any commands.
  Failing to run the script will cause the process initialization to error.
  The variable context left by the script will become the initial context for all `Snex.make_env/3` calls using this interpreter.

- **Add support for sending BEAM messages from within Python code**

  BEAM messages can now be sent asynchronously from Python code.
  See README for description and an example.

- **Make `start_link/1` overridable when deriving `Snex.CustomInterpreter`**

- **Add Python traceback to Elixir-side errors emitted by Snex**

- **Drop down Python version requirement to `3.10`**

- **Add `:sync_start?` option for `Snex.Interpreter` and its derivatives**

  If `false` (default: `true`), Python initialization and custom init script will run asynchronously after starting the Snex interpreter process.

### Fixes

- **Make sure `Snex.Interpreter` process stops when Python interpreter process dies**

- **Fix `returning: [val]` not returning a list**

- **Make sure Snex artifacts are relocatable**
  - Modify created venvs to be path-agnostic.
  - Provide a `&Snex.Release.after_assemble/1` step for Mix release configuration.
  - Drop the `:otp_app` configuration option with `use Snex.Interpreter`.

### Changes

- **Split Python script into multiple files**

  As a direct consequence, Snex now prepends PYTHONPATH for started Python interpreters.

- **Make sure `opts` given to a custom `Interpreter` get passed through to `Snex.Interpreter.start_link/1`**

  Previously, only `:python` and `:environment` options could be customized and other options were discarded.

- **Retype Python commands as `TypedDict`**

- **Add overridable `__mix_recompile?__` implementation for `use Snex.Interpreter`**

  The default implementation will recompile your custom interpreter if `uv sync --check` reports stale state.

- **Do not instal dev dependencies from pyproject.toml**
