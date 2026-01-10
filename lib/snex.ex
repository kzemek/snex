defmodule Snex do
  @external_resource "README.md"
  @moduledoc File.read!("README.md")
             |> String.replace(
               ~r/.*?Quick example\n(.*?)## Installation & Requirements\n.*?(?=### Custom Interpreter)/s,
               "\\1"
             )
             |> String.replace(~r/^##/m, "#")
             |> String.replace("](#", "](#module-")
             |> String.replace("> [!WARNING]", "> #### Warning {: .warning}")
             |> String.replace("> [!IMPORTANT]", "> #### Important {: .info}")
             |> String.replace_prefix("", """
             Easy and efficient Python interop for Elixir.
             """)

  alias Snex.Internal.Commands

  defguardp is_code(code) when is_binary(code) or is_struct(code, Snex.Code)
  defguardp is_vars(vars) when is_map(vars)
  defguardp is_opts(opts) when is_list(opts)

  @typedoc """
  A string of Python code to be evaluated.

  See `Snex.pyeval/4`.
  """
  @type code :: String.t() | Snex.Code.t()

  @typedoc """
  A map of additional variables to be added to the environment.

  See `Snex.make_env/3`.
  """
  @type additional_vars :: %{optional(String.t()) => any()}

  @typedoc """
  A single environment or a list of environments to copy variables from.

  See `Snex.make_env/3`.
  """
  @type from_env ::
          Snex.Env.t() | {Snex.Env.t(), [only: [String.t()], except: [String.t()]]}

  @typedoc """
  Option for `Snex.make_env/3`.
  """
  @type make_env_opt ::
          {:from, from_env() | [from_env()]}
          | {:encoding_opts, Snex.Serde.encoding_opts()}

  @typedoc """
  Option for `Snex.pyeval/4`.
  """
  @type pyeval_opt ::
          {:timeout, timeout()}
          | {:encoding_opts, Snex.Serde.encoding_opts()}

  @type env_or_interpreter :: Snex.Env.t() | Snex.Interpreter.server()

  @doc """
  Shorthand for `Snex.make_env/3`:

      # when given a interpreter:
      Snex.make_env(interpreter, %{} = _additional_vars, [] = _opts)

      # when given an `opts` list with `:from` option:
      Snex.make_env(interpreter_from(opts[:from]), %{}, opts)

  """
  @spec make_env(Snex.Interpreter.server() | [make_env_opt()]) ::
          {:ok, Snex.Env.t()} | {:error, Snex.Error.t() | any()}
  def make_env(opts) when is_list(opts),
    do: make_env(interpreter_from(opts[:from]), %{}, opts)

  def make_env(interpreter),
    do: make_env(interpreter, %{}, [])

  @doc """
  Shorthand for `Snex.make_env/3`:

      # when given a map of `additional_vars`:
      Snex.make_env(interpreter, additional_vars, [] = _opts)

      # when given an `opts` list:
      Snex.make_env(interpreter, %{} = _additional_vars, opts)

      # when given both `additional_vars` and `opts` lists:
      Snex.make_env(interpreter_from(opts[:from]), additional_vars, opts)

  """
  @spec make_env(
          additional_vars(),
          [make_env_opt()]
        ) :: {:ok, Snex.Env.t()} | {:error, Snex.Error.t() | any()}
  def make_env(additional_vars, opts) when is_map(additional_vars) and is_list(opts),
    do: make_env(interpreter_from(opts[:from]), additional_vars, opts)

  @spec make_env(
          Snex.Interpreter.server(),
          additional_vars() | [make_env_opt()]
        ) :: {:ok, Snex.Env.t()} | {:error, Snex.Error.t() | any()}
  def make_env(interpreter, additional_vars) when is_map(additional_vars),
    do: make_env(interpreter, additional_vars, [])

  def make_env(interpreter, opts) when is_list(opts),
    do: make_env(interpreter, %{}, opts)

  @doc """
  Creates a new environment, `%Snex.Env{}`.

  A `%Snex.Env{}` instance is an Elixir-side reference to a variable context in Python.
  The variable contexts are the **global & local symbol table** the Python code will be executed
  with using the `Snex.pyeval/2` function.

  `additional_vars` are additional variables that will be added to the environment.
  They will be applied after copying variables from the environments listed in the `:from` option.

  Returns a tuple `{:ok, %Snex.Env{}}` on success.

  ## Options

    * `:from` - a list of environments to copy variables from.
      Each value in the list can be either a tuple `{%Snex.Env{}, opts}`, or a `%Snex.Env{}`
      (Shorthand for `{%Snex.Env{}, []}`).

      The following mutually exclusive options are supported:

      * `:only` - a list of variable names to copy from the `from` environment.
      * `:except` - a list of variable names to exclude from the `from` environment.

    * `:encoding_opts` (`t:Snex.Serde.encoding_opts/0`) - a list of encoding options to be used
      to encode `additional_vars`. These options will be merged with `:encoding_opts` given
      to the interpreter's `start_link/1` function.

      Note that these options *do not* affect commands that use the created environment!

  ## Examples

      # Create a new empty environment
      Snex.make_env(interpreter)

      # Create a new environment with additional variables
      Snex.make_env(interpreter, %{"x" => 1, "y" => 2})

      # Create a new environment copying variables from existing environments
      Snex.make_env(interpreter, from: env)
      Snex.make_env(interpreter, from: {env, except: ["y"]})
      Snex.make_env(interpreter, from: [env1, {env2, only: ["x"]}])

      # Create a new environment with both additional variables and `:from`
      Snex.make_env(interpreter, %{"x" => 1, "y" => 2}, from: env)

  """
  @spec make_env(
          Snex.Interpreter.server(),
          additional_vars(),
          [make_env_opt()]
        ) :: {:ok, Snex.Env.t()} | {:error, Snex.Error.t() | any()}
  def make_env(interpreter, additional_vars, opts) do
    check_additional_vars(additional_vars)

    from_env = opts |> Keyword.get(:from, []) |> normalize_make_env_from(interpreter)
    command = %Commands.MakeEnv{from_env: from_env, additional_vars: additional_vars}

    %{port: port, encoding_opts: encoding_opts} =
      case from_env do
        [%Commands.MakeEnv.FromEnv{env: env} | _] -> env
        _ -> Snex.Interpreter.get_settings(interpreter)
      end

    merged_encoding_opts = Keyword.merge(encoding_opts, Keyword.get(opts, :encoding_opts, []))

    with {:ok, env_id} <-
           Snex.Interpreter.command(interpreter, port, command, merged_encoding_opts, :infinity),
         do: {:ok, Snex.Env.make(env_id, port, interpreter, encoding_opts)}
  end

  @doc """
  Destroys an environment created with `Snex.make_env/3`.

  This function is idempotent - it can be called multiple times on the same environment. It can also
  be called from any node.

  If the environment was created on the current node, its automatic garbage collection will
  be disabled with `Snex.Env.disable_gc/1`. Otherwise (if `Snex.Env.disable_gc/1` was not called
  beforehand), garbage collection will still be attempted, resulting in extraneous (but harmless)
  communication with Python interpreter.
  """
  @spec destroy_env(Snex.Env.t()) :: :ok
  def destroy_env(%Snex.Env{} = env) do
    :ok =
      Snex.Interpreter.command_noreply(
        env.interpreter,
        env.port,
        %Commands.GC{env: env},
        env.encoding_opts
      )

    if env.ref != nil and node(env.ref) == node(), do: Snex.Env.disable_gc(env)
    :ok
  end

  @doc """
  Shorthand for `Snex.pyeval/4`:

      # with `t:code/0`:
      Snex.pyeval(env_or_interpreter, code, %{} = _additional_vars, [] = _opts)

      # with `t:additional_vars/0`:
      Snex.pyeval(env_or_interpreter, nil = _code, additional_vars, [] = _opts)

      # with `opts/0` list:
      Snex.pyeval(env_or_interpreter, nil = _code, %{} = _additional_vars, opts)

  """
  @spec pyeval(
          Snex.Env.t() | Snex.Interpreter.server(),
          code() | additional_vars() | [pyeval_opt()]
        ) ::
          {:ok, any()} | {:error, Snex.Error.t() | any()}
  def pyeval(env_or_interpreter, code) when is_code(code),
    do: pyeval(env_or_interpreter, code, %{}, [])

  def pyeval(env_or_interpreter, additional_vars) when is_vars(additional_vars),
    do: pyeval(env_or_interpreter, nil, additional_vars, [])

  def pyeval(env_or_interpreter, opts) when is_opts(opts),
    do: pyeval(env_or_interpreter, nil, %{}, opts)

  @doc """
  Shorthand for `Snex.pyeval/4`:

      # with `t:code/0` and `t:additional_vars/0`:
      Snex.pyeval(env_or_interpreter, code, additional_vars, [] = _opts)

      # with `t:code/0` and `opts/0`:
      Snex.pyeval(env_or_interpreter, code, %{} = _additional_vars, opts)

      # with `t:additional_vars/0` and `t:opts/0`:
      Snex.pyeval(env_or_interpreter, nil = _code, additional_vars, opts)

  """
  @spec pyeval(Snex.Env.t() | Snex.Interpreter.server(), code(), additional_vars()) ::
          {:ok, any()} | {:error, Snex.Error.t() | any()}
  def pyeval(env_or_interpreter, code, additional_vars)
      when is_code(code) and is_vars(additional_vars),
      do: pyeval(env_or_interpreter, code, additional_vars, [])

  @spec pyeval(Snex.Env.t() | Snex.Interpreter.server(), code(), [pyeval_opt()]) ::
          {:ok, any()} | {:error, Snex.Error.t() | any()}
  def pyeval(env_or_interpreter, code, opts)
      when is_code(code) and is_opts(opts),
      do: pyeval(env_or_interpreter, code, %{}, opts)

  @spec pyeval(Snex.Env.t() | Snex.Interpreter.server(), additional_vars(), [pyeval_opt()]) ::
          {:ok, any()} | {:error, Snex.Error.t() | any()}
  def pyeval(env_or_interpreter, additional_vars, opts)
      when is_vars(additional_vars) and is_opts(opts),
      do: pyeval(env_or_interpreter, nil, additional_vars, opts)

  @doc ~s'''
  Evaluates Python code in the given environment.

  `additional_vars` are added to the environment before the code is executed.
  See `Snex.make_env/3` for more information.

  Returns `{:ok, result}` on success. If the code does not return a value, `result` will be `nil`.

  ## Options

    * `:timeout` - the timeout for the evaluation. Can be a `timeout()` or `:infinity`.
      Default: 5 seconds.

    * `:encoding_opts` (`t:Snex.Serde.encoding_opts/0`) - a list of encoding options to be used
      to encode `additional_vars`. These options will be merged with `:encoding_opts` given
      to the interpreter's `start_link/1` function.

      Note that these options *do not* affect the encoding of `snex.call` return values!

  ## Examples

      Snex.pyeval(env, """
        return [x * x for x in range(num_range)]
        """, %{"num_range" => 6}")

      [0, 1, 4, 9, 16, 25]

  '''
  @spec pyeval(
          Snex.Env.t() | Snex.Interpreter.server(),
          code() | nil,
          additional_vars(),
          [pyeval_opt()]
        ) :: {:ok, any()} | {:error, Snex.Error.t() | any()}
  def pyeval(env_or_interpreter, code, additional_vars, opts)
      when (is_code(code) or is_nil(code)) and is_vars(additional_vars) and is_opts(opts) do
    check_additional_vars(additional_vars)

    {code, opts} = code |> Snex.Code.wrap() |> handle_deprecated_returning(opts)

    {env, interpreter, %{encoding_opts: encoding_opts, port: port}} =
      case env_or_interpreter do
        %Snex.Env{} = env -> {env, env.interpreter, env}
        interpreter -> {nil, interpreter, Snex.Interpreter.get_settings(interpreter)}
      end

    encoding_opts = Keyword.merge(encoding_opts, Keyword.get(opts, :encoding_opts, []))
    timeout = Keyword.get(opts, :timeout, to_timeout(second: 5))
    command = %Commands.Eval{code: code, env: env, additional_vars: additional_vars}

    Snex.Interpreter.command(interpreter, port, command, encoding_opts, timeout)
  end

  defp handle_deprecated_returning(code, opts) do
    case Keyword.pop(opts, :returning) do
      {returning, opts} when is_code(returning) or is_list(returning) ->
        {:current_stacktrace, stacktrace} = Process.info(self(), :current_stacktrace)
        stacktrace = Enum.drop(stacktrace, 3)
        warn_once_key = {__MODULE__, :show_returning_warning, List.first(stacktrace)}

        if :persistent_term.get(warn_once_key, true) do
          IO.warn("`:returning` is deprecated; use plain Python `return` statements", stacktrace)
          :persistent_term.put(warn_once_key, false)
        end

        returning =
          if is_list(returning),
            do: "[#{Enum.join(returning, ", ")}]",
            else: returning

        returning = Snex.Code.wrap(returning)
        code = Snex.Code.wrap(code)

        code =
          if code,
            do: %Snex.Code{code | src: "#{code.src}\nreturn #{returning.src}\n"},
            else: %Snex.Code{returning | src: "return #{returning.src}"}

        {code, opts}

      _ ->
        {code, opts}
    end
  end

  defp check_additional_vars(additional_vars) do
    if not (additional_vars |> Map.keys() |> Enum.all?(&is_binary/1)),
      do: raise(ArgumentError, "additional_vars must be a map with string keys")
  end

  defp normalize_make_env_from(from, interpreter) do
    for from_env <- List.wrap(from) do
      {env, opts} =
        case from_env do
          {%Snex.Env{} = env, opts} when is_list(opts) -> {env, opts}
          %Snex.Env{} = env -> {env, []}
        end

      if env.interpreter != interpreter,
        do: raise(ArgumentError, "all envs in `from` must belong to the same interpreter")

      only = Keyword.get(opts, :only, [])
      except = Keyword.get(opts, :except, [])

      {keys_mode, keys} =
        case {only, except} do
          {[], except} -> {:except, except}
          {only, []} -> {:only, only}
          {_, _} -> raise(ArgumentError, "`only` and `except` cannot be used together")
        end

      %Commands.MakeEnv.FromEnv{env: env, keys_mode: keys_mode, keys: keys}
    end
  end

  defp interpreter_from(from) do
    case List.wrap(from) do
      [%Snex.Env{} = env | _] -> env.interpreter
      [{%Snex.Env{} = env, _opts} | _] -> env.interpreter
      _ -> raise(ArgumentError, "`from` must contain at least one environment")
    end
  end
end
