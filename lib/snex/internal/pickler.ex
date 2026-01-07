defmodule Snex.Internal.Pickler do
  @moduledoc false

  import Bitwise
  import Record

  alias __MODULE__.{Object, Binary, Float, Fragment}
  alias Snex.Serde

  @start <<0x80>>
  @protocol_version 5
  @stop <<0x2E>>

  @global "c"
  @mark "("
  @reduce "R"

  # bytes
  @short_binbytes "C"
  @binbytes "B"
  @binbytes8 <<0x8E>>
  @bytearray8 <<0x96>>

  # numbers
  @binfloat "G"
  @binint "J"
  @binint1 "K"
  @binint2 "M"
  @long1 <<0x8A>>
  @long4 <<0x8B>>

  # strings
  @short_binunicode <<0x8C>>
  @binunicode "X"
  @binunicode8 <<0x8D>>

  # data structs
  @additems <<0x90>>
  @empty_dict "}"
  @empty_set <<0x8F>>
  @list "l"
  @setitems "u"
  @frozenset <<0x91>>

  # booleans
  @newfalse <<0x89>>
  @newtrue <<0x88>>

  # None
  @none "N"

  # tuples
  @empty_tuple ")"
  @tuple1 <<0x85>>
  @tuple2 <<0x86>>
  @tuple3 <<0x87>>
  @tuple "t"

  @atom_class "snex.models\nAtom\n"
  @distinct_atom_class "snex.models\nDistinctAtom\n"
  @term_class "snex.models\nTerm\n"

  @float_inf_encoded <<@binfloat::binary, 127, 240, 0, 0, 0, 0, 0, 0>>
  @float_neginf_encoded <<@binfloat::binary, 255, 240, 0, 0, 0, 0, 0, 0>>
  @float_nan_encoded <<@binfloat::binary, 127, 248, 0, 0, 0, 0, 0, 0>>

  defrecord :object, Object, [:module, :classname, :args]
  @type record_object :: record(:object, module: String.t(), classname: String.t(), args: list())

  defrecord :binary, Binary, [:value, :as]
  @type record_binary :: record(:binary, value: iodata(), as: :str | :bytes | :bytearray)

  defrecord :float, Float, [:value]
  @type record_float :: record(:float, value: float() | :inf | :"-inf" | :nan)

  defrecordp :fragment, Fragment, [:iodata]
  @opaque record_fragment :: record(:fragment, iodata: iodata())

  defrecordp :encoding_opts, binary_as: :str, set_as: :set, atom_as: :atom

  defp make_encoding_opts(opts) do
    List.foldl(opts, encoding_opts(), fn
      {:binary_as, value}, acc when value in [:str, :bytes, :bytearray] ->
        encoding_opts(acc, binary_as: value)

      {:set_as, value}, acc when value in [:set, :frozenset] ->
        encoding_opts(acc, set_as: value)

      {:atom_as, value}, acc when value in [:atom, :distinct_atom] ->
        encoding_opts(acc, atom_as: value)

      {key, value}, _acc ->
        raise ArgumentError,
              "invalid encoding option key/value pair: `#{inspect(key)}: #{inspect(value)}`"
    end)
  end

  @spec encode_to_iodata!(term(), Serde.encoding_opts()) :: iodata()
  def encode_to_iodata!(term, opts \\ []),
    do: [@start, @protocol_version, do_encode(term, make_encoding_opts(opts)), @stop]

  @spec encode_fragment!(term(), Serde.encoding_opts()) :: record_fragment()
  def encode_fragment!(term, opts \\ []),
    do: fragment(iodata: do_encode(term, make_encoding_opts(opts)))

  defp do_encode(n, _opts) when is_nil(n), do: encode_nil()
  defp do_encode(b, _opts) when is_boolean(b), do: encode_boolean(b)
  defp do_encode(a, opts) when is_atom(a), do: encode_atom(a, opts)
  defp do_encode(i, _opts) when is_integer(i), do: encode_integer(i)
  defp do_encode(f, _opts) when is_float(f), do: encode_float(f)
  defp do_encode(s, opts) when is_binary(s), do: encode_binary(s, opts)
  defp do_encode(b, opts) when is_record(b, Binary), do: encode_binary(b, opts)
  defp do_encode(o, opts) when is_record(o, Object), do: encode_object(o, opts)
  defp do_encode(f, _opts) when is_record(f, Float), do: encode_float(f)
  defp do_encode(f, _opts) when is_record(f, Fragment), do: fragment(f, :iodata)
  defp do_encode(s, opts) when is_struct(s, MapSet), do: encode_set(s, opts)
  defp do_encode(m, opts) when is_struct(m), do: encode_struct(m, opts)
  defp do_encode(m, opts) when is_map(m), do: encode_map(m, opts)
  defp do_encode(l, opts) when is_list(l), do: encode_list(l, opts)
  defp do_encode(t, opts) when is_tuple(t), do: encode_tuple(t, opts)
  defp do_encode(other, _opts), do: encode_term(other)

  defp encode_nil,
    do: @none

  defp encode_boolean(b),
    do: if(b, do: @newtrue, else: @newfalse)

  defp encode_atom(a, opts) do
    encoded = a |> Atom.to_string() |> encode_string()

    case encoding_opts(opts, :atom_as) do
      :atom -> [@global, @atom_class, encoded, @tuple1, @reduce]
      :distinct_atom -> [@global, @distinct_atom_class, encoded, @tuple1, @reduce]
    end
  end

  defp encode_integer(i) when i in 0..0xFF,
    do: [@binint1, i]

  defp encode_integer(i) when i in 0..0xFFFF,
    do: [@binint2, <<i::little-unsigned-16>>]

  defp encode_integer(i) when i in -0x80000000..0x7FFFFFFF,
    do: [@binint, <<i::little-signed-32>>]

  defp encode_integer(i) do
    {bytes, byte_size} = signed_to_binary(i)

    cond do
      byte_size <= 0xFF -> [@long1, byte_size, bytes]
      byte_size <= 0xFFFF_FFFF -> [@long4, <<byte_size::little-unsigned-32>>, bytes]
      true -> raise ArgumentError, "integer too large: #{byte_size} bytes"
    end
  end

  defp encode_float(float(value: value)) do
    case value do
      :inf -> @float_inf_encoded
      :"-inf" -> @float_neginf_encoded
      :nan -> @float_nan_encoded
      f -> encode_float(f)
    end
  end

  defp encode_float(f),
    do: [@binfloat, <<f::64-float>>]

  defp encode_binary(binary(value: b, as: as), opts),
    do: encode_binary(b, encoding_opts(opts, binary_as: as))

  defp encode_binary(b, opts) do
    case encoding_opts(opts, :binary_as) do
      :str -> encode_string(b)
      :bytes -> encode_bytes(b)
      :bytearray -> encode_bytearray(b)
    end
  end

  defp encode_bytes(b) do
    case iodata_size(b) do
      size when size <= 0xFF -> [@short_binbytes, size, b]
      size when size <= 0xFFFFFFFF -> [@binbytes, <<size::little-unsigned-32>>, b]
      size when size <= 0xFFFFFFFF_FFFFFFFF -> [@binbytes8, <<size::little-unsigned-64>>, b]
      size -> raise ArgumentError, "binary too large: #{size} bytes"
    end
  end

  defp encode_bytearray(b) do
    case iodata_size(b) do
      size when size <= 0xFFFFFFFF_FFFFFFFF -> [@bytearray8, <<size::little-unsigned-64>>, b]
      size -> raise ArgumentError, "binary too large: #{size} bytes"
    end
  end

  defp encode_string(s) do
    case iodata_size(s) do
      size when size <= 0xFF -> [@short_binunicode, size, s]
      size when size <= 0xFFFFFFFF -> [@binunicode, <<size::little-unsigned-32>>, s]
      size when size <= 0xFFFFFFFF_FFFFFFFF -> [@binunicode8, <<size::little-unsigned-64>>, s]
      size -> raise ArgumentError, "string too large: #{size} bytes"
    end
  end

  defp encode_object(object(module: module, classname: classname, args: args), opts),
    do: [@global, module, "\n", classname, "\n", encode_tuple(args, opts), @reduce]

  defp encode_list(l, opts),
    do: [@mark, encode_list_elems(l, opts), @list]

  defp encode_tuple(t, opts) do
    elems =
      if is_list(t),
        do: encode_list_elems(t, opts),
        else: encode_tuple_elems(t, opts)

    case elems do
      [] -> @empty_tuple
      [elem] -> [elem, @tuple1]
      [elem1, elem2] -> [elem1, elem2, @tuple2]
      [elem1, elem2, elem3] -> [elem1, elem2, elem3, @tuple3]
      elems -> [@mark, elems, @tuple]
    end
  end

  defp encode_set(s, opts) do
    case encoding_opts(opts, :set_as) do
      :set -> [@empty_set, @mark, encode_set_elems(s, opts), @additems]
      :frozenset -> [@mark, encode_set_elems(s, opts), @frozenset]
    end
  end

  # Dialyzer complains on %^struct{} match
  @dialyzer {:no_opaque, encode_struct: 2}
  @dialyzer {:no_match, encode_struct: 2}
  defp encode_struct(%struct{} = s, opts) do
    case Serde.Encoder.impl_for(s) do
      nil ->
        encode_map(s, opts)

      encoder ->
        case encoder.encode(s) do
          %^struct{} = same_struct_type -> encode_map(same_struct_type, opts)
          encoded -> do_encode(encoded, opts)
        end
    end
  end

  defp encode_map(map, opts),
    do: [@empty_dict, @mark, encode_map_elems(map, opts), @setitems]

  defp encode_term(term),
    do: [@global, @term_class, encode_bytes(:erlang.term_to_binary(term)), @tuple1, @reduce]

  defp signed_to_binary(i) when i >= 0 do
    bytes = :binary.encode_unsigned(i, :little)

    if :binary.last(bytes) > 127,
      # If the MSB has the highest bit set, we need one more byte to represent the sign
      do: {[bytes, 0], byte_size(bytes) + 1},
      else: {bytes, byte_size(bytes)}
  end

  defp signed_to_binary(i) when i < 0 do
    bytes_num =
      case i |> bnot() |> :binary.encode_unsigned() do
        # If the MSB has the highest bit set, we need one more byte to represent the sign
        <<1::1, _::bitstring>> = magnitude -> byte_size(magnitude) + 1
        magnitude -> byte_size(magnitude)
      end

    {<<i::little-signed-unit(8)-size(bytes_num)>>, bytes_num}
  end

  defp encode_list_elems(list, opts),
    do: list |> do_encode_list_elems(opts, []) |> Enum.reverse()

  defp encode_tuple_elems(tuple, opts),
    do: tuple |> Tuple.to_list() |> do_encode_list_elems(opts, []) |> Enum.reverse()

  defp encode_set_elems(set, opts),
    do: set |> MapSet.to_list() |> do_encode_list_elems(opts, [])

  defp encode_map_elems(map, opts),
    do: map |> Map.to_list() |> do_encode_map_elems(opts, [])

  defp do_encode_list_elems([], _opts, acc),
    do: acc

  defp do_encode_list_elems([elem | rest], opts, acc),
    do: do_encode_list_elems(rest, opts, [do_encode(elem, opts) | acc])

  defp do_encode_map_elems([], _opts, acc),
    do: acc

  defp do_encode_map_elems([{k, v} | rest], opts, acc),
    do: do_encode_map_elems(rest, opts, [do_encode(k, opts), do_encode(v, opts) | acc])

  defp iodata_size(b),
    do: if(is_binary(b), do: byte_size(b), else: IO.iodata_length(b))
end
