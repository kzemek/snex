defmodule Snex.Interpreter do
  use GenServer

  require Logger

  @type server :: GenServer.server()

  defstruct [:port, pending: %{}]
  alias __MODULE__, as: State

  defmacro __using__(opts) do
    Snex.Internal.CustomInterpreter.using(__CALLER__, opts)
  end

  @start_link_schema_raw [
    python: [
      type: :string,
      default: "python",
      doc: """
      The Python executable to use. This can be a full path or a command to \
      find via `System.find_executable/1`.\
      """
    ],
    environment: [
      type: {:map, :string, :string},
      default: %{},
      doc: """
      A map of environment variables to set when running the Python \
      executable.\
      """
    ]
  ]
  @start_link_schema NimbleOptions.new!(@start_link_schema_raw)

  def start_link(opts \\ []) do
    {args, genserver_opts} = Keyword.split(opts, Keyword.keys(@start_link_schema.schema))

    with {:ok, args} <- NimbleOptions.validate(args, @start_link_schema),
         do: GenServer.start_link(__MODULE__, args, genserver_opts)
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
        args: [Snex.Internal.Script.path()]
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
