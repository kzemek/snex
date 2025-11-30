defmodule Snex.Interpreter do
  @moduledoc ~s'''
  Runs a Python interpreter in a separate OS process.

  This module is responsible for facilitating in-and-out communication between Elixir
  and the spawned Python interpreter.

  Usually you won't interact with this module directly.
  Instead, you would create a custom interpreter module with `use Snex.Interpreter`:

      defmodule SnexTest.NumpyInterpreter do
        use Snex.Interpreter,
          pyproject_toml: """
          [project]
          name = "my-numpy-project"
          version = "0.0.0"
          requires-python = "==3.11.*"
          dependencies = ["numpy>=2"]
          """
        end

  See the `m:Snex#module-custom-interpreter` module documentation for more detail.
  '''
  use GenServer

  alias Snex.Internal
  alias Snex.Internal.Commands
  alias Snex.Internal.OSMonotonic
  alias Snex.Internal.Telemetry

  require Logger
  require Telemetry

  @request 0
  @response 1
  @default_init_script_timeout to_timeout(minute: 1)

  @typedoc """
  Running instance of `Snex.Interpreter`.
  """
  @type server :: GenServer.server()

  @typep command :: Commands.Init.t() | Commands.MakeEnv.t() | Commands.Eval.t()
  @typep request_id :: binary()
  @typep timestamps :: %{optional(atom() | String.t()) => OSMonotonic.timestamp()}

  # credo:disable-for-next-line
  alias __MODULE__, as: State
  defstruct [:port, :label, pending: %{}]

  @typep state :: %State{
           port: :erlang.port(),
           label: term(),
           pending: %{
             optional(request_id()) => %{client: GenServer.from(), timestamps: timestamps()}
           }
         }

  defmacro __using__(opts),
    do: Internal.CustomInterpreter.using(__CALLER__.module, opts)

  @typedoc """
  Options for `start_link/1`.
  """
  @type option ::
          {:python, String.t()}
          | {:cd, Path.t()}
          | {:environment, %{optional(String.t()) => String.t()}}
          | {:init_script, String.t()}
          | {:init_script_timeout, timeout()}
          | {:sync_start?, boolean()}
          | {:label, term()}
          | GenServer.option()

  @doc """
  Starts a new Python interpreter.

  The interpreter can be used by functions in the `Snex` module.

  ## Options

    - `:python` - The Python executable to use. This can be a full path or a command to find
      via `System.find_executable/1`.

    - `:cd` - The directory to change to before running the interpreter.

    - `:environment` - A map of environment variables to set when running the Python executable.

    - `:init_script` - A string of Python code to run when the interpreter is started.
      Failing to run the script will cause the process initialization to fail. The variable context
      left by the script will be the initial context for all `Snex.make_env/3` calls using this
      interpreter.

    - `:init_script_timeout` - The timeout for the init script. Can be a number of milliseconds
      or `:infinity`. Default: #{@default_init_script_timeout}.

    - `:sync_start?` - If `true`, the interpreter will start and run the init script in the init
      callback. Setting this to `false` is useful for long-running init scripts; the downside
      is that if something goes wrong, the interpreter process will start crashing after
      successfully starting as a part of the supervision tree. Default: `true`.

    - `:label` - The label of the interpreter process. This label will be used to label the process
      through `:proc_lib.set_label/1`. It will also be present in telemetry event metadata under
      `:interpreter_label` key.

    - any other options will be passed to `GenServer.start_link/3`.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {args, genserver_opts} =
      Keyword.split(opts, [
        :python,
        :cd,
        :environment,
        :init_script,
        :init_script_timeout,
        :sync_start?,
        :label
      ])

    GenServer.start_link(__MODULE__, args, genserver_opts)
  end

  @impl GenServer
  @spec init([option()]) ::
          {:ok, state()} | {:ok, state(), {:continue, {:init, [option()]}}}
  def init(opts) do
    label = opts[:label]

    if label != nil and function_exported?(:proc_lib, :set_label, 1),
      do: :proc_lib.set_label(label)

    with true <- !!Keyword.get(opts, :sync_start?, true),
         {:ok, port} <- init_python_port(opts) do
      {:ok, %State{label: label, port: port}}
    else
      false -> {:ok, %State{label: label}, {:continue, {:init, opts}}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  @spec handle_continue({:init, [option()]}, state()) ::
          {:noreply, state()}
  def handle_continue({:init, opts}, %State{} = state) do
    case init_python_port(opts) do
      {:ok, port} -> {:noreply, %State{state | port: port}}
      {:error, reason} -> {:stop, reason, state}
    end
  end

  @impl GenServer
  @spec handle_call({OSMonotonic.portable_timestamp(), command()}, GenServer.from(), state()) ::
          {:noreply, state()} | {:reply, {:error, any()}, state()}
  def handle_call({start_ts, command}, from, %State{} = state) do
    timestamps = %{start: OSMonotonic.from_portable_time(start_ts)}
    timestamps = timestamp(timestamps, :request_elixir_received)

    id = run_command(command, state.port)
    timestamps = timestamp(timestamps, :request_sent_to_python)

    pending = Map.put(state.pending, id, %{client: from, timestamps: timestamps})
    {:noreply, %State{state | pending: pending}}
  rescue
    e -> {:reply, {:error, e}, state}
  end

  @impl GenServer
  @spec handle_info(any(), state()) ::
          {:noreply, state()} | {:stop, {:exit_status, non_neg_integer()}, state()}
  def handle_info(
        {port, {:data, <<id::binary-size(16), @response, data::binary>>}},
        %State{port: port} = state
      ) do
    {pending_entry, pending} = Map.pop(state.pending, id)

    case pending_entry do
      %{client: client, timestamps: timestamps} ->
        timestamps = timestamp(timestamps, :response_received)

        {result, python_timestamps} = decode_reply(data, port)
        timestamps = timestamp(timestamps, :response_decoded)
        timestamps = Map.merge(timestamps, python_timestamps)

        GenServer.reply(client, %Telemetry.Result{
          value: result,
          extra_measurements: telemetry_measurements(timestamps),
          stop_metadata: %{interpreter_label: state.label}
        })

      nil ->
        Logger.warning("Received data for unknown request #{inspect(id)} #{inspect(data)}")
    end

    {:noreply, %State{state | pending: pending}}
  end

  def handle_info(
        {port, {:data, <<_id::binary-size(16), @request, data::binary>>}},
        %State{port: port} = state
      ) do
    case Snex.Serde.decode(data) do
      {:ok, %{"command" => "send", "to" => to, "data" => data}} ->
        send(to, data)
    end

    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %State{port: port} = state) do
    {:stop, {:exit_status, status}, state}
  end

  def handle_info(message, %State{} = state) do
    Logger.warning("Received unexpected message: #{inspect(message)}")
    {:noreply, state}
  end

  defp init_python_port(opts) do
    Telemetry.with_span [:snex, :interpreter, :init],
      start_meta: %{interpreter_label: opts[:label]},
      start_time_var: start_time do
      timestamps = %{start: start_time}

      port = do_init_python_port(opts)
      timestamps = timestamp(timestamps, :port_opened)

      with {:ok, init_script_timestamps} <- run_init_script(port, opts) do
        timestamps = Map.merge(timestamps, init_script_timestamps)

        %Telemetry.Result{
          value: {:ok, port},
          extra_measurements: telemetry_measurements(timestamps),
          stop_metadata: %{interpreter_label: opts[:label]}
        }
      end
    end
  end

  defp do_init_python_port(opts) do
    python = System.find_executable(opts[:python] || "python")
    snex_pythonpath = Internal.Paths.snex_pythonpath()

    pythonpath =
      case opts[:environment]["PYTHONPATH"] || System.get_env("PYTHONPATH") do
        nil -> snex_pythonpath
        pythonpath -> "#{snex_pythonpath}:#{pythonpath}"
      end

    environment =
      opts
      |> Keyword.get(:environment, %{})
      |> Map.put("PYTHONPATH", pythonpath)
      |> Enum.map(fn {key, value} -> {~c"#{key}", ~c"#{value}"} end)

    Port.open(
      {:spawn_executable, python},
      [
        :binary,
        :exit_status,
        :nouse_stdio,
        packet: 4,
        env: environment,
        args: ["-m", "snex"]
      ] ++ Keyword.take(opts, [:cd])
    )
  end

  defp run_init_script(port, opts) do
    id = run_command(%Commands.Init{code: opts[:init_script]}, port)
    timestamps = timestamp(:request_sent_to_python)

    init_script_timeout = Keyword.get(opts, :init_script_timeout, @default_init_script_timeout)

    receive do
      {^port, {:data, <<^id::binary, @response, response::binary>>}} ->
        timestamps = timestamp(timestamps, :response_received)

        {:ok, python_timestamps} = decode_reply(response, port)
        timestamps = timestamp(timestamps, :response_decoded)

        {:ok, Map.merge(timestamps, python_timestamps)}
    after
      init_script_timeout ->
        {:error, Snex.Error.exception(code: :init_script_timeout)}
    end
  end

  defp run_command(command, port) do
    id = :rand.bytes(16)
    data = Snex.Serde.encode_to_iodata!(command)
    Port.command(port, [id, @request, data])
    id
  end

  defp decode_reply(data, port) do
    case Snex.Serde.decode(data) do
      {:ok, reply} ->
        {reply_to_result(reply, port), reply["timestamps"]}

      {:error, reason} ->
        error =
          Snex.Error.exception(
            code: :internal_error,
            reason: {:result_decode_error, reason, data}
          )

        {{:error, error}, nil}
    end
  end

  defp reply_to_result(reply, port) do
    case reply do
      %{"status" => "ok"} ->
        :ok

      %{"status" => "ok_env", "id" => env_id} ->
        {:ok, Snex.Env.make(env_id, port, self())}

      %{"status" => "ok_value", "value" => value} ->
        {:ok, value}

      %{"status" => "error", "code" => code, "reason" => reason} = data ->
        error =
          Snex.Error.exception(
            # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
            code: String.to_atom(code),
            reason: reason,
            traceback: data["traceback"]
          )

        {:error, error}

      value ->
        error = Snex.Error.exception(code: :internal_error, reason: {:unknown_format, value})
        {:error, error}
    end
  end

  defp timestamp(timestamps \\ %{}, key),
    do: Map.put(timestamps, key, OSMonotonic.time())

  defp telemetry_measurements(timestamps) do
    for {measurement, start, stop} <- [
          {:port_open_duration, :start, :port_opened},
          {:request_elixir_queue_duration, :start, :request_elixir_received},
          {:request_encoding_duration, :port_opened, :request_sent_to_python},
          {:request_encoding_duration, :request_elixir_received, :request_sent_to_python},
          {:request_python_queue_duration, :request_sent_to_python, "request_python_dequeued"},
          {:request_decoding_duration, "request_python_dequeued", "request_decoded"},
          {:command_execution_duration, "request_decoded", "command_executed"},
          {:response_encoding_and_queue_duration, "command_executed", :response_received},
          {:response_decoding_duration, :response_received, :response_decoded}
        ],
        start = timestamps[start],
        stop = timestamps[stop],
        into: %{},
        do: {measurement, stop - start}
  end
end
