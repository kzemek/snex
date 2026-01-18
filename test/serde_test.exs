defmodule Snex.SerdeTest do
  use ExUnit.Case, async: true

  import Bitwise
  import Snex.Sigils

  setup_all do
    interpreter = start_link_supervised!({Snex.Interpreter, init_script: "import math, datetime"})
    %{interpreter: interpreter}
  end

  setup ctx do
    {:ok, env} = Snex.make_env(ctx.interpreter)
    %{env: env}
  end

  describe "Elixir nil" do
    test "is encoded as None", %{env: env} do
      assert {:ok, true} = Snex.pyeval(env, "return n is None", %{"n" => nil})
    end
  end

  describe "Python None" do
    test "is decoded as nil", %{env: env} do
      assert {:ok, nil} = Snex.pyeval(env, "return None")
    end
  end

  describe "Elixir boolean" do
    test "true is encoded as True", %{env: env} do
      assert {:ok, true} = Snex.pyeval(env, "return b is True", %{"b" => true})
    end

    test "false is encoded as False", %{env: env} do
      assert {:ok, true} = Snex.pyeval(env, "return b is False", %{"b" => false})
    end
  end

  describe "Python boolean" do
    test "True is decoded as true", %{env: env} do
      assert {:ok, true} = Snex.pyeval(env, "return True")
    end

    test "False is decoded as false", %{env: env} do
      assert {:ok, false} = Snex.pyeval(env, "return False")
    end
  end

  describe "Elixir atom" do
    test "is encoded as snex.Atom", %{env: env} do
      assert {:ok, true} =
               Snex.pyeval(env, "return type(a) is snex.Atom and a == 'hello'", %{"a" => :hello})
    end

    test "when empty", %{env: env} do
      assert {:ok, true} =
               Snex.pyeval(env, "return type(a) is snex.Atom and a == ''", %{"a" => :""})
    end

    test "with unicode characters", %{env: env} do
      atom = :"zażółć gęślą jaźń!"

      assert {:ok, true} =
               Snex.pyeval(
                 env,
                 "return type(a) is snex.Atom and a == 'zażółć gęślą jaźń!'",
                 %{"a" => atom}
               )
    end

    test "conflicts with string map keys", %{env: env} do
      assert {:ok, true} =
               Snex.pyeval(
                 env,
                 "return len(x) == 1 and (x['a'] == 'hello' or x['a'] == 'world')",
                 %{"x" => %{"a" => "hello", a: :world}}
               )
    end

    test "does not conflict with string map keys when `:distinct_atom` is used", %{env: env} do
      assert {:ok, true} =
               Snex.pyeval(
                 env,
                 """
                 return \
                   len(x) == 2 \
                   and x['a'] == 'hello' \
                   and x[snex.DistinctAtom('a')] == snex.DistinctAtom('world')\
                 """,
                 %{"x" => %{"a" => "hello", a: :world}},
                 encoding_opts: [atom_as: :distinct_atom]
               )
    end

    test "can be more than 255 bytes long", %{env: env} do
      atom_str = String.duplicate("ź", 255)
      assert byte_size(atom_str) > 255

      assert {:ok, true} =
               Snex.pyeval(
                 env,
                 "return type(a) is snex.Atom and len(a) == 255",
                 %{"a" => String.to_atom(atom_str)}
               )
    end

    test "is encoded according to `encoding_opts`" do
      atom = :hello

      interpreter =
        start_link_supervised!({Snex.Interpreter, encoding_opts: [atom_as: :distinct_atom]})

      {:ok, env} = Snex.make_env(interpreter, %{"var_default" => atom})

      env =
        Enum.reduce([:atom, :distinct_atom], env, fn type, env ->
          {:ok, env} =
            Snex.make_env(%{"var_#{type}" => atom}, from: env, encoding_opts: [atom_as: type])

          env
        end)

      # interpreter default
      assert {:ok, true} =
               Snex.pyeval(
                 env,
                 """
                 return \
                 type(a) is snex.DistinctAtom \
                 and a == snex.DistinctAtom('hello') \
                 and a != 'hello'\
                 """,
                 %{"a" => atom}
               )

      assert {:ok, true} =
               Snex.pyeval(
                 env,
                 """
                 return \
                 type(var_default) is snex.DistinctAtom \
                 and var_default == snex.DistinctAtom('hello') \
                 and var_default != 'hello'\
                 """
               )

      for {as, {type, expected}} <- [
            atom: {"snex.Atom", "'hello'"},
            distinct_atom: {"snex.DistinctAtom", "snex.DistinctAtom('hello')"}
          ] do
        assert {:ok, true} =
                 Snex.pyeval(
                   env,
                   "return type(a) is #{type} and a == #{expected}",
                   %{"a" => atom},
                   encoding_opts: [atom_as: as]
                 )

        assert {:ok, true} =
                 Snex.pyeval(
                   env,
                   "return type(var_#{as}) is #{type} and var_#{as} == #{expected}",
                   encoding_opts: [atom_as: as]
                 )
      end
    end
  end

  describe "Python snex.Atom" do
    test "is decoded as atom", %{env: env} do
      assert {:ok, :hello} = Snex.pyeval(env, "return snex.Atom('hello')")
    end

    test "when empty", %{env: env} do
      assert {:ok, :""} = Snex.pyeval(env, "return snex.Atom('')")
    end

    test "can be 255 characters long", %{env: env} do
      expected = String.duplicate("a", 255) |> String.to_atom()
      assert {:ok, ^expected} = Snex.pyeval(env, "return snex.Atom('a' * 255)")
    end

    test "cannot be longer than 255 characters", %{env: env} do
      assert {:error, %Snex.Error{code: :python_runtime_error, reason: "atom too long: " <> _}} =
               Snex.pyeval(env, "return snex.Atom('a' * 256)")
    end

    test "is counted by character length", %{env: env} do
      # 'ą' is 2 bytes in UTF-8, but the limit is 255 characters, not bytes
      expected_string = String.duplicate("ą", 255)
      expected_atom = String.to_atom(expected_string)

      assert byte_size(expected_string) > 255
      assert {:ok, ^expected_atom} = Snex.pyeval(env, "return snex.Atom('ą' * 255)")

      assert {:error, %Snex.Error{code: :python_runtime_error, reason: "atom too long: " <> _}} =
               Snex.pyeval(env, "return snex.Atom('ą' * 256)")
    end
  end

  describe "Elixir integer" do
    test "is encoded as Python int", %{env: env} do
      for int <- [
            # 0..0xFF -> BININT1
            0,
            0xFF,
            # 0..0xFFFF -> BININT2
            0xFF + 1,
            0xFFFF,
            0xFFFF + 1,
            # -0x80000000..0x7FFFFFFF -> BININT
            -0x80000000 - 1,
            -0x80000000,
            0x7FFFFFFF,
            0x7FFFFFFF + 1,
            # byte_size(int) <= 0xFF -> LONG1
            1 <<< (8 * (0xFF - 1)),
            -(1 <<< (8 * (0xFF - 1))),
            # byte_size(int) <= 0xFFFF -> LONG4
            (1 <<< (8 * 0xFF)) - 1,
            -((1 <<< (8 * 0xFF)) - 1),
            1 <<< (8 * 0xFF + 1),
            -(1 <<< (8 * 0xFF + 1))
          ] do
        assert {:ok, true} =
                 Snex.pyeval(env, "return type(i) is int and i == #{int}", %{"i" => int})
      end
    end
  end

  describe "Python int" do
    test "is decoded as Elixir integer", %{env: env} do
      for int <- [
            # 0..0xFF -> SMALL_INT_EXT
            0,
            0xFF,
            0xFF + 1,
            # -0x800000000..0x7FFFFFFF -> INTEGER_EXT
            -0x800000000 - 1,
            -0x800000000,
            0x7FFFFFFF,
            0x7FFFFFFF + 1,
            # Anything higher: LARGE_BIG_EXT
            1 <<< (8 * 0xFF),
            -(1 <<< (8 * 0xFF))
          ] do
        assert {:ok, ^int} = Snex.pyeval(env, "return #{int}")
      end
    end
  end

  describe "Elixir float" do
    test "is encoded as Python float", %{env: env} do
      for float <- [-1.25, 1.25, 0.0, -0.0, Float.min_finite(), Float.max_finite()] do
        assert {:ok, true} =
                 Snex.pyeval(env, "return type(f) is float and f == #{float}", %{"f" => float})
      end
    end
  end

  describe "Elixir Snex.Serde.float/1" do
    test "when number", %{env: env} do
      for float <- [-1.25, 1.25, 0.0, -0.0, Float.min_finite(), Float.max_finite()] do
        assert {:ok, true} =
                 Snex.pyeval(
                   env,
                   "return type(f) is float and f == #{float}",
                   %{"f" => Snex.Serde.float(float)}
                 )
      end
    end

    test "when infinity", %{env: env} do
      assert {:ok, true} =
               Snex.pyeval(
                 env,
                 "return type(f) is float and math.isinf(f) and f > 0",
                 %{"f" => Snex.Serde.float(:inf)}
               )
    end

    test "when negative infinity", %{env: env} do
      assert {:ok, true} =
               Snex.pyeval(
                 env,
                 "return type(f) is float and math.isinf(f) and f < 0",
                 %{"f" => Snex.Serde.float(:"-inf")}
               )
    end

    test "when NaN", %{env: env} do
      assert {:ok, true} =
               Snex.pyeval(
                 env,
                 "return type(f) is float and math.isnan(f)",
                 %{"f" => Snex.Serde.float(:nan)}
               )
    end
  end

  describe "Python float" do
    test "is decoded as Elixir float", %{env: env} do
      for float <- [1.25, 0.0, -0.0, Float.min_finite(), Float.max_finite()] do
        assert {:ok, ^float} = Snex.pyeval(env, "return #{float}")
      end
    end

    test "is decoded as :inf when infinity", %{env: env} do
      assert {:ok, :inf} = Snex.pyeval(env, "return float('inf')")
    end

    test ~s'is decoded as :"-inf" when negative infinity', %{env: env} do
      assert {:ok, :"-inf"} = Snex.pyeval(env, "return float('-inf')")
    end

    test "is decoded as :nan when NaN", %{env: env} do
      assert {:ok, :nan} = Snex.pyeval(env, "return float('NaN')")
    end
  end

  describe "Elixir binary" do
    test "is encoded as Python str by default", %{env: env} do
      for strlen <- [0, 1, 255, 256] do
        str = String.duplicate("a", strlen)

        assert {:ok, true} =
                 Snex.pyeval(env, "return type(s) is str and s == '#{str}'", %{"s" => str})
      end
    end

    test "round-trips unicode by default", %{env: env} do
      s = "zażółć gęślą jaźń"
      assert {:ok, ^s} = Snex.pyeval(env, "return s", %{"s" => s})
    end

    test "breaks when non-UTF8 by default", %{env: env} do
      assert {:error, %Snex.Error{code: :python_runtime_error}} =
               Snex.pyeval(env, "return s", %{"s" => <<0xFF>>})
    end

    test "is encoded according to `encoding_opts`" do
      bin = "hello"

      interpreter = start_link_supervised!({Snex.Interpreter, encoding_opts: [binary_as: :bytes]})
      {:ok, env} = Snex.make_env(interpreter, %{"var_default" => bin})

      env =
        Enum.reduce([:str, :bytes, :bytearray], env, fn type, env ->
          {:ok, env} =
            Snex.make_env(%{"var_#{type}" => bin}, from: env, encoding_opts: [binary_as: type])

          env
        end)

      # interpreter default
      assert {:ok, true} =
               Snex.pyeval(env, "return type(b) is bytes and b == b'hello'", %{"b" => bin})

      assert {:ok, true} =
               Snex.pyeval(env, "return type(var_default) is bytes and var_default == b'hello'")

      for {type, expected} <- [
            bytes: "b'hello'",
            bytearray: "bytearray(b'hello')",
            str: "'hello'"
          ] do
        assert {:ok, true} =
                 Snex.pyeval(
                   env,
                   "return type(b) is #{type} and b == #{expected}",
                   %{"b" => bin},
                   encoding_opts: [binary_as: type]
                 )

        assert {:ok, true} =
                 Snex.pyeval(
                   env,
                   "return type(var_#{type}) is #{type} and var_#{type} == #{expected}",
                   encoding_opts: [binary_as: type]
                 )
      end
    end
  end

  describe "Python str" do
    test "is decoded as Elixir binary", %{env: env} do
      for strlen <- [0, 1, 255, 256] do
        str = String.duplicate("a", strlen)
        assert {:ok, ^str} = Snex.pyeval(env, "return '#{str}'")
      end
    end

    test "when unicode", %{env: env} do
      assert {:ok, "zażółć gęślą jaźń"} = Snex.pyeval(env, "return 'zażółć gęślą jaźń'")
    end
  end

  describe "Elixir Snex.Serde.binary/1" do
    test "is encoded as Python bytes by default", %{env: env} do
      for len <- [0, 1, 255, 256] do
        bin = :binary.copy(<<171>>, len)

        assert {:ok, true} =
                 Snex.pyeval(
                   env,
                   "return type(b) is bytes and b == bytes([171]) * #{len}",
                   %{"b" => Snex.Serde.binary(bin)}
                 )
      end
    end

    test "wraps iodata", %{env: env} do
      assert {:ok, true} =
               Snex.pyeval(
                 env,
                 "return type(b) is bytes and b == bytes([1, 2, 3, 4])",
                 %{"b" => Snex.Serde.binary([<<1, 2, 3>>, <<4>>])}
               )
    end

    test "encodes according to `encoding_opts`", %{env: env} do
      bin = "hello"

      for {type, expected} <- [
            str: "'hello'",
            bytearray: "bytearray(b'hello')",
            bytes: "b'hello'"
          ] do
        assert {:ok, true} =
                 Snex.pyeval(
                   env,
                   "return type(b) is #{type} and b == #{expected}",
                   %{"b" => Snex.Serde.binary(bin, type)}
                 )
      end
    end
  end

  describe "Python bytes-like" do
    test "decodes as Elixir binary", %{env: env} do
      for len <- [0, 1, 255, 256] do
        bin = :binary.copy(<<171>>, len)

        assert {:ok, {^bin, ^bin, ^bin}} =
                 Snex.pyeval(env, """
                 b = bytearray([171] * #{len})
                 return (b, bytes(b), memoryview(b))
                 """)
      end
    end
  end

  describe "Elixir Snex.Serde.term/1" do
    test "can be round-tripped opaquely", %{env: env} do
      pid = self()
      ref = make_ref()
      term = {:ok, pid, ref, env, %{a: 1, b: [2, 3]}}

      assert {:ok, {true, ^term}} =
               Snex.pyeval(
                 env,
                 "return (type(t) is snex.Term, t)",
                 %{"t" => Snex.Serde.term(term)}
               )
    end
  end

  describe "Elixir list" do
    test "is encoded as Python list", %{env: env} do
      assert {:ok, true} =
               Snex.pyeval(env, "return type(l) is list and l == [1, 2, 3]", %{"l" => [1, 2, 3]})
    end

    test "when empty", %{env: env} do
      assert {:ok, true} =
               Snex.pyeval(env, "return type(l) is list and l == []", %{"l" => []})
    end

    test "when nested", %{env: env} do
      assert {:ok, true} =
               Snex.pyeval(env, "return type(l) is list and l == [[], [[]]]", %{"l" => [[], [[]]]})
    end
  end

  describe "Python list" do
    test "is decoded as Elixir list", %{env: env} do
      assert {:ok, [1, 2, 3]} = Snex.pyeval(env, "return [1, 2, 3]")
    end

    test "when empty", %{env: env} do
      assert {:ok, []} = Snex.pyeval(env, "return []")
    end

    test "when nested", %{env: env} do
      assert {:ok, [[], [[]]]} = Snex.pyeval(env, "return [[], [[]]]")
    end
  end

  describe "Elixir tuple" do
    test "is encoded as Python tuple", %{env: env} do
      for len <- [0, 1, 2, 3, 4, 255, 256] do
        list = Enum.to_list(1..len//1)
        tuple = List.to_tuple(list)

        assert {:ok, true} =
                 Snex.pyeval(
                   env,
                   "return type(t) is tuple and t == tuple(#{inspect(list, limit: :infinity)})",
                   %{"t" => tuple}
                 )
      end
    end
  end

  describe "Python tuple" do
    test "is decoded as Elixir tuple", %{env: env} do
      for len <- [0, 2, 255, 256] do
        list = Enum.to_list(1..len//1)
        tuple = List.to_tuple(list)

        assert {:ok, ^tuple} =
                 Snex.pyeval(env, "return tuple(#{inspect(list, limit: :infinity)})")
      end
    end
  end

  describe "Elixir map" do
    test "is recursively encoded as Python dict", %{env: env} do
      m = %{"x" => 1, "nested" => %{z: 3}, y: 2}

      assert {:ok, true} =
               Snex.pyeval(
                 env,
                 "return type(m) is dict and m['x'] == 1 and m['y'] == 2 and m['nested']['z'] == 3",
                 %{"m" => m}
               )
    end

    test "when empty", %{env: env} do
      assert {:ok, true} =
               Snex.pyeval(env, "return type(m) is dict and m == {}", %{"m" => %{}})
    end
  end

  describe "Python dict" do
    test "is decoded as Elixir map", %{env: env} do
      assert {:ok, %{"x" => 1, "y" => 2}} = Snex.pyeval(env, "return {'x': 1, 'y': 2}")
    end

    test "when empty", %{env: env} do
      assert {:ok, %{}} = Snex.pyeval(env, "return {}")
    end

    test "with snex.Atom keys", %{env: env} do
      assert {:ok, %{x: 1, y: 2}} =
               Snex.pyeval(env, "return {snex.Atom('x'): 1, snex.Atom('y'): 2}")
    end
  end

  describe "Elixir MapSet" do
    test "is encoded as Python set", %{env: env} do
      assert {:ok, true} =
               Snex.pyeval(
                 env,
                 "return type(s) is set and s == {1, 2, 3}",
                 %{"s" => MapSet.new([1, 2, 3])}
               )
    end

    test "when empty", %{env: env} do
      assert {:ok, true} =
               Snex.pyeval(
                 env,
                 "return type(s) is set and s == set()",
                 %{"s" => MapSet.new()}
               )
    end

    test "is encoded according to `encoding_opts`" do
      set = MapSet.new([1, 2, 3])

      interpreter =
        start_link_supervised!({Snex.Interpreter, encoding_opts: [set_as: :frozenset]})

      {:ok, env} = Snex.make_env(interpreter, %{"var_default" => set})

      env =
        Enum.reduce([:set, :frozenset], env, fn type, env ->
          {:ok, env} =
            Snex.make_env(%{"var_#{type}" => set}, from: env, encoding_opts: [set_as: type])

          env
        end)

      # interpreter default
      assert {:ok, true} =
               Snex.pyeval(
                 env,
                 "return type(s) is frozenset and s == {1, 2, 3}",
                 %{"s" => set}
               )

      assert {:ok, true} =
               Snex.pyeval(
                 env,
                 "return type(var_default) is frozenset and var_default == {1, 2, 3}"
               )

      for type <- [:set, :frozenset] do
        assert {:ok, true} =
                 Snex.pyeval(
                   env,
                   "return type(s) is #{type} and s == {1, 2, 3}",
                   %{"s" => set},
                   encoding_opts: [set_as: type]
                 )

        assert {:ok, true} =
                 Snex.pyeval(
                   env,
                   "return type(var_#{type}) is #{type} and var_#{type} == {1, 2, 3}",
                   encoding_opts: [set_as: type]
                 )
      end
    end
  end

  describe "Python set / frozenset" do
    test "is decoded as MapSet", %{env: env} do
      expected_set = MapSet.new([1, 2, 3])

      assert {:ok, {^expected_set, ^expected_set}} =
               Snex.pyeval(env, "return (set([1, 2, 3]), frozenset([1, 2, 3]))")
    end

    test "empty set decodes as empty MapSet", %{env: env} do
      empty_set = MapSet.new()
      assert {:ok, {^empty_set, ^empty_set}} = Snex.pyeval(env, "return (set(), frozenset())")
    end
  end

  describe "Elixir struct" do
    test "is encoded as Python dict with __struct__ key", %{env: env} do
      uri = URI.parse("https://example.com/path?q=1")

      assert {:ok, true} =
               Snex.pyeval(
                 env,
                 """
                 return \
                 type(uri) is dict \
                 and all(type(k) is snex.Atom for k in uri.keys()) \
                 and type(uri['__struct__']) is snex.Atom \
                 and uri['__struct__'] == 'Elixir.URI' \
                 and uri[snex.Atom('scheme')] == 'https'\
                 """,
                 %{"uri" => uri}
               )
    end

    test "round-trips (generic struct encoding)", %{env: env} do
      uri = URI.parse("https://example.com/path?q=1")
      assert {:ok, ^uri} = Snex.pyeval(env, "return uri", %{"uri" => uri})
    end

    test "with custom Snex.Serde.Encoder", %{env: env} do
      # Test Snex.Serde.Encoder defimpl in test/fixtures/snex_serde_encoder_date.ex
      date = ~D[2025-12-28]

      assert {:ok, true} =
               Snex.pyeval(
                 env,
                 "return type(d) is datetime.date and d == datetime.date(2025, 12, 28)",
                 %{"d" => date}
               )
    end
  end

  describe "Python snex.set_custom_encoder()" do
    test "can encode custom objects", %{env: env} do
      assert {:ok, nil} =
               Snex.pyeval(env, """
               def custom_encoder(obj):
                   if type(obj) is datetime.date:
                       return {
                           snex.Atom("__struct__"): snex.Atom("Elixir.Date"),
                           snex.Atom("year"): obj.year,
                           snex.Atom("month"): obj.month,
                           snex.Atom("day"): obj.day,
                           snex.Atom("calendar"): snex.Atom("Elixir.Calendar.ISO"),
                       }
                   raise TypeError(f"Cannot serialize object of {type(obj)}")

               snex.set_custom_encoder(custom_encoder)
               """)

      assert {:ok, ~D[2025-12-28]} = Snex.pyeval(env, "return datetime.date(2025, 12, 28)")
    end
  end

  describe "snex.call result_encoding_opts" do
    test "can override binary_as for call results", %{env: env} do
      assert {:ok, true} =
               Snex.pyeval(
                 env,
                 ~P"""
                 result = await snex.call(
                   'Elixir.Kernel', 'inspect', [42],
                   result_encoding_opts={"binary_as": snex.EncodingOpt.BinaryAs.BYTES},
                 )
                 return type(result) is bytes and result == b'42'
                 """
               )
    end

    test "can override atom_as for call results", %{env: env} do
      assert {:ok, true} =
               Snex.pyeval(
                 env,
                 ~P"""
                 result = await snex.call(
                   'Elixir.String', 'to_atom', ['hello'],
                   result_encoding_opts={"atom_as": snex.EncodingOpt.AtomAs.DISTINCT_ATOM},
                 )
                 return type(result) is snex.DistinctAtom and result != 'hello'
                 """
               )
    end

    test "can override set_as for call results", %{env: env} do
      assert {:ok, true} =
               Snex.pyeval(
                 env,
                 ~P"""
                 result = await snex.call(
                   'Elixir.MapSet', 'new', [[1, 2, 3]],
                   result_encoding_opts={"set_as": snex.EncodingOpt.SetAs.FROZENSET},
                 )
                 return type(result) is frozenset and result == {1, 2, 3}
                 """
               )
    end
  end

  describe "nested structures" do
    test "round-trips", %{env: env} do
      nested = %{
        "list" => [1, 2, %{a: [3, 4]}],
        "tuple" => {5, {6, 7}},
        "set" => MapSet.new([8, 9]),
        "nil" => nil,
        "bool" => true
      }

      assert {:ok, ^nested} = Snex.pyeval(env, "return n", %{"n" => nested})
    end
  end
end
