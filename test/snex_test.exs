defmodule SnexTest do
  use ExUnit.Case, async: true
  use MarkdownDoctest

  markdown_doctest "README.md",
    except:
      &String.contains?(&1, [
        "defmodule",
        "defimpl",
        "def deps",
        "def project",
        "def handle_call",
        "a@localhost"
      ])

  setup_all do
    inp = start_link_supervised!(SnexTest.NumpyInterpreter)
    %{inp: inp}
  end

  setup ctx do
    if ctx[:trap_exit?], do: Process.flag(:trap_exit, true)

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
    test "unserializable value in :returning", %{env: env} do
      assert {:error,
              %Snex.Error{
                code: :python_runtime_error,
                reason: "Cannot serialize object of <class 'module'>"
              }} = Snex.pyeval(env, "import datetime", returning: "datetime")
    end

    test "the interpreter exits if Port fails to start" do
      Process.flag(:trap_exit, true)

      {:error, %Snex.Error{code: :interpreter_exited, reason: {:exit_status, 127}}} =
        Snex.Interpreter.start_link(
          wrap_exec: fn _python, _args -> {"/bin/bash", ["-c", "nonexistent 2>/dev/null"]} end
        )
    end

    @tag capture_log: true
    @tag trap_exit?: true
    test "the interpreter exits on Python fatal error" do
      {:ok, inp} = SnexTest.NumpyInterpreter.start_link()

      os_pid = SnexTest.NumpyInterpreter.os_pid(inp)
      assert {_, 0} = System.cmd("kill", ~w[-SIGTERM #{os_pid}])

      assert_receive {:EXIT, ^inp,
                      %Snex.Error{code: :interpreter_exited, reason: {:exit_status, 143}}}
    end

    @tag capture_log: true
    @tag trap_exit?: true
    test "interpreter shutdown stops pending requests" do
      {:ok, inp} = Snex.Interpreter.start_link()

      self = self()

      task =
        Task.async(fn ->
          {:ok, env} = Snex.make_env(inp)

          Snex.pyeval(
            env,
            """
            import asyncio
            snex.send(parent, snex.Atom("running"))
            await asyncio.sleep(10)
            """,
            %{"parent" => self}
          )
        end)

      assert_receive :running
      Snex.Interpreter.stop(inp, :any_reason)

      assert {:error, %Snex.Error{code: :call_failed, reason: :any_reason}} = Task.await(task)
    end
  end

  describe "sync_start_timeout" do
    @tag trap_exit?: true
    test "returns an error if sync_start? is true" do
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

    @tag trap_exit?: true
    @tag capture_log: true
    test "exits asynchronously if sync_start? is false" do
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

  describe "wrap_exec" do
    test "can wrap the python executable with a function" do
      {:ok, inp} =
        Snex.Interpreter.start_link(
          wrap_exec: &wrap_with_env/2,
          init_script: "import os"
        )

      {:ok, env} = Snex.make_env(inp)
      assert {:ok, "42"} = Snex.pyeval(env, returning: "os.getenv('TESTVAR')")
    end

    test "can wrap the python executable with an MFA" do
      {:ok, inp} =
        SnexTest.NumpyInterpreter.start_link(
          wrap_exec: {__MODULE__, :wrap_with_env, []},
          init_script: "import os"
        )

      {:ok, env} = Snex.make_env(inp)
      assert {:ok, "42"} = Snex.pyeval(env, returning: "os.getenv('TESTVAR')")
    end

    @spec wrap_with_env(String.t(), [String.t()]) :: {String.t(), [String.t()]}
    def wrap_with_env(python, args), do: {"/usr/bin/env", ["TESTVAR=42", python | args]}
  end

  describe "Snex.Interpreter.os_pid/1" do
    test "returns the OS PID of the interpreter", %{inp: inp} do
      os_pid = SnexTest.NumpyInterpreter.os_pid(inp)
      assert ^os_pid = Snex.Interpreter.os_pid(inp)

      assert {cmd, 0} = System.cmd("ps", ["-p", "#{os_pid}", "-o", "comm="])
      assert cmd =~ "python"
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
      {:ok, inp} =
        SnexTest.NumpyInterpreter.start_link(max_rss_bytes: 1_000_000_000, name: :test_high_rss)

      {:ok, env} = Snex.make_env(inp)

      assert {:ok, 42} = Snex.pyeval(env, "x = 42", returning: "x")
      assert {:ok, 84} = Snex.pyeval(env, "y = x * 2", returning: "y")

      GenServer.stop(inp)
    end
  end
end
