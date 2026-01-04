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
  alias Snex.Internal.Command
  alias Snex.Internal.Commands

  require Logger

  @request 0
  @response 1
  @default_init_script_timeout to_timeout(minute: 1)

  @typedoc """
  Running instance of `Snex.Interpreter`.
  """
  @type server :: GenServer.server()

  @typep command ::
           Commands.Init.t()
           | Commands.MakeEnv.t()
           | Commands.Eval.t()
           | Commands.GC.t()
           | Commands.CallResponse.t()
           | Commands.CallErrorResponse.t()

  @typep request_id :: binary()

  # credo:disable-for-next-line
  alias __MODULE__, as: State
  defstruct [:port, pending: %{}, pending_tasks: %{}]

  @typep state :: %State{
           port: port(),
           pending: %{optional(request_id()) => %{client: GenServer.from()}},
           pending_tasks: %{optional(Task.ref()) => request_id()}
         }

  defmacro __using__(opts),
    do: Internal.CustomInterpreter.using(__CALLER__.module, opts)

  @typedoc """
  Options for `start_link/1`.
  """
  @type option ::
          {:python, String.t()}
          | {:wrap_exec, mfa() | (String.t(), [String.t()] -> {String.t(), [String.t()]})}
          | {:cd, Path.t()}
          | {:environment, %{optional(String.t()) => String.t()}}
          | {:init_script, String.t()}
          | {:init_script_timeout, timeout()}
          | {:sync_start?, boolean()}
          | {:label, term()}
          | GenServer.option()

  @doc false
  @spec command(server(), port(), command(), timeout()) ::
          {:ok, term()} | {:error, Snex.Error.t() | term()}
  def command(interpreter, port, command, timeout) do
    envs = Internal.Command.referenced_envs(command)

    id = generate_request_id()
    encoded_command = encode_command(command, id)
    request_id = :gen_server.send_request(interpreter, {:expect_reply, id})
    run_command(interpreter, port, encoded_command)

    case :gen_server.receive_response(request_id, timeout) do
      {:reply, reply} ->
        Snex.Env.touch(envs)
        decode_reply(reply)

      :timeout ->
        {:error, Snex.Error.exception(code: :response_timeout)}

      {:error, {reason, _server_ref}} ->
        {:error, Snex.Error.exception(code: :call_failed, reason: reason)}
    end
  end

  @doc false
  @spec command_noreply(server(), port(), request_id() | nil, command()) :: :ok
  def command_noreply(interpreter, port, id \\ nil, command) do
    envs = Internal.Command.referenced_envs(command)
    id = id || generate_request_id()
    encoded_command = encode_command(command, id)
    run_command(interpreter, port, encoded_command)
    Snex.Env.touch(envs)
  end

  @doc false
  @spec get_port(server()) :: port()
  def get_port(interpreter),
    do: GenServer.call(interpreter, :get_port)

  @doc """
  Returns the OS PID of the Python interpreter.
  """
  @spec os_pid(server()) :: non_neg_integer()
  def os_pid(interpreter),
    do: GenServer.call(interpreter, :os_pid)

  @doc """
  Stops the interpreter process with reason `reason`.

  Pending callers will return `{:error, %Snex.Error{code: :call_failed, reason: reason}}`.
  """
  @spec stop(server(), term(), timeout()) :: :ok
  def stop(interpreter, reason \\ :normal, timeout \\ :infinity),
    do: GenServer.stop(interpreter, reason, timeout)

  @doc """
  Starts a new Python interpreter.

  The interpreter can be used by functions in the `Snex` module.

  ## Options

    - `:python` - The Python executable to use. This can be a full path or a command to find
      via `System.find_executable/1`.

    - `:wrap_exec` - A function to wrap the Python executable and arguments. It can be given
      as an MFA or a function that takes two arguments: the Python executable path
      and its arguments. If given as MFA, the arguments will be appended to the A list.

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
        :wrap_exec,
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
    {label, opts} = Keyword.pop(opts, :label)

    if label != nil and function_exported?(:proc_lib, :set_label, 1),
      do: :proc_lib.set_label(label)

    with true <- !!Keyword.get(opts, :sync_start?, true),
         {:ok, port} <- init_python_port(opts) do
      {:ok, %State{port: port}}
    else
      false -> {:ok, %State{}, {:continue, {:init, opts}}}
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
  @spec handle_call(:get_port, GenServer.from(), state()) ::
          {:reply, port(), state()}
  def handle_call(:get_port, _from, %State{} = state),
    do: {:reply, state.port, state}

  @spec handle_call(:os_pid, GenServer.from(), state()) ::
          {:reply, non_neg_integer(), state()}
  def handle_call(:os_pid, _from, %State{port: port} = state) do
    {:os_pid, os_pid} = :erlang.port_info(port, :os_pid)
    {:reply, os_pid, state}
  end

  @spec handle_call({:expect_reply, request_id()}, GenServer.from(), state()) ::
          {:noreply, state()}
  def handle_call({:expect_reply, id}, from, %State{} = state) do
    pending = Map.put(state.pending, id, %{client: from})
    {:noreply, %State{state | pending: pending}}
  end

  @impl GenServer
  @spec handle_info({port(), {:data, binary()}}, state()) ::
          {:noreply, state()} | {:stop, {:exit_status, non_neg_integer()}, state()}
  def handle_info(
        {port, {:data, <<id::binary-size(16), @response, data::binary>>}},
        %State{port: port} = state
      )
      when is_map_key(state.pending, id) do
    {%{client: client}, pending} = Map.pop!(state.pending, id)
    GenServer.reply(client, data)
    {:noreply, %State{state | pending: pending}}
  end

  def handle_info(
        {port, {:data, <<id::binary-size(16), @request, data::binary>>}},
        %State{port: port} = state
      ) do
    task =
      Task.Supervisor.async_nolink(Snex.Internal.TaskSupervisor, fn ->
        case Snex.Serde.decode(data) do
          {:ok, %{"command" => cmd, "module" => m, "function" => f, "args" => a, "node" => node}} ->
            result = call_or_cast(cmd, to_atom(m), to_atom(f), a, to_atom(node))
            (cmd == "call" && {:reply, result}) || :noreply

          other ->
            Logger.warning("Received unexpected request: #{inspect(other)}")
            :noreply
        end
      end)

    {:noreply, %State{state | pending_tasks: Map.put(state.pending_tasks, task.ref, id)}}
  end

  @spec handle_info({port(), {:exit_status, integer()}}, state()) ::
          {:stop, Snex.Error.t(), state()}
  def handle_info({port, {:exit_status, _status} = reason}, %State{port: port} = state) do
    {:stop, Snex.Error.exception(code: :interpreter_exited, reason: reason), state}
  end

  @spec handle_info({Task.ref(), term()}, state()) :: {:noreply, state()}
  def handle_info({ref, result}, state) when is_map_key(state.pending_tasks, ref) do
    Process.demonitor(ref, [:flush])
    {id, pending_tasks} = Map.pop!(state.pending_tasks, ref)

    case result do
      :noreply ->
        :ok

      {:reply, result} ->
        command_noreply(self(), state.port, id, %Commands.CallResponse{result: result})
    end

    {:noreply, %State{state | pending_tasks: pending_tasks}}
  end

  @spec handle_info({:DOWN, Task.ref(), term(), term(), term()}, state()) :: {:noreply, state()}
  def handle_info({:DOWN, ref, _, _, reason}, state) when is_map_key(state.pending_tasks, ref) do
    {id, pending_tasks} = Map.pop!(state.pending_tasks, ref)

    if id do
      command = %Commands.CallErrorResponse{reason: inspect(reason)}
      command_noreply(self(), state.port, id, command)
    end

    {:noreply, %State{state | pending_tasks: pending_tasks}}
  end

  @spec handle_info(any(), state()) :: {:noreply, state()}
  def handle_info(message, %State{} = state) do
    Logger.warning("Received unexpected message: #{inspect(message)}")
    {:noreply, state}
  end

  defp init_python_port(opts) do
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

    default_args = ["-m", "snex"]

    {exec, args} =
      case opts[:wrap_exec] do
        nil -> {python, default_args}
        {m, f, a} -> apply(m, f, a ++ [python, default_args])
        fun when is_function(fun, 2) -> fun.(python, default_args)
      end

    port =
      Port.open(
        {:spawn_executable, exec},
        [
          :binary,
          :exit_status,
          :nouse_stdio,
          packet: 4,
          env: environment,
          args: args
        ] ++ Keyword.take(opts, [:cd])
      )

    with :ok <- run_init_script(port, opts),
         do: {:ok, port}
  end

  defp run_init_script(port, opts) do
    command = %Commands.Init{code: opts[:init_script]}
    id = generate_request_id()
    encoded_command = encode_command(command, id)
    run_command(self(), port, encoded_command)

    init_script_timeout = Keyword.get(opts, :init_script_timeout, @default_init_script_timeout)

    receive do
      {^port, {:data, <<^id::binary, @response, response::binary>>}} ->
        :ok = decode_reply(response)

      {^port, {:exit_status, _status} = reason} ->
        {:error, Snex.Error.exception(code: :interpreter_exited, reason: reason)}
    after
      init_script_timeout ->
        {:error, Snex.Error.exception(code: :init_script_timeout)}
    end
  end

  defp run_command(interpreter, port, data) do
    case GenServer.whereis(interpreter) do
      owner when is_pid(owner) and node(owner) == node() ->
        send(port, {owner, {:command, data}})

      owner when is_pid(owner) ->
        node = node(owner)
        :erpc.cast(node, fn -> send(port, {owner, {:command, data}}) end)

      {name, node} ->
        :erpc.cast(node, fn -> send(port, {Process.whereis(name), {:command, data}}) end)
    end

    :ok
  end

  defp decode_reply(data) do
    case Snex.Serde.decode(data) do
      {:ok, reply} ->
        reply_to_result(reply)

      {:error, reason} ->
        error =
          Snex.Error.exception(
            code: :internal_error,
            reason: {:result_decode_error, reason, data}
          )

        {:error, error}
    end
  end

  defp reply_to_result(reply) do
    case reply do
      %{"status" => "ok"} ->
        :ok

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

  defp generate_request_id,
    do: :rand.bytes(16)

  defp encode_command(command, id),
    do: [id, @request, Command.encode(command)]

  defp call_or_cast(_command, m, f, a, node) when node in [nil, node()],
    do: apply(m, f, a)

  defp call_or_cast("cast", m, f, a, node),
    do: Task.Supervisor.start_child({Snex.Internal.TaskSupervisor, node}, m, f, a)

  defp call_or_cast("call", m, f, a, node) do
    Task.Supervisor.async({Snex.Internal.TaskSupervisor, node}, m, f, a)
    |> Task.await(:infinity)
  end

  # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
  defp to_atom(value) when is_binary(value), do: String.to_atom(value)
  defp to_atom(value) when is_atom(value), do: value
end
