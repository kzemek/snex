defmodule Snex.Internal.GarbageCollector do
  @moduledoc false
  # This module receives notifications about Snex.Env structs ready for garbage collection
  # from Snex.Env.EnvReferenceNif, and sends a GC command to the interpreter.
  # The NIF can't send the command itself because it can only interact with local processes.

  use GenServer

  alias Snex.Internal.Commands

  require Logger

  @spec start_link(opts :: Keyword.t()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    {:ok, []}
  end

  @impl GenServer
  def handle_info(%Snex.Env{} = env, state) do
    Snex.Interpreter.command_noreply(env.interpreter, env.port, %Commands.GC{env: env})
    {:noreply, state}
  end
end
