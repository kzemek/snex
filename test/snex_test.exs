defmodule SnexTest do
  use ExUnit.Case, async: true
  use MarkdownDoctest

  markdown_doctest "README.md",
    except: &String.contains?(&1, ["defmodule", "def deps", "def project", "def handle_call"])

  setup_all do
    inp = start_link_supervised!(SnexTest.NumpyInterpreter)
    %{inp: inp}
  end

  setup ctx do
    {:ok, env} = Snex.make_env(ctx.inp)
    %{env: env}
  end

  describe "from_env" do
    test "can create a new environment from an existing environment", %{env: env} do
      :ok = Snex.pyeval(env, "x = 1")
      assert {:ok, new_env} = Snex.make_env(from: env)
      assert {:ok, 1} = Snex.pyeval(new_env, returning: "x")
    end
  end

  describe "binary & term serialization" do
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

    test "term can be round-tripped to Python", %{env: env} do
      self = self()
      ref = make_ref()

      assert {:ok, {^self, ^ref}} =
               Snex.pyeval(env, nil, %{"val" => Snex.Serde.term({self, ref})}, returning: "val")
    end

    test "multiple binaries and terms in nested structures round-trip correctly", %{env: env} do
      binary1 = Snex.Serde.binary(<<0xFF, 0x00, 0x42>>)
      binary2 = Snex.Serde.binary("hello world")
      binary3 = Snex.Serde.binary([<<1, 2>>, <<3, 4, 5>>])

      term1 = Snex.Serde.term({:ok, "test", 123})
      term2 = Snex.Serde.term(%{key: "value", num: 42})
      term3 = Snex.Serde.term([:a, :b, :c])
      term4_ref = make_ref()
      term4 = Snex.Serde.term(term4_ref)

      variables = %{
        "level1" => %{
          "binaries" => [binary1, binary2],
          "terms" => {term1, term2}
        },
        "level2" => [
          %{"mixed" => binary3, "term" => term3},
          {term4, "string", 999}
        ],
        "simple" => binary1
      }

      assert {:ok, result} =
               Snex.pyeval(env, nil, variables,
                 returning: ~s'{"level1": level1, "level2": level2, "simple": simple}'
               )

      assert %{
               "level1" => %{
                 "binaries" => [<<0xFF, 0x00, 0x42>>, "hello world"],
                 "terms" => [{:ok, "test", 123}, %{key: "value", num: 42}]
               },
               "level2" => [
                 %{"mixed" => <<1, 2, 3, 4, 5>>, "term" => [:a, :b, :c]},
                 # tuples become lists in Python
                 [^term4_ref, "string", 999]
               ],
               "simple" => <<0xFF, 0x00, 0x42>>
             } = result
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

  describe "sending" do
    test "can send from Python", %{env: env} do
      assert :ok =
               Snex.pyeval(env, "snex.send(self, b'hello from snex')", %{
                 "self" => Snex.Serde.term(self())
               })

      assert_receive "hello from snex"
    end
  end

  describe "returning" do
    test "return an Elixir list of a single value", %{env: env} do
      assert {:ok, [42]} = Snex.pyeval(env, returning: ["42"])
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

    @tag capture_log: true
    test "the interpreter exits on Python fatal error" do
      inp = start_link_supervised!(SnexTest.NumpyInterpreter)
      Process.flag(:trap_exit, true)

      %{port: port} = :sys.get_state(inp)
      {:os_pid, os_pid} = :erlang.port_info(port, :os_pid)

      assert {_, 0} = System.cmd("kill", ~w[-SIGTERM #{os_pid}])
      assert_receive {:EXIT, ^inp, {:exit_status, 143}}
    end
  end

  describe "sync_start_timeout" do
    test "returns an error if sync_start? is true" do
      Process.flag(:trap_exit, true)

      assert {:error, %Snex.Error{code: :init_script_timeout}} =
               Snex.Interpreter.start_link(
                 sync_start?: true,
                 init_script_timeout: 0,
                 init_script: """
                 import time
                 time.sleep(1)
                 """
               )
    end

    @tag capture_log: true
    test "exits asynchronously if sync_start? is false" do
      Process.flag(:trap_exit, true)

      assert {:ok, inp} =
               Snex.Interpreter.start_link(
                 sync_start?: false,
                 init_script_timeout: 0,
                 init_script: """
                 import time
                 time.sleep(1)
                 """
               )

      assert_receive {:EXIT, ^inp, %Snex.Error{code: :init_script_timeout}}
    end
  end
end
