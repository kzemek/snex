## 0.2.1 (Unreleased)

### Features

- **Add `:label` option to `Snex.Interpreter`**

  The option labels the interpreter process through `:proc_lib.set_label/1`.
  Most usefully, the label is automatically set to `__MODULE__` when calling `use Snex.Interpreter`.
  This way, `Snex.Interpreter` processes become easily traceable to the custom interpreter that spawned them.

- **Add `:init_script_timeout` option to `Snex.Interpreter`**

  The timeout waits for the init script to finish, otherwise errors with `%Snex.Error{code: :init_script_timeout}`.
  It's set to 60 seconds by default.

- **Add `Snex.get_interpreter/1` function to get the interpreter for a `Snex.Env`**

- **Infer interpreter if `Snex.make_env` is created `:from` existing environments**

  We can now call `Snex.make_env(from: env)` without explicitly passing in an interpreter, roughly equivalent to `Snex.make_env(Snex.get_interpreter(env), from: env)`.

### Changes

- Document `Snex.Env` garbage collection behavior in multi-node scenarios.

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
