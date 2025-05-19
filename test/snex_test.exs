defmodule SnexTest do
  use ExUnit.Case

  doctest_file("README.md")

  setup do
    inp = start_link_supervised!(SnexTest.NumpyInterpreter)
    {:ok, env} = Snex.make_env(inp)
    %{inp: inp, env: env}
  end

  describe "error handling" do
    test "unserializable value in make_eval", %{inp: inp} do
      assert {:error, %Protocol.UndefinedError{}} = Snex.make_env(inp, %{"x" => {1, 2, 3}})
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
