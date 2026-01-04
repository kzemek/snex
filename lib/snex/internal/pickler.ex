defmodule Snex.Internal.Pickler do
  @moduledoc false

  import Bitwise
  import Record, only: [defrecord: 3, is_record: 2]

  alias __MODULE__.{Object, Binary}
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
  @term_class "snex.models\nTerm\n"

  @float_map %{
    inf: <<@binfloat::binary, 127, 240, 0, 0, 0, 0, 0, 0>>,
    "-inf": <<@binfloat::binary, 255, 240, 0, 0, 0, 0, 0, 0>>,
    nan: <<@binfloat::binary, 127, 248, 0, 0, 0, 0, 0, 0>>
  }

  defrecord :object, Object, [:module, :classname, :args]
  @type record_object :: record(:object, module: String.t(), classname: String.t(), args: list())

  defrecord :binary, Binary, [:value]
  @type record_binary :: record(:binary, value: iodata())

  defrecord :float, Float, [:value]
  @type record_float :: record(:float, value: float() | :inf | :"-inf" | :nan)

  @spec encode_to_iodata!(term()) :: iodata()
  def encode_to_iodata!(term),
    do: [@start, @protocol_version, do_encode(term), @stop]

  defp do_encode(n) when is_nil(n), do: encode_nil()
  defp do_encode(b) when is_boolean(b), do: encode_boolean(b)
  defp do_encode(a) when is_atom(a), do: encode_atom(a)
  defp do_encode(i) when is_integer(i), do: encode_integer(i)
  defp do_encode(f) when is_float(f), do: encode_float(f)
  defp do_encode(s) when is_binary(s), do: encode_string(s)
  defp do_encode(b) when is_record(b, Binary), do: encode_bytes(b)
  defp do_encode(o) when is_record(o, Object), do: encode_object(o)
  defp do_encode(f) when is_record(f, Float), do: encode_float(f)
  defp do_encode(s) when is_struct(s, MapSet), do: encode_set(s)
  defp do_encode(m) when is_struct(m), do: encode_struct(m)
  defp do_encode(m) when is_map(m), do: encode_map(m)
  defp do_encode(l) when is_list(l), do: encode_list(l)
  defp do_encode(t) when is_tuple(t), do: encode_tuple(t)
  defp do_encode(other), do: encode_term(other)

  defp encode_nil,
    do: @none

  defp encode_boolean(b),
    do: if(b, do: @newtrue, else: @newfalse)

  defp encode_atom(a) do
    encoded = a |> Atom.to_string() |> encode_string()
    [@global, @atom_class, encoded, @tuple1, @reduce]
  end

  defp encode_integer(i) when i in 0..0xFF,
    do: [@binint1, <<i>>]

  defp encode_integer(i) when i in 0..0xFFFF,
    do: [@binint2, <<i::little-unsigned-16>>]

  defp encode_integer(i) when i in -0x80000000..0x7FFFFFFF,
    do: [@binint, <<i::little-signed-32>>]

  defp encode_integer(i) do
    bytes = signed_to_binary(i)

    case byte_size(bytes) do
      size when size <= 0xFF -> [@long1, <<size>>, bytes]
      size when size <= 0xFFFF_FFFF -> [@long4, <<size::little-unsigned-32>>, bytes]
      size -> raise ArgumentError, "integer too large: #{size} bytes"
    end
  end

  defp encode_float(float(value: value)) when is_atom(value),
    do: Map.fetch!(@float_map, value)

  defp encode_float(float(value: value)),
    do: encode_float(value)

  defp encode_float(f),
    do: [@binfloat, <<f::64-float>>]

  defp encode_bytes(binary(value: b)),
    do: encode_bytes(b)

  defp encode_bytes(b) do
    case IO.iodata_length(b) do
      size when size <= 0xFF -> [@short_binbytes, size, b]
      size when size <= 0xFFFFFFFF -> [@binbytes, <<size::little-unsigned-32>>, b]
      size when size <= 0xFFFFFFFF_FFFFFFFF -> [@binbytes8, <<size::little-unsigned-64>>, b]
      size -> raise ArgumentError, "binary too large: #{size} bytes"
    end
  end

  defp encode_string(s) do
    case byte_size(s) do
      size when size <= 0xFF -> [@short_binunicode, size, s]
      size when size <= 0xFFFFFFFF -> [@binunicode, <<size::little-unsigned-32>>, s]
      size when size <= 0xFFFFFFFF_FFFFFFFF -> [@binunicode8, <<size::little-unsigned-64>>, s]
      size -> raise ArgumentError, "string too large: #{size} bytes"
    end
  end

  defp encode_object(object(module: module, classname: classname, args: args)),
    do: [@global, "#{module}\n#{classname}\n", encode_tuple(args), @reduce]

  defp encode_list(l),
    do: [@mark, Enum.map(l, &do_encode/1), @list]

  defp encode_tuple(t) do
    elems =
      if is_list(t),
        do: Enum.map(t, &do_encode/1),
        else: Enum.map(0..(tuple_size(t) - 1)//1, &do_encode(elem(t, &1)))

    case elems do
      [] -> @empty_tuple
      [elem] -> [elem, @tuple1]
      [elem1, elem2] -> [elem1, elem2, @tuple2]
      [elem1, elem2, elem3] -> [elem1, elem2, elem3, @tuple3]
      elems -> [@mark, elems, @tuple]
    end
  end

  defp encode_set(s),
    do: [@empty_set, @mark, Enum.map(s, &do_encode/1), @additems]

  defp encode_struct(%struct{} = s) do
    case Serde.Encoder.impl_for(s) do
      nil ->
        encode_map(s)

      encoder ->
        case encoder.encode(s) do
          %^struct{} = same_struct_type -> encode_map(same_struct_type)
          encoded -> do_encode(encoded)
        end
    end
  end

  defp encode_map(map) do
    {map, struct_keys} =
      case map do
        %struct{} -> {Map.from_struct(map), [encode_atom(:__struct__), encode_atom(struct)]}
        _ -> {map, []}
      end

    [
      @empty_dict,
      @mark,
      struct_keys,
      Enum.map(map, fn {k, v} -> [do_encode(k), do_encode(v)] end),
      @setitems
    ]
  end

  defp encode_term(term),
    do: [[@global, @term_class], encode_bytes(:erlang.term_to_binary(term)), @tuple1, @reduce]

  defp signed_to_binary(i) do
    bytes_num =
      case :binary.encode_unsigned((i < 0 && bnot(i)) || i) do
        <<>> -> 1
        # If the MSB has the highest bit set, we need one more byte to represent the sign
        <<1::1, _::bitstring>> = magnitude -> byte_size(magnitude) + 1
        magnitude -> byte_size(magnitude)
      end

    <<i::little-signed-unit(8)-size(bytes_num)>>
  end
end
