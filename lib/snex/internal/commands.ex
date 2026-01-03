defprotocol Snex.Internal.Command do
  @moduledoc false

  @spec referenced_envs(t()) :: [Snex.Env.t()]
  def referenced_envs(command)
end

defmodule Snex.Internal.Commands.Init do
  @moduledoc false

  @type t :: %__MODULE__{
          code: String.t() | nil
        }

  @enforce_keys [:code]
  defstruct [:code]

  defimpl Snex.Internal.Command do
    @impl Snex.Internal.Command
    def referenced_envs(_command),
      do: []
  end

  defimpl Snex.Serde.Encoder do
    @impl Snex.Serde.Encoder
    def encode(%@for{} = command),
      do: %{"command" => "init", "code" => command.code}
  end
end

defmodule Snex.Internal.Commands.MakeEnv do
  @moduledoc false

  defmodule FromEnv do
    @moduledoc false

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

  defimpl Snex.Internal.Command do
    @impl Snex.Internal.Command
    def referenced_envs(%@for{from_env: from_envs}),
      do: Enum.map(from_envs, & &1.env)
  end

  defimpl Snex.Serde.Encoder do
    @impl Snex.Serde.Encoder
    def encode(%@for{} = command) do
      %{
        "command" => "make_env",
        "additional_vars" => command.additional_vars,
        "from_env" =>
          Enum.map(
            command.from_env,
            &%{
              "env" => Snex.Serde.binary(&1.env.id),
              "keys_mode" => Atom.to_string(&1.keys_mode),
              "keys" => &1.keys
            }
          )
      }
    end
  end
end

defmodule Snex.Internal.Commands.Eval do
  @moduledoc false

  @type t :: %__MODULE__{
          code: String.t() | nil,
          env: Snex.Env.t(),
          returning: String.t() | nil,
          additional_vars: %{String.t() => term()}
        }

  @enforce_keys [:code, :env]
  defstruct [:code, :env, returning: nil, additional_vars: %{}]

  defimpl Snex.Internal.Command do
    @impl Snex.Internal.Command
    def referenced_envs(%@for{env: env}),
      do: [env]
  end

  defimpl Snex.Serde.Encoder do
    @impl Snex.Serde.Encoder
    def encode(%@for{} = command) do
      %{
        "command" => "eval",
        "code" => command.code,
        "env" => Snex.Serde.binary(command.env.id),
        "returning" => command.returning,
        "additional_vars" => command.additional_vars
      }
    end
  end
end

defmodule Snex.Internal.Commands.GC do
  @moduledoc false

  @type t :: %__MODULE__{
          env: Snex.Env.t()
        }

  @enforce_keys [:env]
  defstruct [:env]

  defimpl Snex.Internal.Command do
    @impl Snex.Internal.Command
    def referenced_envs(%@for{env: env}),
      do: [env]
  end

  defimpl Snex.Serde.Encoder do
    @impl Snex.Serde.Encoder
    def encode(%@for{} = command),
      do: %{"command" => "gc", "env" => Snex.Serde.binary(command.env.id)}
  end
end

defmodule Snex.Internal.Commands.CallResponse do
  @moduledoc false

  @type t :: %__MODULE__{
          result: term()
        }

  @enforce_keys [:result]
  defstruct [:result]

  defimpl Snex.Internal.Command do
    @impl Snex.Internal.Command
    def referenced_envs(%@for{}),
      do: []
  end

  defimpl Snex.Serde.Encoder do
    @impl Snex.Serde.Encoder
    def encode(%@for{} = command),
      do: %{"command" => "call_response", "result" => command.result}
  end
end

defmodule Snex.Internal.Commands.CallErrorResponse do
  @moduledoc false

  @type t :: %__MODULE__{}

  @enforce_keys []
  defstruct []

  defimpl Snex.Internal.Command do
    @impl Snex.Internal.Command
    def referenced_envs(%@for{}),
      do: []
  end

  defimpl Snex.Serde.Encoder do
    @impl Snex.Serde.Encoder
    def encode(%@for{}),
      do: %{"command" => "call_error_response"}
  end
end
