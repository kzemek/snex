defmodule Snex.Interpreter do
  @moduledoc """
  Runs a Python interpreter in a separate OS process.

  This module is responsible for facilitating in-and-out communication between Elixir
  and the spawned Python interpreter.
  """
  use GenServer

  alias Snex.Internal

  require Logger

  @typedoc """
  Running instance of `Snex.Interpreter`.
  """
  @type server :: GenServer.server()

  # credo:disable-for-next-line
  alias __MODULE__, as: State
  defstruct [:port, pending: %{}]

  defmacro __using__(opts), do: Internal.CustomInterpreter.using(__CALLER__.module, opts)

  @typedoc """
  Options for `start_link/1`.
  """
  @type option ::
          {:python, String.t()}
          | {:environment, %{optional(String.t()) => String.t()}}
          | GenServer.option()

  @doc """
  Starts a new Python interpreter.

  The interpreter can be used by functions in the `Snex` module.

  ## Options

    * `:python` - The Python executable to use. This can be a full path or a command to \
      find via `System.find_executable/1`.
    * `:environment` - A map of environment variables to set when running the Python \
      executable.
    * any other options will be passed to `GenServer.start_link/3`.

  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {args, genserver_opts} = Keyword.split(opts, [:python, :environment])
    GenServer.start_link(__MODULE__, args, genserver_opts)
  end

  @impl GenServer
  def init(opts) do
    python = System.find_executable(opts[:python])

    environment =
      for {key, value} <- opts[:environment],
          do: {~c"#{key}", ~c"#{value}"}

    port =
      Port.open({:spawn_executable, python}, [
        :binary,
        :nouse_stdio,
        packet: 4,
        env: environment,
        args: [Internal.Script.path()]
      ])

    {:ok, %State{port: port}}
  end

  @impl GenServer
  def handle_call(command, from, state) do
    id = run_command(command, state.port)
    {:noreply, %{state | pending: Map.put(state.pending, id, from)}}
  rescue
    e -> {:reply, {:error, e}, state}
  end

  @impl GenServer
  def handle_info({_port, {:data, <<id::binary-size(16), data::binary>>}}, state) do
    {client, pending} = Map.pop(state.pending, id)

    if client do
      result = decode_reply(data, state.port)
      GenServer.reply(client, result)
    else
      Logger.warning("Received data for unknown request #{inspect(id)} #{inspect(data)}")
    end

    {:noreply, %{state | pending: pending}}
  end

  defp run_command(command, port) do
    id = :rand.bytes(16)
    data = JSON.encode_to_iodata!(command)
    Port.command(port, [id, data])
    id
  end

  defp decode_reply(data, port) do
    case JSON.decode(data) do
      {:ok, %{"status" => "ok"}} ->
        :ok

      {:ok, %{"status" => "ok_env", "id" => env_id}} ->
        {:ok, env_id |> Base.decode64!() |> Snex.Env.make(port, self())}

      {:ok, %{"status" => "ok_value", "value" => value}} ->
        {:ok, value}

      {:ok, %{"status" => "error", "code" => code, "reason" => reason}} ->
        {:error, Snex.Error.from_raw(code, reason)}

      {:ok, value} ->
        {:error, Snex.Error.exception(code: :internal_error, reason: {:unknown_format, value})}

      {:error, reason} ->
        {:error,
         Snex.Error.exception(code: :internal_error, reason: {:result_decode_error, reason, data})}
    end
  end
end
