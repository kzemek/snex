defmodule Snex.GCTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  setup do
    interpreter = start_supervised!(SnexTest.NumpyInterpreter)
    {:ok, env} = Snex.make_env(interpreter)

    %{interpreter: interpreter, env: env}
  end

  describe "Snex.Env garbage collection" do
    test "is garbage collected when the last reference to the environment is dropped", %{env: env} do
      garbage_collector = Process.whereis(Snex.Internal.GarbageCollector)
      Process.unregister(Snex.Internal.GarbageCollector)
      Process.register(self(), Snex.Internal.GarbageCollector)

      on_exit(fn ->
        Process.register(garbage_collector, Snex.Internal.GarbageCollector)
      end)

      %{id: env_id} = env = %{env | ref: nil}
      :erlang.garbage_collect()

      assert_receive %Snex.Env{id: ^env_id} = gc_env
      send(garbage_collector, gc_env)

      assert {:error, %Snex.Error{code: :env_not_found}} =
               wait_until_error_code(env, :env_not_found)
    end

    test "doesn't error when the interpreter is stopped",
         %{interpreter: interpreter, env: env, test: test} do
      session = :trace.session_create(test, self(), [])

      1 =
        :trace.function(
          session,
          {Snex.Interpreter, :command_noreply, 3},
          [{:_, [], [{:return_trace}]}],
          [
            :meta
          ]
        )

      {_, log} =
        with_log(fn ->
          Process.exit(interpreter, :shutdown)

          assert {:error, %Snex.Error{code: :interpreter_communication_failure, reason: :noproc}} =
                   wait_until_error_code(env, :interpreter_communication_failure)

          %{id: env_id} = env
          :erlang.garbage_collect()

          assert_receive {:trace_ts, gc_pid, :call,
                          {Snex.Interpreter, :command_noreply,
                           [
                             _interpreter,
                             _port,
                             %Snex.Internal.Commands.GC{env: %Snex.Env{id: ^env_id}}
                           ]}, _ts}

          assert_receive {:trace_ts, ^gc_pid, :return_from,
                          {Snex.Interpreter, :command_noreply, 3}, :ok, _ts}

          :trace.session_destroy(session)
        end)

      assert log == ""
    end
  end

  defp wait_until_error_code(env, code, retries \\ 1000) do
    case Snex.pyeval(env, returning: "1") do
      {:error, %Snex.Error{code: ^code}} = err ->
        err

      _ when retries > 0 ->
        Process.sleep(1)
        wait_until_error_code(env, code, retries - 1)

      result ->
        result
    end
  end
end
