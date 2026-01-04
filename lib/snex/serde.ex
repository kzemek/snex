defmodule Snex.Serde do
  @moduledoc """
  Serialization and deserialization between Elixir and Python.

  See the `m:Snex#module-serialization` module documentation for more detail.
  """

  alias Snex.Internal.Pickler

  require Pickler

  @opaque serde_binary :: Pickler.record_binary()
  @opaque serde_term :: Pickler.record_object()
  @opaque serde_object :: Pickler.record_object()
  @opaque serde_float :: Pickler.record_float()

  @type encoding_opts :: []

  @doc false
  defdelegate encode_to_iodata!(term, opts \\ []), to: Pickler

  @doc false
  defdelegate encode_fragment!(term, opts \\ []), to: Pickler

  @doc false
  @spec decode(binary()) :: {:ok, term()} | {:error, term()}
  def decode(binary) do
    {:ok, :erlang.binary_to_term(binary)}
  rescue
    error -> {:error, error}
  end

  @doc """
  Wraps an iodata value to decode as `bytes` on the Python side.
  """
  @spec binary(iodata()) :: serde_binary()
  def binary(value) when is_binary(value) or is_list(value),
    do: Pickler.binary(value: value)

  @doc """
  Wraps an arbitrary Erlang term for efficient passing to Python.
  The value will be opaque on the Python side and decoded back to the original Erlang term when
  returned to Elixir.
  """
  @spec term(term()) :: serde_term()
  def term(value),
    do: object("snex.models", "Term", [binary(:erlang.term_to_binary(value))])

  @doc ~s'''
  Builds a Python object from a module, class name, and arguments.
  Arguments are encoded and passed to the Python object constructor.

  ## Example

      {:ok, "date"} =
        Snex.pyeval(env, %{"d" => Snex.Serde.object("datetime", "date", [2025, 12, 28])},
          returning: "type(d).__name__")
  '''
  @spec object(String.t(), String.t(), list()) :: serde_object()
  def object(module, classname, args)
      when is_binary(module) and is_binary(classname) and is_list(args),
      do: Pickler.object(module: module, classname: classname, args: args)

  @doc """
  Wraps a float value for decoding in Python.

  Since Erlang floats can't represent infinity, -infinity or NaN, this function can be used to wrap
  atoms `:inf`, `:"-inf"` or `:nan` to decode as the corresponding Python float.
  """
  @spec float(:"-inf" | :inf | :nan | float()) :: serde_float()
  def float(value) when is_float(value) or value in [:inf, :"-inf", :nan],
    do: Pickler.float(value: value)
end

defprotocol Snex.Serde.Encoder do
  @moduledoc """
  Protocol for custom encoding of Elixir terms to a desired representation on the Python side
  used by `Snex.Serde`.

  If no implementation is defined, structs will be encoded "as-is".

  See the `m:Snex#module-serialization` module documentation for more detail.
  """

  @doc """
  A function invoked to encode the given term to a desired representation on the Python side.

  The return value will be subject to recursive encoding. For example, if `encode/1` returns another
  struct that implements `Snex.Serde.Encoder`, `encode/1` will be called again on the result.

  If the return value is the same struct type (e.g. `encode(%X{}) -> %X{}`), it will be encoded like
  a generic struct (i.e. as a `dict` with `__struct__` key).
  """
  @spec encode(term()) :: term()
  def encode(term)
end
