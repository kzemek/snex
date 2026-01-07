defprotocol Snex.Internal.Command do
  @moduledoc false

  @spec referenced_envs(t()) :: [Snex.Env.t()]
  def referenced_envs(command)

  @spec encode(t(), Snex.Serde.encoding_opts()) :: iodata()
  def encode(command, user_encoding_opts)
end

defmodule Snex.Internal.Commands.Init do
  @moduledoc false

  @type t :: %__MODULE__{
          code: Snex.Code.t() | nil,
          additional_vars: %{optional(String.t()) => term()}
        }

  @enforce_keys [:code]
  defstruct [:code, additional_vars: %{}]

  defimpl Snex.Internal.Command do
    @impl Snex.Internal.Command
    def referenced_envs(_command),
      do: []

    @impl Snex.Internal.Command
    def encode(%@for{} = command, user_encoding_opts) do
      Snex.Serde.encode_to_iodata!(%{
        "command" => "init",
        "code" => command.code,
        "additional_vars" =>
          Map.new(command.additional_vars, fn {k, v} ->
            {k, Snex.Serde.encode_fragment!(v, user_encoding_opts)}
          end)
      })
    end
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
          additional_vars: %{optional(String.t()) => term()}
        }

  @enforce_keys []
  defstruct from_env: [], additional_vars: %{}

  defimpl Snex.Internal.Command do
    @impl Snex.Internal.Command
    def referenced_envs(%@for{from_env: from_envs}),
      do: Enum.map(from_envs, & &1.env)

    @impl Snex.Internal.Command
    def encode(%@for{} = command, user_encoding_opts) do
      Snex.Serde.encode_to_iodata!(%{
        "command" => "make_env",
        "additional_vars" =>
          Map.new(command.additional_vars, fn {k, v} ->
            {k, Snex.Serde.encode_fragment!(v, user_encoding_opts)}
          end),
        "from_env" =>
          Enum.map(
            command.from_env,
            &%{
              "env" => Snex.Serde.binary(&1.env.id, :bytes),
              "keys_mode" => Atom.to_string(&1.keys_mode),
              "keys" => &1.keys
            }
          )
      })
    end
  end
end

defmodule Snex.Internal.Commands.Eval do
  @moduledoc false

  @type t :: %__MODULE__{
          code: Snex.Code.t() | nil,
          env: Snex.Env.t(),
          returning: Snex.Code.t() | nil,
          additional_vars: %{optional(String.t()) => term()}
        }

  @enforce_keys [:code, :env]
  defstruct [:code, :env, returning: nil, additional_vars: %{}]

  defimpl Snex.Internal.Command do
    @impl Snex.Internal.Command
    def referenced_envs(%@for{env: env}),
      do: [env]

    @impl Snex.Internal.Command
    def encode(%@for{} = command, user_encoding_opts) do
      Snex.Serde.encode_to_iodata!(%{
        "command" => "eval",
        "code" => command.code,
        "env" => Snex.Serde.binary(command.env.id, :bytes),
        "returning" => command.returning,
        "additional_vars" =>
          Map.new(command.additional_vars, fn {k, v} ->
            {k, Snex.Serde.encode_fragment!(v, user_encoding_opts)}
          end)
      })
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

    @impl Snex.Internal.Command
    def encode(%@for{} = command, _user_encoding_opts) do
      Snex.Serde.encode_to_iodata!(%{
        "command" => "gc",
        "env" => Snex.Serde.binary(command.env.id, :bytes)
      })
    end
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

    @impl Snex.Internal.Command
    def encode(%@for{} = command, user_encoding_opts) do
      Snex.Serde.encode_to_iodata!(%{
        "command" => "call_response",
        "result" => Snex.Serde.encode_fragment!(command.result, user_encoding_opts)
      })
    end
  end
end

defmodule Snex.Internal.Commands.CallErrorResponse do
  @moduledoc false

  @type t :: %__MODULE__{reason: String.t()}

  @enforce_keys [:reason]
  defstruct [:reason]

  defimpl Snex.Internal.Command do
    @impl Snex.Internal.Command
    def referenced_envs(%@for{}),
      do: []

    @impl Snex.Internal.Command
    def encode(%@for{} = command, _user_encoding_opts) do
      Snex.Serde.encode_to_iodata!(%{
        "command" => "call_error_response",
        "reason" => command.reason
      })
    end
  end
end
