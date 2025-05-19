defmodule Snex do
  @moduledoc """
  See [README](README.md) for an overview.
  """
  alias Snex.Internal.Commands

  @pyeval_default_timeout to_timeout(second: 5)

  @type interpreter :: Snex.Interpreter.server()
  @type code :: String.t()
  @type error :: Snex.Error.t() | any()

  @type additional_values :: %{optional(String.t()) => any()}
  @type from_env_opt :: {:only, [String.t()]} | {:except, [String.t()]}
  @type from_env :: Snex.Env.t() | {Snex.Env.t(), [from_env_opt()]}
  @type make_env_opts :: [from: from_env() | [from_env()]]

  @spec make_env(interpreter()) :: {:ok, Snex.Env.t()} | {:error, error()}
  def make_env(interpreter),
    do: make_env(interpreter, %{}, from: [])

  @spec make_env(
          interpreter(),
          additional_values() | make_env_opts()
        ) :: {:ok, Snex.Env.t()} | {:error, error()}
  def make_env(interpreter, additional_values) when is_map(additional_values),
    do: make_env(interpreter, additional_values, from: [])

  def make_env(interpreter, from: envs),
    do: make_env(interpreter, %{}, from: envs)

  @spec make_env(
          interpreter(),
          additional_values(),
          make_env_opts()
        ) :: {:ok, Snex.Env.t()} | {:error, error()}
  def make_env(interpreter, additional_values, from: envs) do
    if not (additional_values |> Map.keys() |> Enum.all?(&is_binary/1)),
      do: raise(ArgumentError, "additional_values must be a map with string keys")

    from = normalize_make_env_from(interpreter, envs)

    GenServer.call(
      interpreter,
      %Commands.MakeEnv{from_env: from, additional_values: additional_values},
      :infinity
    )
  end

  @type pyeval_opts :: [returning: [String.t()] | String.t(), timeout: timeout()]

  @spec pyeval(
          Snex.Env.t(),
          code() | additional_values() | pyeval_opts()
        ) :: :ok | {:ok, any()} | {:error, error()}
  def pyeval(%Snex.Env{} = env, code) when is_binary(code),
    do: pyeval(env, code, %{}, [])

  def pyeval(%Snex.Env{} = env, additional_values) when is_map(additional_values),
    do: pyeval(env, nil, additional_values, [])

  def pyeval(%Snex.Env{} = env, opts) when is_list(opts),
    do: pyeval(env, nil, %{}, opts)

  @spec pyeval(
          Snex.Env.t(),
          code() | nil,
          additional_values() | pyeval_opts()
        ) :: :ok | {:ok, any()} | {:error, error()}
  def pyeval(%Snex.Env{} = env, code, additional_values) when is_map(additional_values),
    do: pyeval(env, code, additional_values, [])

  def pyeval(%Snex.Env{} = env, code, opts) when is_list(opts),
    do: pyeval(env, code, %{}, opts)

  @spec pyeval(
          Snex.Env.t(),
          code() | nil,
          additional_values(),
          pyeval_opts()
        ) :: :ok | {:ok, any()} | {:error, error()}
  def pyeval(%Snex.Env{} = env, code, additional_values, opts)
      when (is_binary(code) or is_nil(code)) and is_map(additional_values) and is_list(opts) do
    check_additional_values(additional_values)

    returning =
      with ret when is_list(ret) <- opts[:returning],
           do: Enum.join(ret, ", ")

    GenServer.call(
      env.interpreter,
      %Commands.Eval{
        code: code,
        env: env,
        additional_values: additional_values,
        returning: returning
      },
      Keyword.get(opts, :timeout, @pyeval_default_timeout)
    )
  end

  defp check_additional_values(additional_values) do
    if not (additional_values |> Map.keys() |> Enum.all?(&is_binary/1)),
      do: raise(ArgumentError, "additional_values must be a map with string keys")
  end

  defp normalize_make_env_from(interpreter, from) do
    from
    |> List.wrap()
    |> Enum.map(fn
      {%Snex.Env{} = env, opts} when is_list(opts) -> {env, opts}
      %Snex.Env{} = env -> {env, []}
    end)
    |> Enum.map(fn {%Snex.Env{} = env, opts} ->
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
    end)
  end
end
