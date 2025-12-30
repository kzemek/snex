defmodule SnexTest do
  use ExUnit.Case, async: true
  use MarkdownDoctest

  markdown_doctest "README.md",
    except: &String.contains?(&1, ["defmodule", "def deps", "def project", "def handle_call"])

  setup do
    inp = start_link_supervised!(SnexTest.NumpyInterpreter)
    {:ok, env} = Snex.make_env(inp)
    %{inp: inp, env: env}
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
    test "the interpreter exits on Python fatal error", %{inp: inp} do
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

  describe "max_rss_bytes" do
    @tag capture_log: true
    test "interpreter shuts down when memory exceeds limit" do
      Process.flag(:trap_exit, true)

      # Start interpreter with a very low memory limit (1 byte - will trigger on first command)
      {:ok, inp} = SnexTest.NumpyInterpreter.start_link(max_rss_bytes: 1)

      # make_env succeeds (command completes) but triggers memory check which exceeds limit
      {:ok, _env} = Snex.make_env(inp)

      # Interpreter should shut down immediately after
      assert_receive {:EXIT, ^inp, {:shutdown, :max_rss_bytes}}, 1000
    end

    @tag capture_log: true
    test "pending requests receive error when memory limit exceeded" do
      Process.flag(:trap_exit, true)

      # Start interpreter with a very low memory limit
      {:ok, inp} = SnexTest.NumpyInterpreter.start_link(max_rss_bytes: 1)

      test_pid = self()

      # Spawn tasks that will try to run commands concurrently.
      # Both tasks signal when they're about to call the GenServer.

      # Task 1: make_env - this will succeed but trigger memory check
      task1 =
        Task.async(fn ->
          send(test_pid, :task1_starting)
          Snex.make_env(inp)
        end)

      # Task 2: another make_env - this should be pending when task1 triggers shutdown
      task2 =
        Task.async(fn ->
          # Wait for task1 to start, then immediately send our request too
          receive do
            :task2_go -> :ok
          end

          send(test_pid, :task2_starting)
          Snex.make_env(inp)
        end)

      # Wait for task1 to start its call
      assert_receive :task1_starting, 1000

      # Signal task2 to start immediately
      send(task2.pid, :task2_go)

      # Wait for task2 to also start
      assert_receive :task2_starting, 1000

      # Task 1 should succeed (the command completes before shutdown)
      assert {:ok, _env} = Task.await(task1, 5000)

      # Task 2 should receive the max_rss_bytes error
      assert {:error, %Snex.Error{code: :max_rss_bytes}} = Task.await(task2, 5000)

      # Interpreter should exit
      assert_receive {:EXIT, ^inp, {:shutdown, :max_rss_bytes}}, 1000
    end

    test "interpreter runs normally when max_rss_bytes is nil" do
      # Use a unique name to avoid conflicts with setup's interpreter
      {:ok, inp} = SnexTest.NumpyInterpreter.start_link(max_rss_bytes: nil, name: :test_nil_rss)
      {:ok, env} = Snex.make_env(inp)

      assert {:ok, 42} = Snex.pyeval(env, "x = 42", returning: "x")
      assert {:ok, 84} = Snex.pyeval(env, "y = x * 2", returning: "y")

      GenServer.stop(inp)
    end

    test "interpreter runs normally when memory is under limit" do
      # 1 GB limit should be plenty. Use a unique name to avoid conflicts.
      {:ok, inp} = SnexTest.NumpyInterpreter.start_link(max_rss_bytes: 1_000_000_000, name: :test_high_rss)
      {:ok, env} = Snex.make_env(inp)

      assert {:ok, 42} = Snex.pyeval(env, "x = 42", returning: "x")
      assert {:ok, 84} = Snex.pyeval(env, "y = x * 2", returning: "y")

      GenServer.stop(inp)
    end
  end
end
