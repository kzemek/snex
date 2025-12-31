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

    @tag capture_log: true
    test "the interpreter exits if Port fails to start" do
      Process.flag(:trap_exit, true)

      {:error, %Snex.Error{code: :interpreter_exited, reason: {:exit_status, 127}}} =
        Snex.Interpreter.start_link(
          wrap_exec: fn _python, _args -> {"/bin/bash", ["-c", "nonexistent 2>/dev/null"]} end
        )
    end

    @tag capture_log: true
    test "the interpreter exits on Python fatal error" do
      inp = start_link_supervised!(SnexTest.NumpyInterpreter)
      Process.flag(:trap_exit, true)

      %{port: port} = :sys.get_state(inp)
      {:os_pid, os_pid} = :erlang.port_info(port, :os_pid)

      assert {_, 0} = System.cmd("kill", ~w[-SIGTERM #{os_pid}])

      assert_receive {:EXIT, ^inp,
                      %Snex.Error{code: :interpreter_exited, reason: {:exit_status, 143}}}
    end

    @tag capture_log: true
    test "interpreter shutdown stops pending requests" do
      {:ok, inp} = Snex.Interpreter.start_link()
      Process.flag(:trap_exit, true)

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
    test "returns the OS PID of the interpreter" do
      {:ok, inp} = Snex.Interpreter.start_link()
      os_pid = Snex.Interpreter.os_pid(inp)

      assert {cmd, 0} = System.cmd("ps", ["-p", "#{os_pid}", "-o", "comm="])
      assert cmd =~ "python"
    end

    test "returns the OS PID of the custom interpreter", %{inp: inp} do
      os_pid = Snex.Interpreter.os_pid(inp)

      assert {cmd, 0} = System.cmd("ps", ["-p", "#{os_pid}", "-o", "comm="])
      assert cmd =~ "python"
    end
  end
end
