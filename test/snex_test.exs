defmodule SnexTest do
  use ExUnit.Case, async: true
  use MarkdownDoctest

  import Snex.Sigils

  markdown_doctest "README.md",
    except:
      &String.contains?(&1, [
        "iex>",
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

    test "can use atoms and tuples as send destinations", %{env: env} do
      Process.register(self(), :test_send_destination)

      assert :ok =
               Snex.pyeval(
                 env,
                 "snex.send(snex.Atom('test_send_destination'), b'hello from snex')"
               )

      assert_receive "hello from snex"
    end

    test "can use tuples and snex.Term as send destinations", %{env: env} do
      Process.register(self(), :test_sendt_destination)

      assert :ok =
               Snex.pyeval(
                 env,
                 "snex.send((snex.Atom('test_sendt_destination'), node), b'hello from snex')",
                 %{"node" => Snex.Serde.term(node())}
               )

      assert_receive "hello from snex"
    end
  end

  describe "snex.call" do
    test "can call Elixir functions from Python and get the result", %{env: env} do
      {:ok, agent} = Agent.start_link(fn -> 42 end)

      assert {:ok, 42} =
               Snex.pyeval(
                 env,
                 "result = await snex.call(snex.Atom('Elixir.Agent'), snex.Atom('get'), [agent, identity])",
                 %{"agent" => agent, "identity" => &Function.identity/1},
                 returning: "result"
               )
    end

    test "can call with string module/function names", %{env: env} do
      assert {:ok, 3} =
               Snex.pyeval(
                 env,
                 "result = await snex.call('Elixir.Kernel', 'length', [[1, 2, 3]])",
                 returning: "result"
               )
    end

    @tag capture_log: true
    test "call raises ElixirError when Elixir function raises", %{env: env} do
      assert {:error, %Snex.Error{code: :python_runtime_error, reason: reason}} =
               Snex.pyeval(
                 env,
                 "await snex.call(snex.Atom('Elixir.Kernel'), snex.Atom('div'), [10, 0])"
               )

      assert reason =~ "failed on Elixir side"
      assert reason =~ ":badarith"
      assert reason =~ ":erlang, :div, [10, 0]"
    end

    test "can handle multiple concurrent calls", %{env: env} do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      assert {:ok, [1, 2, 3]} =
               Snex.pyeval(
                 env,
                 """
                 import asyncio
                 results = await asyncio.gather(
                   snex.call("Elixir.Agent", "get_and_update", [agent, fun]),
                   snex.call("Elixir.Agent", "get_and_update", [agent, fun]),
                   snex.call("Elixir.Agent", "get_and_update", [agent, fun])
                 )
                 """,
                 %{"agent" => agent, "fun" => &{&1 + 1, &1 + 1}},
                 returning: "results"
               )
    end
  end

  describe "snex.cast" do
    test "can cast to Elixir functions without waiting for response", %{env: env} do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      assert :ok =
               Snex.pyeval(
                 env,
                 "snex.cast(snex.Atom('Elixir.Agent'), snex.Atom('update'), [agent, update_fn])",
                 %{"agent" => agent, "update_fn" => &(&1 + 1)}
               )

      assert Enum.find(1..100, fn _ ->
               if Agent.get(agent, & &1) == 1 do
                 true
               else
                 Process.sleep(1)
                 false
               end
             end)
    end

    test "can cast with string module/function names", %{env: env} do
      assert :ok =
               Snex.pyeval(
                 env,
                 "snex.cast('Elixir.Kernel', 'send', [target, b'cast_message'])",
                 %{"target" => self()}
               )

      assert_receive "cast_message", 500
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

  describe "init_script" do
    test "can run a init script with additional variables" do
      {:ok, inp} = Snex.Interpreter.start_link(init_script: {"y = 2 * x", %{"x" => 3}})
      {:ok, env} = Snex.make_env(inp)
      assert {:ok, {3, 6}} = Snex.pyeval(env, returning: "x, y")
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

  describe "sigil_p" do
    test "preserves code location", %{env: env} do
      {line, code} = {
        __ENV__.line,
        ~p"""
        raise RuntimeError("test")
        """
      }

      assert {:error, %Snex.Error{} = reason} = Snex.pyeval(env, code)
      assert Enum.at(reason.traceback, -2) =~ ~s'File "#{__ENV__.file}", line #{line + 2}'

      {line, code} = {
        __ENV__.line,
        ~P"""
        raise RuntimeError("test")
        """
      }

      assert {:error, %Snex.Error{} = reason} = Snex.pyeval(env, code)
      assert Enum.at(reason.traceback, -2) =~ ~s'File "#{__ENV__.file}", line #{line + 2}'
    end

    test "preserves code location in single-line strings", %{env: env} do
      {line, code} = {__ENV__.line, ~p"raise RuntimeError('test')"}
      assert {:error, %Snex.Error{} = reason} = Snex.pyeval(env, code)
      assert Enum.at(reason.traceback, -2) =~ ~s'File "#{__ENV__.file}", line #{line}'
    end

    test "accepts empty code", %{env: env} do
      assert :ok = Snex.pyeval(env, ~p"")
    end
  end
end
