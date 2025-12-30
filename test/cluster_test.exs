defmodule Snex.ClusterTest do
  @moduledoc false
  use ExUnit.ClusteredCase, async: true

  scenario "given a healthy cluster", cluster_size: 1, boot_timeout: to_timeout(minute: 1) do
    node_setup do
      {:ok, _} = Application.ensure_all_started(:snex)
      :ok
    end

    setup ctx do
      remote_node = Cluster.random_member(ctx.cluster)

      interpreter_pid =
        :erpc.call(remote_node, fn ->
          case Snex.Interpreter.start_link(name: Snex.Interpreter) do
            {:ok, interpreter} ->
              Process.unlink(interpreter)
              interpreter

            {:error, {:already_started, interpreter}} ->
              interpreter
          end
        end)

      interpreter =
        if ctx.by_name?,
          do: {Snex.Interpreter, remote_node},
          else: interpreter_pid

      %{remote_node: remote_node, interpreter: interpreter}
    end

    for suffix <- ["", " by name"] do
      @describetag by_name?: suffix == " by name"

      test "copy remote env on another node#{suffix}",
           %{remote_node: remote_node, interpreter: interpreter} do
        remote_env =
          :erpc.call(remote_node, fn ->
            {:ok, env} = Snex.make_env(interpreter, %{"v" => 42})
            {:ok, _} = Agent.start(fn -> env end)
            env
          end)

        {:ok, local_env} = Snex.make_env(from: remote_env)

        assert {:ok, 42} = Snex.pyeval(local_env, returning: "v")
      end

      test "make_env on remote interpreter#{suffix}", %{interpreter: interpreter} do
        {:ok, env} = Snex.make_env(interpreter, %{"v" => 123})
        assert {:ok, 123} = Snex.pyeval(env, returning: "v")
      end

      test "run pyeval on remote env#{suffix}",
           %{remote_node: remote_node, interpreter: interpreter} do
        remote_env =
          :erpc.call(remote_node, fn ->
            {:ok, env} = Snex.make_env(interpreter, %{"v" => 567})
            {:ok, _} = Agent.start(fn -> env end)
            env
          end)

        assert {:ok, 567} = Snex.pyeval(remote_env, returning: "v")
      end

      test "disable GC on remote env, send it to local and back, disable GC again#{suffix}",
           %{remote_node: remote_node, interpreter: interpreter} do
        {:ok, env_agent} =
          :erpc.call(remote_node, Agent, :start, [
            fn ->
              {:ok, env} = Snex.make_env(interpreter, %{"v" => 1024})
              # we should've used env that we got from `disable_gc`, but we're simulating
              # a case where the other node received an env with a resource
              _ = Snex.Env.disable_gc(env)
              env
            end
          ])

        env = Agent.get(env_agent, &Function.identity/1)
        Agent.stop(env_agent)
        # at this point, env resource has definitely been cleaned up by the GC

        assert {:ok, 1024} = Snex.pyeval(env, returning: "v")

        assert {:ok, 1024} =
                 :erpc.call(remote_node, fn ->
                   # check that we can disable GC again
                   env = Snex.Env.disable_gc(env)
                   Snex.pyeval(env, returning: "v")
                 end)
      end

      test "disable GC on local env for remote interpreter#{suffix}", %{interpreter: interpreter} do
        {:ok, env} = Snex.make_env(interpreter, %{"v" => 4096})
        env = Snex.Env.disable_gc(env)

        assert {:ok, 4096} = Snex.pyeval(env, returning: "v")

        _ = Snex.Env.disable_gc(env)
      end

      test "destroy_env can be called from local node on remote env#{suffix}",
           %{remote_node: remote_node, interpreter: interpreter} do
        remote_env =
          :erpc.call(remote_node, fn ->
            {:ok, env} = Snex.make_env(interpreter, %{"v" => 789})
            env = Snex.Env.disable_gc(env)
            env
          end)

        assert {:ok, 789} = Snex.pyeval(remote_env, returning: "v")

        # Destroy from local node
        assert :ok = Snex.destroy_env(remote_env)

        assert {:error, %Snex.Error{code: :env_not_found}} =
                 Snex.pyeval(remote_env, returning: "v")
      end

      test "destroy_env is idempotent across nodes#{suffix}",
           %{remote_node: remote_node, interpreter: interpreter} do
        {:ok, env} = Snex.make_env(interpreter, %{"v" => 555})
        env = Snex.Env.disable_gc(env)

        assert :ok = Snex.destroy_env(env)
        assert :ok = :erpc.call(remote_node, Snex, :destroy_env, [env])
        assert :ok = Snex.destroy_env(env)

        assert {:error, %Snex.Error{code: :env_not_found}} = Snex.pyeval(env, returning: "v")
      end
    end
  end
end
