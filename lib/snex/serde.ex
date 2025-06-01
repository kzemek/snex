defmodule Snex.Serde.Binary do
  @moduledoc false
  @enforce_keys [:value]
  defstruct [:value]
  @typedoc false
  @type t :: %__MODULE__{value: iodata()}
end

defmodule Snex.Serde.Term do
  @moduledoc false
  @enforce_keys [:value]
  defstruct [:value]
  @typedoc false
  @type t :: %__MODULE__{value: term()}
end

defprotocol Snex.Serde.Encoder do
  @moduledoc """
  Protocol for custom encoding of Elixir terms to JSON used by Snex Serde.

  If no implementation is defined, encoding falls back to `JSON` encoding
  (`JSON.Encoder` and its defaults).

  See the `m:Snex#module-serialization` module documentation for more detail.
  """

  @fallback_to_any true

  @type encoder :: (term(), encoder() -> iodata())

  @doc """
  A function invoked to encode the given term to `t:iodata/0`.
  """
  @spec encode(term, encoder()) :: iodata
  def encode(term, encoder)
end

defimpl Snex.Serde.Encoder, for: Snex.Serde.Binary do
  def encode(%Snex.Serde.Binary{value: value}, encoder),
    do: Snex.Serde.binary_encode("binary", value, encoder)
end

defimpl Snex.Serde.Encoder, for: Snex.Serde.Term do
  def encode(%Snex.Serde.Term{value: value}, encoder),
    do: Snex.Serde.binary_encode("term", :erlang.term_to_binary(value), encoder)
end

defimpl Snex.Serde.Encoder, for: Snex.Env do
  def encode(%Snex.Env{id: id}, encoder),
    do: Snex.Serde.binary_encode("env", id, encoder)
end

defimpl Snex.Serde.Encoder, for: Any do
  def encode(term, encoder),
    do: JSON.Encoder.encode(term, encoder)
end

defmodule Snex.Serde do
  @moduledoc """
  Serialization and deserialization between Elixir and Python.

  See the `m:Snex#module-serialization` module documentation for more detail.
  """

  alias __MODULE__

  @binary_acc_key {__MODULE__, :binary_acc}

  @typep encoder :: (term(), encoder() -> iodata())
  @opaque serde_binary :: Serde.Binary.t()
  @opaque serde_term :: Serde.Term.t()

  @doc false
  @spec encode_to_iodata!(term(), encoder()) :: iodata()
  def encode_to_iodata!(term, encoder \\ &protocol_encode/2) do
    Process.put(@binary_acc_key, [])
    data = encoder.(term, encoder)
    binary_acc = Process.get(@binary_acc_key) |> Enum.reverse()
    [<<IO.iodata_length(binary_acc)::32>>, binary_acc, data]
  after
    Process.delete(@binary_acc_key)
  end

  @doc false
  @spec decode(binary()) :: {:ok, term()} | {:error, :trailing_data | term()}
  def decode(binary) when is_binary(binary) do
    <<binary_len::32, binary_data::binary-size(binary_len), json::binary>> = binary
    Process.put(@binary_acc_key, binary_data)

    with {decoded, _acc, rest} <- JSON.decode(json, [], object_finish: &decode_object_finish/2),
         true <- String.trim(rest) == "" || {:error, :trailing_data},
         do: {:ok, decoded}
  after
    Process.delete(@binary_acc_key)
  end

  @doc """
  Wraps an iodata value for efficient out-of-band passing to Python.
  """
  @spec binary(iodata()) :: serde_binary()
  def binary(value) when is_binary(value) or is_list(value),
    do: %Serde.Binary{value: value}

  @doc """
  Wraps an arbitrary Erlang term for efficient out-of-band passing to Python.
  The value will be opaque on the Python side and decoded back to the original Erlang term when
  returned to Elixir.
  """
  @spec term(term()) :: serde_term()
  def term(value),
    do: %Serde.Term{value: value}

  @doc false
  @spec protocol_encode(term(), encoder()) :: iodata()
  def protocol_encode(struct, encoder) when is_struct(struct),
    do: struct |> Serde.Encoder.encode(encoder)

  def protocol_encode(tuple, encoder) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> encoder.(encoder)

  def protocol_encode(value, encoder),
    do: value |> JSON.protocol_encode(encoder)

  @doc false
  # Common implementation for encoding out-of-json binary data
  @spec binary_encode(binary(), iodata(), encoder()) :: iodata()
  def binary_encode(tag, data, encoder) when tag in ~w[binary term env] do
    binary_acc = Process.get(@binary_acc_key)
    len = IO.iodata_length(data)
    Process.put(@binary_acc_key, [data | binary_acc])
    encoder.(%{"__snex__" => [tag, len]}, encoder)
  end

  defp decode_object_finish(acc, old_acc) do
    case Map.new(acc) do
      %{"__snex__" => [tag, size]} ->
        <<data::binary-size(size), rest::binary>> = Process.get(@binary_acc_key)
        Process.put(@binary_acc_key, rest)
        value = if tag == "binary", do: data, else: :erlang.binary_to_term(data)
        {value, old_acc}

      obj ->
        {obj, old_acc}
    end
  end
end
