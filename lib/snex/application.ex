defmodule Snex.Application do
  @moduledoc """
  The Snex application.

  This module is not intended to be used directly.
  Instead, you would start the application with `Application.start(:snex)`.

  If `:snex` is in your application's dependencies, it will be started
  automatically unless you explicitly set `runtime: false`.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: Snex.Internal.TaskSupervisor},
      Snex.Internal.GarbageCollector
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
