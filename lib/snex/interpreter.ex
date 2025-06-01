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

  require Logger

  @request 0
  @response 1

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
          | {:init_script, String.t()}
          | GenServer.option()

  @doc """
  Starts a new Python interpreter.

  The interpreter can be used by functions in the `Snex` module.

  ## Options

    * `:python` - The Python executable to use. This can be a full path or a command to \
      find via `System.find_executable/1`.
    * `:environment` - A map of environment variables to set when running the Python \
      executable.
    * `:init_script` - A string of Python code to run when the interpreter is started.
      Failing to run the script will cause the process initialization to fail. The variable
      context left by the script will be the initial context for all `Snex.make_env/3` calls
      using this interpreter.
    * any other options will be passed to `GenServer.start_link/3`.

  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {args, genserver_opts} = Keyword.split(opts, [:python, :environment, :init_script])
    GenServer.start_link(__MODULE__, args, genserver_opts)
  end

  @impl GenServer
  def init(opts) do
    python = System.find_executable(opts[:python])

    environment =
      opts
      |> Keyword.get(:environment, %{})
      |> Map.put_new_lazy("PYTHONPATH", fn -> System.get_env("PYTHONPATH", "") end)
      |> Map.update!("PYTHONPATH", &"#{:code.priv_dir(:snex)}:#{&1}")
      |> Enum.map(fn {key, value} -> {~c"#{key}", ~c"#{value}"} end)

    port =
      Port.open({:spawn_executable, python}, [
        :binary,
        :exit_status,
        :nouse_stdio,
        packet: 4,
        env: environment,
        args: ["-m", "snex"]
      ])

    id = run_command(%Commands.Init{code: opts[:init_script]}, port)

    receive do
      {^port, {:data, <<^id::binary, @response, response::binary>>}} ->
        :ok = decode_reply(response, port)
    end

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
  def handle_info(
        {port, {:data, <<id::binary-size(16), @response, data::binary>>}},
        %{port: port} = state
      ) do
    {client, pending} = Map.pop(state.pending, id)

    if client do
      result = decode_reply(data, port)
      GenServer.reply(client, result)
    else
      Logger.warning("Received data for unknown request #{inspect(id)} #{inspect(data)}")
    end

    {:noreply, %{state | pending: pending}}
  end

  def handle_info(
        {port, {:data, <<_id::binary-size(16), @request, data::binary>>}},
        %{port: port} = state
      ) do
    case Snex.Serde.decode(data) do
      {:ok, %{"command" => "send", "to" => to, "data" => data}} ->
        send(to, data)
    end

    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:stop, {:exit_status, status}, state}
  end

  def handle_info(message, state) do
    Logger.warning("Received unexpected message: #{inspect(message)}")
    {:noreply, state}
  end

  defp run_command(command, port) do
    id = :rand.bytes(16)
    data = Snex.Serde.encode_to_iodata!(command)
    Port.command(port, [id, @request, data])
    id
  end

  defp decode_reply(data, port) do
    case Snex.Serde.decode(data) do
      {:ok, %{"status" => "ok"}} ->
        :ok

      {:ok, %{"status" => "ok_env", "id" => env_id}} ->
        {:ok, Snex.Env.make(env_id, port, self())}

      {:ok, %{"status" => "ok_value", "value" => value}} ->
        {:ok, value}

      {:ok, %{"status" => "error", "code" => code, "reason" => reason, "traceback" => traceback}} ->
        # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
        code = String.to_atom(code)
        {:error, Snex.Error.exception(code: code, reason: reason, traceback: traceback)}

      {:ok, value} ->
        {:error, Snex.Error.exception(code: :internal_error, reason: {:unknown_format, value})}

      {:error, reason} ->
        {:error,
         Snex.Error.exception(code: :internal_error, reason: {:result_decode_error, reason, data})}
    end
  end
end
