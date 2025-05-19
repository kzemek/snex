defmodule Snex.Env do
  alias Snex.Internal.EnvReferenceNif

  @opaque t :: %__MODULE__{
            id: binary(),
            ref: :erlang.nif_resource(),
            interpreter: Snex.Interpreter.server()
          }

  @enforce_keys [:id, :ref, :interpreter]
  defstruct [:id, :ref, :interpreter]

  @doc false
  @spec make(
          id :: binary(),
          port :: :erlang.port(),
          interpreter :: Snex.Interpreter.server()
        ) :: t()
  def make(id, port, interpreter) do
    %__MODULE__{
      id: id,
      ref: EnvReferenceNif.make_ref(id, port),
      interpreter: interpreter
    }
  end
end

defmodule Snex.Internal.EnvReferenceNif do
  @moduledoc false
  @on_load :load_nif
  @nifs [make_ref: 2]

  defp load_nif do
    :code.priv_dir(:snex)
    |> :filename.join(~c"env_reference_nif")
    |> :erlang.load_nif(0)
  end

  @doc """
  Creates a NIF reference that will send a `<<id::binary, "gc">> message to the
  port when garbage collected.
  """
  @spec make_ref(id :: binary(), port()) :: :erlang.nif_resource()
  def make_ref(_id, _port), do: :erlang.nif_error(:not_loaded)
end
