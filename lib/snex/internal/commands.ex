defmodule Snex.Internal.Commands.Init do
  @moduledoc false

  @type t :: %__MODULE__{
          command: String.t(),
          code: String.t() | nil
        }

  @enforce_keys [:code]
  @derive JSON.Encoder
  defstruct [:code, command: "init"]
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
end
