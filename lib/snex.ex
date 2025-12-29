defmodule Snex do
  @external_resource "README.md"
  @moduledoc File.read!("README.md")
             |> String.replace(~r/^.*?(?=Easy and efficient Python interop for Elixir)/s, "")
             |> String.replace("> [!WARNING]", "> #### Warning {: .warning}")
             |> String.replace("> [!IMPORTANT]", "> #### Important {: .info}")

  alias Snex.Internal.Commands

  @typedoc """
  An "environment" is an Elixir-side reference to Python-side variable context in which your Python
  code will run.

  See `Snex.make_env/3` for more information.
  """
  @opaque env() :: Snex.Env.t()

  @typedoc """
  A string of Python code to be evaluated.

  See `Snex.pyeval/4`.
  """
  @type code :: String.t()

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
          env() | {env(), [only: [String.t()], except: [String.t()]]}

  @typedoc """
  Option for `Snex.make_env/3`.
  """
  @type make_env_opt :: {:from, from_env() | [from_env()]}

  @typedoc """
  Option for `Snex.pyeval/4`.
  """
  @type pyeval_opt :: {:returning, [String.t()] | String.t()} | {:timeout, timeout()}

  @doc """
  Shorthand for `Snex.make_env/3`:

      # when given a interpreter:
      Snex.make_env(interpreter, %{} = _additional_vars, [] = _opts)

      # when given an `opts` list with `:from` option:
      Snex.make_env(interpreter_from(opts[:from]), %{}, opts)

  """
  @spec make_env(Snex.Interpreter.server() | [make_env_opt()]) ::
          {:ok, env()} | {:error, Snex.Error.t() | any()}
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
        ) :: {:ok, env()} | {:error, Snex.Error.t() | any()}
  def make_env(additional_vars, opts) when is_map(additional_vars) and is_list(opts),
    do: make_env(interpreter_from(opts[:from]), additional_vars, opts)

  @spec make_env(
          Snex.Interpreter.server(),
          additional_vars() | [make_env_opt()]
        ) :: {:ok, env()} | {:error, Snex.Error.t() | any()}
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
        ) :: {:ok, env()} | {:error, Snex.Error.t() | any()}
  def make_env(interpreter, additional_vars, opts) do
    check_additional_vars(additional_vars)

    from_env = opts |> Keyword.get(:from, []) |> normalize_make_env_from(interpreter)
    command = %Commands.MakeEnv{from_env: from_env, additional_vars: additional_vars}

    port =
      case from_env do
        [%Commands.MakeEnv.FromEnv{env: %Snex.Env{port: port}} | _] -> port
        _ -> Snex.Interpreter.get_port(interpreter)
      end

    Snex.Interpreter.command(interpreter, port, command, :infinity)
  end

  @doc """
  Returns the interpreter that the given environment belongs to.
  """
  @spec get_interpreter(env()) :: Snex.Interpreter.server()
  def get_interpreter(%Snex.Env{} = env),
    do: env.interpreter

  @doc """
  Shorthand for `Snex.pyeval/4`:

      # when given a `code` string:
      Snex.pyeval(env, code, %{} = _additional_vars, [] = _opts)

      # when given an `additional_vars` map:
      Snex.pyeval(env, nil = _code, additional_vars, [] = _opts)

      # when given an `opts` list:
      Snex.pyeval(env, nil = _code, %{} = _additional_vars, opts)

  """
  @spec pyeval(
          env(),
          code() | additional_vars() | [pyeval_opt()]
        ) :: :ok | {:ok, any()} | {:error, Snex.Error.t() | any()}
  def pyeval(%Snex.Env{} = env, code) when is_binary(code),
    do: pyeval(env, code, %{}, [])

  def pyeval(%Snex.Env{} = env, additional_vars) when is_map(additional_vars),
    do: pyeval(env, nil, additional_vars, [])

  def pyeval(%Snex.Env{} = env, opts) when is_list(opts),
    do: pyeval(env, nil, %{}, opts)

  @doc """
  Shorthand for `Snex.pyeval/4`:

      # when given code and an `additional_vars` map:
      Snex.pyeval(env, code, additional_vars, [] = _opts)

      # when given code and an `opts` list:
      Snex.pyeval(env, code, %{} = _additional_vars, opts)

      # when given an `additional_vars` map and an `opts` list:
      Snex.pyeval(env, nil = _code, additional_vars, opts)

  """
  @spec pyeval(
          env(),
          code() | nil | additional_vars(),
          additional_vars() | [pyeval_opt()]
        ) :: :ok | {:ok, any()} | {:error, Snex.Error.t() | any()}
  def pyeval(%Snex.Env{} = env, additional_vars, opts)
      when is_map(additional_vars) and is_list(opts),
      do: pyeval(env, nil, additional_vars, opts)

  def pyeval(%Snex.Env{} = env, code, additional_vars) when is_map(additional_vars),
    do: pyeval(env, code, additional_vars, [])

  def pyeval(%Snex.Env{} = env, code, opts) when is_list(opts),
    do: pyeval(env, code, %{}, opts)

  @doc ~s'''
  Evaluates a Python code string in the given environment.

  `additional_vars` are added to the environment before the code is executed.
  See `Snex.make_env/3` for more information.

  Returns `:ok` on success, or a tuple `{:ok, result}` if `:returning` option is provided.

  ## Options

    * `:returning` - a Python expression or a list of Python expressions to evaluate and return from
      this function. If not provided, the result will be `:ok`.

    * `:timeout` - the timeout for the evaluation. Can be a `timeout()` or `:infinity`.
      Default: 5 seconds.

  ## Examples

      Snex.pyeval(env, """
        res = [x for x in range(num_range)]
        """, %{"num_range" => 6}, returning: "[x * x for x in res]")

      [0, 1, 4, 9, 16, 25]

  '''
  @spec pyeval(
          env(),
          code() | nil,
          additional_vars(),
          [pyeval_opt()]
        ) :: :ok | {:ok, any()} | {:error, Snex.Error.t() | any()}
  def pyeval(%Snex.Env{} = env, code, additional_vars, opts)
      when (is_binary(code) or is_nil(code)) and is_map(additional_vars) and is_list(opts) do
    check_additional_vars(additional_vars)

    returning =
      with ret when is_list(ret) <- opts[:returning],
           do: "[#{Enum.join(ret, ", ")}]"

    command =
      %Commands.Eval{
        code: code,
        env: env,
        additional_vars: additional_vars,
        returning: returning
      }

    Snex.Interpreter.command(
      env.interpreter,
      env.port,
      command,
      Keyword.get(opts, :timeout, to_timeout(second: 5))
    )
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
