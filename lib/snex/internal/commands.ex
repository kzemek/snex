defprotocol Snex.Internal.Command do
  @moduledoc false

  @spec referenced_envs(t()) :: [Snex.Env.t()]
  def referenced_envs(command)
end

defmodule Snex.Internal.Commands.Init do
  @moduledoc false

  @type t :: %__MODULE__{
          command: String.t(),
          code: String.t() | nil
        }

  @enforce_keys [:code]
  @derive JSON.Encoder
  defstruct [:code, command: "init"]

  defimpl Snex.Internal.Command do
    def referenced_envs(_command),
      do: []
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
    @derive JSON.Encoder
    defstruct [:env, keys_mode: :except, keys: []]
  end

  @type t :: %__MODULE__{
          command: String.t(),
          from_env: [FromEnv.t()],
          additional_vars: %{String.t() => term()}
        }

  @enforce_keys []
  @derive JSON.Encoder
  defstruct from_env: [], additional_vars: %{}, command: "make_env"

  defimpl Snex.Internal.Command do
    def referenced_envs(%@for{from_env: from_envs}),
      do: Enum.map(from_envs, & &1.env)
  end
end

defmodule Snex.Internal.Commands.Eval do
  @moduledoc false

  @type t :: %__MODULE__{
          command: String.t(),
          code: String.t() | nil,
          env: Snex.Env.t(),
          returning: String.t() | nil,
          additional_vars: %{String.t() => term()}
        }

  @enforce_keys [:code, :env]
  @derive JSON.Encoder
  defstruct [:code, :env, returning: nil, additional_vars: %{}, command: "eval"]

  defimpl Snex.Internal.Command do
    def referenced_envs(%@for{env: env}),
      do: [env]
  end
end

defmodule Snex.Internal.Commands.GC do
  @moduledoc false

  @type t :: %__MODULE__{
          command: String.t(),
          env: Snex.Env.t()
        }

  @enforce_keys [:env]
  @derive JSON.Encoder
  defstruct [:env, command: "gc"]

  defimpl Snex.Internal.Command do
    def referenced_envs(%@for{env: env}),
      do: [env]
  end
end
