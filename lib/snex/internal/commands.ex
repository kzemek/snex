defmodule Snex.Internal.Command do
  @moduledoc false
  defmacro __using__(_opts) do
    quote do
      @before_compile unquote(__MODULE__)
    end
  end

  @spec __before_compile__(Macro.Env.t()) :: nil
  def __before_compile__(env) do
    defimpl JSON.Encoder, for: env.module do
      alias Snex.Internal

      def encode(command, encoder),
        do: Internal.Command.encode(command, encoder)
    end

    nil
  end

  @doc false
  @spec encode(struct(), JSON.Encoder.t()) :: JSON.Encoder.t()
  def encode(%struct{} = command, encoder) do
    command_name = struct |> Module.split() |> List.last() |> Macro.underscore()

    command
    |> Map.from_struct()
    |> Map.put(:command, command_name)
    |> case do
      %{env: env} = command ->
        command |> Map.delete(:env) |> Map.put(:env_id, Base.encode64(env.id))

      command ->
        command
    end
    |> JSON.Encoder.encode(encoder)
  end
end

defmodule Snex.Internal.Commands.Init do
  @moduledoc false
  use Snex.Internal.Command

  @type t :: %__MODULE__{
          code: String.t() | nil
        }

  @enforce_keys [:code]
  defstruct [:code]
end

defmodule Snex.Internal.Commands.MakeEnv do
  @moduledoc false
  use Snex.Internal.Command

  defmodule FromEnv do
    @moduledoc false
    use Snex.Internal.Command

    @type t :: %__MODULE__{
            env: Snex.Env.t(),
            keys_mode: :only | :except,
            keys: [String.t()]
          }

    @enforce_keys [:env]
    defstruct [:env, keys_mode: :except, keys: []]
  end

  @type t :: %__MODULE__{
          from_env: [FromEnv.t()],
          additional_vars: %{String.t() => term()}
        }

  @enforce_keys []
  defstruct from_env: [], additional_vars: %{}
end

defmodule Snex.Internal.Commands.Eval do
  @moduledoc false
  use Snex.Internal.Command

  @type t :: %__MODULE__{
          code: String.t() | nil,
          env: Snex.Env.t(),
          returning: String.t() | nil,
          additional_vars: %{String.t() => term()}
        }

  @enforce_keys [:code, :env]
  defstruct [:code, :env, returning: nil, additional_vars: %{}]
end
