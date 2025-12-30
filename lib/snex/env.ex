defmodule Snex.Env do
  @moduledoc """
  An environment (`%Snex.Env{}`) is a Elixir-side reference to Python-side variable context in which
  the Python code is executed.

  This module is not intended to be used directly.
  Instead, you would use the `Snex.make_env/3` to create environments, `Snex.pyeval/4`
  to use them, and `Snex.get_interpreter/1` to get the interpreter for an environment.

  See `m:Snex#module-environments` module documentation for more details.
  """
  alias Snex.Internal.EnvReferenceNif

  @typedoc false
  @type t :: %__MODULE__{
          id: binary(),
          ref: :erlang.nif_resource() | nil,
          port: port(),
          interpreter: Snex.Interpreter.server()
        }

  @enforce_keys [:id, :ref, :port, :interpreter]
  defstruct [:id, :ref, :port, :interpreter]

  @doc false
  @spec make(id :: binary(), port(), Snex.Interpreter.server()) :: t()
  def make(id, port, interpreter) do
    env = %__MODULE__{id: id, ref: nil, port: port, interpreter: interpreter}
    %__MODULE__{env | ref: EnvReferenceNif.make_ref(env)}
  end

  @doc false
  # This weird function makes sure the envs are not garbage collected before we're done using them.
  # to the interpreter. BEAM turns out to be very aggressive about garbage collection in that
  # it can drop our Snex.Env.EnvReferenceNif resource as soon as it's no longer used, not waiting
  # until the end of the function.
  @spec touch(envs :: list(t())) :: :ok
  def touch(envs) when is_list(envs),
    do: :ok
end

defmodule Snex.Internal.EnvReferenceNif do
  @moduledoc false
  @on_load :load_nif
  @nifs [make_ref: 1]

  defp load_nif do
    :code.priv_dir(:snex)
    |> :filename.join(~c"env_reference_nif")
    |> :erlang.load_nif(0)
  end

  @doc """
  Creates a NIF reference that will send a `<<id::binary, "gc">> message to the
  port when garbage collected.
  """
  @spec make_ref(Snex.Env.t()) :: :erlang.nif_resource()
  def make_ref(_env), do: :erlang.nif_error(:not_loaded)
end
