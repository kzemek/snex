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
    end
  end
end
