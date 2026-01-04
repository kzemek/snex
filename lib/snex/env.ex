defmodule Snex.Env do
  @moduledoc """
  An environment (`%Snex.Env{}`) is a Elixir-side reference to Python-side variable context in which
  the Python code is executed.

  This module is not intended to be used directly.
  Instead, you would use the `Snex.make_env/3` to create environments, `Snex.pyeval/4`
  to use them.

  The only exceptions are `Snex.Env.disable_gc/1`, which can be called to opt into manual management
  of the environment lifecycle, and `Snex.Env.interpreter/1`, which can be used to get
  the interpreter the environment is bound to.

  See `m:Snex#module-environments` module documentation for more details.
  """
  alias Snex.Internal.EnvReferenceNif

  @opaque id :: binary()

  @typedoc """
  Elixir-side reference to a Python-side environment.

  The `id` field can be used to identify the environment, but its underlying type can change without
  notice. All other fields should be considered an implementation detail and never used directly.
  """
  @type t :: %__MODULE__{
          id: id(),
          ref: :erlang.nif_resource() | nil,
          port: port(),
          interpreter: Snex.Interpreter.server(),
          encoding_opts: Snex.Serde.encoding_opts()
        }

  @derive {Inspect, only: [:id]}
  @enforce_keys [:id, :ref, :port, :interpreter, :encoding_opts]
  defstruct [:id, :ref, :port, :interpreter, :encoding_opts]

  @doc false
  @spec make(id :: binary(), port(), Snex.Interpreter.server(), Snex.Serde.encoding_opts()) :: t()
  def make(id, port, interpreter, encoding_opts) do
    env = %__MODULE__{
      id: id,
      ref: nil,
      port: port,
      interpreter: interpreter,
      encoding_opts: encoding_opts
    }

    %__MODULE__{env | ref: EnvReferenceNif.make_ref(env)}
  end

  @doc """
  Returns the interpreter that the given environment belongs to.
  """
  @spec interpreter(t()) :: Snex.Interpreter.server()
  def interpreter(%__MODULE__{interpreter: interpreter}),
    do: interpreter

  @doc """
  Disables automatic garbage collection for the given environment.

  This function can only be called on the node that created the environment.
  It can be called multiple times on the same environment.

  Once garbage collection is disabled, the environment can only be cleaned up by calling
  `Snex.destroy_env/1`, or by stopping the interpreter altogether.
  """
  @spec disable_gc(t()) :: t()
  def disable_gc(%__MODULE__{ref: nil} = env),
    do: env

  def disable_gc(%__MODULE__{} = env) do
    if node(env.ref) != node(),
      do: raise(ArgumentError, "Cannot disable garbage collection for a remote environment")

    %__MODULE__{env | ref: EnvReferenceNif.disable_gc(env.ref)}
  end

  @doc false
  # This weird function makes sure the envs are not garbage collected before we're done using them.
  # BEAM turns out to be very aggressive about garbage collection in that
  # it can drop our Snex.Env.EnvReferenceNif resource as soon as it's no longer used, not waiting
  # until the end of the function.
  @spec touch([t()]) :: :ok
  def touch(envs) when is_list(envs),
    do: :ok
end

defmodule Snex.Internal.EnvReferenceNif do
  @moduledoc false
  @on_load :load_nif
  @nifs [make_ref: 1, disable_gc: 1]

  defp load_nif do
    :code.priv_dir(:snex)
    |> :filename.join(~c"env_reference_nif")
    |> :erlang.load_nif(0)
  end

  @doc """
  Creates a NIF reference that will send the env to `Snex.Internal.GarbageCollector` when destroyed.
  """
  @spec make_ref(Snex.Env.t()) :: :erlang.nif_resource()
  def make_ref(_env), do: :erlang.nif_error(:not_loaded)

  @doc """
  Disables automatic garbage collection for the given reference.
  """
  @spec disable_gc(:erlang.nif_resource()) :: nil
  def disable_gc(_reference), do: :erlang.nif_error(:not_loaded)
end
