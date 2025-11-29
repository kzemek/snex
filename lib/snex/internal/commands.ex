defmodule Snex.Internal.Commands.Init do
  @moduledoc false

  @type t :: %__MODULE__{
          command: :init,
          start_ts: {:wall | :os_monotonic, non_neg_integer()},
          code: String.t() | nil
        }

  @enforce_keys [:start_ts, :code]
  @derive {JSON.Encoder, except: [:start_ts]}
  defstruct [:start_ts, :code, command: :init]
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
          command: :make_env,
          start_ts: {:wall | :os_monotonic, non_neg_integer()},
          from_env: [FromEnv.t()],
          additional_vars: %{String.t() => term()}
        }

  @enforce_keys [:start_ts]
  @derive {JSON.Encoder, except: [:start_ts]}
  defstruct [:start_ts, from_env: [], additional_vars: %{}, command: :make_env]
end

defmodule Snex.Internal.Commands.Eval do
  @moduledoc false

  @type t :: %__MODULE__{
          command: :eval,
          start_ts: {:wall | :os_monotonic, non_neg_integer()},
          code: String.t() | nil,
          env: Snex.Env.t(),
          returning: String.t() | nil,
          additional_vars: %{String.t() => term()}
        }

  @enforce_keys [:start_ts, :code, :env]
  @derive {JSON.Encoder, except: [:start_ts]}
  defstruct [:start_ts, :code, :env, returning: nil, additional_vars: %{}, command: :eval]
end
