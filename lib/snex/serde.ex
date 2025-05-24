defmodule Snex.Serde.Binary do
  @enforce_keys [:value]
  defstruct [:value]
  @type t :: %__MODULE__{value: binary()}
end

defmodule Snex.Serde.Term do
  @enforce_keys [:value]
  defstruct [:value]
  @type t :: %__MODULE__{value: term()}
end

defprotocol Snex.Serde.Encoder do
  @fallback_to_any true

  @spec encode(term, Snex.Serde.encoder()) :: iodata
  def encode(term, encoder)
end

defimpl Snex.Serde.Encoder, for: Snex.Serde.Binary do
  def encode(%Snex.Serde.Binary{value: value}, encoder),
    do: Snex.Serde.binary_encode("binary", value, encoder)
end

defimpl Snex.Serde.Encoder, for: Snex.Serde.Term do
  def encode(%Snex.Serde.Term{value: value}, encoder),
    do: Snex.Serde.binary_encode("term", value, encoder)
end

defimpl Snex.Serde.Encoder, for: Any do
  def encode(term, encoder),
    do: JSON.Encoder.encode(term, encoder)
end

defmodule Snex.Serde do
  @moduledoc false

  @binary_acc_key {__MODULE__, :binary_acc}

  @type encoder :: (term(), encoder() -> iodata())

  @spec encode_to_iodata!(term(), encoder()) :: iodata()
  def encode_to_iodata!(term, encoder \\ &protocol_encode/2) do
    Process.put(@binary_acc_key, {[], 0})
    data = encoder.(term, encoder)
    {binary_acc, binary_len} = Process.get(@binary_acc_key)
    [<<binary_len::32>>, Enum.reverse(binary_acc), data]
  after
    Process.delete(@binary_acc_key)
  end

  def decode(binary) when is_binary(binary) do
    <<binary_len::32, binary_data::binary-size(binary_len), json::binary>> = binary
    decoders = [object_finish: &decode_object_finish(&1, &2, binary_data)]

    with {decoded, _acc, rest} <- JSON.decode(json, [], decoders),
         true <- String.trim(rest) == "" || {:error, :trailing_data},
         do: {:ok, decoded}
  end

  def binary(value) when is_binary(value), do: %Snex.Serde.Binary{value: value}
  def term(value), do: %Snex.Serde.Term{value: value}

  @spec protocol_encode(term(), encoder()) :: iodata()
  def protocol_encode(struct, encoder) when is_struct(struct),
    do: Snex.Serde.Encoder.encode(struct, encoder)

  def protocol_encode(tuple, encoder) when is_tuple(tuple),
    do: encoder.(Tuple.to_list(tuple), encoder)

  def protocol_encode(value, encoder),
    do: JSON.protocol_encode(value, encoder)

  @doc false
  # Common implementation for encoding out-of-json binary data
  @spec binary_encode(binary(), term(), encoder()) :: iodata()
  def binary_encode(tag, value, encoder) when tag in ~w[binary term] do
    case Process.get(@binary_acc_key) do
      {binary_acc, binary_offset} ->
        data = if tag == "binary", do: value, else: :erlang.term_to_binary(value)
        Process.put(@binary_acc_key, {[data | binary_acc], binary_offset + byte_size(data)})
        encoder.(%{"__snex__" => [tag, binary_offset, byte_size(data)]}, encoder)

      _ ->
        encoder.(value, encoder)
    end
  end

  defp decode_object_finish(acc, old_acc, binary_data) do
    case Map.new(acc) do
      %{"__snex__" => [tag, offset, size]} ->
        data = binary_part(binary_data, offset, size)
        value = if tag == "binary", do: data, else: :erlang.binary_to_term(data)
        {value, old_acc}

      obj ->
        {obj, old_acc}
    end
  end
end
