defmodule SnexTest do
  use ExUnit.Case, async: true

  doctest_file("README.md")

  setup do
    inp = start_link_supervised!(SnexTest.NumpyInterpreter)
    {:ok, env} = Snex.make_env(inp)
    %{inp: inp, env: env}
  end

  describe "binary serialization" do
    test "binary can be passed to Python", %{env: env} do
      assert {:ok, true} =
               Snex.pyeval(env, nil, %{"val" => Snex.Serde.binary(<<1, 2, 3>>)},
                 returning: "val == b'\\x01\\x02\\x03'"
               )
    end

    test "iodata can be passed to Python", %{env: env} do
      assert {:ok, true} =
               Snex.pyeval(env, nil, %{"val" => Snex.Serde.binary([<<1, 2, 3>>, <<4, 5, 6>>])},
                 returning: "val == b'\\x01\\x02\\x03\\x04\\x05\\x06'"
               )
    end

    test "binary can be got from Python", %{env: env} do
      assert {:ok, <<1, 2, 3>>} = Snex.pyeval(env, returning: "b'\\x01\\x02\\x03'")
    end
  end

  describe "term serialization" do
    test "term can be round-tripped to Python", %{env: env} do
      self = self()
      ref = make_ref()

      assert {:ok, {^self, ^ref}} =
               Snex.pyeval(env, nil, %{"val" => Snex.Serde.term({self, ref})}, returning: "val")
    end
  end

  describe "tuple serialization" do
    test "tuple can be passed to Python as list", %{env: env} do
      assert {:ok, true} =
               Snex.pyeval(env, nil, %{"val" => {1, 2, 3}}, returning: "val == [1, 2, 3]")
    end

    test "tuple can be got from Python as list", %{env: env} do
      assert {:ok, [1, 2, 3]} = Snex.pyeval(env, returning: "(1, 2, 3)")
    end
  end

  describe "error handling" do
    test "unserializable value in make_eval", %{inp: inp} do
      assert {:error, %Protocol.UndefinedError{}} = Snex.make_env(inp, %{"x" => make_ref()})
    end

    test "unserializable value in :returning", %{env: env} do
      assert {:error,
              %Snex.Error{
                code: :python_runtime_error,
                reason: "Object of type module is not JSON serializable"
              }} = Snex.pyeval(env, "import datetime", returning: "datetime")
    end
  end
end
