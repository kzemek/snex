defmodule Snex.GCTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  setup ctx do
    interpreter = start_supervised!(SnexTest.NumpyInterpreter)
    {:ok, env} = Snex.make_env(interpreter)

    attrs =
      if ctx[:garbage_collector_mitm?] do
        garbage_collector = Process.whereis(Snex.Internal.GarbageCollector)
        Process.unregister(Snex.Internal.GarbageCollector)
        Process.register(self(), Snex.Internal.GarbageCollector)

        on_exit(fn ->
          Process.register(garbage_collector, Snex.Internal.GarbageCollector)
        end)

        %{garbage_collector: garbage_collector}
      else
        %{}
      end

    Map.merge(%{interpreter: interpreter, env: env}, attrs)
  end

  describe "Snex.Env garbage collection" do
    @tag garbage_collector_mitm?: true
    test "is garbage collected when the last reference to the environment is dropped",
         %{env: env, garbage_collector: garbage_collector} do
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

          assert {:error, %Snex.Error{code: :call_failed, reason: :noproc}} =
                   wait_until_error_code(env, :call_failed)

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

  describe "Snex.destroy_env/1" do
    test "destroys the environment and subsequent pyeval calls return env_not_found", %{env: env} do
      assert {:ok, 1} = Snex.pyeval(env, returning: "1")

      assert :ok = Snex.destroy_env(env)

      assert {:error, %Snex.Error{code: :env_not_found}} = Snex.pyeval(env, returning: "1")
    end

    test "is idempotent - can be called multiple times on the same environment", %{env: env} do
      assert :ok = Snex.destroy_env(env)
      assert :ok = Snex.destroy_env(env)
      assert :ok = Snex.destroy_env(env)

      assert {:error, %Snex.Error{code: :env_not_found}} = Snex.pyeval(env, returning: "1")
    end

    @tag garbage_collector_mitm?: true
    test "prevents automatic GC from sending duplicate destroy commands", %{env: env} do
      # Manually destroy the env - this should disable automatic GC for local envs
      assert :ok = Snex.destroy_env(env)
      assert {:error, %Snex.Error{code: :env_not_found}} = Snex.pyeval(env, returning: "1")

      # Drop the ref by setting it to nil and trigger GC
      %{id: env_id} = _env = %{env | ref: nil}
      :erlang.garbage_collect()

      # GC should NOT send a message since destroy_env disabled automatic GC
      refute_receive %Snex.Env{id: ^env_id}, 100
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
